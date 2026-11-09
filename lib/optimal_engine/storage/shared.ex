defmodule OptimalEngine.Storage.Shared do
  @moduledoc """
  The cache, counter, lock and rate-limit state the Engine's nodes share.

  With `OPTIMAL_VALKEY_URL` set, every operation here runs on Valkey through
  `OptimalEngine.Storage.Valkey.Pool`, so all the Engine processes that point
  at one Valkey see one rate-limit bucket per key, one key cache and one set
  of locks. Without it, or while Valkey is unreachable, the same operation runs
  on the node's own ETS (`OptimalEngine.Storage.Shared.Local`). Valkey being
  down never fails a request: a command that cannot be answered within the
  pool's timeout is answered locally instead, and the connection reconnects in
  the background. Nothing here is durable truth; all of it can be lost.

  ## What runs on it

    * `OptimalEngine.API.RateLimiter`: the HTTP API token buckets (`take_token/6`)
    * `OptimalEngine.Connectors.RateLimit`: outbound connector token buckets
    * `OptimalEngine.Auth.KeyCache`: which API key secrets bcrypt already verified
    * `OptimalEngine.Sync.GateCache`: the workspace scans a sync gate reuses

  ## Namespaces and keys

  A namespace is an atom, which is also the name of the local ETS table its
  owner creates with `Shared.Local.new_table/1`. On Valkey a key lives at
  `optimal:shared:<namespace>:<generation>:<key>`: a binary key as it is (when
  short and printable), any other term as the SHA-256 of its external form.
  `clear/1` moves the namespace's generation, so a clear is one command
  however many keys the namespace holds; the old keys expire on their own.
  Every key written carries a TTL.

  Cached values are Erlang terms, signed with an HMAC before they are written
  and checked when they are read, so a value Valkey hands back that this
  Engine did not write is a miss, not a term it trusts. The signing key comes
  from `CONNECTOR_KEY` when it is set (set the same one on every node that
  shares a Valkey and they share entries); without it each node signs with a
  key of its own and reads only its own entries.

  ## Invalidation during an outage

  `delete/2` and `clear/1` always apply locally. When Valkey cannot take them,
  they are deferred in the pool and applied, in order, before any later command
  reaches Valkey, so nothing deleted during an outage (a revoked API key) is
  read back from Valkey after it.

  Locks are leases: a holder that outlives its TTL loses the lock. While
  Valkey is down a lock is per node, as all locks were before.
  """

  alias OptimalEngine.Storage.Shared.Local
  alias OptimalEngine.Storage.Valkey.Pool

  @prefix "optimal:shared:"
  @max_plain_key 200

  # Each script starts by resolving the namespace's generation, so a clear is
  # one INCR. KEYS[1] is the generation key; ARGV[1] the namespace prefix and
  # ARGV[2] the key.
  @resolve """
  local g = redis.call('GET', KEYS[1]) or '0'
  local k = ARGV[1] .. g .. ':' .. ARGV[2]
  """

  @sources %{
    get: "-- optimal:get\n" <> @resolve <> "return redis.call('GET', k)\n",
    put:
      "-- optimal:put\n" <>
        @resolve <> "redis.call('SET', k, ARGV[3], 'PX', ARGV[4])\nreturn 1\n",
    del: "-- optimal:del\n" <> @resolve <> "return redis.call('DEL', k)\n",
    incr:
      "-- optimal:incr\n" <>
        @resolve <>
        """
        local n = redis.call('INCR', k)
        if n == 1 then redis.call('PEXPIRE', k, ARGV[3]) end
        return n
        """,
    lock:
      "-- optimal:lock\n" <>
        @resolve <>
        """
        if redis.call('SET', k, ARGV[3], 'NX', 'PX', ARGV[4]) then return 1 end
        return 0
        """,
    unlock:
      "-- optimal:unlock\n" <>
        @resolve <>
        """
        if redis.call('GET', k) == ARGV[3] then return redis.call('DEL', k) end
        return 0
        """,
    # The bucket of Shared.Local.take_token/6, on the server's clock. A
    # denied step answers the tokens it found and the time since the stamp;
    # with 'keep' it writes nothing, so no elapsed time is credited twice.
    bucket:
      "-- optimal:bucket\n" <>
        @resolve <>
        """
        local cap = tonumber(ARGV[3])
        local rate = tonumber(ARGV[4])
        local ttl = tonumber(ARGV[6])
        local t = redis.call('TIME')
        local now = tonumber(t[1]) * 1000 + math.floor(tonumber(t[2]) / 1000)
        local v = redis.call('HMGET', k, 'tokens', 'at')
        if not v[1] then
          redis.call('HSET', k, 'tokens', string.format('%.17g', cap - 1), 'at', string.format('%d', now))
          redis.call('PEXPIRE', k, ttl)
          return {1}
        end
        local at = tonumber(v[2])
        local elapsed = math.max(0, now - at)
        local current = math.min(cap, tonumber(v[1]) + elapsed * rate)
        if current >= 1 then
          redis.call('HSET', k, 'tokens', string.format('%.17g', current - 1), 'at', string.format('%d', now))
          redis.call('PEXPIRE', k, ttl)
          return {1}
        end
        if ARGV[5] ~= 'keep' then
          redis.call('HSET', k, 'tokens', string.format('%.17g', current), 'at', string.format('%d', now))
          redis.call('PEXPIRE', k, ttl)
        end
        return {0, string.format('%.17g', current), elapsed}
        """
  }

  @scripts Map.new(@sources, fn {name, source} ->
             {name, {Base.encode16(:crypto.hash(:sha, source), case: :lower), source}}
           end)

  @type namespace :: atom()

  @doc "`:valkey` while the pool has a connection up, otherwise `:local`."
  @spec backend() :: :valkey | :local
  def backend, do: if(Pool.serving?(), do: :valkey, else: :local)

  @doc "The value under `key`, or `:miss`."
  @spec get(namespace(), term()) :: {:ok, term()} | :miss
  def get(ns, key) do
    remote(
      fn ->
        case eval(:get, ns, key, []) do
          {:ok, nil} -> :miss
          {:ok, signed} when is_binary(signed) -> verify(ns, key, signed)
          _ -> :unavailable
        end
      end,
      fn -> Local.get(ns, key) end
    )
  end

  @doc "Stores `value` under `key` for `ttl_ms`. Options: `:max_entries` (local table)."
  @spec put(namespace(), term(), term(), pos_integer(), keyword()) :: :ok
  def put(ns, key, value, ttl_ms, opts \\ []) when is_integer(ttl_ms) and ttl_ms > 0 do
    remote(
      fn ->
        case eval(:put, ns, key, [sign(ns, key, value), Integer.to_string(ttl_ms)]) do
          {:ok, 1} -> :ok
          _ -> :unavailable
        end
      end,
      fn -> Local.put(ns, key, value, ttl_ms, opts) end
    )
  end

  @doc "Deletes `key` here and on Valkey (deferred while Valkey is unreachable)."
  @spec delete(namespace(), term()) :: :ok
  def delete(ns, key) do
    Local.delete(ns, key)
    invalidate({:delete, ns, key})
  end

  @doc "Drops every entry of the namespace here and on Valkey (deferred while unreachable)."
  @spec clear(namespace()) :: :ok
  def clear(ns) do
    Local.clear(ns)
    invalidate({:clear, ns})
  end

  @doc "Increments a counter that expires `ttl_ms` after it was created."
  @spec incr(namespace(), term(), pos_integer()) :: {:ok, integer()}
  def incr(ns, key, ttl_ms) when is_integer(ttl_ms) and ttl_ms > 0 do
    remote(
      fn ->
        case eval(:incr, ns, key, [Integer.to_string(ttl_ms)]) do
          {:ok, n} when is_integer(n) -> {:ok, n}
          _ -> :unavailable
        end
      end,
      fn -> Local.incr(ns, key, ttl_ms) end
    )
  end

  @doc """
  Takes a lease on `key` for `ttl_ms`. `{:ok, token}` for the holder, who
  passes the token to `unlock/3`; `{:error, :locked}` while someone holds it.
  """
  @spec lock(namespace(), term(), pos_integer()) :: {:ok, String.t()} | {:error, :locked}
  def lock(ns, key, ttl_ms) when is_integer(ttl_ms) and ttl_ms > 0 do
    token = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

    remote(
      fn ->
        case eval(:lock, ns, key, [token, Integer.to_string(ttl_ms)]) do
          {:ok, 1} -> {:ok, token}
          {:ok, 0} -> {:error, :locked}
          _ -> :unavailable
        end
      end,
      fn -> Local.lock(ns, key, token, ttl_ms) end
    )
  end

  @doc "Releases a lease taken with `lock/3`; a stale token releases nothing."
  @spec unlock(namespace(), term(), String.t()) :: :ok
  def unlock(ns, key, token) do
    Local.unlock(ns, key, token)

    if Pool.serving?(), do: eval(:unlock, ns, key, [token])
    :ok
  end

  @doc """
  One token-bucket step (see `Shared.Local.take_token/6`): `:ok` when a token
  was taken, otherwise `{:limited, tokens_now, elapsed_ms}`. On Valkey the
  bucket runs on the server's clock, atomically, so every node draws on it.
  """
  @spec take_token(namespace(), term(), pos_integer(), float(), :keep | :advance, pos_integer()) ::
          :ok | {:limited, float(), non_neg_integer()}
  def take_token(ns, key, capacity, refill_per_ms, deny, ttl_ms)
      when deny in [:keep, :advance] and is_integer(ttl_ms) and ttl_ms > 0 do
    remote(
      fn ->
        args = [
          Integer.to_string(capacity),
          :erlang.float_to_binary(refill_per_ms * 1.0, [:short]),
          Atom.to_string(deny),
          Integer.to_string(ttl_ms)
        ]

        case eval(:bucket, ns, key, args) do
          {:ok, [1]} -> :ok
          {:ok, [0, tokens, elapsed]} -> limited(tokens, elapsed)
          _ -> :unavailable
        end
      end,
      fn -> Local.take_token(ns, key, capacity, refill_per_ms, deny, ttl_ms) end
    )
  end

  @doc "The Valkey key a namespace and key resolve to under `generation`."
  @spec valkey_key(namespace(), term(), non_neg_integer()) :: String.t()
  def valkey_key(ns, key, generation \\ 0),
    do: namespace_prefix(ns) <> Integer.to_string(generation) <> ":" <> encode_key(key)

  # ---------------------------------------------------------------------------

  # Runs on Valkey when the pool has a connection up and every deferred
  # invalidation has been applied; anything Valkey cannot answer runs locally.
  defp remote(valkey_fun, local_fun) do
    with true <- Pool.serving?(),
         :ok <- Pool.flush(&apply_invalidation/1),
         result when result != :unavailable <- valkey_fun.() do
      result
    else
      _ -> local_fun.()
    end
  end

  defp invalidate(operation) do
    cond do
      not Pool.running?() ->
        :ok

      Pool.serving?() and Pool.flush(&apply_invalidation/1) == :ok and
          apply_invalidation(operation) == :ok ->
        :ok

      true ->
        Pool.defer(operation)
    end
  end

  defp apply_invalidation({:delete, ns, key}) do
    case eval(:del, ns, key, []) do
      {:ok, n} when is_integer(n) -> :ok
      other -> {:error, other}
    end
  end

  defp apply_invalidation({:clear, ns}) do
    case Pool.command(["INCR", generation_key(ns)]) do
      {:ok, n} when is_integer(n) -> :ok
      other -> {:error, other}
    end
  end

  defp eval(name, ns, key, args) do
    {sha, source} = Map.fetch!(@scripts, name)
    tail = ["1", generation_key(ns), namespace_prefix(ns), encode_key(key) | args]

    case Pool.command(["EVALSHA", sha | tail]) do
      {:error, {:server, "NOSCRIPT" <> _}} -> Pool.command(["EVAL", source | tail])
      other -> other
    end
  end

  defp limited(tokens, elapsed) when is_binary(tokens) and is_integer(elapsed) do
    case Float.parse(tokens) do
      {value, ""} -> {:limited, value, elapsed}
      _ -> :unavailable
    end
  end

  defp limited(_tokens, _elapsed), do: :unavailable

  defp namespace_prefix(ns), do: @prefix <> Atom.to_string(ns) <> ":"
  defp generation_key(ns), do: @prefix <> Atom.to_string(ns) <> ":gen"

  defp encode_key(key) when is_binary(key) and byte_size(key) <= @max_plain_key do
    if String.printable?(key) and not String.contains?(key, ["\r", "\n"]),
      do: "k:" <> key,
      else: hashed_key(key)
  end

  defp encode_key(key), do: hashed_key(key)

  defp hashed_key(key) do
    "h:" <>
      Base.encode16(:crypto.hash(:sha256, :erlang.term_to_binary(key, [:deterministic])),
        case: :lower
      )
  end

  # The MAC binds the value to its namespace and key, so a signed value cannot
  # be moved under another key either.
  defp sign(ns, key, value) do
    payload = :erlang.term_to_binary(value)
    mac(ns, key, payload) <> payload
  end

  defp verify(ns, key, <<mac::binary-size(32), payload::binary>>) do
    if Plug.Crypto.secure_compare(mac, mac(ns, key, payload)) do
      {:ok, :erlang.binary_to_term(payload, [:safe])}
    else
      :miss
    end
  rescue
    ArgumentError -> :miss
  end

  defp verify(_ns, _key, _other), do: :miss

  defp mac(ns, key, payload) do
    :crypto.mac(:hmac, :sha256, signing_key(), [
      Atom.to_string(ns),
      0,
      encode_key(key),
      0,
      payload
    ])
  end

  defp signing_key do
    case :persistent_term.get({__MODULE__, :signing_key}, nil) do
      nil ->
        key = derive_signing_key()
        :persistent_term.put({__MODULE__, :signing_key}, key)
        key

      key ->
        key
    end
  end

  defp derive_signing_key do
    with hex when is_binary(hex) <- System.get_env("CONNECTOR_KEY"),
         {:ok, master} when byte_size(master) == 32 <- Base.decode16(hex, case: :mixed) do
      :crypto.mac(:hmac, :sha256, master, "optimal-engine shared cache v1")
    else
      _ -> :crypto.strong_rand_bytes(32)
    end
  end
end
