defmodule OptimalEngine.Storage.Shared.Local do
  @moduledoc """
  The per-node ETS side of `OptimalEngine.Storage.Shared`: what every caller
  runs on when Valkey is not configured, and falls back to when it is down.

  Each namespace is one named, public ETS table that its owner creates with
  `new_table/1` (the rate limiters, the key cache and the gate cache own theirs,
  as before). Rows are `{key, value, expires_at}` with `expires_at` in
  monotonic milliseconds. A table that does not exist reads as empty and
  ignores writes, so a cache whose owner died builds instead of failing; only
  `take_token/6` creates its table when it is missing, as the rate limiters
  always did, so a limiter keeps limiting across a restart of its owner.
  """

  @doc "Creates the named table when it does not exist. Idempotent."
  @spec new_table(atom()) :: :ok
  def new_table(table) do
    if :ets.whereis(table) == :undefined do
      :ets.new(table, [:named_table, :public, :set, read_concurrency: true, write_concurrency: true])
    end

    :ok
  rescue
    # Created by another process between the check and the call.
    ArgumentError -> :ok
  end

  @spec get(atom(), term()) :: {:ok, term()} | :miss
  def get(table, key) do
    now = now()

    case :ets.lookup(table, key) do
      [{^key, value, expires}] when expires > now -> {:ok, value}
      _ -> :miss
    end
  rescue
    ArgumentError -> :miss
  end

  @doc """
  Stores `value` for `ttl_ms`. With `:max_entries`, a full table drops its
  expired rows first and every row when the live ones still fill it.
  """
  @spec put(atom(), term(), term(), pos_integer(), keyword()) :: :ok
  def put(table, key, value, ttl_ms, opts \\ []) do
    now = now()

    case Keyword.get(opts, :max_entries) do
      max when is_integer(max) -> if :ets.info(table, :size) >= max, do: make_room(table, now, max)
      _ -> :ok
    end

    :ets.insert(table, {key, value, now + ttl_ms})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @spec delete(atom(), term()) :: :ok
  def delete(table, key) do
    :ets.delete(table, key)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @spec clear(atom()) :: :ok
  def clear(table) do
    :ets.delete_all_objects(table)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "Drops the expired rows; returns how many."
  @spec sweep(atom()) :: non_neg_integer()
  def sweep(table) do
    :ets.select_delete(table, [{{:_, :_, :"$1"}, [{:<, :"$1", now()}], [true]}])
  rescue
    ArgumentError -> 0
  end

  @doc "A counter that starts at 1 and expires `ttl_ms` after it was created."
  @spec incr(atom(), term(), pos_integer()) :: {:ok, integer()}
  def incr(table, key, ttl_ms) do
    new_table(table)
    now = now()

    case :ets.lookup(table, key) do
      [{^key, _count, expires}] when expires > now ->
        {:ok, :ets.update_counter(table, key, {2, 1})}

      _ ->
        :ets.insert(table, {key, 1, now + ttl_ms})
        {:ok, 1}
    end
  end

  @doc "Takes the lock when no one holds it (or the holder's lease expired)."
  @spec lock(atom(), term(), String.t(), pos_integer()) :: {:ok, String.t()} | {:error, :locked}
  def lock(table, key, token, ttl_ms) do
    new_table(table)
    now = now()

    # An expired lease is removed only if it is still the same row.
    case :ets.lookup(table, key) do
      [{^key, _holder, expires} = row] when expires <= now -> :ets.delete_object(table, row)
      _ -> :ok
    end

    if :ets.insert_new(table, {key, token, now + ttl_ms}),
      do: {:ok, token},
      else: {:error, :locked}
  end

  @doc "Releases the lock only for the token that took it."
  @spec unlock(atom(), term(), String.t()) :: :ok
  def unlock(table, key, token) do
    :ets.match_delete(table, {key, token, :_})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  One token-bucket step: `:ok` when a token was taken, otherwise
  `{:limited, tokens_now, elapsed_ms}` where `elapsed_ms` is the time since the
  bucket's refill stamp. `deny` decides what a denied step writes: `:keep`
  writes nothing, so the bucket keeps its tokens and its stamp and the next
  step credits the time since that stamp once (the HTTP API limiter);
  `:advance` stores the refilled tokens with the stamp moved to now (the
  connector limiter). Either way a denied step never credits the same
  elapsed time twice. The bucket row expires `ttl_ms` after its last write.
  """
  @spec take_token(atom(), term(), number(), float(), :keep | :advance, pos_integer()) ::
          :ok | {:limited, float(), non_neg_integer()}
  def take_token(table, key, capacity, refill_per_ms, deny, ttl_ms) do
    new_table(table)
    now = now()

    case :ets.lookup(table, key) do
      [{^key, {tokens, stamp}, expires}] when expires > now ->
        elapsed = now - stamp
        current = min(capacity * 1.0, tokens + elapsed * refill_per_ms)

        if current >= 1.0 do
          :ets.insert(table, {key, {current - 1.0, now}, now + ttl_ms})
          :ok
        else
          # Storing `current` under the old stamp would credit `elapsed`
          # again on the next step, letting a client that keeps asking
          # through before the rate allows.
          if deny == :advance,
            do: :ets.insert(table, {key, {current, now}, now + ttl_ms})

          {:limited, current, elapsed}
        end

      _ ->
        # A first request (or one after the bucket idled out) opens a full
        # bucket and takes one token from it.
        :ets.insert(table, {key, {capacity - 1.0, now}, now + ttl_ms})
        :ok
    end
  end

  defp make_room(table, now, max) do
    :ets.select_delete(table, [{{:_, :_, :"$1"}, [{:<, :"$1", now}], [true]}])
    if :ets.info(table, :size) >= max, do: :ets.delete_all_objects(table)
  end

  defp now, do: System.monotonic_time(:millisecond)
end
