defmodule OptimalEngine.Storage.Qdrant.Gate do
  @moduledoc """
  Whether a search may read the Qdrant projection: Qdrant's health, the
  workspaces a failed mirror marked dirty, and the comparison of what Qdrant
  holds with what the embedded store holds.

  A workspace is searched through Qdrant only when Qdrant is healthy, the
  workspace is not dirty, no `maintenance.qdrant_sync` job is queued or
  running for it, and Qdrant holds exactly as many of this Engine's points in
  the searched scope as SQLite holds searchable rows
  (`OptimalEngine.Storage.Qdrant.Projection.from_sql/1`). The comparison is
  kept two minutes per scope by default (`:count_ttl_ms`) and reads indexes,
  never the vectors. A scope the store holds nothing of while Qdrant does
  queues a sync, and equal counts are verified by a sync once a day
  (`:verify_interval_ms`), since they do not prove equal sets.

  A dirty mark carries a generation (`stamp/0`), never the wall clock. A sync that
  completes clears the marks made before it began; a mark made while it ran
  stays, and the job that ran it queues a follow-up
  (`OptimalEngine.Maintenance`). Every mark queues a sync job for its
  workspace, which is what survives a restart.
  """

  require Logger

  alias OptimalEngine.Storage.Qdrant
  alias OptimalEngine.Storage.Qdrant.Projection
  alias OptimalEngine.Store

  @default_health_ttl_ms 30_000
  @default_count_ttl_ms 120_000
  @default_verify_interval_ms 86_400_000

  # ── health ──────────────────────────────────────────────────────────────

  @doc """
  Whether Qdrant answered its health check within the cache window (30
  seconds by default). A failed request marks it unhealthy for the window.
  """
  @spec healthy?() :: boolean()
  def healthy? do
    now = now()

    case Projection.lookup(:health) do
      {expires, value} when expires > now ->
        value

      _ ->
        value = Qdrant.health(timeout: Projection.timeout()) == :healthy
        Projection.store(:health, now + health_ttl(), value)
        value
    end
  end

  @doc false
  def mark_unhealthy(reason) do
    Projection.store(:health, now() + health_ttl(), false)
    Projection.store(:last_error, :infinity, Projection.error_class(reason))
    :ok
  end

  @doc "Forgets the cached health, so the next request checks again."
  @spec reset_health() :: :ok
  def reset_health, do: Projection.delete_key(:health)

  # ── dirty marks ─────────────────────────────────────────────────────────

  @doc """
  The generation a dirty mark and a sync's start are compared by: a counter
  every mark advances, so a mark made after a sync started, in the same
  millisecond or after the wall clock stepped back, is always later than the
  start. It begins at the wall clock in microseconds when the projection's
  table is created, so a start carried in a job's cursor across a restart is
  earlier than every mark made since.
  """
  @spec stamp() :: integer()
  def stamp, do: Projection.generation(0)

  @doc "Whether a mirror into the workspace failed since the last sync that completed for it."
  @spec dirty?(String.t()) :: boolean()
  def dirty?(workspace_id), do: Projection.lookup({:dirty, workspace_id}) != nil

  @doc """
  Marks a workspace dirty and queues a sync job for it. `:all` (a mirror that
  failed before its rows could be read, or one dropped past the queue limit
  without a workspace) marks every active workspace.
  """
  #
  # A workspace already marked only takes the newer generation: its job was
  # queued with the first mark (and the retry timer queues it again while the
  # mark stays, `requeue_dirty/0`), so a burst of dropped mirrors writes to the
  # store once. `:all` lists the workspaces at most once a second.
  @spec mark_dirty(String.t() | :all) :: :ok
  def mark_dirty(:all) do
    now = now()

    case Projection.lookup(:dirty_all) do
      {at, _} when is_integer(at) and now - at < 1_000 ->
        :ok

      _ ->
        Projection.store(:dirty_all, now, true)

        case Store.raw_query("SELECT id FROM workspaces WHERE status = 'active' ORDER BY id", []) do
          {:ok, rows} ->
            Enum.each(rows, fn [id] -> mark_dirty(id) end)

          {:error, reason} ->
            Logger.error("[Qdrant] could not list workspaces to mark dirty: #{inspect(reason)}")
        end
    end

    invalidate_all()
  end

  def mark_dirty(workspace_id) when is_binary(workspace_id) do
    already? = dirty?(workspace_id)
    Projection.store({:dirty, workspace_id}, Projection.generation(1), true)
    invalidate(workspace_id)

    if already? do
      :ok
    else
      Projection.schedule_retry()
      queue_sync(workspace_id)
    end
  end

  @doc """
  Queues the sync job of every workspace still marked dirty (one already
  queued or running is found, not duplicated) and returns how many are
  marked. The projection's retry timer calls it, so a mark whose job died is
  repaired.
  """
  @spec requeue_dirty() :: non_neg_integer()
  def requeue_dirty do
    marks = Projection.match({{:dirty, :_}, :_, :_})
    Enum.each(marks, fn {{:dirty, workspace_id}, _, _} -> queue_sync(workspace_id) end)
    length(marks)
  end

  @doc """
  Clears the dirty marks a sync that started at `started` (`stamp/0`) has
  repaired: those of the workspace (every one when nil) made before it began.
  """
  @spec clear_dirty(String.t() | nil, integer()) :: :ok
  def clear_dirty(workspace_id, started) do
    marks =
      case workspace_id do
        nil -> Projection.match({{:dirty, :_}, :_, :_})
        ws -> Projection.match({{:dirty, ws}, :_, :_})
      end

    for {key, marked, _} <- marks, marked <= started, do: Projection.delete_key(key)
    :ok
  end

  @doc "How many workspaces are marked dirty."
  @spec dirty_count() :: non_neg_integer()
  def dirty_count, do: length(Projection.match({{:dirty, :_}, :_, :_}))

  @doc "Queues a `maintenance.qdrant_sync` job for the workspace, or finds the one queued."
  @spec queue_sync(String.t()) :: :ok
  def queue_sync(workspace_id) do
    OptimalEngine.Maintenance.enqueue(:qdrant_sync, workspace_id, %{}, priority: -10)
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  # ── the comparison ──────────────────────────────────────────────────────

  @doc """
  Whether search may read Qdrant for `kind` in `scope` (see the module doc).
  A scope with no rows is not in sync: the embedded search answers it at no
  cost. A difference is logged and queues a sync.
  """
  @spec in_sync?(Projection.kind(), map()) :: boolean()
  def in_sync?(kind, %{workspace_id: workspace_id} = scope) do
    if dirty?(workspace_id) do
      false
    else
      key = {:gate, kind, workspace_id, scope, nil}
      now = now()

      case Projection.lookup(key) do
        {expires, value} when expires > now ->
          value

        _ ->
          value = not sync_active?(workspace_id) and compare(kind, scope)
          if value, do: verify_when_due(workspace_id, now)
          Projection.store(key, now + count_ttl(), value)
          value
      end
    end
  end

  @doc "Forgets the count comparisons of a workspace, so its next search compares again."
  @spec invalidate(String.t()) :: :ok
  def invalidate(workspace_id) do
    Projection.match_delete({{:gate, :_, workspace_id, :_, :_}, :_, :_})
  end

  @doc "Forgets every count comparison."
  @spec invalidate_all() :: :ok
  def invalidate_all, do: Projection.match_delete({{:gate, :_, :_, :_, :_}, :_, :_})

  defp sync_active?(workspace_id) do
    case OptimalEngine.Maintenance.active(:qdrant_sync, workspace_id) do
      {:ok, nil} -> false
      {:ok, _job} -> true
      _ -> false
    end
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  # Equal counts do not prove equal sets (a point missing and an orphan
  # cancel out), so a workspace whose counts agree is synced anyway once every
  # `:verify_interval_ms` (a day by default) after it was last synced, or
  # first compared since boot; it is searched through Qdrant meanwhile, and
  # any candidate Qdrant proposes is read back from the store.
  defp verify_when_due(workspace_id, now) do
    since =
      case Projection.lookup({:verified, workspace_id}) do
        {at, _} when is_integer(at) ->
          at

        _ ->
          Projection.store({:verified, workspace_id}, now, true)
          now
      end

    if now - since >= verify_interval() do
      Projection.store({:verified, workspace_id}, now, true)
      queue_sync(workspace_id)
    end
  end

  @doc false
  # A completed sync of the workspace verified it.
  def verified(workspace_id), do: Projection.store({:verified, workspace_id}, now(), true)

  # A scope with no searchable rows is answered by the embedded search; if
  # Qdrant still holds points there (rows removed behind the Engine's back),
  # a sync is queued to remove them.
  defp compare(kind, scope) do
    with {:ok, local} <- local_count(kind, scope),
         {:ok, remote} <- remote_total(kind, scope) do
      cond do
        local == remote and local > 0 ->
          true

        local == remote ->
          false

        true ->
          drift(kind, scope, local, remote)
          false
      end
    else
      {:error, reason} ->
        mark_unhealthy(reason)
        false
    end
  end

  defp local_count(:contexts, %{workspace_id: ws}),
    do:
      scalar("SELECT COUNT(*) " <> Projection.from_sql(:contexts) <> " WHERE c.workspace_id = ?1", [
        ws
      ])

  defp local_count(:memories, %{tenant_id: t, workspace_id: ws, model: m}),
    do:
      scalar(
        "SELECT COUNT(*) " <>
          Projection.from_sql(:memories) <>
          " WHERE me.tenant_id = ?1 AND me.workspace_id = ?2 AND me.model = ?3",
        [t, ws, m]
      )

  defp scalar(sql, params) do
    case Store.raw_query(sql, params) do
      {:ok, [[n]]} when is_integer(n) -> {:ok, n}
      {:ok, _} -> {:ok, 0}
      {:error, _} = error -> error
    end
  end

  # This Engine's points in the scope, across every dimension of the kind.
  defp remote_total(kind, scope) do
    with {:ok, names} <- Projection.collections(kind) do
      Enum.reduce_while(names, {:ok, 0}, fn name, {:ok, total} ->
        case remote_count(name, scope) do
          {:ok, n} -> {:cont, {:ok, total + n}}
          error -> {:halt, error}
        end
      end)
    end
  end

  @doc "The exact number of this Engine's points in `collection` matching `scope`; 0 for a missing collection."
  @spec remote_count(String.t(), map()) :: {:ok, non_neg_integer()} | {:error, term()}
  def remote_count(collection, scope) do
    case Projection.request(:post, "/collections/#{collection}/points/count", %{
           filter: Projection.filter(scope),
           exact: true
         }) do
      {:ok, 200, %{"result" => %{"count" => n}}} when is_integer(n) -> {:ok, n}
      {:ok, 404, _} -> {:ok, 0}
      other -> {:error, Projection.failure(other)}
    end
  end

  defp drift(kind, scope, local, remote) do
    Projection.count(:drift, 1)

    Logger.info(
      "[Qdrant] #{kind} in #{scope.workspace_id} differ (embedded #{local}, qdrant #{remote}); " <>
        "searching the embedded vectors and queueing a sync"
    )

    queue_sync(scope.workspace_id)
  end

  defp settings, do: Application.get_env(:optimal_engine, :qdrant_projection, [])
  defp health_ttl, do: Keyword.get(settings(), :health_ttl_ms, @default_health_ttl_ms)
  defp count_ttl, do: Keyword.get(settings(), :count_ttl_ms, @default_count_ttl_ms)

  defp verify_interval,
    do: Keyword.get(settings(), :verify_interval_ms, @default_verify_interval_ms)

  defp now, do: System.monotonic_time(:millisecond)
end
