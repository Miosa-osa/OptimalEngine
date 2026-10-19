defmodule OptimalEngine.Connectors.Adapters.Gmail do
  @moduledoc """
  Gmail connector -- messages, threads, labels, attachments.

  ## Required config keys
    * `:user_email`, `:labels` (list of label names to sync; default all)

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
    subject = get_header(raw, "Subject") || "(no subject)"
    from = get_header(raw, "From") || ""

    {:ok,
     Transform.new_signal(%{
       id: Transform.signal_id(:gmail, ext_id),
       title: String.slice(subject, 0, 120),
       content: Transform.strip_html(raw["snippet"] || raw["body"] || ""),
       path: Transform.source_uri(:gmail, ext_id),
       genre: "email",
       mode: :linguistic,
       entities: extract_addresses(from),
       modified_at: Transform.parse_epoch(raw["internalDate"])
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

    with {:ok, message_stubs} <- fetch_all_messages(query, headers),
         {:ok, cursor} <- current_history_id(headers) do
      enrich_and_return(message_stubs, cursor, headers)
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
        enrich_and_return(messages, next_cursor, headers)

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
  defp enrich_and_return(message_stubs, next_cursor, headers) do
    message_stubs
    |> Enum.reduce_while({:ok, []}, fn %{"id" => id}, {:ok, acc} ->
      case fetch_message(id, headers) do
        {:ok, msg} ->
          case transform(msg) do
            {:ok, signal} -> {:cont, {:ok, [signal | acc]}}
            {:error, _reason} -> {:cont, {:ok, acc}}
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
    url = "#{@base_url}/messages/#{id}?format=metadata&metadataHeaders=Subject,From,Date"

    case HTTP.get_json(url, headers: headers) do
      {:ok, %{status: 200, body: msg}} -> {:ok, msg}
      {:ok, %{status: 401}} -> {:error, :auth_expired}
      {:ok, %{status: 429}} -> {:error, :rate_limited}
      {:ok, %{status: status}} when status >= 500 -> {:error, :transient}
      {:ok, %{status: status}} -> {:error, {:http, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp get_header(%{"payload" => %{"headers" => headers}}, name) when is_list(headers) do
    Enum.find_value(headers, fn
      %{"name" => ^name, "value" => v} -> v
      _ -> nil
    end)
  end

  defp get_header(_, _), do: nil

  defp extract_addresses(header) when is_binary(header) do
    Regex.scan(~r/[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}/, header)
    |> Enum.flat_map(& &1)
  end

  defp extract_addresses(_), do: []
end
