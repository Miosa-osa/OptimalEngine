defmodule OptimalEngine.Storage.Shared.Local do
  @moduledoc """
  The per-node ETS side of `OptimalEngine.Storage.Shared`: what every caller
  runs on when Valkey is not configured, and falls back to when it is down.

  Each namespace is one named, public ETS table that its owner creates with
  `new_table/1` (the rate limiters, the key cache and the gate cache own theirs,
  as before). Rows are `{key, value, expires_at}` with `expires_at` in
  monotonic milliseconds. A table that does not exist reads as empty and
  ignores writes, so a cache whose owner died builds instead of failing; only
  `take_token/7` creates its table when it is missing, as the rate limiters
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
  expired rows first and then its oldest rows, a tenth of the bound at a time.
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

  Options, for the steps `OptimalEngine.Storage.Shared` runs here while Valkey
  is configured but cannot answer:

    * `:missing` - `:full` (default) opens a bucket that has no row full, as a
      node without Valkey always has; `:empty` opens it with no tokens and the
      stamp at now, so it refills at its rate. A node that never saw the
      bucket on Valkey does not know how much of it other nodes spent.
    * `:mark` - `:fallback` marks the rows it writes and counts the tokens
      taken while marked, so the first step back on Valkey charges the server
      what this node spent (`fallback_spent/2`).

  The table is bounded (`config :optimal_engine, :shared_bucket_max_entries`,
  100000): a new bucket in a full table first drops the expired rows, then the
  buckets holding the most tokens, a tenth of the bound at a time. A bucket
  dropped that way opens full again (as one idle long enough would), so the
  ones closest to full go first and an exhausted bucket is dropped last.
  """
  @spec take_token(atom(), term(), number(), float(), :keep | :advance, pos_integer(), keyword()) ::
          :ok | {:limited, float(), non_neg_integer()}
  def take_token(table, key, capacity, refill_per_ms, deny, ttl_ms, opts \\ []) do
    new_table(table)
    now = now()
    rows = :ets.lookup(table, key)

    spent =
      case rows do
        [{^key, {_tokens, _stamp, {:fallback, spent}}, _expires}] -> spent
        _ -> 0
      end

    write = fn tokens, taken ->
      :ets.insert(table, {key, bucket(tokens, now, opts, spent + taken), now + ttl_ms})
    end

    if rows == [], do: bound(table, now)

    case rows do
      [{^key, state, expires}] when expires > now and is_tuple(state) ->
        stamp = elem(state, 1)
        elapsed = now - stamp
        current = min(capacity * 1.0, elem(state, 0) + elapsed * refill_per_ms)

        cond do
          current >= 1.0 ->
            write.(current - 1.0, 1)
            :ok

          # Storing `current` under the old stamp would credit `elapsed`
          # again on the next step, letting a client that keeps asking
          # through before the rate allows. A mirror of Valkey's bucket being
          # spent locally is marked even when the step is denied.
          deny == :advance or (Keyword.get(opts, :mark) != nil and tuple_size(state) == 2) ->
            write.(current, 0)
            {:limited, current, elapsed}

          true ->
            {:limited, current, elapsed}
        end

      _ ->
        case Keyword.get(opts, :missing, :full) do
          # A first request (or one after the bucket idled out) opens a full
          # bucket and takes one token from it.
          :full ->
            write.(capacity - 1.0, 1)
            :ok

          # Written whatever `deny` says, or the stamp would never move and
          # the bucket would never refill.
          :empty ->
            write.(0.0, 0)
            {:limited, 0.0, 0}
        end
    end
  end

  defp bucket(tokens, now, opts, spent) do
    case Keyword.get(opts, :mark) do
      nil -> {tokens, now}
      mark -> {tokens, now, {mark, spent}}
    end
  end

  @doc """
  Records the bucket Valkey just answered (`tokens` as of now), unmarked, so a
  later outage continues from it instead of from a full bucket.
  """
  @spec mirror_bucket(atom(), term(), float(), pos_integer()) :: :ok
  def mirror_bucket(table, key, tokens, ttl_ms) do
    new_table(table)
    now = now()
    max = bucket_max_entries()

    # A new key into a full table makes room as `take_token/7` does.
    if not :ets.member(table, key) and :ets.info(table, :size) >= max,
      do: make_bucket_room(table, now, max)

    :ets.insert(table, {key, {tokens * 1.0, now}, now + ttl_ms})
    :ok
  end

  @default_bucket_max_entries 100_000

  defp bucket_max_entries do
    case Application.get_env(:optimal_engine, :shared_bucket_max_entries) do
      max when is_integer(max) and max > 0 -> max
      _ -> @default_bucket_max_entries
    end
  end

  @doc """
  The tokens this node took from a bucket while Valkey was down, or `nil`
  when the bucket was not written during an outage. Valkey is charged this
  much when it answers again; it is a lower bound on what was spent, never the
  bucket's count.
  """
  @spec fallback_spent(atom(), term()) :: non_neg_integer() | nil
  def fallback_spent(table, key) do
    now = now()

    case :ets.lookup(table, key) do
      [{^key, {_tokens, _stamp, {:fallback, spent}}, expires}] when expires > now -> spent
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @doc """
  Takes what this node spent from a bucket during an outage, for the one step
  that charges Valkey with it: the row is unmarked atomically, so steps in
  flight at the same time find nothing to charge. `nil` when nothing is owed.
  A step that then cannot reach Valkey gives it back (`restore_fallback_spent/3`).
  """
  @spec claim_fallback_spent(atom(), term()) :: pos_integer() | nil
  def claim_fallback_spent(table, key) do
    now = now()

    case :ets.lookup(table, key) do
      [{^key, {tokens, stamp, {:fallback, spent}}, expires} = row] when expires > now ->
        unmarked = {key, {tokens, stamp}, expires}
        if spent > 0 and swap(table, row, unmarked), do: spent, else: nil

      _ ->
        nil
    end
  rescue
    ArgumentError -> nil
  end

  @doc "Owes Valkey `spent` again for a bucket, after a claim that could not be charged."
  @spec restore_fallback_spent(atom(), term(), pos_integer()) :: :ok
  def restore_fallback_spent(table, key, spent, tries \\ 5)

  def restore_fallback_spent(_table, _key, _spent, 0), do: :ok

  def restore_fallback_spent(table, key, spent, tries) do
    case :ets.lookup(table, key) do
      [{^key, {tokens, stamp}, expires} = row] ->
        swap(table, row, {key, {tokens, stamp, {:fallback, spent}}, expires}) or
          restore_fallback_spent(table, key, spent, tries - 1)

      [{^key, {tokens, stamp, {:fallback, owed}}, expires} = row] ->
        swap(table, row, {key, {tokens, stamp, {:fallback, owed + spent}}, expires}) or
          restore_fallback_spent(table, key, spent, tries - 1)

      _ ->
        :ok
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  # Replaces `row` with `new` (same key) only if the row is still exactly
  # `row`. The replacement keeps the matched key, as select_replace requires.
  defp swap(table, row, {_key, value, expires}) do
    spec = [
      {{:"$1", :"$2", :"$3"}, [{:"=:=", {{:"$1", :"$2", :"$3"}}, {:const, row}}],
       [{{:"$1", {:const, value}, {:const, expires}}}]}
    ]

    :ets.select_replace(table, spec) == 1
  end

  defp bound(table, now) do
    max = bucket_max_entries()
    if :ets.info(table, :size) >= max, do: make_bucket_room(table, now, max)
  end

  # Expired rows first; then the buckets holding the most tokens (an evicted
  # bucket opens full again, so a full one loses nothing), a tenth of the
  # bound at a time. A bucket that still owes Valkey an outage spend goes last.
  defp make_bucket_room(table, now, max) do
    :ets.select_delete(table, [{{:_, :_, :"$1"}, [{:<, :"$1", now}], [true]}])
    size = :ets.info(table, :size)

    if size >= max do
      table
      |> :ets.select([{{:"$1", :"$2", :_}, [], [{{:"$2", :"$1"}}]}])
      |> Enum.map(fn {state, key} -> {eviction_rank(state), key} end)
      |> Enum.sort()
      |> Enum.take(size - max + max(div(max, 10), 1))
      |> Enum.each(fn {_rank, key} -> :ets.delete(table, key) end)
    end

    :ok
  end

  defp eviction_rank({tokens, _stamp}) when is_number(tokens), do: {0, -tokens}
  defp eviction_rank({tokens, _stamp, _mark}) when is_number(tokens), do: {1, -tokens}
  defp eviction_rank(_other), do: {0, 0}

  # Expired rows first; then the rows that expire soonest (the oldest
  # written, for one TTL), a tenth of the bound at a time, so a flood of new
  # keys never wipes every live row at once.
  defp make_room(table, now, max) do
    :ets.select_delete(table, [{{:_, :_, :"$1"}, [{:<, :"$1", now}], [true]}])
    size = :ets.info(table, :size)

    if size >= max do
      table
      |> :ets.select([{{:"$1", :_, :"$2"}, [], [{{:"$2", :"$1"}}]}])
      |> Enum.sort()
      |> Enum.take(size - max + max(div(max, 10), 1))
      |> Enum.each(fn {_expires, key} -> :ets.delete(table, key) end)
    end

    :ok
  end

  defp now, do: System.monotonic_time(:millisecond)
end
