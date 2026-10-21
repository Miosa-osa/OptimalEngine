defmodule OptimalEngine.Connectors.HTTP do
  @moduledoc """
  Thin wrapper around `:httpc` for connector adapters.

  We deliberately avoid pulling in `Req` / `Finch` / `HTTPoison`: the
  engine is an Elixir app consumed as a library, and each extra
  dependency widens the attack surface for downstream users.

  What this module gives you beyond `:httpc`:

    * JSON request + response handling
    * Uniform `{:ok, %{status, headers, body}}` / `{:error, reason}` shape
    * Automatic `Retry-After` extraction on 429
    * Adapter-owned rate-limit bucket via `RateLimit.wait/4`
    * A single seam for `Mox` in tests — see `request/2`

  Swap to Finch in Phase 10 when pooling becomes critical. The public
  API is designed so callers won't change.
  """

  alias OptimalEngine.Connectors.RateLimit

  @default_timeout 10_000

  @type method :: :get | :post | :put | :delete | :patch
  @type headers :: [{String.t(), String.t()}]
  @type body :: map() | binary() | nil
  @type request_opts :: keyword()
  @type response :: %{status: non_neg_integer(), headers: headers(), body: any()}

  @doc """
  Make an HTTP request. Options:

    * `:method`         — `:get | :post | :put | :delete | :patch` (default `:get`)
    * `:headers`        — list of `{name, value}`
    * `:body`           — map (will be JSON-encoded) or raw binary
    * `:timeout`        — ms (default 10_000)
    * `:follow_redirects` - follow a 3xx answer (default `false`: the redirect
      is handed back as the response, so a credential sent to one host is not
      sent on to another)
    * `:verify_tls`     - verify the server's certificate and host name against
      the system's roots for an https URL (default `false`: Erlang's own default)
    * `:max_body_bytes` - fail with `{:error, :response_too_large}` when the
      answer is longer than this (default: no limit)
    * `:single_attempt` - the request is sent once and no more (default
      `false`): `connection: close`, so it is never sent again on a kept-alive
      session the server closed, and `autoretry: 0`, so httpc does not send it a
      second time after an answer that names a `Retry-After` (see
      `autoretry_supported?/0`)
    * `:ratelimit`      — `{bucket_key, rate, burst}` to wait on before firing
    * `:parse_json`     — try to decode response body (default `true`)
  """
  @spec request(String.t(), request_opts()) :: {:ok, response()} | {:error, term()}
  def request(url, opts \\ []) when is_binary(url) do
    opts = opts |> header_strings() |> Keyword.put_new(:follow_redirects, false)

    with :ok <- maybe_wait_for_quota(opts),
         {:ok, raw} <- fire(url, opts) do
      {:ok, normalize(raw, opts)}
    end
  end

  @doc "Convenience GET with JSON-decoded body."
  @spec get_json(String.t(), request_opts()) :: {:ok, response()} | {:error, term()}
  def get_json(url, opts \\ []) do
    request(url, Keyword.put(opts, :method, :get))
  end

  @doc "Convenience POST with JSON-encoded body + JSON-decoded response."
  @spec post_json(String.t(), map(), request_opts()) :: {:ok, response()} | {:error, term()}
  def post_json(url, body, opts \\ []) when is_map(body) do
    opts = opts |> Keyword.put(:method, :post) |> Keyword.put(:body, body)
    request(url, opts)
  end

  @doc """
  The TLS options that make a request verify the server: its certificate
  against the system's roots, and its host name. Empty for a URL that is not
  https.
  """
  @spec ssl_options(String.t()) :: keyword()
  def ssl_options(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: "https"} ->
        [
          verify: :verify_peer,
          depth: 3,
          customize_hostname_check: [
            match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
          ]
        ] ++ cacerts()

      _other ->
        []
    end
  end

  defp cacerts do
    [cacerts: :public_key.cacerts_get()]
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  # ─── private ─────────────────────────────────────────────────────────────

  # A header value may be a held secret (`AccessToken`); it goes out, and into
  # a test's mock, as the string it stands for.
  defp header_strings(opts) do
    case Keyword.fetch(opts, :headers) do
      {:ok, headers} ->
        Keyword.put(opts, :headers, Enum.map(headers, fn {k, v} -> {k, header_value(v)} end))

      :error ->
        opts
    end
  end

  defp header_value(value) when is_binary(value), do: value

  defp header_value(%{__struct__: _} = secret),
    do: OptimalEngine.Connectors.AccessToken.reveal(secret)

  defp header_value(value), do: to_string(value)

  defp maybe_wait_for_quota(opts) do
    case Keyword.get(opts, :ratelimit) do
      nil -> :ok
      {bucket, rate, burst} -> RateLimit.wait(bucket, rate, burst, timeout: 5_000)
    end
  end

  defp fire(url, opts) do
    case Application.get_env(:optimal_engine, :http_mock) do
      nil -> fire_httpc(url, opts)
      mock_fn when is_function(mock_fn, 2) -> mock_fn.(url, opts)
    end
  end

  defp fire_httpc(url, opts) do
    method = Keyword.get(opts, :method, :get)
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    headers = build_headers(opts)

    # httpc takes the content type of a body apart from the other headers, so
    # the one the caller named is lifted out of them and handed over there.
    {headers, declared_type} =
      if method in [:get, :delete], do: {headers, nil}, else: pop_content_type(headers)

    headers =
      if Keyword.get(opts, :single_attempt, false),
        do: headers ++ [{"connection", "close"}],
        else: headers

    {content_type, body_payload} = encode_body(Keyword.get(opts, :body), declared_type)

    http_request =
      case method do
        :get -> {String.to_charlist(url), to_charlist_headers(headers)}
        :delete -> {String.to_charlist(url), to_charlist_headers(headers)}
        _ -> {String.to_charlist(url), to_charlist_headers(headers), content_type, body_payload}
      end

    http_opts =
      [{:timeout, timeout}, {:connect_timeout, timeout}] ++
        if(Keyword.get(opts, :follow_redirects, false), do: [], else: [{:autoredirect, false}]) ++
        retry_opts(opts) ++
        tls_opts(url, opts)

    case Keyword.get(opts, :max_body_bytes) do
      nil -> :httpc.request(method, http_request, http_opts, body_format: :binary)
      cap -> fire_capped(method, http_request, http_opts, cap, timeout)
    end
  end

  defp retry_opts(opts) do
    if Keyword.get(opts, :single_attempt, false) and autoretry_supported?(),
      do: [{:autoretry, 0}],
      else: []
  end

  @doc """
  Whether this Erlang/OTP's httpc takes `autoretry` (OTP 28.4 and later). An
  earlier httpc sends a request once more, after the delay, when the answer
  names a `Retry-After`, and has no option to stop it; it refuses an option it
  does not know, so `autoretry` is passed only where it is known.
  """
  @spec autoretry_supported?() :: boolean()
  def autoretry_supported? do
    otp = :erlang.system_info(:otp_release) |> to_string()
    file = Path.join([to_string(:code.root_dir()), "releases", otp, "OTP_VERSION"])

    with {:ok, text} <- File.read(file),
         [major | rest] <- text |> String.trim() |> String.split("."),
         {major, _} <- Integer.parse(major) do
      case rest do
        [minor | _] ->
          case Integer.parse(minor) do
            {minor, _} -> major > 28 or (major == 28 and minor >= 4)
            :error -> false
          end

        [] ->
          major > 28
      end
    else
      _unknown -> false
    end
  end

  defp tls_opts(url, opts) do
    if Keyword.get(opts, :verify_tls, false) do
      _ = Application.ensure_all_started(:ssl)

      case ssl_options(url) do
        [] -> []
        ssl -> [{:ssl, ssl}]
      end
    else
      []
    end
  end

  # Reads the answer as it arrives and stops at `cap` bytes. httpc streams only
  # a 200 or 206; any other answer arrives whole and is measured when it does.
  defp fire_capped(method, http_request, http_opts, cap, timeout) do
    request_opts = [body_format: :binary, sync: false, stream: :self]

    case :httpc.request(method, http_request, http_opts, request_opts) do
      {:ok, id} -> await(id, cap, timeout)
      {:error, _reason} = error -> error
    end
  end

  defp await(id, cap, timeout) do
    receive do
      {:http, {^id, :stream_start, headers}} ->
        stream(id, cap, timeout, headers, [], 0)

      {:http, {^id, {{_vsn, _status, _reason}, _headers, body} = raw}} ->
        if byte_size(body) > cap, do: {:error, :response_too_large}, else: {:ok, raw}

      {:http, {^id, {:error, reason}}} ->
        {:error, reason}
    after
      timeout ->
        :httpc.cancel_request(id)
        {:error, :timeout}
    end
  end

  defp stream(id, cap, timeout, headers, chunks, size) do
    receive do
      {:http, {^id, :stream, chunk}} ->
        size = size + byte_size(chunk)

        if size > cap do
          :httpc.cancel_request(id)
          flush(id)
          {:error, :response_too_large}
        else
          stream(id, cap, timeout, headers, [chunk | chunks], size)
        end

      {:http, {^id, :stream_end, trailers}} ->
        body = chunks |> Enum.reverse() |> IO.iodata_to_binary()
        {:ok, {{~c"HTTP/1.1", 200, ~c"OK"}, headers ++ trailers, body}}

      {:http, {^id, {:error, reason}}} ->
        {:error, reason}
    after
      timeout ->
        :httpc.cancel_request(id)
        flush(id)
        {:error, :timeout}
    end
  end

  defp flush(id) do
    receive do
      {:http, {^id, _message}} -> flush(id)
      {:http, {^id, _kind, _message}} -> flush(id)
    after
      0 -> :ok
    end
  end

  defp build_headers(opts) do
    [{"accept", "application/json"} | Keyword.get(opts, :headers, [])]
    |> Enum.uniq_by(fn {k, _} -> String.downcase(k) end)
  end

  defp pop_content_type(headers) do
    case Enum.split_with(headers, fn {k, _} -> String.downcase(k) == "content-type" end) do
      {[{_name, type} | _], rest} -> {rest, to_string(type)}
      {[], rest} -> {rest, nil}
    end
  end

  defp encode_body(nil, type), do: {content_type(type, "application/json"), ""}

  defp encode_body(bin, type) when is_binary(bin),
    do: {content_type(type, "application/octet-stream"), bin}

  defp encode_body(map, type) when is_map(map) do
    {content_type(type, "application/json"), Jason.encode!(map)}
  end

  defp content_type(nil, default), do: String.to_charlist(default)
  defp content_type(type, _default), do: String.to_charlist(type)

  defp to_charlist_headers(headers) do
    Enum.map(headers, fn {k, v} ->
      {String.to_charlist(k), v |> header_value() |> String.to_charlist()}
    end)
  end

  # :httpc returns {:ok, {{vsn, status, reason}, headers, body}}.
  # fire/2 returns that tuple directly; request/2 unwraps the {:ok, raw} via
  # a with-clause, so normalize receives the inner raw value: {{vsn...}, headers, body}.
  defp normalize({{_vsn, status, _reason}, resp_headers, raw_body}, opts) do
    headers = Enum.map(resp_headers, fn {k, v} -> {to_string(k), to_string(v)} end)
    body = maybe_decode(raw_body, headers, opts)
    %{status: status, headers: headers, body: body}
  end

  defp normalize({:error, reason}, _), do: {:error, reason}

  defp maybe_decode(body, headers, opts) do
    parse? = Keyword.get(opts, :parse_json, true)

    content_type =
      headers
      |> Enum.find(fn {k, _} -> String.downcase(k) == "content-type" end)
      |> case do
        {_, v} -> String.downcase(v)
        _ -> ""
      end

    if parse? and String.contains?(content_type, "json") do
      case Jason.decode(body) do
        {:ok, decoded} -> decoded
        _ -> body
      end
    else
      body
    end
  end

  @doc "Extract `Retry-After` seconds from response headers, if present."
  @spec retry_after(headers()) :: non_neg_integer() | nil
  def retry_after(headers) do
    headers
    |> Enum.find(fn {k, _} -> String.downcase(k) == "retry-after" end)
    |> case do
      {_, v} ->
        case Integer.parse(v) do
          {n, _} when n > 0 -> n * 1000
          _ -> nil
        end

      _ ->
        nil
    end
  end
end
