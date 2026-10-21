defmodule OptimalEngine.Connectors.Adapters.Fathom do
  @moduledoc """
  Fathom connector - recorded meetings with their summary, transcript and
  action items. One meeting becomes one Signal.

  Being registered under the `:fathom` kind is what makes the
  `meeting_archive` analysis in `OptimalEngine.Analyses` pull a workspace's
  Fathom meetings: that analysis runs every enabled connector of kind `zoom`,
  `teams` or `fathom` in the workspace.

  ## Required config keys
  None. Optional: `:lookback_days` (how far back a full sync reaches; default 90).

  ## Credentials
    * `:api_key` -- a Fathom API key, sent as the `X-Api-Key` header

  ## Content
  The summary first, then a `## Transcript` section with one `speaker: text`
  line per entry, then an `## Action items` list. The transcript text is kept
  verbatim, so a spoken commitment ("I will send it tomorrow") reaches
  `OptimalEngine.Operating.Loops.detect/2` exactly as it was said. The
  Signal's `created_at` is the recording start, so a relative due date such
  as "tomorrow" resolves against the day of the meeting, not the day of the
  sync. Every calendar invitee's email goes in `entities`.

  ## Cursor shape
  A string with one of three forms:

    * `nil` -- full sync: lists meetings created in the last `:lookback_days`
    * `"since:<iso8601>"` -- a watermark parked after a complete walk: lists
      meetings created after that instant
    * `"page:<since>|<created_after>|<next_cursor>"` -- a walk cut short at the
      page bound: resumes on Fathom's opaque `next_cursor`, then parks `since`

  One sync walks every page (Fathom's `next_cursor` is `null` on the last),
  bounded at 20 pages. Anything else is read as `nil`, which is safe because
  Signal ids are derived from the recording id.
  """

  use OptimalEngine.Connectors.Adapters.Base,
    kind: :fathom,
    display_name: "Fathom",
    auth_scheme: :token,
    required_keys: [],
    credential_keys: [:api_key],
    token_key: :api_key

  alias OptimalEngine.Connectors.HTTP

  @base_url "https://api.fathom.ai/external/v1"
  @page_size 100
  @max_pages 20
  @default_lookback_days 90
  @title_limit 120

  @impl true
  def sync(state, cursor) do
    headers = [{"X-Api-Key", pick(state, :api_key)}]
    started = DateTime.utc_now() |> DateTime.truncate(:second)
    {since, created_after, page_cursor} = resume_point(state, cursor, started)

    with {:ok, meetings, remaining} <- fetch_pages(created_after, page_cursor, headers) do
      {:ok, %{signals: to_signals(meetings), cursor: next_cursor(remaining, since, created_after)}}
    end
  end

  @impl true
  def transform(raw) when is_map(raw) do
    case present(raw["recording_id"]) do
      nil ->
        {:error, :missing_recording_id}

      recording_id ->
        ext_id = to_string(recording_id)
        started_at = Transform.parse_iso8601(raw["recording_start_time"] || raw["created_at"])

        {:ok,
         Transform.new_signal(%{
           id: Transform.signal_id(:fathom, ext_id),
           title: title(raw),
           content: build_content(raw),
           path: Transform.source_uri(:fathom, ext_id),
           genre: "meeting",
           mode: :linguistic,
           format: :markdown,
           entities: invitee_emails(raw),
           created_at: started_at,
           modified_at: started_at
         })}
    end
  end

  def transform(_raw), do: {:error, :invalid_payload}

  # ---- paging -------------------------------------------------------------------

  # Walks the list page by page. Returns the meetings and the cursor still
  # unread (`nil` once Fathom reports the last page).
  defp fetch_pages(created_after, page_cursor, headers) do
    fetch_pages(created_after, page_cursor, headers, [], 0)
  end

  defp fetch_pages(_created_after, page_cursor, _headers, pages, count)
       when count >= @max_pages do
    {:ok, flatten_pages(pages), page_cursor}
  end

  defp fetch_pages(created_after, page_cursor, headers, pages, count) do
    case HTTP.get_json(list_url(created_after, page_cursor), headers: headers) do
      {:ok, %{status: 200, body: %{} = body}} ->
        pages = [List.wrap(body["items"]) | pages]

        case present(body["next_cursor"]) do
          nil -> {:ok, flatten_pages(pages), nil}
          next -> fetch_pages(created_after, next, headers, pages, count + 1)
        end

      {:ok, %{status: 200}} ->
        {:error, :bad_response}

      {:ok, response} ->
        {:error, error_reason(response)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp flatten_pages(pages), do: pages |> Enum.reverse() |> Enum.concat()

  # The `include_*` flags are what make the list carry the summary, transcript
  # and action items; Fathom leaves all three out by default.
  defp list_url(created_after, page_cursor) do
    "#{@base_url}/meetings?limit=#{@page_size}" <>
      "&include_transcript=true&include_summary=true&include_action_items=true" <>
      if(page_cursor, do: "&cursor=#{URI.encode_www_form(page_cursor)}", else: "") <>
      "&created_after=#{URI.encode_www_form(created_after)}"
  end

  defp error_reason(%{status: status}) when status in [401, 403], do: :auth_expired

  defp error_reason(%{status: 429, headers: headers}) do
    case HTTP.retry_after(headers) do
      nil -> :rate_limited
      retry_after_ms -> {:rate_limited, retry_after_ms}
    end
  end

  defp error_reason(%{status: status}) when status >= 500, do: :transient
  defp error_reason(%{status: status}), do: {:http, status}

  # ---- cursor -------------------------------------------------------------------

  # {the watermark to park after a complete walk, the `created_after` filter,
  # the Fathom cursor to start from}.
  defp resume_point(state, cursor, started) do
    case parse_cursor(cursor) do
      {:since, instant} -> {iso(started), instant, nil}
      {:page, since, created_after, page_cursor} -> {since, created_after, page_cursor}
      :full -> {iso(started), iso(DateTime.add(started, -lookback_days(state) * 86_400)), nil}
    end
  end

  defp parse_cursor("since:" <> instant) do
    if iso8601?(instant), do: {:since, instant}, else: :full
  end

  defp parse_cursor("page:" <> rest) do
    with [since, created_after, page_cursor] when page_cursor != "" <-
           String.split(rest, "|", parts: 3),
         true <- iso8601?(since) and iso8601?(created_after) do
      {:page, since, created_after, page_cursor}
    else
      _ -> :full
    end
  end

  defp parse_cursor(_cursor), do: :full

  defp next_cursor(nil, since, _created_after), do: "since:" <> since

  defp next_cursor(page_cursor, since, created_after),
    do: "page:#{since}|#{created_after}|#{page_cursor}"

  defp lookback_days(state) do
    case pick(state, :lookback_days, @default_lookback_days) do
      days when is_integer(days) and days > 0 ->
        days

      days when is_binary(days) ->
        case Integer.parse(days) do
          {n, ""} when n > 0 -> n
          _ -> @default_lookback_days
        end

      _ ->
        @default_lookback_days
    end
  end

  defp iso(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)

  defp iso8601?(value) do
    match?({:ok, _datetime, _offset}, DateTime.from_iso8601(value))
  end

  # ---- signals ------------------------------------------------------------------

  defp title(raw) do
    title = present(raw["meeting_title"]) || present(raw["title"]) || "Fathom meeting"
    String.slice(title, 0, @title_limit)
  end

  defp to_signals(meetings) do
    Enum.flat_map(meetings, fn meeting ->
      case transform(meeting) do
        {:ok, signal} -> [signal]
        _ -> []
      end
    end)
  end

  defp build_content(raw) do
    [summary_section(raw), transcript_section(raw), action_items_section(raw)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  defp summary_section(%{"default_summary" => %{"markdown_formatted" => summary}}),
    do: present(summary)

  defp summary_section(_raw), do: nil

  defp transcript_section(%{"transcript" => [_ | _] = transcript}) do
    lines =
      for %{"text" => text} = entry <- transcript, present(text) != nil do
        "#{speaker_name(entry)}: #{String.trim(text)}"
      end

    if lines == [], do: nil, else: "## Transcript\n\n" <> Enum.join(lines, "\n")
  end

  defp transcript_section(_raw), do: nil

  defp speaker_name(%{"speaker" => %{"display_name" => name}}) when is_binary(name) do
    present(name) || "Unknown"
  end

  defp speaker_name(_entry), do: "Unknown"

  defp action_items_section(%{"action_items" => [_ | _] = items}) do
    lines =
      for %{"description" => description} = item <- items, present(description) != nil do
        mark = if item["completed"] == true, do: "x", else: " "
        "- [#{mark}] #{String.trim(description)}"
      end

    if lines == [], do: nil, else: "## Action items\n\n" <> Enum.join(lines, "\n")
  end

  defp action_items_section(_raw), do: nil

  defp invitee_emails(%{"calendar_invitees" => invitees}) when is_list(invitees) do
    invitees
    |> Enum.flat_map(fn
      %{"email" => email} -> [present(email)]
      _ -> []
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp invitee_emails(_raw), do: []

  # A value worth using: not nil and, for text, not blank.
  defp present(nil), do: nil

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      _ -> value
    end
  end

  defp present(value), do: value
end
