defmodule OptimalEngine.Connectors.Adapters.Gmail do
  @moduledoc """
  Gmail connector -- messages, threads, labels, attachments.

  ## Required config keys
    * `:user_email`, `:labels` (list of label names to sync; default all)
    * optional `:exclude_categories` -- Gmail tabs left out (default
      `["promotions", "social", "updates", "forums"]`; `[]` reads every tab).
      Spam, trash and drafts are never read.

  ## What a message becomes
  Each message is fetched in full: the Signal's title is the subject, its
  content is a From / To / Cc / Date / Subject header block followed by the
  text body (the text/plain part, else the text/html part reduced to text,
  cut at 20,000 characters), and it is dated when the mail arrived.

  ## Credentials
    * `:oauth_refresh_token` -- long-lived OAuth2 refresh token
    * `:client_id`, `:client_secret` -- Google app credentials

  ## Cursor shape
  Opaque: a Gmail `historyId`. Initial sync: `nil` -> full fetch bounded
  by `:initial_lookback_days` (default 30).
  """

  use OptimalEngine.Connectors.Adapters.Base,
    kind: :gmail,
    display_name: "Gmail",
    auth_scheme: :oauth2,
    required_keys: [:user_email],
    credential_keys: [:oauth_refresh_token, :client_id, :client_secret]

  alias OptimalEngine.Connectors.HTTP

  @token_url "https://oauth2.googleapis.com/token"
  @base_url "https://gmail.googleapis.com/gmail/v1/users/me"
  @page_size 100
  @max_pages 20
  @default_excluded_categories ~w(promotions social updates forums)
  @skipped_labels ~w(SPAM TRASH DRAFT)
  @max_body_chars 20_000

  @impl true
  def sync(state, cursor) do
    with {:ok, access_token} <- refresh_access_token(state) do
      headers = [{"authorization", "Bearer #{access_token}"}]

      case cursor do
        nil -> full_sync(state, headers)
        history_id -> incremental_sync(history_id, state, headers)
      end
    end
  end

  @impl true
  def transform(raw) when is_map(raw) do
    ext_id = raw["id"] || ""
    subject = get_header(raw, "Subject")
    from = get_header(raw, "From") || ""
    received_at = Transform.parse_epoch(raw["internalDate"])

    header_block =
      [
        {"From", from},
        {"To", get_header(raw, "To")},
        {"Cc", get_header(raw, "Cc")},
        {"Date", get_header(raw, "Date")},
        {"Subject", subject}
      ]
      |> Enum.reject(fn {_name, value} -> value in [nil, ""] end)
      |> Enum.map_join("\n", fn {name, value} -> "#{name}: #{value}" end)

    {:ok,
     Transform.new_signal(%{
       id: Transform.signal_id(:gmail, ext_id),
       title: String.slice(subject || "(no subject)", 0, 120),
       content: join_nonempty([header_block, body_text(raw)], "\n\n"),
       path: Transform.source_uri(:gmail, ext_id),
       genre: "email",
       mode: :linguistic,
       entities: extract_addresses(from),
       created_at: received_at,
       modified_at: received_at
     })}
  end

  # A record that is not a message is not a crash: every adapter answers with the
  # same error shape for something it cannot read.
  def transform(_raw), do: {:error, :invalid_payload}

  # ---- private ----------------------------------------------------------------

  defp refresh_access_token(state) do
    body = %{
      "grant_type" => "refresh_token",
      "refresh_token" => pick(state, :oauth_refresh_token),
      "client_id" => pick(state, :client_id),
      "client_secret" => pick(state, :client_secret)
    }

    case HTTP.post_json(@token_url, body) do
      {:ok, %{status: 200, body: %{"access_token" => token}}} -> {:ok, token}
      {:ok, %{status: 401}} -> {:error, :auth_expired}
      # A revoked refresh token comes back as a 400 naming invalid_grant, which
      # is an auth failure rather than a malformed request.
      {:ok, %{status: 400, body: body}} -> revoked_or(body)
      {:ok, %{status: 429}} -> {:error, :rate_limited}
      {:ok, %{status: status}} when status >= 500 -> {:error, :transient}
      {:ok, %{body: body}} -> {:error, {:token_error, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp revoked_or(body) do
    if body |> inspect() |> String.contains?("invalid_grant"),
      do: {:error, :auth_expired},
      else: {:error, {:token_error, body}}
  end

  # The initial pull walks every page of the message list, then parks the
  # cursor on the mailbox's current `historyId` (from the profile), which is
  # the shape the next run's incremental sync needs. Leaving the cursor on a
  # list `pageToken` would make the next run poll `history?startHistoryId=<page
  # token>` and fall back to a full sync on the 404.
  defp full_sync(state, headers) do
    lookback = pick(state, :initial_lookback_days, 30)

    after_ts =
      DateTime.utc_now()
      |> DateTime.add(-lookback * 86_400, :second)
      |> DateTime.to_unix()

    query = "after:#{after_ts}"
    labels = pick(state, :labels, [])

    query =
      if labels != [] do
        label_q = labels |> Enum.map(&"label:#{&1}") |> Enum.join(" OR ")
        "#{query} (#{label_q})"
      else
        query
      end

    query =
      state
      |> excluded_categories()
      |> Enum.reduce(query, &"#{&2} -category:#{&1}")

    with {:ok, message_stubs} <- fetch_all_messages(query, headers),
         {:ok, cursor} <- current_history_id(headers) do
      enrich_and_return(message_stubs, cursor, headers, state)
    end
  end

  defp fetch_all_messages(query, headers) do
    fetch_all_messages(query, nil, headers, [], 0)
  end

  defp fetch_all_messages(_query, _page_token, _headers, acc, page) when page >= @max_pages do
    {:ok, acc}
  end

  defp fetch_all_messages(query, page_token, headers, acc, page) do
    url =
      "#{@base_url}/messages?maxResults=#{@page_size}&q=#{URI.encode_www_form(query)}" <>
        if(page_token, do: "&pageToken=#{page_token}", else: "")

    case HTTP.get_json(url, headers: headers) do
      {:ok, %{status: 200, body: body}} ->
        messages = acc ++ (body["messages"] || [])

        case body["nextPageToken"] do
          nil -> {:ok, messages}
          next -> fetch_all_messages(query, next, headers, messages, page + 1)
        end

      {:ok, %{status: 401}} ->
        {:error, :auth_expired}

      {:ok, %{status: 429}} ->
        {:error, :rate_limited}

      {:ok, %{status: status}} ->
        {:error, {:http, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # `historyId` is a cursor into the mailbox's change log, not a page token: it
  # is a property of the mailbox, not of the listing we just finished.
  defp current_history_id(headers) do
    case HTTP.get_json("#{@base_url}/profile", headers: headers) do
      {:ok, %{status: 200, body: %{"historyId" => history_id}}} -> {:ok, history_id}
      {:ok, %{status: 401}} -> {:error, :auth_expired}
      {:ok, %{status: 429}} -> {:error, :rate_limited}
      {:ok, %{status: status}} -> {:error, {:http, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp incremental_sync(history_id, state, headers) do
    url = "#{@base_url}/history?startHistoryId=#{history_id}&historyTypes=messageAdded"

    case HTTP.get_json(url, headers: headers) do
      {:ok, %{status: 200, body: body}} ->
        messages =
          (body["history"] || [])
          |> Enum.flat_map(fn h -> h["messagesAdded"] || [] end)
          |> Enum.map(fn %{"message" => m} -> m end)

        next_cursor = body["historyId"] || history_id
        enrich_and_return(messages, next_cursor, headers, state)

      {:ok, %{status: 404}} ->
        # A history id older than the mailbox's retention window. Start over
        # from a full sync, keeping this run's state so the lookback window and
        # the label filter still apply.
        full_sync(state, headers)

      {:ok, %{status: 401}} ->
        {:error, :auth_expired}

      {:ok, %{status: 429}} ->
        {:error, :rate_limited}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # A message can go missing between the list and the fetch, which is not a
  # failure. Any other failure is one: reporting it as a smaller batch would
  # advance the cursor past messages that were never read, and the history they
  # are only listed in is gone by the next run. Failing the sync leaves the
  # cursor where it was, so nothing is skipped.
  defp enrich_and_return(message_stubs, next_cursor, headers, state) do
    skipped = skipped_labels(state)

    message_stubs
    |> Enum.reduce_while({:ok, []}, fn %{"id" => id}, {:ok, acc} ->
      case fetch_message(id, headers) do
        {:ok, msg} ->
          # The history log names every added message, whatever its tab or
          # folder, so the filter the list query applies is applied here too.
          with false <- Enum.any?(msg["labelIds"] || [], &(&1 in skipped)),
               {:ok, signal} <- transform(msg) do
            {:cont, {:ok, [signal | acc]}}
          else
            _skipped_or_invalid -> {:cont, {:ok, acc}}
          end

        {:error, {:http, 404}} ->
          {:cont, {:ok, acc}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, signals} -> {:ok, %{signals: Enum.reverse(signals), cursor: next_cursor}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_message(id, headers) do
    # The full format carries every header and the body. (A comma-separated
    # `metadataHeaders` value is ignored by Gmail and returns no headers.)
    url = "#{@base_url}/messages/#{id}?format=full"

    case HTTP.get_json(url, headers: headers) do
      {:ok, %{status: 200, body: msg}} -> {:ok, msg}
      {:ok, %{status: 401}} -> {:error, :auth_expired}
      {:ok, %{status: 429}} -> {:error, :rate_limited}
      {:ok, %{status: status}} when status >= 500 -> {:error, :transient}
      {:ok, %{status: status}} -> {:error, {:http, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  # Header names are case-insensitive (RFC 5322).
  defp get_header(%{"payload" => %{"headers" => headers}}, name) when is_list(headers) do
    wanted = String.downcase(name)

    Enum.find_value(headers, fn
      %{"name" => header, "value" => value} when is_binary(header) ->
        if String.downcase(header) == wanted, do: value

      _ ->
        nil
    end)
  end

  defp get_header(_, _), do: nil

  # The text/plain part, else the text/html part reduced to text, else the
  # snippet; cut to a bounded size.
  defp body_text(raw) do
    payload = raw["payload"] || %{}

    text =
      case find_part(payload, "text/plain") do
        nil ->
          case find_part(payload, "text/html") do
            nil -> Transform.strip_html(raw["snippet"] || raw["body"] || "")
            html -> Transform.strip_html(html)
          end

        plain ->
          plain
      end

    text
    |> String.replace("\r\n", "\n")
    |> String.replace(~r/\n{3,}/, "\n\n")
    |> String.trim()
    |> String.slice(0, @max_body_chars)
  end

  defp find_part(%{"mimeType" => mime, "body" => %{"data" => data}}, mime) when is_binary(data) do
    case Base.url_decode64(data, padding: false) do
      {:ok, text} -> if String.valid?(text), do: text
      :error -> nil
    end
  end

  defp find_part(%{"parts" => parts}, mime) when is_list(parts),
    do: Enum.find_value(parts, &find_part(&1, mime))

  defp find_part(_part, _mime), do: nil

  defp join_nonempty(pieces, separator) do
    pieces |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join(separator)
  end

  defp excluded_categories(state) do
    case pick(state, :exclude_categories) do
      nil -> @default_excluded_categories
      list when is_list(list) -> Enum.map(list, &(&1 |> to_string() |> String.downcase()))
      _other -> @default_excluded_categories
    end
  end

  defp skipped_labels(state) do
    @skipped_labels ++
      Enum.map(excluded_categories(state), &("CATEGORY_" <> String.upcase(&1)))
  end

  defp extract_addresses(header) when is_binary(header) do
    Regex.scan(~r/[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}/, header)
    |> Enum.flat_map(& &1)
  end

  defp extract_addresses(_), do: []
end
