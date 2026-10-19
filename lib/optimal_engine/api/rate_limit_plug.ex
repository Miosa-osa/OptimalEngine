defmodule OptimalEngine.API.RateLimitPlug do
  @moduledoc """
  Plug that enforces per-key token-bucket rate limiting on the HTTP API.

  It runs after `OptimalEngine.API.AuthPlug`, so the key that identifies a
  request has already been verified.

  ## Bucket key resolution

  1. `conn.assigns[:current_api_key].id` when an authenticated API key is present.
  2. The request's peer IP address as a string, for unauthenticated requests
     only (no key on an Engine that does not require one).

  A request with an invalid, revoked or expired key never reaches this plug:
  `AuthPlug` refuses it and charges the peer IP's bucket through
  `unauthenticated/1`, answering 429 instead of 401 once that bucket is empty.
  A forged key can therefore never spend a real key's bucket.

  ## Rate limit values

  Priority (highest to lowest), read on every request so runtime
  configuration applies:

  1. `api_key.metadata["rate_limit_per_minute"]`: per-key override; the key's
     bucket holds that many requests and refills at that rate.
  2. Explicit plug options `:default_capacity` and `:default_per_minute`.
  3. `config :optimal_engine, :api_rate_limit, default_capacity: ..., default_per_minute: ...`.
  4. The size profile (OptimalEngine.Sizing): 300 to 6,000 requests per minute
     per key by profile, or `config :optimal_engine, :api_per_minute`.

  ## Response headers

  On every allowed request:
    - `X-RateLimit-Limit`     - capacity (burst size)
    - `X-RateLimit-Remaining` - tokens remaining (as an integer)
    - `X-RateLimit-Reset`     - Unix timestamp (seconds) when bucket will be full

  On a rate-limited request the plug halts and returns:
    - HTTP 429 with `Content-Type: application/json`
    - Body: `{"error":"rate_limited","retry_after_ms":N}`
    - `Retry-After: <seconds>` header

  ## Exempt paths

  Paths listed in `exempt_paths` (default `["/api/status", "/api/health",
  "/api/metrics/prometheus"]`, also reached as `/v1/...`) are passed through
  without consuming a token.

  ## Usage

      plug OptimalEngine.API.AuthPlug
      plug OptimalEngine.API.RateLimitPlug,
        exempt_paths: ["/api/status", "/api/health", "/api/metrics/prometheus"]
  """

  @behaviour Plug

  import Plug.Conn

  alias OptimalEngine.API.RateLimiter

  @default_exempt ["/api/status", "/api/health", "/api/metrics/prometheus"]

  # ── Plug callbacks ───────────────────────────────────────────────────────────

  @impl Plug
  def init(opts) do
    # Plug.Builder calls init/1 at compile time, so only explicit options are
    # kept here; application config and the size profile are read per request.
    %{
      default_capacity: Keyword.get(opts, :default_capacity),
      default_per_minute: Keyword.get(opts, :default_per_minute),
      exempt_paths: Keyword.get(opts, :exempt_paths, @default_exempt)
    }
  end

  @impl Plug
  def call(conn, config) do
    if exempt?(conn, config.exempt_paths) do
      conn
    else
      enforce(conn, config)
    end
  end

  @doc """
  Charges the peer IP's bucket for a request that failed authentication.

  Returns `{:ok, conn}` while the bucket has tokens (the caller then answers
  401) and `{:halt, conn}` with a 429 already sent once it is empty. Exempt
  paths are never charged.
  """
  @spec unauthenticated(Plug.Conn.t()) :: {:ok, Plug.Conn.t()} | {:halt, Plug.Conn.t()}
  def unauthenticated(conn) do
    config = init([])

    if exempt?(conn, config.exempt_paths) do
      {:ok, conn}
    else
      {capacity, per_minute} = default_limits(config)

      case RateLimiter.check("ip:#{peer_ip(conn)}", capacity, per_minute) do
        :ok -> {:ok, conn}
        limited -> {:halt, send_rate_limited(conn, limited, capacity)}
      end
    end
  end

  # ── Private ─────────────────────────────────────────────────────────────────

  defp exempt?(conn, exempt_paths) do
    conn.request_path in exempt_paths
  end

  defp enforce(conn, config) do
    {bucket_key, capacity, per_minute} = resolve_bucket(conn, config)

    case RateLimiter.check(bucket_key, capacity, per_minute) do
      :ok -> put_success_headers(conn, capacity, per_minute)
      limited -> send_rate_limited(conn, limited, capacity)
    end
  end

  defp send_rate_limited(
         conn,
         {:rate_limited, retry_after_ms, remaining: 0, reset_at: reset_at},
         capacity
       ) do
    conn
    |> put_resp_content_type("application/json")
    |> put_resp_header("retry-after", to_string(div(retry_after_ms, 1_000) + 1))
    |> put_resp_header("x-ratelimit-limit", to_string(capacity))
    |> put_resp_header("x-ratelimit-remaining", "0")
    |> put_resp_header("x-ratelimit-reset", monotonic_to_unix(reset_at))
    |> send_resp(429, Jason.encode!(%{error: "rate_limited", retry_after_ms: retry_after_ms}))
    |> halt()
  end

  # Returns `{bucket_key, capacity, per_minute}`.
  defp resolve_bucket(conn, config) do
    api_key = conn.assigns[:current_api_key]

    bucket_key =
      if api_key && api_key.id do
        "key:#{api_key.id}"
      else
        "ip:#{peer_ip(conn)}"
      end

    {capacity, per_minute} = resolve_limits(api_key, config)
    {bucket_key, capacity, per_minute}
  end

  defp resolve_limits(api_key, config) do
    case key_limit(api_key) do
      limit when is_integer(limit) -> {limit, limit}
      nil -> default_limits(config)
    end
  end

  # A key's own allowance, set at mint time in its metadata.
  defp key_limit(nil), do: nil

  defp key_limit(api_key) do
    case Map.get(api_key, :metadata) do
      %{"rate_limit_per_minute" => limit} when is_integer(limit) and limit > 0 -> limit
      _ -> nil
    end
  end

  defp default_limits(config) do
    app = Application.get_env(:optimal_engine, :api_rate_limit) || []
    profile_rate = OptimalEngine.Sizing.tuning(:api_per_minute)

    {config.default_capacity || Keyword.get(app, :default_capacity) || profile_rate,
     config.default_per_minute || Keyword.get(app, :default_per_minute) || profile_rate}
  end

  defp peer_ip(conn) do
    case Plug.Conn.get_peer_data(conn) do
      %{address: addr} when is_tuple(addr) ->
        addr |> :inet.ntoa() |> to_string()

      _ ->
        "unknown"
    end
  end

  defp put_success_headers(conn, capacity, per_minute) do
    # Estimate remaining tokens without a second ETS read; the caller already
    # consumed one, so we report capacity - 1 as a conservative bound.
    # Accurate remaining counts would need a second lookup — not worth it.
    remaining = max(0, capacity - 1)

    # Monotonic time when the bucket would be full if empty right now.
    now_ms = System.monotonic_time(:millisecond)
    full_in_ms = trunc(capacity / (per_minute / 60_000.0))
    reset_unix = monotonic_to_unix(now_ms + full_in_ms)

    conn
    |> put_resp_header("x-ratelimit-limit", to_string(capacity))
    |> put_resp_header("x-ratelimit-remaining", to_string(remaining))
    |> put_resp_header("x-ratelimit-reset", reset_unix)
  end

  # Convert a monotonic timestamp (ms) to a Unix epoch second string.
  # Monotonic time has no absolute meaning; we offset it against the
  # current wall/monotonic delta to get a wall-clock value.
  defp monotonic_to_unix(monotonic_ms) do
    wall_now_s = System.system_time(:second)
    mono_now_ms = System.monotonic_time(:millisecond)
    delta_s = div(monotonic_ms - mono_now_ms, 1_000)
    to_string(wall_now_s + delta_s)
  end
end
