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

    * `OptimalEngine.API.RateLimiter`: the HTTP API token buckets (`take_token/6`, which an outage never refills)
    * `OptimalEngine.Connectors.RateLimit`: outbound connector token buckets
    * `OptimalEngine.Auth.KeyCache`: which API key secrets bcrypt already verified
    * `OptimalEngine.Sync.GateCache`: the workspace scans a sync gate reuses

  ## Namespaces and keys

  A namespace is an atom, which is also the name of the local ETS table its
  owner creates with `Shared.Local.new_table/1`. On Valkey a key lives at
  `<prefix>:<namespace>:<generation>:<key>`, with this Engine's prefix
  (`key_prefix/0`, `optimal:shared:<engine hash>` by default): a binary key as it is (when
  short and printable), any other term as the SHA-256 of its external form.
  `clear/1` moves the namespace's generation, so a clear is one command
  however many keys the namespace holds; the old keys expire on their own.
  Every key written carries a TTL.

  Cached values are Erlang terms, signed with an HMAC before they are written
  and checked when they are read, so a value Valkey hands back that this
  Engine did not write is a miss, not a term it trusts. The signing key comes
  from `CONNECTOR_KEY` when it is set (set the same one on every node that
  shares a Valkey and they share entries); without it each node signs with a
  key of its own and reads only its own entries. `CONNECTOR_KEY` is read
  through the Engine's secret resolver (`OptimalEngine.Secrets` when the build
  has it), so an `openbao:<path>#<field>` reference is resolved, never decoded
  as the key; a reference that cannot be read is logged and the node signs
  with a key of its own, trying the reference again a minute later.

  ## Invalidation during an outage

  `delete/2` and `clear/1` always apply locally. When Valkey cannot take them,
  they are deferred in the pool and applied, in order, before any later command
  reaches Valkey, so nothing deleted during an outage (a revoked API key) is
  read back from Valkey after it.

  Locks are leases: a holder that outlives its TTL loses the lock. While
  Valkey is down a lock is per node, as all locks were before.
  """

  require Logger

  alias OptimalEngine.Storage.Shared.Local
  alias OptimalEngine.Storage.Valkey.Pool

  @prefix_env "OPTIMAL_VALKEY_KEY_PREFIX"
  @prefix_pattern ~r/\A[A-Za-z0-9][A-Za-z0-9:_.\-]{0,63}\z/
  @signing_key_retry_ms 60_000
  @max_plain_key 200

  # A generation key lives @generation_ttl_ms after its last use, longer than
  # any key written under it (every TTL here is capped below it), so it can
  # only expire once nothing under it is left.
  @generation_ttl_ms 30 * 24 * 60 * 60 * 1000
  @max_ttl_ms div(@generation_ttl_ms, 2)

  # Each script starts by resolving the namespace's generation, so a clear is
  # one INCR. KEYS[1] is the generation key; ARGV[1] its TTL, ARGV[2] the
  # namespace prefix and ARGV[3] the key. A generation in use whose TTL is
  # missing (written before it had one) or past half is given it again.
  @resolve """
  local g = redis.call('GET', KEYS[1])
  if g then
    if redis.call('PTTL', KEYS[1]) < tonumber(ARGV[1]) / 2 then
      redis.call('PEXPIRE', KEYS[1], ARGV[1])
    end
  else
    g = '0'
  end
  local k = ARGV[2] .. g .. ':' .. ARGV[3]
  """

  @sources %{
    clear:
      "-- optimal:clear\n" <>
        """
        local n = redis.call('INCR', KEYS[1])
        redis.call('PEXPIRE', KEYS[1], ARGV[1])
        return n
        """,
    get: "-- optimal:get\n" <> @resolve <> "return redis.call('GET', k)\n",
    put:
      "-- optimal:put\n" <>
        @resolve <> "redis.call('SET', k, ARGV[4], 'PX', ARGV[5])\nreturn 1\n",
    del: "-- optimal:del\n" <> @resolve <> "return redis.call('DEL', k)\n",
    incr:
      "-- optimal:incr\n" <>
        @resolve <>
        """
        local n = redis.call('INCR', k)
        if n == 1 then redis.call('PEXPIRE', k, ARGV[4]) end
        return n
        """,
    lock:
      "-- optimal:lock\n" <>
        @resolve <>
        """
        if redis.call('SET', k, ARGV[4], 'NX', 'PX', ARGV[5]) then return 1 end
        return 0
        """,
    unlock:
      "-- optimal:unlock\n" <>
        @resolve <>
        """
        if redis.call('GET', k) == ARGV[4] then return redis.call('DEL', k) end
        return 0
        """,
    # The bucket of Shared.Local.take_token/7, on the server's clock. A
    # denied step answers the tokens it found and the time since the stamp;
    # with 'keep' it writes nothing, so no elapsed time is credited twice.
    # ARGV[8], when not empty, is what this node spent locally during an
    # outage: it is taken off the bucket (a lower bound on what was spent,
    # never the bucket's new count), and that lowered count is written even on
    # a 'keep' denial.
    # A taken step answers the tokens left, so the node can mirror them.
    bucket:
      "-- optimal:bucket\n" <>
        @resolve <>
        """
        local cap = tonumber(ARGV[4])
        local rate = tonumber(ARGV[5])
        local ttl = tonumber(ARGV[7])
        local spent = tonumber(ARGV[8] or '')
        local t = redis.call('TIME')
        local now = tonumber(t[1]) * 1000 + math.floor(tonumber(t[2]) / 1000)
        local v = redis.call('HMGET', k, 'tokens', 'at')
        local current = cap
        local elapsed = 0
        if v[1] then
          elapsed = math.max(0, now - tonumber(v[2]))
          current = math.min(cap, tonumber(v[1]) + elapsed * rate)
        end
        local lowered = false
        if spent and spent > 0 then
          current = math.max(0, current - spent)
          lowered = true
        end
        if current >= 1 then
          redis.call('HSET', k, 'tokens', string.format('%.17g', current - 1), 'at', string.format('%d', now))
          redis.call('PEXPIRE', k, ttl)
          return {1, string.format('%.17g', current - 1)}
        end
        if ARGV[6] ~= 'keep' or lowered or not v[1] then
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
        case eval(:put, ns, key, [sign(ns, key, value), server_ttl(ttl_ms)]) do
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
        case eval(:incr, ns, key, [server_ttl(ttl_ms)]) do
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
        case eval(:lock, ns, key, [token, server_ttl(ttl_ms)]) do
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
  One token-bucket step (see `Shared.Local.take_token/7`): `:ok` when a token
  was taken, otherwise `{:limited, tokens_now, elapsed_ms}`. On Valkey the
  bucket runs on the server's clock, atomically, so every node draws on it.

  Valkey dropping out never hands out a fresh bucket. Each answer from Valkey
  is mirrored into this node's table, and while Valkey is configured but
  cannot answer, the local step continues from that mirror; a bucket this
  node never saw opens empty and refills at its rate. When Valkey answers
  again, the first step gives it the tokens the local bucket holds, and the
  server keeps the lower of its own count and that one. Both choices take the
  conservative side: an outage can only make a limit tighter, never looser.
  """
  @spec take_token(namespace(), term(), pos_integer(), float(), :keep | :advance, pos_integer()) ::
          :ok | {:limited, float(), non_neg_integer()}
  def take_token(ns, key, capacity, refill_per_ms, deny, ttl_ms)
      when deny in [:keep, :advance] and is_integer(ttl_ms) and ttl_ms > 0 do
    remote(
      fn ->
        spent =
          case Local.fallback_spent(ns, key) do
            nil -> ""
            spent -> :erlang.float_to_binary(spent * 1.0, [:short])
          end

        args = [
          Integer.to_string(capacity),
          :erlang.float_to_binary(refill_per_ms * 1.0, [:short]),
          Atom.to_string(deny),
          server_ttl(ttl_ms),
          spent
        ]

        case eval(:bucket, ns, key, args) do
          {:ok, [1, left]} -> mirrored(ns, key, ttl_ms, left, :ok)
          {:ok, [0, tokens, elapsed]} -> mirrored(ns, key, ttl_ms, tokens, limited(tokens, elapsed))
          _ -> :unavailable
        end
      end,
      fn ->
        # Configured but not answering: an outage, not a node without Valkey.
        # An Engine that cannot be named shares nothing on Valkey, so its
        # local bucket is all there is, as on a node without Valkey.
        opts =
          if Pool.running?() and not unidentified?(),
            do: [missing: outage_missing(), mark: :fallback],
            else: []

        Local.take_token(ns, key, capacity, refill_per_ms, deny, ttl_ms, opts)
      end
    )
  end

  # OPTIMAL_VALKEY_OUTAGE_POLICY: `closed` (the default) opens a bucket this
  # node never saw with no tokens during an outage, since other nodes may have
  # spent it; `open` opens it full, as a node without Valkey does.
  defp outage_missing do
    case System.get_env("OPTIMAL_VALKEY_OUTAGE_POLICY")
         |> to_string()
         |> String.trim()
         |> String.downcase() do
      "open" -> :full
      _closed -> :empty
    end
  end

  # Every key written to Valkey expires before its namespace's generation can.
  defp server_ttl(ttl_ms), do: Integer.to_string(min(ttl_ms, @max_ttl_ms))

  defp mirrored(_ns, _key, _ttl_ms, _tokens, :unavailable), do: :unavailable

  defp mirrored(ns, key, ttl_ms, tokens, result) do
    case Float.parse(to_string(tokens)) do
      {value, ""} ->
        Local.mirror_bucket(ns, key, value, ttl_ms)
        result

      _ ->
        :unavailable
    end
  end

  @doc "The Valkey key a namespace and key resolve to under `generation`."
  @spec valkey_key(namespace(), term(), non_neg_integer()) :: String.t()
  def valkey_key(ns, key, generation \\ 0),
    do:
      (key_prefix() || "") <>
        ":" <> Atom.to_string(ns) <> ":" <> Integer.to_string(generation) <> ":" <> encode_key(key)

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
    with {:ok, prefix} <- keyspace(),
         {:ok, n} when is_integer(n) <-
           run_script(:clear, [
             "1",
             generation_key(prefix, ns),
             Integer.to_string(@generation_ttl_ms)
           ]) do
      :ok
    else
      other -> {:error, other}
    end
  end

  # Without a prefix (this Engine cannot be named yet) nothing goes to
  # Valkey: the caller runs on local ETS, and an invalidation is deferred.
  defp eval(name, ns, key, args) do
    with {:ok, prefix} <- keyspace() do
      cleanup_legacy_once()

      run_script(name, [
        "1",
        generation_key(prefix, ns),
        Integer.to_string(@generation_ttl_ms),
        namespace_prefix(prefix, ns),
        encode_key(key) | args
      ])
    end
  end

  defp run_script(name, tail) do
    {sha, source} = Map.fetch!(@scripts, name)

    case Pool.command(["EVALSHA", sha | tail]) do
      {:error, {:server, "NOSCRIPT" <> _}} -> Pool.command(["EVAL", source | tail])
      other -> other
    end
  end

  # Before the prefix, keys were optimal:shared:<namespace>:..., and their
  # generation keys never expired. Once per boot each such generation key is
  # removed if nothing else is left under its namespace: an Engine still on
  # the old layout keeps live keys there, and removing its generation would
  # bring back what it cleared, so that one is left for a later boot.
  @legacy_generations "optimal:shared:optimal_*:gen"

  defp cleanup_legacy_once do
    unless :persistent_term.get({__MODULE__, :legacy_cleaned}, false) do
      :persistent_term.put({__MODULE__, :legacy_cleaned}, true)
      Task.start(&cleanup_legacy/0)
    end

    :ok
  end

  @doc false
  # Tests: run the cleanup again, as a fresh boot would.
  @spec reset_legacy_cleanup() :: :ok
  def reset_legacy_cleanup do
    :persistent_term.erase({__MODULE__, :legacy_cleaned})
    :ok
  end

  defp cleanup_legacy do
    for gen <- scan(@legacy_generations) do
      namespace = String.trim_trailing(gen, ":gen")

      if scan(namespace <> ":*") -- [gen] == [] do
        Pool.command(["DEL", gen])
        Logger.info("[Valkey] removed #{gen}, left by the key layout before the Engine prefix")
      end
    end

    :ok
  rescue
    error -> Logger.debug("[Valkey] legacy key cleanup stopped: #{Exception.message(error)}")
  end

  defp scan(pattern, cursor \\ "0", acc \\ []) do
    case Pool.command(["SCAN", cursor, "MATCH", pattern, "COUNT", "1000"]) do
      {:ok, ["0", keys]} -> acc ++ keys
      {:ok, [next, keys]} -> scan(pattern, next, acc ++ keys)
      _ -> acc
    end
  end

  defp keyspace do
    case key_prefix() do
      nil -> {:error, :no_key_prefix}
      prefix -> {:ok, prefix}
    end
  end

  defp limited(tokens, elapsed) when is_binary(tokens) and is_integer(elapsed) do
    case Float.parse(tokens) do
      {value, ""} -> {:limited, value, elapsed}
      _ -> :unavailable
    end
  end

  defp limited(_tokens, _elapsed), do: :unavailable

  defp namespace_prefix(prefix, ns), do: prefix <> ":" <> Atom.to_string(ns) <> ":"
  defp generation_key(prefix, ns), do: prefix <> ":" <> Atom.to_string(ns) <> ":gen"

  @doc """
  The prefix every key this Engine writes to Valkey starts with (keys are
  `<prefix>:<namespace>:...`), or `nil` while this Engine cannot be named.

    * `OPTIMAL_VALKEY_KEY_PREFIX=P` (1 to 64 of `A-Z a-z 0-9 : _ . -`,
      starting with a letter or digit) gives `P:shared`. This is the one
      setting that isolates Engines by choice; note that `P:shared:*` is
      outside a Valkey ACL written for `optimal:shared:*`.
    * Otherwise it is `optimal:shared:` and 16 hex characters of a hash of
      this Engine's identity, the first of:
        1. `OPTIMAL_ENGINE_ID`, an id the platform gives each Engine (for
           MIOSA, the Engine's database id);
        2. the store's replica id (`sync_identity`), which is per database:
           a copy restored from another Engine's dump has that Engine's;
        3. on the PostgreSQL store only, `OPTIMAL_POSTGRES_URL` without user
           and password, plus `OPTIMAL_POSTGRES_SCHEMA`: per database and
           schema, and it moves when the host or URL does.
      Engines that resolve to the same identity (one database and schema)
      share their keys on purpose.

  A prefix is kept for the life of the process only once it came from one of
  those. A store without a `sync_identity` table has no replica id. A replica
  id read that fails otherwise is `nil` and read again on the next call
  (that call runs on local ETS, never on a second keyspace); after
  20 failures in a row it is logged once, read only every ten seconds,
  and buckets stop being held closed as in an outage. With no identity at
  all it is `nil` with a warning, once: set `OPTIMAL_VALKEY_KEY_PREFIX` or
  `OPTIMAL_ENGINE_ID`.
  """
  @spec key_prefix() :: String.t() | nil
  def key_prefix do
    case :persistent_term.get({__MODULE__, :key_prefix}, nil) do
      nil -> fresh_prefix()
      prefix -> prefix
    end
  end

  @identity_failures_logged 20
  @identity_retry_ms 10_000

  defp fresh_prefix do
    case resolve_prefix(throttled: true) do
      {:ok, prefix} ->
        :persistent_term.put({__MODULE__, :key_prefix}, prefix)
        :persistent_term.erase({__MODULE__, :prefix_warned})
        :persistent_term.erase({__MODULE__, :identity_failures})
        prefix

      :retry ->
        nil

      {:retry, reason} ->
        note_identity_failure(reason)
        nil

      :unidentified ->
        warn_unidentified()
        nil
    end
  end

  @doc false
  # The prefix from the sources above, without keeping it. Options for tests:
  # `:store` (the store implementation) and `:query` (runs the replica id
  # query: `fun.(sql, params)` answering `{:ok, rows}` or `{:error, reason}`).
  @spec resolve_prefix(keyword()) ::
          {:ok, String.t()} | :retry | {:retry, term()} | :unidentified
  def resolve_prefix(opts \\ []) do
    cond do
      prefix = configured_prefix() ->
        {:ok, prefix <> ":shared"}

      id = engine_id() ->
        {:ok, "optimal:shared:" <> digest("engine:" <> id)}

      Keyword.get(opts, :throttled, false) and identity_wait?() ->
        :retry

      true ->
        store = Keyword.get_lazy(opts, :store, &OptimalEngine.Store.adapter/0)

        case replica_identity(Keyword.get_lazy(opts, :query, &identity_query/0)) do
          {:ok, id} -> {:ok, "optimal:shared:" <> digest(id)}
          :none -> store_identity(store)
          {:error, reason} -> {:retry, reason}
        end
    end
  end

  @doc false
  # The replica id the store answers, `:none` when it has none (no row, or no
  # sync_identity table at all), or the error to retry.
  @spec replica_identity((String.t(), list() -> {:ok, list()} | {:error, term()})) ::
          {:ok, String.t()} | :none | {:error, term()}
  def replica_identity(query) do
    case query.("SELECT replica_id FROM sync_identity WHERE id = 1", []) do
      {:ok, [[id]]} when is_binary(id) and id != "" -> {:ok, id}
      {:ok, _no_row} -> :none
      {:error, reason} -> if missing_table?(reason), do: :none, else: {:error, reason}
      other -> {:error, other}
    end
  rescue
    error -> if missing_table?(error), do: :none, else: {:error, error}
  catch
    :exit, reason -> {:error, reason}
  end

  # PostgreSQL's undefined_table (42P01) and SQLite's "no such table".
  defp missing_table?(%{postgres: %{code: :undefined_table}}), do: true
  defp missing_table?(%{postgres: %{code: "42P01"}}), do: true

  defp missing_table?(reason) do
    text =
      if is_exception(reason), do: Exception.message(reason), else: inspect(reason, limit: 50)

    text =~ "no such table" or text =~ "undefined_table" or
      (text =~ "sync_identity" and text =~ "does not exist")
  end

  defp identity_query do
    case Application.get_env(:optimal_engine, :valkey_identity_query) do
      query when is_function(query, 2) -> query
      _ -> &OptimalEngine.Store.raw_query/2
    end
  end

  # Only the store this Engine runs on names it: a leftover
  # OPTIMAL_POSTGRES_URL on a SQLite Engine is not its identity.
  defp store_identity(OptimalEngine.Store.Postgres) do
    case postgres_identity() do
      {:ok, identity} -> {:ok, "optimal:shared:" <> digest(identity)}
      :unidentified -> :unidentified
    end
  end

  defp store_identity(_store), do: :unidentified

  defp engine_id do
    case System.get_env("OPTIMAL_ENGINE_ID") |> to_string() |> String.trim() do
      "" -> nil
      id -> id
    end
  end

  defp identity_wait? do
    case :persistent_term.get({__MODULE__, :identity_failures}, nil) do
      {count, retry_at} when count >= @identity_failures_logged ->
        System.monotonic_time(:millisecond) < retry_at

      _ ->
        false
    end
  end

  defp note_identity_failure(reason) do
    count =
      case :persistent_term.get({__MODULE__, :identity_failures}, nil) do
        {count, _retry_at} -> count + 1
        nil -> 1
      end

    retry_at = System.monotonic_time(:millisecond) + @identity_retry_ms

    cond do
      count == @identity_failures_logged ->
        :persistent_term.put({__MODULE__, :identity_failures}, {count, retry_at})
        :persistent_term.put({__MODULE__, :prefix_warned}, true)

        Logger.warning(
          "[Valkey] this Engine could not read its replica id #{count} times in a row " <>
            "(#{inspect(reason, limit: 20)}); shared state stays in local ETS and the id is read " <>
            "again every #{div(@identity_retry_ms, 1000)}s. Set #{@prefix_env} or OPTIMAL_ENGINE_ID to name it."
        )

      count > @identity_failures_logged ->
        :persistent_term.put({__MODULE__, :identity_failures}, {count, retry_at})

      true ->
        :persistent_term.put({__MODULE__, :identity_failures}, {count, 0})
    end
  end

  @doc false
  # Tests: read the prefix again, as a fresh process would.
  @spec reset_key_prefix() :: :ok
  def reset_key_prefix do
    :persistent_term.erase({__MODULE__, :key_prefix})
    :persistent_term.erase({__MODULE__, :prefix_warned})
    :persistent_term.erase({__MODULE__, :identity_failures})
    :ok
  end

  defp digest(identity) do
    :crypto.hash(:sha256, "optimal-engine valkey prefix:" <> identity)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  defp unidentified?, do: :persistent_term.get({__MODULE__, :prefix_warned}, false)

  defp warn_unidentified do
    unless unidentified?() do
      :persistent_term.put({__MODULE__, :prefix_warned}, true)

      Logger.warning(
        "[Valkey] this Engine has no OPTIMAL_ENGINE_ID, no replica id and (on the PostgreSQL store) " <>
          "no OPTIMAL_POSTGRES_URL to name it by; set #{@prefix_env} to a value of its own. " <>
          "Until then shared state stays in local ETS."
      )
    end
  end

  defp configured_prefix do
    case System.get_env(@prefix_env) do
      nil ->
        nil

      value ->
        value = String.trim(value)

        cond do
          value == "" ->
            nil

          Regex.match?(@prefix_pattern, value) ->
            value

          true ->
            Logger.warning(
              "[Valkey] #{@prefix_env} is not 1 to 64 of A-Z a-z 0-9 : _ . - " <>
                "(starting with a letter or digit); using the default prefix"
            )

            nil
        end
    end
  end

  # The database an Engine lives in, without the credentials that reach it
  # (a rotated password must not move the keys).
  defp postgres_identity do
    with url when is_binary(url) and url != "" <- System.get_env("OPTIMAL_POSTGRES_URL"),
         %URI{host: host} = uri when is_binary(host) <- URI.parse(String.trim(url)) do
      schema = System.get_env("OPTIMAL_POSTGRES_SCHEMA") |> to_string() |> String.trim()
      schema = if schema == "", do: "public", else: schema

      {:ok,
       "postgres://" <>
         String.downcase(host) <>
         ":" <> to_string(uri.port || 5432) <> (uri.path || "") <> "#" <> schema}
    else
      _none -> :unidentified
    end
  end

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

  @doc false
  # Tests: forget the signing key, as a fresh process would.
  @spec reset_signing_key() :: :ok
  def reset_signing_key do
    :persistent_term.erase({__MODULE__, :signing_key})
    :ok
  end

  # A key derived from CONNECTOR_KEY is kept for good. A per-node key made
  # because a CONNECTOR_KEY reference could not be read is kept only for
  # @signing_key_retry_ms, so the node starts sharing entries once OpenBao
  # answers.
  defp signing_key do
    now = System.monotonic_time(:millisecond)

    case :persistent_term.get({__MODULE__, :signing_key}, nil) do
      {key, :final} ->
        key

      {key, {:until, until}} when until > now ->
        key

      _none_or_expired ->
        {key, keep} = derive_signing_key()

        entry =
          if keep == :final, do: {key, :final}, else: {key, {:until, now + @signing_key_retry_ms}}

        :persistent_term.put({__MODULE__, :signing_key}, entry)
        key
    end
  end

  defp derive_signing_key do
    case connector_key() do
      {:ok, hex} ->
        case Base.decode16(hex, case: :mixed) do
          {:ok, master} when byte_size(master) == 32 ->
            {:crypto.mac(:hmac, :sha256, master, "optimal-engine shared cache v1"), :final}

          _ ->
            {:crypto.strong_rand_bytes(32), :final}
        end

      :unset ->
        {:crypto.strong_rand_bytes(32), :final}

      {:error, reason} ->
        Logger.error(
          "[Valkey] CONNECTOR_KEY could not be resolved (#{reason}); shared cache entries " <>
            "are signed with a key of this process's own until it can be"
        )

        {:crypto.strong_rand_bytes(32), :retry}
    end
  end

  # CONNECTOR_KEY through the Engine's secret resolver, so an OpenBao
  # reference (`openbao:<path>#<field>`) is resolved, never decoded as the key.
  defp connector_key do
    resolver = Application.get_env(:optimal_engine, :secrets_resolver, OptimalEngine.Secrets)

    if Code.ensure_loaded?(resolver) and function_exported?(resolver, :fetch, 1) do
      case resolver.fetch("CONNECTOR_KEY") do
        {:ok, value} -> {:ok, value}
        {:error, :not_set} -> :unset
        {:error, {:secret_unavailable, _name, why}} -> {:error, describe(why)}
        {:error, _other} -> {:error, "the secret resolver refused it"}
      end
    else
      case System.get_env("CONNECTOR_KEY") do
        nil -> :unset
        "openbao:" <> _ -> {:error, "it is an OpenBao reference and this build has no resolver"}
        value -> {:ok, String.trim(value)}
      end
    end
  end

  defp describe(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp describe(_reason), do: "the secret is unavailable"
end
