defmodule OptimalEngine.Storage.Qdrant.Removals do
  @moduledoc """
  Removals from the Qdrant projection, kept until Qdrant has taken them.

  A removal (a vector or memory deleted, a memory forgotten or superseded, a
  workspace archived or moved, the second pass of an erasure) is written to
  `qdrant_pending_removals` first and returns; the projection process applies
  it in order behind the mirrors queued before it, and deletes the record when
  Qdrant has deleted the points. A removal Qdrant refuses stays recorded: the
  projection retries on a timer (`:retry_interval_ms`, one minute by default,
  and once at boot), queues a sync for an active workspace, and every
  `OptimalEngine.Storage.Qdrant.Sync` run retries the records first and fails
  while one remains. Before a retry deletes anything it reads which of the
  named rows are searchable again (a vector stored anew, a workspace no longer
  archived) and leaves their points alone.

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
  @batch 100

  @doc """
  Records the removal of this Engine's points of `kind` whose payload `field`
  is one of `values` and hands it to the projection process. Options:
  `:tenant_id` limits it to a tenant, `:workspace_id` names the workspace (for
  the sync a failure queues). Returns `:ok`, or `{:error, reason}` when the
  record could not be written. `:ok` and nothing recorded when no Qdrant URL
  is configured.
  """
  @spec remove(Projection.kind(), String.t(), [String.t()], keyword()) :: :ok | {:error, term()}
  def remove(kind, field, values, opts \\ [])
  def remove(_kind, _field, [], _opts), do: :ok

  def remove(kind, field, values, opts) do
    if Projection.configured?() do
      id = "qpr_" <> Base.encode16(:crypto.strong_rand_bytes(10), case: :lower)

      case Store.raw_query(
             "INSERT INTO qdrant_pending_removals " <>
               "(id, kind, field, ids, tenant_id, workspace_id, attempts, created_at) " <>
               "VALUES (?1, ?2, ?3, ?4, ?5, ?6, 0, ?7)",
             [
               id,
               Atom.to_string(kind),
               field,
               Jason.encode!(Enum.uniq(values)),
               Keyword.get(opts, :tenant_id),
               Keyword.get(opts, :workspace_id),
               created_at()
             ]
           ) do
        {:ok, _} ->
          Projection.enqueue({:removal, id})
          :ok

        {:error, reason} = error ->
          Logger.error("[Qdrant] could not record a removal of #{kind}: #{inspect(reason)}")
          error
      end
    else
      :ok
    end
  end

  # Wall clock to the microsecond, so records order as they were made.
  defp created_at, do: DateTime.utc_now() |> DateTime.to_iso8601()

  @doc """
  Applies the recorded removals (all of them, oldest first) and returns `:ok`
  when none is left, or `{:error, reason}` with the first failure. Never
  raises.
  """
  @spec retry_pending() :: :ok | {:error, term()}
  def retry_pending do
    case Store.raw_query(
           "SELECT id FROM qdrant_pending_removals ORDER BY created_at, id LIMIT ?1",
           [@batch]
         ) do
      {:ok, []} ->
        :ok

      {:ok, rows} ->
        result =
          Enum.reduce_while(rows, :ok, fn [id], :ok ->
            case apply_one(id) do
              :ok -> {:cont, :ok}
              error -> {:halt, error}
            end
          end)

        if result == :ok and length(rows) == @batch, do: retry_pending(), else: result

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
           "SELECT kind, field, ids, tenant_id, workspace_id FROM qdrant_pending_removals WHERE id = ?1",
           [id]
         ) do
      {:ok, [[kind, field, ids, tenant, workspace]]} ->
        kind = String.to_existing_atom(kind)
        values = Jason.decode!(ids) -- searchable(kind, field, Jason.decode!(ids))

        case delete(kind, field, values, tenant) do
          :ok ->
            {:ok, _} = Store.raw_query("DELETE FROM qdrant_pending_removals WHERE id = ?1", [id])
            :ok

          {:error, reason} = error ->
            Store.raw_query(
              "UPDATE qdrant_pending_removals SET attempts = attempts + 1, last_error = ?2 WHERE id = ?1",
              [id, inspect(Projection.error_class(reason))]
            )

            Projection.schedule_retry()
            if workspace, do: Gate.queue_sync(workspace)
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

  @doc "How many removals are recorded and not yet taken by Qdrant."
  @spec pending_count() :: non_neg_integer()
  def pending_count do
    case Store.raw_query("SELECT COUNT(*) FROM qdrant_pending_removals", []) do
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
