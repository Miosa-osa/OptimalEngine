defmodule OptimalEngine.Connectors.Adapters.JotForm do
  @moduledoc """
  JotForm connector -- form submissions.

  ## Required config keys
    * `:form_ids` -- list of form ids to read; an empty list means every form
      the API key can see
    * optional `:max_pages` -- submission pages fetched per run across all
      forms (default 20)

  ## Credentials
    * `:api_key` -- a JotForm API key, sent as the `apiKey` query parameter
      (the API takes no bearer header)

  ## Cursor shape
  Opaque string: `"<form_id>:<offset>"`, the form and the submission offset to
  fetch next. Initial sync: `nil`.

  A run walks the forms in order, paging each by `offset`, until it reaches the
  end or spends its page bound. At the bound the cursor names the next form and
  offset, so the following run resumes there. At the end the cursor is `nil`
  and the following run starts over: signal ids are deterministic, so replaying
  a page does not create duplicates.

  JotForm answers HTTP 200 and reports the real outcome in the body's
  `responseCode`, so both are mapped to the Runner's error categories.
  """

  use OptimalEngine.Connectors.Adapters.Base,
    kind: :jot_form,
    display_name: "JotForm",
    auth_scheme: :token,
    required_keys: [:form_ids],
    credential_keys: [:api_key],
    token_key: :api_key

  alias OptimalEngine.Connectors.{AccessToken, HTTP}

  @base_url "https://api.jotform.com"
  @page_size 100
  @max_pages 20

  @impl true
  def sync(state, cursor) do
    key = URI.encode_www_form(AccessToken.reveal(pick(state, :api_key)))

    with {:ok, form_ids} <- form_ids(state, key) do
      {forms, offset} = resume_position(form_ids, cursor)
      walk(key, forms, offset, [], max_pages(state))
    end
  end

  @impl true
  def transform(raw) when is_map(raw) do
    ext_id = external_id(raw)
    form_id = external_id(raw["form_id"])
    answers = answer_lines(raw["answers"])
    created = parse_time(raw["created_at"])

    {:ok,
     Transform.new_signal(%{
       id: Transform.signal_id(:jot_form, ext_id),
       title: title(form_id, ext_id),
       content:
         Enum.map_join(answers, "\n", fn {label, values} ->
           "#{label}: #{Enum.join(values, ", ")}"
         end),
       path: Transform.source_uri(:jot_form, ext_id),
       genre: "form_submission",
       entities:
         answers
         |> Enum.flat_map(fn {_label, values} -> values end)
         |> Enum.filter(&email?/1)
         |> Enum.uniq(),
       created_at: created,
       modified_at: parse_time(raw["updated_at"], created)
     })}
  end

  # ---- private ----------------------------------------------------------------

  # `acc` holds signals newest first.
  defp walk(_key, [], _offset, acc, _budget), do: finish(acc, nil)
  defp walk(_key, [form_id | _rest], offset, acc, 0), do: finish(acc, "#{form_id}:#{offset}")

  defp walk(key, [form_id | rest] = forms, offset, acc, budget) do
    with {:ok, submissions, next_offset} <- fetch_submissions(key, form_id, offset) do
      acc =
        Enum.reduce(submissions, acc, fn submission, signals ->
          case transform(Map.put_new(submission, "form_id", form_id)) do
            {:ok, signal} -> [signal | signals]
            _ -> signals
          end
        end)

      case next_offset do
        nil -> walk(key, rest, 0, acc, budget - 1)
        next -> walk(key, forms, next, acc, budget - 1)
      end
    end
  end

  defp finish(acc, cursor), do: {:ok, %{signals: Enum.reverse(acc), cursor: cursor}}

  # Returns the page's submissions and the offset of the next page, or `nil`
  # when this was the last one. A page is the last when it holds fewer records
  # than the limit the server applied, which is the limit the response reports
  # (it can be lower than the one requested).
  defp fetch_submissions(key, form_id, offset) do
    url =
      "#{@base_url}/form/#{encode_segment(form_id)}/submissions" <>
        "?apiKey=#{key}&limit=#{@page_size}&offset=#{offset}"

    with {:ok, content, limit} <- get_content(url) do
      count = length(content)
      next_offset = if count > 0 and count >= limit, do: offset + count

      {:ok, Enum.filter(content, &is_map/1), next_offset}
    end
  end

  defp form_ids(state, key) do
    case configured_form_ids(pick(state, :form_ids)) do
      [] -> list_form_ids(key, nil, [], @max_pages)
      ids -> {:ok, ids}
    end
  end

  defp configured_form_ids(ids) when is_list(ids) do
    ids
    |> Enum.filter(&(is_binary(&1) or is_integer(&1)))
    |> Enum.map(&(&1 |> to_string() |> String.trim()))
    |> Enum.reject(&(&1 == ""))
  end

  defp configured_form_ids(ids) when is_binary(ids),
    do: ids |> String.split(~r/[\s,]+/, trim: true)

  defp configured_form_ids(_ids), do: []

  # Every form the key can see, paged like the submissions are. The first page
  # carries no offset.
  defp list_form_ids(_key, _offset, acc, 0), do: {:ok, Enum.reverse(acc)}

  defp list_form_ids(key, offset, acc, budget) do
    url =
      "#{@base_url}/user/forms?apiKey=#{key}&limit=#{@page_size}" <>
        if(offset, do: "&offset=#{offset}", else: "")

    with {:ok, content, limit} <- get_content(url) do
      ids = for %{"id" => id} <- content, is_binary(id) or is_integer(id), do: to_string(id)
      acc = Enum.reverse(ids, acc)
      count = length(content)

      if count > 0 and count >= limit do
        list_form_ids(key, (offset || 0) + count, acc, budget - 1)
      else
        {:ok, Enum.reverse(acc)}
      end
    end
  end

  # Resume at the form named in the cursor. A cursor whose form is no longer in
  # the list (or that does not parse) starts the walk over.
  defp resume_position(form_ids, nil), do: {form_ids, 0}

  defp resume_position(form_ids, cursor) when is_binary(cursor) do
    with [form_id, offset] <- String.split(cursor, ":", parts: 2),
         {offset, ""} when offset >= 0 <- Integer.parse(offset),
         [_ | _] = remaining <- Enum.drop_while(form_ids, &(&1 != form_id)) do
      {remaining, offset}
    else
      _ -> {form_ids, 0}
    end
  end

  defp resume_position(form_ids, _cursor), do: {form_ids, 0}

  defp max_pages(state) do
    case pick(state, :max_pages) do
      n when is_integer(n) and n > 0 -> n
      _ -> @max_pages
    end
  end

  # One GET. Returns `{:ok, content, limit}`, where `limit` is the page size the
  # server applied.
  defp get_content(url) do
    case HTTP.get_json(url) do
      {:ok, %{status: 200, body: %{"responseCode" => code}}}
      when is_integer(code) and code != 200 ->
        status_error(code)

      {:ok, %{status: 200, body: %{"content" => content} = body}} when is_list(content) ->
        {:ok, content, applied_limit(body)}

      {:ok, %{status: 200}} ->
        {:error, {:unexpected_response, 200}}

      {:ok, %{status: status}} ->
        status_error(status)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp applied_limit(%{"resultSet" => %{"limit" => limit}}) when is_integer(limit) and limit > 0,
    do: limit

  defp applied_limit(_body), do: @page_size

  defp status_error(status) when status in [401, 403], do: {:error, :auth_expired}
  defp status_error(429), do: {:error, :rate_limited}
  defp status_error(status) when status >= 500, do: {:error, :transient}
  defp status_error(status), do: {:error, {:http, status}}

  # ---- submissions ------------------------------------------------------------

  # The answered questions in form order, as `{label, [value]}`. Unanswered
  # questions (headings, buttons, blank fields) carry no value and are dropped.
  defp answer_lines(answers) when is_map(answers) do
    answers
    |> Enum.filter(fn {_qid, entry} -> is_map(entry) end)
    |> Enum.sort_by(fn {qid, entry} -> {question_order(qid, entry), qid} end)
    |> Enum.flat_map(fn {qid, entry} ->
      case answer_values(entry) do
        [] -> []
        values -> [{label(qid, entry), values}]
      end
    end)
  end

  defp answer_lines(_answers), do: []

  defp question_order(qid, entry) do
    Enum.find_value([entry["order"], qid], 1_000_000, &parse_int/1)
  end

  defp parse_int(value) when is_integer(value), do: value

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp parse_int(_value), do: nil

  defp label(qid, entry) do
    Enum.find_value([entry["text"], entry["name"]], qid, fn
      value when is_binary(value) ->
        case Transform.strip_html(value) do
          "" -> nil
          text -> text
        end

      _other ->
        nil
    end)
  end

  # Structured answers (a name, an address) come with a ready `prettyFormat`;
  # everything else is flattened to its text values.
  defp answer_values(%{"answer" => answer} = entry) do
    case entry["prettyFormat"] do
      pretty when is_map(answer) and is_binary(pretty) and pretty != "" -> [String.trim(pretty)]
      _ -> flatten(answer)
    end
  end

  defp answer_values(_entry), do: []

  defp flatten(value) when is_binary(value) do
    case String.trim(value) do
      "" -> []
      trimmed -> [trimmed]
    end
  end

  defp flatten(value) when is_number(value), do: [to_string(value)]
  defp flatten(value) when is_list(value), do: Enum.flat_map(value, &flatten/1)
  defp flatten(value) when is_map(value), do: value |> Map.values() |> Enum.flat_map(&flatten/1)
  defp flatten(_value), do: []

  # A value that is an email address on its own, not free text that mentions one.
  defp email?(value), do: Regex.match?(~r/^[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}$/, value)

  # JotForm reports "2026-10-26 09:00:00" with no zone; it is read as UTC.
  defp parse_time(value, fallback \\ nil)

  defp parse_time(value, fallback) when is_binary(value) do
    value = String.trim(value)

    value =
      if Regex.match?(~r/(Z|[+-]\d{2}:?\d{2})$/i, value), do: value, else: value <> "Z"

    Transform.parse_iso8601(value, fallback)
  end

  defp parse_time(_value, fallback), do: Transform.parse_iso8601(nil, fallback)

  defp title("", ext_id), do: "Form submission #{ext_id}"
  defp title(form_id, ext_id), do: "Form #{form_id} submission #{ext_id}"

  defp external_id(%{"id" => id}), do: external_id(id)
  defp external_id(id) when is_binary(id), do: id
  defp external_id(id) when is_integer(id), do: Integer.to_string(id)
  defp external_id(_id), do: ""

  defp encode_segment(segment), do: URI.encode(segment, &URI.char_unreserved?/1)
end
