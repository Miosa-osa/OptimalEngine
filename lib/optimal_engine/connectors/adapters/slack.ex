defmodule OptimalEngine.Connectors.Adapters.Slack do
  @moduledoc """
  Slack connector -- the message history of channels.

  ## Required config keys
    * `:workspace_id`, `:channels` (list of channel ids; empty = every channel
      the bot can list)

  ## Optional config keys
    * `:max_pages` -- history pages (200 messages each) read per channel per run
      (default 10). A channel with more history is finished by the next run.

  ## Credentials
    * `:bot_token` -- starts with `xoxb-...`, or
    * an `:access_token` -- given directly or issued by the credential broker
      (`credential_source: "broker"`). Every Slack call goes through
      `OptimalEngine.Connectors.AccessToken`, which renews a brokered token
      before it expires and once after Slack refuses it.

  ## What is read
  The top-level messages of each channel (`conversations.history`). Thread
  replies, files and direct messages are not read yet.

  ## Cursor shape
  Opaque: a JSON object with one position per channel id. Initial sync: `nil`.
  A cursor this adapter did not write is read as `nil`, which starts over.

  `conversations.history` returns messages newest first; `oldest` and `latest`
  are exclusive bounds. A channel's position is:

    * `"oldest"` -- everything at or before this `ts` has been read, so the next
      run asks for messages after it.
    * `"latest"` and `"head"` -- present only while a run stopped part-way
      through the channel (its page budget ran out, or a request failed after
      the first page). Messages between `"oldest"` and `"latest"` are still
      unread, and `"head"` is the newest `ts` already read: the next run reads
      the gap and then moves `"oldest"` up to `"head"`.

  A rate limit or a server error part-way through the channel list stops the
  run but keeps what was read; the positions say exactly where each channel
  got to. When nothing was read yet the error is returned so the Runner can
  back off. An expired token always fails the whole run.
  """

  use OptimalEngine.Connectors.Adapters.Base,
    kind: :slack,
    display_name: "Slack",
    auth_scheme: :oauth2,
    required_keys: [:workspace_id, :channels],
    credential_keys: [:bot_token],
    access_token: true

  require Logger

  alias OptimalEngine.Connectors.{AccessToken, HTTP}

  @base_url "https://slack.com/api"
  @page_size 200
  @max_pages 10
  @max_list_pages 50
  @position_keys ["oldest", "latest", "head"]

  # Slack answers application errors with HTTP 200 and {"ok": false, "error": code}.
  @auth_errors ~w(invalid_auth not_authed token_expired token_revoked account_inactive)
  @transient_errors ~w(internal_error fatal_error service_unavailable request_timeout)
  # About one channel, not the connector: the bot is not a member, the channel is gone.
  @channel_errors ~w(channel_not_found not_in_channel access_denied method_not_supported_for_channel_type)

  @impl true
  def sync(state, cursor) do
    AccessToken.session(state, &bot_token/1, fn token ->
      with {:ok, channel_ids} <- channel_ids(pick(state, :channels, []), token) do
        pull_channels(channel_ids, decode_cursor(cursor), max_pages(state), token)
      end
    end)
  end

  @impl true
  def transform(raw) when is_map(raw) do
    ext_id = raw["client_msg_id"] || raw["ts"] || ""
    text = raw["text"] || ""
    user = raw["user"] || "slack-user"

    {:ok,
     Transform.new_signal(%{
       id: Transform.signal_id(:slack, ext_id),
       title: String.slice(text, 0, 80),
       content: text,
       path: Transform.source_uri(:slack, ext_id),
       genre: "message",
       entities: [user],
       modified_at: Transform.parse_epoch(raw["ts"])
     })}
  end

  defp bot_token(state), do: {:ok, pick(state, :bot_token)}

  # ---- channels ---------------------------------------------------------------

  defp channel_ids([], token), do: list_channels(nil, token, [], 1)

  defp channel_ids(ids, _token) when is_list(ids),
    do: {:ok, ids |> Enum.map(&to_string/1) |> Enum.uniq()}

  defp channel_ids(_other, _token), do: {:error, {:invalid_config, :channels}}

  # Follows `response_metadata.next_cursor` until Slack returns an empty one.
  defp list_channels(cursor, token, acc, page) do
    url =
      "#{@base_url}/conversations.list?types=public_channel,private_channel&limit=#{@page_size}" <>
        param("cursor", cursor)

    case call(url, token) do
      {:ok, body} ->
        ids = Enum.uniq(acc ++ Enum.map(body["channels"] || [], & &1["id"]))

        case next_page(body) do
          nil ->
            {:ok, ids}

          _next when page >= @max_list_pages ->
            Logger.warning("[Connectors.Slack] channel list cut at #{page} pages")
            {:ok, ids}

          next ->
            list_channels(next, token, ids, page + 1)
        end

      {:error, failure} ->
        {:error, failure_reason(failure)}
    end
  end

  defp next_page(%{"response_metadata" => %{"next_cursor" => next}})
       when is_binary(next) and next != "",
       do: next

  defp next_page(_body), do: nil

  defp failure_reason({:skip, code}), do: {:slack_error, code}
  defp failure_reason({_kind, reason}), do: reason

  # ---- the run ----------------------------------------------------------------

  # Reads the channels in order. The accumulator is the signals so far (in
  # reverse) and the cursor positions.
  defp pull_channels(channel_ids, positions, max_pages, token) do
    channel_ids
    |> Enum.reduce_while({:ok, {[], positions}}, fn ch_id, {:ok, {signals, acc_positions}} ->
      {messages, position, outcome} =
        pull_channel(ch_id, Map.get(positions, ch_id, %{}), max_pages, token)

      progress = {
        Enum.reduce(to_signals(messages), signals, &[&1 | &2]),
        put_position(acc_positions, ch_id, position)
      }

      case outcome do
        done when done in [:done, :more] ->
          {:cont, {:ok, progress}}

        {:skip, code} ->
          Logger.warning("[Connectors.Slack] skipped channel #{ch_id}: #{code}")
          {:cont, {:ok, progress}}

        {:retry, reason} ->
          {:halt, {:retry, reason, progress}}

        {:abort, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> finish()
  end

  defp finish({:ok, progress}), do: {:ok, result(progress)}
  defp finish({:error, reason}), do: {:error, reason}

  # Nothing was read before the rate limit or the server error, so there is
  # nothing to keep: the error goes to the Runner, which backs off and retries.
  defp finish({:retry, reason, {[], _positions}}), do: {:error, reason}

  defp finish({:retry, reason, progress}) do
    Logger.warning(
      "[Connectors.Slack] stopped early (#{inspect(reason)}); the next run resumes from the saved positions"
    )

    {:ok, result(progress)}
  end

  defp result({signals, positions}) do
    %{signals: Enum.reverse(signals), cursor: encode_cursor(positions)}
  end

  # One channel: the messages read (oldest first), the position to save, and how it ended.
  defp pull_channel(ch_id, position, max_pages, token) do
    {messages, outcome} =
      fetch_pages(ch_id, position["oldest"], position["latest"], max_pages, token, [])

    {Enum.reverse(messages), next_position(position, messages, outcome), outcome}
  end

  # Pages backwards from `latest` (or from now) down to `oldest`. `latest` is
  # the page-back bound: `oldest` only ever marks where to stop.
  defp fetch_pages(ch_id, oldest, latest, pages_left, token, acc) do
    case history_page(ch_id, oldest, latest, token) do
      {:ok, page, has_more?} ->
        acc = acc ++ page

        cond do
          not has_more? or page == [] -> {acc, :done}
          pages_left <= 1 -> {acc, :more}
          true -> fetch_pages(ch_id, oldest, oldest_ts(page), pages_left - 1, token, acc)
        end

      {:error, failure} ->
        {acc, failure}
    end
  end

  defp history_page(ch_id, oldest, latest, token) do
    url =
      "#{@base_url}/conversations.history?channel=#{URI.encode_www_form(ch_id)}&limit=#{@page_size}" <>
        param("oldest", oldest) <> param("latest", latest)

    with {:ok, body} <- call(url, token) do
      {:ok, body["messages"] || [], body["has_more"] == true}
    end
  end

  # The whole window was read: everything up to the newest `ts` seen is done.
  defp next_position(position, messages, :done) do
    case position["head"] || newest_ts(messages) do
      nil -> Map.drop(position, ["latest", "head"])
      ts -> %{"oldest" => ts}
    end
  end

  defp next_position(position, [], _unfinished), do: position

  # Stopped before the lower bound: park the gap, and keep the newest `ts`
  # seen so that closing the gap can move `oldest` past everything.
  defp next_position(position, messages, _unfinished) do
    position
    |> Map.put("latest", oldest_ts(messages))
    |> Map.put_new("head", newest_ts(messages))
  end

  # ---- requests ---------------------------------------------------------------

  # `{:ok, body}`, or `{:error, failure}` where failure says what the run should do:
  # `{:skip, code}` (this channel only), `{:retry, reason}` (stop, keep progress,
  # the Runner may back off), `{:abort, reason}` (fail the run).
  defp call(url, token) do
    case AccessToken.get_json(token, url, rejected?: &refused?/1) do
      {:ok, %{status: 200, body: %{"ok" => true} = body}} ->
        {:ok, body}

      {:ok, %{status: 200, body: %{"ok" => false, "error" => code}}} ->
        {:error, classify(code)}

      {:ok, %{status: 429, headers: response_headers}} ->
        {:error, {:retry, rate_limited(response_headers)}}

      {:ok, %{status: 401}} ->
        {:error, {:abort, :auth_expired}}

      {:ok, %{status: status}} when status >= 500 ->
        {:error, {:retry, :transient}}

      {:ok, %{status: status}} ->
        {:error, {:abort, {:http, status}}}

      {:error, _reason} ->
        {:error, {:retry, :transient}}
    end
  end

  # Slack refuses a token with a 200 that names the reason, not with a 401, so
  # a brokered token is renewed on either.
  defp refused?({:ok, %{status: 401}}), do: true

  defp refused?({:ok, %{status: 200, body: %{"ok" => false, "error" => code}}}),
    do: code in @auth_errors

  defp refused?(_response), do: false

  defp classify("ratelimited"), do: {:retry, :rate_limited}
  defp classify(code) when code in @auth_errors, do: {:abort, :auth_expired}
  defp classify(code) when code in @transient_errors, do: {:retry, :transient}
  defp classify(code) when code in @channel_errors, do: {:skip, code}
  defp classify(code), do: {:abort, {:slack_error, code}}

  defp rate_limited(headers) do
    case HTTP.retry_after(headers) do
      nil -> :rate_limited
      ms -> {:rate_limited, ms}
    end
  end

  defp param(_name, nil), do: ""
  defp param(name, value), do: "&#{name}=#{URI.encode_www_form(value)}"

  # ---- cursor -----------------------------------------------------------------

  defp decode_cursor(cursor) when is_binary(cursor) do
    case Jason.decode(cursor) do
      {:ok, %{} = positions} ->
        Map.new(positions, fn {ch_id, position} -> {ch_id, clean_position(position)} end)

      _ ->
        %{}
    end
  end

  defp decode_cursor(_cursor), do: %{}

  defp clean_position(%{} = position) do
    position
    |> Map.take(@position_keys)
    |> Enum.filter(fn {_key, ts} -> is_binary(ts) end)
    |> Map.new()
  end

  defp clean_position(_position), do: %{}

  defp encode_cursor(positions) when map_size(positions) == 0, do: nil
  defp encode_cursor(positions), do: Jason.encode!(positions)

  defp put_position(positions, ch_id, position) when map_size(position) == 0,
    do: Map.delete(positions, ch_id)

  defp put_position(positions, ch_id, position), do: Map.put(positions, ch_id, position)

  # ---- messages ---------------------------------------------------------------

  defp to_signals(messages) do
    Enum.flat_map(messages, fn msg ->
      case transform(msg) do
        {:ok, signal} -> [signal]
        _ -> []
      end
    end)
  end

  defp max_pages(state) do
    case pick(state, :max_pages) do
      n when is_integer(n) and n > 0 -> n
      _ -> @max_pages
    end
  end

  defp newest_ts(messages), do: messages |> timestamps() |> Enum.max_by(&ts_key/1, fn -> nil end)
  defp oldest_ts(messages), do: messages |> timestamps() |> Enum.min_by(&ts_key/1, fn -> nil end)

  defp timestamps(messages) do
    for %{"ts" => ts} <- messages, is_binary(ts), do: ts
  end

  # A Slack `ts` is "<seconds>.<microseconds>". Compared as numbers, not text.
  defp ts_key(ts) do
    [seconds | fraction] = String.split(ts, ".", parts: 2)
    micros = fraction |> List.first("") |> String.pad_trailing(6, "0")
    {to_int(seconds), to_int(micros)}
  end

  defp to_int(text) do
    case Integer.parse(text) do
      {n, _rest} -> n
      :error -> 0
    end
  end
end
