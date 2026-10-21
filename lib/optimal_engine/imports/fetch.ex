defmodule OptimalEngine.Imports.Fetch do
  @moduledoc """
  Downloads an import source named by URL to a file, under a byte cap.

  The Engine fetches the URL itself, so the URL is checked before any request:

    * `https` only, with the server's certificate and host name verified
    * the host must resolve only to public addresses: loopback, private,
      link-local, shared, multicast and reserved ranges are refused
    * no redirects are followed (a presigned object URL answers directly)

  An operator can allow internal hosts (and plain `http` to them) with
  `config :optimal_engine, :import_url_hosts, ["storage.internal"]` or the
  `OPTIMAL_IMPORT_URL_HOSTS` environment variable (comma-separated).

  The body is streamed to the file and the transfer is cancelled the moment it
  passes the cap, whatever `Content-Length` claimed.
  """

  import Bitwise

  @timeout_ms 600_000
  @connect_timeout_ms 15_000

  @doc """
  Checks a source URL without fetching it. Returns `:ok`,
  `{:error, :invalid_source_url}` for a URL that is not absolute `https` (or
  `http` to an allowed host), or `{:error, :source_url_refused}` for a host
  that resolves to a non-public address.
  """
  @spec check(String.t()) :: :ok | {:error, :invalid_source_url | :source_url_refused}
  def check(url) when is_binary(url) do
    with {:ok, uri} <- parse(url) do
      check_address(uri)
    end
  end

  def check(_url), do: {:error, :invalid_source_url}

  @doc """
  Downloads `url` to `dest`, refusing more than `max_bytes`. Returns
  `{:ok, bytes}` or `{:error, reason}`: `:invalid_source_url`,
  `:source_url_refused`, `:download_too_large`, `{:download_failed, detail}`.
  """
  @spec download(String.t(), Path.t(), pos_integer()) :: {:ok, non_neg_integer()} | {:error, term()}
  def download(url, dest, max_bytes) do
    with :ok <- check(url),
         {:ok, _} <- Application.ensure_all_started(:inets),
         {:ok, _} <- Application.ensure_all_started(:ssl) do
      {:ok, out} = File.open(dest, [:write, :binary, :raw])

      result =
        try do
          stream(url, out, max_bytes)
        after
          File.close(out)
        end

      with {:error, _} <- result, do: File.rm(dest)
      result
    end
  end

  defp stream(url, out, max_bytes) do
    {:ok, uri} = parse(url)

    http_opts = [
      timeout: @timeout_ms,
      connect_timeout: @connect_timeout_ms,
      autoredirect: false,
      ssl: ssl_opts(uri)
    ]

    case :httpc.request(
           :get,
           {String.to_charlist(url), []},
           http_opts,
           [sync: false, stream: :self],
           :default
         ) do
      {:ok, ref} -> receive_body(ref, out, 0, max_bytes)
      {:error, reason} -> {:error, {:download_failed, inspect(reason)}}
    end
  end

  defp receive_body(ref, out, bytes, max_bytes) do
    receive do
      {:http, {^ref, :stream_start, headers}} ->
        if declared(headers) > max_bytes do
          cancel(ref)
          {:error, :download_too_large}
        else
          receive_body(ref, out, bytes, max_bytes)
        end

      {:http, {^ref, :stream, chunk}} ->
        bytes = bytes + byte_size(chunk)

        if bytes > max_bytes do
          cancel(ref)
          {:error, :download_too_large}
        else
          :ok = IO.binwrite(out, chunk)
          receive_body(ref, out, bytes, max_bytes)
        end

      {:http, {^ref, :stream_end, _headers}} ->
        {:ok, bytes}

      {:http, {^ref, {{_version, status, _reason}, _headers, _body}}} ->
        {:error, {:download_failed, "http #{status}"}}

      {:http, {^ref, {:error, reason}}} ->
        {:error, {:download_failed, inspect(reason)}}
    after
      @timeout_ms ->
        cancel(ref)
        {:error, {:download_failed, "timeout"}}
    end
  end

  defp cancel(ref), do: :httpc.cancel_request(ref, :default)

  defp declared(headers) do
    Enum.find_value(headers, 0, fn {name, value} ->
      if String.downcase(to_string(name)) == "content-length" do
        case Integer.parse(to_string(value)) do
          {n, _} -> n
          :error -> 0
        end
      end
    end)
  end

  # ── checks ─────────────────────────────────────────────────────────────

  defp parse(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host} = uri when is_binary(host) and host != "" ->
        {:ok, uri}

      %URI{scheme: "http", host: host} = uri when is_binary(host) and host != "" ->
        if allowed_host?(host), do: {:ok, uri}, else: {:error, :invalid_source_url}

      _ ->
        {:error, :invalid_source_url}
    end
  end

  defp check_address(%URI{host: host}) do
    if allowed_host?(host) do
      :ok
    else
      case addresses(host) do
        [] -> {:error, :source_url_refused}
        ips -> if Enum.all?(ips, &public?/1), do: :ok, else: {:error, :source_url_refused}
      end
    end
  end

  defp addresses(host) do
    charlist = String.to_charlist(host)

    case :inet.parse_address(charlist) do
      {:ok, ip} ->
        [ip]

      {:error, _} ->
        for family <- [:inet, :inet6],
            {:ok, ips} <- [:inet.getaddrs(charlist, family)],
            ip <- ips,
            do: ip
    end
  end

  defp allowed_host?(host) do
    host = String.downcase(host)
    Enum.any?(allowed_hosts(), &(String.downcase(&1) == host))
  end

  defp allowed_hosts do
    configured = Application.get_env(:optimal_engine, :import_url_hosts, [])

    from_env =
      "OPTIMAL_IMPORT_URL_HOSTS"
      |> System.get_env("")
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)

    List.wrap(configured) ++ from_env
  end

  @doc "True for a public unicast address."
  @spec public?(:inet.ip_address()) :: boolean()
  def public?({a, b, c, _d}) do
    not (a == 0 or a == 10 or a == 127 or a >= 224 or
           (a == 100 and b >= 64 and b <= 127) or
           (a == 169 and b == 254) or
           (a == 172 and b >= 16 and b <= 31) or
           (a == 192 and b == 168) or
           (a == 192 and b == 0 and c in [0, 2]) or
           (a == 198 and (b == 18 or b == 19)) or
           (a == 198 and b == 51 and c == 100) or
           (a == 203 and b == 0 and c == 113))
  end

  def public?({0, 0, 0, 0, 0, 0xFFFF, hi, lo}),
    do: public?({hi >>> 8, hi &&& 0xFF, lo >>> 8, lo &&& 0xFF})

  def public?({first, _, _, _, _, _, _, _} = ip) do
    not (ip == {0, 0, 0, 0, 0, 0, 0, 0} or ip == {0, 0, 0, 0, 0, 0, 0, 1} or
           (first &&& 0xFE00) == 0xFC00 or (first &&& 0xFFC0) == 0xFE80 or
           (first &&& 0xFF00) == 0xFF00 or (first == 0x2001 and elem(ip, 1) == 0x0DB8))
  end

  defp ssl_opts(%URI{scheme: "https"}) do
    [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      depth: 4,
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]
  end

  defp ssl_opts(_uri), do: []
end
