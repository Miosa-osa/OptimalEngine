defmodule OptimalEngine.API.RateLimiter do
  @moduledoc """
  Token-bucket rate limiter for the HTTP API layer.

  With `OPTIMAL_VALKEY_URL` set, the buckets live in Valkey, so every Engine
  process behind one load balancer draws on one bucket per key; without it, or
  while Valkey is unreachable, they live in this node's ETS table
  (`OptimalEngine.Storage.Shared`). A single GenServer owns the ETS table and
  runs a periodic GC pass to evict local buckets that have been idle for more
  than one hour; Valkey expires its own. Hot-path checks never go through the
  GenServer.

  ## Bucket record layout (local)

      {key, {tokens :: float(), last_refill_at :: integer()}, expires_at :: integer()}

  Both times are `System.monotonic_time(:millisecond)`.

  ## Public API

      # Succeeds if a token was available; rate-limited otherwise.
      :ok = RateLimiter.check("api_key_abc", 200, 100)

      {:rate_limited, retry_after_ms, remaining: 0, reset_at: ts} =
        RateLimiter.check("anon_1.2.3.4", 200, 100)

  `capacity` is the burst capacity (max tokens in the bucket).
  `refill_per_minute` is the steady-state refill rate.
  """

  use GenServer
  require Logger

  alias OptimalEngine.Storage.Shared
  alias OptimalEngine.Storage.Shared.Local

  @table :optimal_api_rate_limit_buckets

  # Buckets idle for longer than this are collected.
  @gc_idle_threshold_ms 60 * 60 * 1_000

  # GC runs every 5 minutes.
  @gc_interval_ms 5 * 60 * 1_000

  # ── Child spec ──────────────────────────────────────────────────────────────

  @doc false
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent
    }
  end

  # ── Client API ──────────────────────────────────────────────────────────────

  @doc """
  Starts the rate limiter and creates its ETS table.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Check (and consume) one token from the bucket identified by `key`.

  - `capacity` — burst capacity; the maximum number of tokens the bucket may
    hold at any point in time.
  - `refill_per_minute` — steady-state token replenishment rate.

  Returns `:ok` on success (token consumed) or
  `{:rate_limited, retry_after_ms, remaining: 0, reset_at: monotonic_ms}`
  when the bucket is empty.

  With Valkey configured the bucket lives there (one bucket per key for every
  node, stepped atomically on the server's clock); otherwise, or while Valkey
  is unreachable, it is one `:ets.lookup` + `:ets.insert` on this node, with
  no GenServer message in the path (`OptimalEngine.Storage.Shared`).
  """
  @spec check(term(), pos_integer(), pos_integer()) ::
          :ok
          | {:rate_limited, non_neg_integer(), [remaining: 0, reset_at: integer()]}
  def check(key, capacity, refill_per_minute)
      when is_integer(capacity) and capacity > 0 and
             is_integer(refill_per_minute) and refill_per_minute > 0 do
    # Tokens replenished per millisecond.
    refill_rate_per_ms = refill_per_minute / 60_000.0

    case Shared.take_token(
           @table,
           key,
           capacity,
           refill_rate_per_ms,
           :keep,
           ttl(capacity, refill_rate_per_ms)
         ) do
      :ok ->
        :ok

      {:limited, tokens_now, elapsed_ms} ->
        # A denied check leaves the refill stamp where it was and reports the wait.
        needed = 1.0 - tokens_now
        retry_after_ms = ceil(needed / refill_rate_per_ms)

        # When the bucket will next have ≥1 token (monotonic ms).
        last_refill_at = System.monotonic_time(:millisecond) - elapsed_ms
        reset_at = last_refill_at + retry_after_ms

        {:rate_limited, retry_after_ms, remaining: 0, reset_at: reset_at}
    end
  end

  @doc "Delete all bucket state. Intended for tests only."
  @spec reset() :: :ok
  def reset do
    Local.new_table(@table)
    Shared.clear(@table)
  end

  # A bucket idle this long is dropped: it is full again by then, so dropping
  # it changes nothing a client sees.
  defp ttl(capacity, refill_rate_per_ms),
    do: max(@gc_idle_threshold_ms, ceil(capacity / refill_rate_per_ms) + 1_000)

  # ── GenServer callbacks ──────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    Local.new_table(@table)
    schedule_gc()
    Logger.debug("[RateLimiter] Started; ETS table #{@table} ready")
    {:ok, %{}}
  end

  @impl true
  def handle_info(:gc, state) do
    gc_stale_buckets()
    schedule_gc()
    {:noreply, state}
  end

  # ── Private ─────────────────────────────────────────────────────────────────

  defp schedule_gc do
    Process.send_after(self(), :gc, @gc_interval_ms)
  end

  # Only the local buckets: those on Valkey expire there.
  defp gc_stale_buckets do
    deleted = Local.sweep(@table)

    if deleted > 0 do
      Logger.debug("[RateLimiter] GC evicted #{deleted} stale buckets")
    end
  end
end
