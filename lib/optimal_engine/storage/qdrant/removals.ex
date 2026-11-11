defmodule OptimalEngine.Storage.Qdrant.Removals do
  @moduledoc """
  Removals from the Qdrant projection, kept until Qdrant has taken them.

  A removal (a vector or memory deleted, a memory forgotten or superseded, a
  workspace archived or moved, the second pass of an erasure) is written to
  `qdrant_pending_removals` first and returns; the projection process applies
  it in order behind the mirrors queued before it, and deletes the record when
  Qdrant has deleted the points. A removal that goes with rows a transaction
  deletes (a memory forgotten or hard deleted, a context a peer deleted, a
  workspace archived) is recorded inside that transaction (`record_in/5`) and
  handed over once it commits, so the rows never go without their record.

  A removal Qdrant refuses stays recorded: the projection retries on a timer
  (`:retry_interval_ms`, one minute by default, and once at boot), queues a
  sync for an active workspace, and every `OptimalEngine.Storage.Qdrant.Sync`
  run retries the records first. One that is still refused after
  `:max_removal_attempts` (100) is dead: kept with `dead_at` set, logged, and
  retried no more, so it never holds up the others or a sync; the orphan
  sweep of a full sync removes its points. Before a retry deletes anything it
  reads which of the named rows are searchable again (a vector stored anew, a
  workspace no longer archived) and leaves their points alone.

  Every removal names this Engine's points only (`engine_id`). Removals run
  whenever a Qdrant URL is configured, serving or not.

  An erasure cannot wait: `erase_contexts/2` deletes in the caller, never
  behind the mirror queue, within the request timeout, and answers
  `{:error, {:qdrant_delete_failed, reason}}` on any failure (a timeout or an
  exit included), so the erasure stops with its rows intact.
  `erased_contexts/2`, after the erasure has committed, records the same
  removal again, which takes any point a mirror racing the erasure put back.
  """

  require Logger

  alias OptimalEngine.Storage.Qdrant.{Gate, Projection}
  alias OptimalEngine.Store

  @default_retry_ms 60_000
  @default_max_attempts 100
  @batch 100

  @insert "INSERT INTO qdrant_pending_removals " <>
            "(id, kind, field, ids, tenant_id, workspace_id, attempts, created_at) " <>
            "VALUES (?1, ?2, ?3, ?4, ?5, ?6, 0, ?7)"

  @doc """
  Records the removal of this Engine's points of `kind` whose payload `field`
  is one of `values` and hands it to the projection process. Options:
  `:tenant_id` limits it to a tenant, `:workspace_id` names the workspace (for
  the sync a failure queues). Returns `:ok`, or `{:error, reason}` when the
  record could not be written. `:ok` and nothing recorded when no Qdrant URL
  is configured.

  For a removal that goes with rows a transaction deletes, use `record_in/5`
  inside it and `enqueue/1` after it commits, so a crash between the two
  loses nothing (the record is retried at boot).
  """
  @spec remove(Projection.kind(), String.t(), [String.t()], keyword()) :: :ok | {:error, term()}
  def remove(kind, field, values, opts \\ [])
  def remove(_kind, _field, [], _opts), do: :ok

  def remove(kind, field, values, opts) do
    if Projection.configured?() do
      {id, params} = row(kind, field, values, opts)

      case Store.raw_query(@insert, params) do
        {:ok, _} ->
          enqueue([id])

        {:error, reason} = error ->
          Logger.error("[Qdrant] could not record a removal of #{kind}: #{inspect(reason)}")
          error
      end
    else
      :ok
    end
  end

  @doc """
  Records a removal (as `remove/4` does) inside the transaction `txn`, which
  deletes the rows, and returns the record's ids for `enqueue/1` once it has
  committed: `{:ok, []}` when there is nothing to remove. The caller checks
  `OptimalEngine.Storage.Qdrant.Projection.configured?/0` before the
  transaction (it reads the store).
  """
  @spec record_in(term(), Projection.kind(), String.t(), [String.t()], keyword()) ::
          {:ok, [String.t()]} | {:error, term()}
  def record_in(_txn, _kind, _field, [], _opts), do: {:ok, []}

  def record_in(txn, kind, field, values, opts) do
    {id, params} = row(kind, field, values, opts)

    case Store.txn_execute(txn, @insert, params) do
      {:ok, _} -> {:ok, [id]}
      {:error, _} = error -> error
    end
  end

  @doc """
  `record_in/5` for several `{kind, field, values}` at once. Returns every
  record's id, or the first error.
  """
  @spec record_all_in(term(), [{Projection.kind(), String.t(), [String.t()]}], keyword()) ::
          {:ok, [String.t()]} | {:error, term()}
  def record_all_in(txn, removals, opts) do
    Enum.reduce_while(removals, {:ok, []}, fn {kind, field, values}, {:ok, ids} ->
      case record_in(txn, kind, field, values, opts) do
        {:ok, new} -> {:cont, {:ok, ids ++ new}}
        error -> {:halt, error}
      end
    end)
  end

  @doc "The removals that go with deleted contexts: their vectors' points and their chunks'."
  @spec of_contexts([String.t()]) :: [{Projection.kind(), String.t(), [String.t()]}]
  def of_contexts(context_ids),
    do: [{:contexts, "context_id", context_ids}, {:chunks, "context_id", context_ids}]

  @doc "Hands recorded removals (`record_in/5`) to the projection process. Always `:ok`."
  @spec enqueue([String.t()]) :: :ok
  def enqueue(ids) do
    Enum.each(ids, &Projection.enqueue({:removal, &1}))
    :ok
  end

  defp row(kind, field, values, opts) do
    id = "qpr_" <> Base.encode16(:crypto.strong_rand_bytes(10), case: :lower)

    {id,
     [
       id,
       Atom.to_string(kind),
       field,
       Jason.encode!(Enum.uniq(values)),
       Keyword.get(opts, :tenant_id),
       Keyword.get(opts, :workspace_id),
       created_at()
     ]}
  end

  # Wall clock to the microsecond, so records order as they were made.
  defp created_at, do: DateTime.utc_now() |> DateTime.to_iso8601()

  @doc """
  Applies the recorded removals that are not dead (all of them, oldest
  first) and returns `:ok` when none of them failed, or `{:error, reason}`
  with the first failure. A failure never stops the others. Never raises.
  """
  @spec retry_pending() :: :ok | {:error, term()}
  def retry_pending, do: retry_pending(nil, :ok)

  defp retry_pending(after_key, result) do
    {where, params} =
      case after_key do
        nil -> {"", [@batch]}
        {at, id} -> {" AND (created_at > ?2 OR (created_at = ?2 AND id > ?3))", [@batch, at, id]}
      end

    case Store.raw_query(
           "SELECT id, created_at FROM qdrant_pending_removals WHERE dead_at IS NULL" <>
             where <> " ORDER BY created_at, id LIMIT ?1",
           params
         ) do
      {:ok, []} ->
        result

      {:ok, rows} ->
        result =
          Enum.reduce(rows, result, fn [id, _at], acc ->
            case apply_one(id) do
              :ok -> acc
              error -> if acc == :ok, do: error, else: acc
            end
          end)

        [last_id, last_at] = List.last(rows)

        if length(rows) == @batch,
          do: retry_pending({last_at, last_id}, result),
          else: result

      {:error, _} = error ->
        error
    end
  rescue
    error -> {:error, {:raised, Exception.message(error)}}
  end

  @doc false
  @spec apply_one(String.t()) :: :ok | {:error, term()}
  def apply_one(id) do
    case Store.raw_query(
           "SELECT kind, field, ids, tenant_id, workspace_id, attempts FROM qdrant_pending_removals " <>
             "WHERE id = ?1 AND dead_at IS NULL",
           [id]
         ) do
      {:ok, [[kind, field, ids, tenant, workspace, attempts]]} ->
        case attempt(kind, field, ids, tenant) do
          :ok ->
            {:ok, _} = Store.raw_query("DELETE FROM qdrant_pending_removals WHERE id = ?1", [id])
            :ok

          {:error, reason} = error ->
            failed_attempt(id, workspace, (attempts || 0) + 1, reason)
            error
        end

      {:ok, []} ->
        :ok

      {:error, _} = error ->
        error
    end
  rescue
    error -> {:error, {:raised, Exception.message(error)}}
  end

  defp attempt(kind, field, ids, tenant) do
    kind = String.to_existing_atom(kind)
    values = Jason.decode!(ids)
    delete(kind, field, values -- searchable(kind, field, values), tenant)
  rescue
    error -> {:error, {:raised, Exception.message(error)}}
  end

  # A removal still refused after `:max_removal_attempts` (100 by default) is
  # dead: kept, with `dead_at` set, for an operator, and retried no more, so it
  # never holds up the others or a sync. The orphan sweep of a full sync
  # removes the points it named.
  defp failed_attempt(id, workspace, attempts, reason) do
    dead? = attempts >= max_attempts()

    Store.raw_query(
      "UPDATE qdrant_pending_removals SET attempts = ?2, last_error = ?3, dead_at = ?4 WHERE id = ?1",
      [id, attempts, inspect(Projection.error_class(reason)), if(dead?, do: created_at())]
    )

    if dead? do
      Logger.error(
        "[Qdrant] removal #{id} failed #{attempts} times and is retried no more " <>
          "(#{inspect(Projection.error_class(reason))}); a full sync sweeps its points"
      )
    else
      Projection.schedule_retry()
      if workspace, do: Gate.queue_sync(workspace)
    end
  end

  defp max_attempts,
    do:
      Keyword.get(
        Application.get_env(:optimal_engine, :qdrant_projection, []),
        :max_removal_attempts,
        @default_max_attempts
      )

  @doc "How many removals are recorded and not yet taken by Qdrant (the dead ones not counted)."
  @spec pending_count() :: non_neg_integer()
  def pending_count,
    do: count("SELECT COUNT(*) FROM qdrant_pending_removals WHERE dead_at IS NULL")

  @doc "How many removals are dead: refused `:max_removal_attempts` times, kept and retried no more."
  @spec dead_count() :: non_neg_integer()
  def dead_count,
    do: count("SELECT COUNT(*) FROM qdrant_pending_removals WHERE dead_at IS NOT NULL")

  defp count(sql) do
    case Store.raw_query(sql, []) do
      {:ok, [[n]]} when is_integer(n) -> n
      _ -> 0
    end
  end

  @doc false
  def retry_interval,
    do:
      Keyword.get(
        Application.get_env(:optimal_engine, :qdrant_projection, []),
        :retry_interval_ms,
        @default_retry_ms
      )

  # The values whose rows are searchable again: their points are the rows'
  # own, mirrored after the removal was recorded, and stay.
  defp searchable(kind, field, values) do
    column = column(kind, field)

    values
    |> Enum.chunk_every(500)
    |> Enum.flat_map(fn batch ->
      placeholders = Enum.map_join(1..length(batch), ", ", &"?#{&1}")

      case Store.raw_query(
             "SELECT DISTINCT #{column} " <>
               Projection.from_sql(kind) <> " WHERE #{column} IN (#{placeholders})",
             batch
           ) do
        {:ok, rows} -> Enum.map(rows, fn [value] -> value end)
        # Unknown: keep every value out of the delete, and try again later.
        {:error, _} -> batch
      end
    end)
  end

  defp column(:contexts, "context_id"), do: "v.context_id"
  defp column(:contexts, "workspace_id"), do: "c.workspace_id"
  defp column(:chunks, "context_id"), do: "ch.signal_id"
  defp column(:chunks, "chunk_id"), do: "ce.chunk_id"
  defp column(:chunks, "workspace_id"), do: "ce.workspace_id"
  defp column(:memories, "memory_id"), do: "me.memory_id"
  defp column(:memories, "workspace_id"), do: "me.workspace_id"

  defp delete(_kind, _field, [], _tenant), do: :ok

  defp delete(kind, field, values, tenant) do
    tenant_condition = if tenant, do: [%{key: "tenant_id", match: %{value: tenant}}], else: []
    Projection.delete_where(kind, [%{key: field, match: %{any: values}} | tenant_condition])
  end

  # ── erasure ─────────────────────────────────────────────────────────────

  @doc """
  Deletes the points of erased contexts (their document vectors and their
  chunks' vectors, within `tenant_id` when given) now, in the caller. Any
  failure, a timeout or an exit included, is `{:error, {:qdrant_delete_failed,
  reason}}`. `:ok` when no Qdrant URL is configured.
  """
  @spec erase_contexts([String.t()], String.t() | nil) :: :ok | {:error, term()}
  def erase_contexts([], _tenant_id), do: :ok

  def erase_contexts(context_ids, tenant_id) do
    if Projection.configured?() do
      with :ok <- delete(:contexts, "context_id", context_ids, tenant_id),
           :ok <- delete(:chunks, "context_id", context_ids, tenant_id) do
        :ok
      else
        {:error, reason} -> {:error, {:qdrant_delete_failed, reason}}
      end
    else
      :ok
    end
  rescue
    error -> {:error, {:qdrant_delete_failed, {:raised, Exception.message(error)}}}
  catch
    kind, reason -> {:error, {:qdrant_delete_failed, {kind, reason}}}
  end

  @doc """
  After an erasure has committed: records the removal of the contexts' points
  again, so a point a mirror put back between `erase_contexts/2` and the
  commit goes too.
  """
  @spec erased_contexts([String.t()], String.t() | nil) :: :ok
  def erased_contexts([], _tenant_id), do: :ok

  def erased_contexts(context_ids, tenant_id) do
    opts = if tenant_id, do: [tenant_id: tenant_id], else: []
    remove(:contexts, "context_id", context_ids, opts)
    remove(:chunks, "context_id", context_ids, opts)
    :ok
  end
end
