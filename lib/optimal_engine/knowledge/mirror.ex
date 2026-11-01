defmodule OptimalEngine.Knowledge.Mirror do
  @moduledoc """
  Keeps the knowledge triple store (`Knowledge.DefaultStore`) a mirror of the
  `graph_edges` table, whatever path changed an edge.

  A new edge reaches the store as it is written (`Graph`). An edge also leaves
  or moves by paths that never tell the store: an erasure
  (`Compliance.DerivedData`), a peer's replicated delete, a context moved to
  another workspace, a graph rebuild. Two SQLite triggers on `graph_edges`
  record each delete, and each change of an edge's workspace, source, relation
  or target, as rows of `triple_mirror_changes` in the same transaction as the
  write, so no path can leave a change out:

    * a delete is a `retract` of the edge's triple
    * a change is a `retract` of the old triple and an `assert` of the new one

  `drain/2` applies the rows in order and removes them. A retract drops the
  triple only when no edge of any tenant still holds it (the triple store keys
  a triple by workspace, not by tenant), so applying a row twice changes
  nothing.

  `prepare/2` runs before the store opens. It installs the triggers and decides
  whether the store starts empty. An in-memory store always does, and loads
  every edge in full. A persistent store (RocksDB) keeps what it holds only
  when it has followed these changes since its last full load and its
  hydration marker can be trusted. Otherwise it is emptied first, so a full
  load never adds edges on top of triples whose edges are gone, such as those
  left by an earlier release that did not record deletes, or by a restore of
  an older database.

  Every call to the Store here survives a busy Store: a call that times out
  is an error, the changes stay recorded, and the next drain applies them. A
  crash would take the default store down with it, and a run of them its
  supervisor.

  The triggers are installed at boot and not by a migration, because the
  PostgreSQL store derives its schema from the migrations and has no
  counterpart for a trigger that writes an ordinary table. A PostgreSQL build
  records no changes.
  """

  require Logger

  alias OptimalEngine.Knowledge.Backend
  alias OptimalEngine.Knowledge.Hydration
  alias OptimalEngine.Knowledge.Store, as: KnowledgeStore
  alias OptimalEngine.Store

  @batch 500
  @following "OPTIMAL_FOLLOWS_GRAPH_CHANGES"

  @triggers [
    """
    CREATE TRIGGER triple_mirror_edge_deleted AFTER DELETE ON graph_edges
    BEGIN
      INSERT INTO triple_mirror_changes (op, graph, subject, predicate, object)
      VALUES ('retract', OLD.workspace_id, OLD.source_id, OLD.relation, OLD.target_id);
    END
    """,
    """
    CREATE TRIGGER triple_mirror_edge_moved
    AFTER UPDATE OF workspace_id, source_id, relation, target_id ON graph_edges
    WHEN OLD.workspace_id IS NOT NEW.workspace_id OR OLD.source_id IS NOT NEW.source_id
      OR OLD.relation IS NOT NEW.relation OR OLD.target_id IS NOT NEW.target_id
    BEGIN
      INSERT INTO triple_mirror_changes (op, graph, subject, predicate, object)
      VALUES ('retract', OLD.workspace_id, OLD.source_id, OLD.relation, OLD.target_id);
      INSERT INTO triple_mirror_changes (op, graph, subject, predicate, object)
      VALUES ('assert', NEW.workspace_id, NEW.source_id, NEW.relation, NEW.target_id);
    END
    """
  ]

  @doc """
  Installs the triggers and readies the store at `backend_opts` before it
  opens. Returns `:empty` when the store starts empty and is loaded in full,
  `:kept` when a persistent store keeps what it holds, and `:unfollowed` when
  changes cannot be recorded or the store cannot be emptied, so the store must
  not be marked as following them.
  """
  @spec prepare(module(), keyword()) :: :empty | :kept | :unfollowed
  def prepare(backend, backend_opts) do
    installed = install()
    decide(backend, backend_opts, installed)
  catch
    :exit, reason ->
      Logger.warning("[Knowledge.Mirror] Store unavailable while preparing: #{inspect(reason)}")
      :unfollowed
  end

  defp decide(backend, backend_opts, installed) do
    cond do
      backend != Backend.RocksDB ->
        if installed == :ok, do: :empty, else: :unfollowed

      installed != :ok ->
        :unfollowed

      following?(backend_opts) and not Hydration.full_load?(backend, backend_opts) ->
        :kept

      reset(backend_opts) == :ok ->
        :empty

      true ->
        :unfollowed
    end
  end

  @doc """
  Installs the two triggers, or replaces them when their definition changed.
  Only the SQLite store records changes.
  """
  @spec install() :: :ok | :skipped | {:error, term()}
  def install do
    if Store.selected?(OptimalEngine.Store.SQLite),
      do: store_call(&install_triggers/0),
      else: :skipped
  end

  defp install_triggers do
    case Store.raw_query(
           "SELECT sql FROM sqlite_master WHERE type = 'trigger' AND name LIKE 'triple_mirror_%' ORDER BY name",
           []
         ) do
      {:ok, rows} ->
        installed = Enum.map(rows, fn [sql] -> String.trim(sql || "") end)

        if Enum.sort(installed) == Enum.sort(Enum.map(@triggers, &String.trim/1)),
          do: :ok,
          else: replace_triggers()

      {:error, _} = error ->
        error
    end
  end

  defp replace_triggers do
    result =
      Store.transaction(fn txn ->
        with {:ok, _} <-
               Store.txn_execute(txn, "DROP TRIGGER IF EXISTS triple_mirror_edge_deleted", []),
             {:ok, _} <-
               Store.txn_execute(txn, "DROP TRIGGER IF EXISTS triple_mirror_edge_moved", []) do
          Enum.reduce_while(@triggers, {:ok, :installed}, fn sql, ok ->
            case Store.txn_execute(txn, sql, []) do
              {:ok, _} -> {:cont, ok}
              {:error, _} = error -> {:halt, error}
            end
          end)
        end
      end)

    case result do
      {:ok, _} ->
        :ok

      {:error, reason} = error ->
        Logger.warning(
          "[Knowledge.Mirror] Could not install the graph edge triggers: #{inspect(reason)}"
        )

        error
    end
  end

  @doc "Whether the persistent store at `backend_opts` has followed the recorded changes since its last full load."
  @spec following?(keyword()) :: boolean()
  def following?(backend_opts), do: File.exists?(following_path(backend_opts))

  @doc "Records that the persistent store at `backend_opts` follows the changes from now on: after a full load."
  @spec mark_following(keyword()) :: :ok | {:error, term()}
  def mark_following(backend_opts), do: File.write(following_path(backend_opts), "")

  defp following_path(backend_opts), do: Path.join(Keyword.fetch!(backend_opts, :path), @following)

  # Empties a persistent store before it opens. RocksDB's own destroy removes
  # only the files of the database; the two markers go with it.
  defp reset(backend_opts) do
    path = Keyword.fetch!(backend_opts, :path)

    with true <- File.dir?(path),
         :ok <- :rocksdb.destroy(String.to_charlist(path), []) do
      _ = File.rm(Hydration.marker_path(backend_opts))
      _ = File.rm(following_path(backend_opts))
      Logger.info("[Knowledge.Mirror] Emptied the triple store at #{path}; it loads in full")
      :ok
    else
      false ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[Knowledge.Mirror] Could not empty the triple store at #{path}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  @doc "The id of the newest recorded change, 0 when there is none."
  @spec newest_change() :: non_neg_integer()
  def newest_change do
    case store_call(fn ->
           Store.raw_query("SELECT COALESCE(MAX(id), 0) FROM triple_mirror_changes", [])
         end) do
      {:ok, [[id]]} when is_integer(id) -> id
      _ -> 0
    end
  end

  @doc """
  Removes the changes up to `id` without applying them: for a store loaded in
  full after they were made, which holds their result already.
  """
  @spec discard_through(non_neg_integer()) :: :ok | {:error, term()}
  def discard_through(id) when is_integer(id) do
    case store_call(fn ->
           Store.raw_execute("DELETE FROM triple_mirror_changes WHERE id <= ?1", [id])
         end) do
      :ok -> :ok
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end

  @doc """
  Applies every recorded change to `store` in order and removes it. With
  `keep: true` the changes are applied and kept, for a store still being
  loaded: a page it loads after a change was applied could bring the triple
  back, and applying the change again once the load is done removes it.
  Returns how many changes were applied.
  """
  @spec drain(GenServer.server(), keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def drain(store, opts \\ []), do: drain_after(store, 0, Keyword.get(opts, :keep, false), 0)

  defp drain_after(store, after_id, keep?, applied) do
    case store_call(fn ->
           Store.raw_query(
             "SELECT id, op, graph, subject, predicate, object FROM triple_mirror_changes WHERE id > ?1 ORDER BY id LIMIT ?2",
             [after_id, @batch]
           )
         end) do
      {:ok, []} ->
        {:ok, applied}

      {:ok, rows} ->
        [last_id | _] = List.last(rows)

        with :ok <- apply_changes(store, rows),
             :ok <- if(keep?, do: :ok, else: discard_through(last_id)) do
          drain_after(store, last_id, keep?, applied + length(rows))
        end

      {:error, _} = error ->
        error
    end
  end

  # A Store or triple store that does not answer stops the batch before its
  # rows are removed, so the next drain applies them again.
  defp apply_changes(store, rows) do
    Enum.reduce_while(rows, :ok, fn row, :ok ->
      case apply_change(store, row) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  catch
    :exit, reason -> {:error, {:triple_store_unavailable, reason}}
  end

  defp apply_change(store, [_id, "assert", graph, subject, predicate, object]) do
    _ = KnowledgeStore.assert(store, graph, subject, predicate, object)
    :ok
  end

  defp apply_change(store, [_id, "retract", graph, subject, predicate, object]) do
    case held(graph, subject, predicate, object) do
      {:ok, true} ->
        :ok

      {:ok, false} ->
        _ = KnowledgeStore.retract(store, graph, subject, predicate, object)
        :ok

      {:error, _} = error ->
        error
    end
  end

  # An edge of any tenant in the workspace keeps the triple.
  defp held(graph, subject, predicate, object) do
    case store_call(fn ->
           Store.raw_query(
             "SELECT EXISTS (SELECT 1 FROM graph_edges WHERE workspace_id = ?1 AND source_id = ?2 AND relation = ?3 AND target_id = ?4)",
             [graph, subject, predicate, object]
           )
         end) do
      {:ok, [[held]]} when held in [0, false] -> {:ok, false}
      {:ok, [[_held]]} -> {:ok, true}
      {:error, _} = error -> error
      other -> {:error, {:unexpected, other}}
    end
  end

  defp store_call(fun) do
    fun.()
  catch
    :exit, reason -> {:error, {:store_unavailable, reason}}
  end
end
