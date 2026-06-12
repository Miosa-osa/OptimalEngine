defmodule OptimalEngine.Graph do
  @moduledoc """
  Knowledge graph edge management.

  Edges connect contexts, entities, and nodes in a typed directed graph.

  ## Edge types (relation values)

  - `mentioned_in`  — entity → context: entity appears in a context
  - `lives_in`      — context → node: context belongs to a node
  - `cross_ref`     — context → context: signal is cross-referenced to another node
  - `works_on`      — entity → node: person works on a node (from topology)
  - `supersedes`    — context → context: newer context supersedes an older one

  ## Node conventions

  Node names are bare strings like "project-platform-launch", "product-customer-portal", etc. — they are
  NOT context IDs. Entity names like "Alice" are also bare strings. Only
  context-to-context edges use real context IDs as both source and target.

  The edges table has no FK constraints (migrated from the original FK schema) so
  that entity, node, and context IDs can all coexist as edge endpoints.

  ## Workspace scoping

  Every edge row carries the `workspace_id` of the context it was derived from
  (no cross-workspace leakage by default — see `OptimalEngine.Workspace`).
  Read functions accept a `:workspace_id` option (default: `"default"`).
  `rebuild/1` re-attributes every edge to its context's workspace, which also
  serves as the backfill for rows written before edges carried workspace_id.
  """

  require Logger

  alias OptimalEngine.Store

  @doc """
  Creates all edges for a newly indexed or ingested context.

  Inserts:
  - `entity --mentioned_in--> context.id` for each entity
  - `context.id --lives_in--> context.node`
  - `context.id --cross_ref--> dest` for each extra destination in routed_to
  - `context.id --supersedes--> supersedes_id` if context.supersedes is set

  This variant is used outside the Store GenServer (e.g. post-indexing tasks).
  For calls from within the Store GenServer, use `create_edges_for_context_db/2`
  to pass the raw db reference directly and avoid the re-entrant call deadlock.
  """
  @spec create_edges_for_context(map() | struct()) :: :ok
  def create_edges_for_context(context) do
    id = struct_or_map_get(context, :id)

    if is_binary(id) do
      node = struct_or_map_get(context, :node)
      entities = struct_or_map_get(context, :entities) || []
      routed_to = struct_or_map_get(context, :routed_to) || []
      supersedes = struct_or_map_get(context, :supersedes)
      ws = context_workspace(context)

      now = DateTime.to_iso8601(DateTime.utc_now())

      # entity → context (mentioned_in)
      Enum.each(entities, fn entity ->
        insert_edge_via_store(entity, id, "mentioned_in", 1.0, now, ws)
      end)

      # context → node (lives_in)
      if is_binary(node) and node != "" do
        insert_edge_via_store(id, node, "lives_in", 1.0, now, ws)
      end

      # context → context (cross_ref) — extra destinations beyond the primary node
      cross_refs = Enum.reject(routed_to, fn dest -> dest == node end)

      Enum.each(cross_refs, fn dest ->
        insert_edge_via_store(id, dest, "cross_ref", 0.8, now, ws)
      end)

      # context → context (supersedes)
      if is_binary(supersedes) and supersedes != "" do
        insert_edge_via_store(id, supersedes, "supersedes", 1.0, now, ws)
      end
    end

    :ok
  end

  @doc """
  Creates edges for a context using a raw SQLite db reference.

  Used from within the Store GenServer to avoid re-entrant `GenServer.call` deadlocks.
  The `db` argument is the raw Exqlite connection reference.
  """
  @spec create_edges_for_context_db(reference(), map() | struct()) :: :ok
  def create_edges_for_context_db(db, context) do
    id = struct_or_map_get(context, :id)

    if is_binary(id) do
      node = struct_or_map_get(context, :node)
      entities = struct_or_map_get(context, :entities) || []
      routed_to = struct_or_map_get(context, :routed_to) || []
      supersedes = struct_or_map_get(context, :supersedes)
      ws = context_workspace(context)

      now = DateTime.to_iso8601(DateTime.utc_now())

      Enum.each(entities, fn entity ->
        insert_edge_direct(db, entity, id, "mentioned_in", 1.0, now, ws)
      end)

      if is_binary(node) and node != "" do
        insert_edge_direct(db, id, node, "lives_in", 1.0, now, ws)
      end

      cross_refs = Enum.reject(routed_to, fn dest -> dest == node end)

      Enum.each(cross_refs, fn dest ->
        insert_edge_direct(db, id, dest, "cross_ref", 0.8, now, ws)
      end)

      if is_binary(supersedes) and supersedes != "" do
        insert_edge_direct(db, id, supersedes, "supersedes", 1.0, now, ws)
      end
    end

    :ok
  end

  @doc """
  Seeds `works_on` edges from topology — entity → node relationships.

  These encode which people work on which nodes. Idempotent (INSERT OR IGNORE).

  Options:
  - `:workspace_id` — workspace to attribute the edges to (default: "default";
    the static mapping below is legacy single-workspace data)
  """
  @spec seed_from_topology(keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def seed_from_topology(opts \\ []) do
    ws = Keyword.get(opts, :workspace_id, "default")
    now = DateTime.to_iso8601(DateTime.utc_now())

    edges = topology_works_on_edges()

    inserted =
      Enum.reduce(edges, 0, fn {entity, node}, count ->
        case insert_edge_via_store(entity, node, "works_on", 1.0, now, ws) do
          :ok -> count + 1
          {:error, _} -> count
        end
      end)

    Logger.info("[Graph] Seeded #{inserted} works_on edges from topology")
    {:ok, inserted}
  end

  @doc """
  Rebuilds edges from scratch:
  1. Clears the edges table (one workspace, or all)
  2. Iterates contexts and creates their edges, attributed to each context's
     own `workspace_id`
  3. Seeds topology works_on edges (into the "default" workspace)

  Options:
  - `:workspace_id` — rebuild only this workspace's edges. When omitted, ALL
    edges are rebuilt; because attribution is taken per-context, a full
    rebuild also backfills workspace_id on edges written before scoping.
  """
  @spec rebuild(keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def rebuild(opts \\ []) do
    ws = Keyword.get(opts, :workspace_id)
    Logger.info("[Graph] Rebuilding edges (workspace: #{ws || "all"})...")

    with :ok <- clear_edges(ws),
         {:ok, context_count} <- rebuild_context_edges(ws),
         {:ok, topology_count} <- maybe_seed_topology(ws) do
      total = context_count + topology_count
      Logger.info("[Graph] Edge rebuild complete. #{total} edges created.")
      {:ok, total}
    end
  end

  @doc """
  Returns all edges for a given source or target ID.

  Options:
  - `:direction`    — `:out` (default), `:in`, or `:both`
  - `:relation`     — filter by relation type
  - `:workspace_id` — workspace to scope to (default: "default")
  """
  @spec edges_for(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def edges_for(id, opts \\ []) when is_binary(id) do
    direction = Keyword.get(opts, :direction, :out)
    relation = Keyword.get(opts, :relation)
    ws = Keyword.get(opts, :workspace_id, "default")

    {where_clause, params} = build_edges_where(id, direction, relation)
    ws_param = length(params) + 1
    where_clause = "(#{where_clause}) AND workspace_id = ?#{ws_param}"

    sql = "SELECT source_id, target_id, relation, weight FROM edges WHERE #{where_clause}"

    case Store.raw_query(sql, params ++ [ws]) do
      {:ok, rows} ->
        edges = Enum.map(rows, &row_to_edge/1)
        {:ok, edges}

      err ->
        err
    end
  end

  @doc """
  Returns all contexts that mention a given entity (traverse mentioned_in edges).

  Options:
  - `:workspace_id` — workspace to scope to (default: "default")
  """
  @spec related_contexts(String.t(), keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def related_contexts(entity_name, opts \\ []) when is_binary(entity_name) do
    ws = Keyword.get(opts, :workspace_id, "default")

    sql = """
    SELECT target_id FROM edges
    WHERE source_id = ?1 AND relation = 'mentioned_in' AND workspace_id = ?2
    """

    case Store.raw_query(sql, [entity_name, ws]) do
      {:ok, rows} -> {:ok, Enum.map(rows, fn [id] -> id end)}
      err -> err
    end
  end

  @doc """
  Returns the 1-hop subgraph around a context ID.
  Returns all edges where source_id OR target_id equals the context_id.

  Options:
  - `:workspace_id` — workspace to scope to (default: "default")
  """
  @spec subgraph(String.t(), pos_integer(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def subgraph(context_id, _depth \\ 1, opts \\ []) when is_binary(context_id) do
    ws = Keyword.get(opts, :workspace_id, "default")

    sql = """
    SELECT source_id, target_id, relation, weight FROM edges
    WHERE (source_id = ?1 OR target_id = ?1) AND workspace_id = ?2
    """

    case Store.raw_query(sql, [context_id, ws]) do
      {:ok, rows} ->
        edges = Enum.map(rows, &row_to_edge/1)
        {:ok, edges}

      err ->
        err
    end
  end

  @doc """
  Returns aggregate stats about the graph.

  Options:
  - `:workspace_id` — workspace to scope to (default: "default")
  """
  @spec stats(keyword()) :: {:ok, map()} | {:error, term()}
  def stats(opts \\ []) do
    ws = Keyword.get(opts, :workspace_id, "default")

    queries = [
      {"total_edges", "SELECT COUNT(*) FROM edges WHERE workspace_id = ?1"},
      {"mentioned_in",
       "SELECT COUNT(*) FROM edges WHERE relation = 'mentioned_in' AND workspace_id = ?1"},
      {"lives_in", "SELECT COUNT(*) FROM edges WHERE relation = 'lives_in' AND workspace_id = ?1"},
      {"works_on", "SELECT COUNT(*) FROM edges WHERE relation = 'works_on' AND workspace_id = ?1"},
      {"cross_ref",
       "SELECT COUNT(*) FROM edges WHERE relation = 'cross_ref' AND workspace_id = ?1"},
      {"supersedes",
       "SELECT COUNT(*) FROM edges WHERE relation = 'supersedes' AND workspace_id = ?1"}
    ]

    result =
      Enum.reduce_while(queries, %{}, fn {key, sql}, acc ->
        case Store.raw_query(sql, [ws]) do
          {:ok, [[val]]} -> {:cont, Map.put(acc, key, val)}
          {:ok, []} -> {:cont, Map.put(acc, key, 0)}
          {:error, _} = err -> {:halt, err}
        end
      end)

    case result do
      %{} = s -> {:ok, s}
      err -> err
    end
  end

  @doc """
  Returns the top N most connected entities by edge count.

  Options:
  - `:workspace_id` — workspace to scope to (default: "default")
  """
  @spec top_entities(pos_integer(), keyword()) ::
          {:ok, [{String.t(), non_neg_integer()}]} | {:error, term()}
  def top_entities(limit \\ 10, opts \\ []) do
    ws = Keyword.get(opts, :workspace_id, "default")

    sql = """
    SELECT source_id, COUNT(*) as cnt
    FROM edges
    WHERE relation IN ('mentioned_in', 'works_on') AND workspace_id = ?2
    GROUP BY source_id
    ORDER BY cnt DESC
    LIMIT ?1
    """

    case Store.raw_query(sql, [limit, ws]) do
      {:ok, rows} -> {:ok, Enum.map(rows, fn [id, cnt] -> {id, cnt} end)}
      err -> err
    end
  end

  @doc """
  Returns sample edges for display.

  Options:
  - `:workspace_id` — workspace to scope to (default: "default")
  """
  @spec sample_edges(pos_integer(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def sample_edges(limit \\ 10, opts \\ []) do
    ws = Keyword.get(opts, :workspace_id, "default")

    sql = """
    SELECT source_id, target_id, relation, weight
    FROM edges
    WHERE workspace_id = ?2
    ORDER BY ROWID DESC
    LIMIT ?1
    """

    case Store.raw_query(sql, [limit, ws]) do
      {:ok, rows} -> {:ok, Enum.map(rows, &row_to_edge/1)}
      err -> err
    end
  end

  # ---------------------------------------------------------------------------
  # Private: topology works_on edges
  # ---------------------------------------------------------------------------

  defp topology_works_on_edges do
    # Static mapping: entity name → [nodes they work on]
    # Derived from CLAUDE.md routing table and OptimalOS topology
    [
      {"Alice", "project-platform-launch"},
      {"Bob", "project-platform-launch"},
      {"Quinn", "project-platform-launch"},
      {"Erin", "product-customer-portal"},
      {"Ruth", "product-customer-portal"},
      {"Frank", "product-customer-portal"},
      {"Carol", "product-customer-portal"},
      {"Nina", "product-customer-portal"},
      {"Dan", "operation-delivery"},
      {"Dan", "learning-research-library"},
      {"Dan", "team"},
      {"Sam", "operation-delivery"},
      {"Tina", "operation-delivery"},
      {"Ivan", "entity-company"},
      {"Ivan", "learning-research-library"},
      {"Judy", "learning-research-library"},
      {"Grace", "learning-research-library"},
      {"Oscar", "operator"},
      {"Alice", "operator"},
      {"Alice", "product-customer-portal"},
      {"Alice", "project-platform-launch"},
      {"Alice", "entity-company"},
      {"Alice", "operation-delivery"},
      {"Alice", "team"},
      {"Alice", "learning-research-library"},
      {"Alice", "operation-revenue"},
      {"Alice", "team"},
      {"Alice", "entity-company"},
      {"Alice", "operation-delivery"}
    ]
  end

  # ---------------------------------------------------------------------------
  # Private: rebuild helpers
  # ---------------------------------------------------------------------------

  # nil workspace = full rebuild across all workspaces
  defp clear_edges(nil) do
    case Store.raw_query("DELETE FROM edges", []) do
      {:ok, _} -> :ok
      :ok -> :ok
      err -> err
    end
  end

  defp clear_edges(ws) when is_binary(ws) do
    case Store.raw_query("DELETE FROM edges WHERE workspace_id = ?1", [ws]) do
      {:ok, _} -> :ok
      :ok -> :ok
      err -> err
    end
  end

  defp rebuild_context_edges(ws) do
    {sql, params} =
      case ws do
        nil ->
          {"SELECT id, node, entities, routed_to, supersedes, workspace_id FROM contexts", []}

        ws ->
          {"SELECT id, node, entities, routed_to, supersedes, workspace_id FROM contexts WHERE workspace_id = ?1",
           [ws]}
      end

    case Store.raw_query(sql, params) do
      {:ok, rows} ->
        Enum.each(rows, fn [id, node, entities_json, routed_to_json, supersedes, workspace_id] ->
          entities = decode_json_list(entities_json)
          routed_to = decode_json_list(routed_to_json)

          context = %{
            id: id,
            node: node,
            entities: entities,
            routed_to: routed_to,
            supersedes: supersedes,
            workspace_id: workspace_id
          }

          create_edges_for_context(context)
        end)

        # Return actual count from the table after insertion
        count_result =
          case ws do
            nil -> Store.raw_query("SELECT COUNT(*) FROM edges", [])
            ws -> Store.raw_query("SELECT COUNT(*) FROM edges WHERE workspace_id = ?1", [ws])
          end

        case count_result do
          {:ok, [[count]]} -> {:ok, count}
          {:ok, []} -> {:ok, 0}
          err -> err
        end

      err ->
        err
    end
  end

  # The static topology mapping is legacy single-workspace data: only seed it
  # for full rebuilds or rebuilds of the "default" workspace.
  defp maybe_seed_topology(ws) when ws in [nil, "default"], do: seed_from_topology()
  defp maybe_seed_topology(_ws), do: {:ok, 0}

  # ---------------------------------------------------------------------------
  # Private: SQL helpers
  # ---------------------------------------------------------------------------

  @edge_insert_sql """
  INSERT OR IGNORE INTO edges (source_id, target_id, relation, weight, valid_from, workspace_id)
  VALUES (?1, ?2, ?3, ?4, ?5, ?6)
  """

  # Insert via Store GenServer (for use outside of Store callbacks)
  defp insert_edge_via_store(source, target, relation, weight, now, ws) do
    case Store.raw_query(@edge_insert_sql, [source, target, relation, weight, now, ws]) do
      {:ok, _} ->
        :ok

      :ok ->
        :ok

      {:error, reason} ->
        Logger.debug("[Graph] Edge insert skipped: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Insert directly via db reference (for use inside Store callbacks — avoids deadlock)
  defp insert_edge_direct(db, source, target, relation, weight, now, ws) do
    with {:ok, stmt} <- Exqlite.Sqlite3.prepare(db, @edge_insert_sql),
         :ok <- Exqlite.Sqlite3.bind(stmt, [source, target, relation, weight, now, ws]),
         _ <- Exqlite.Sqlite3.step(db, stmt),
         :ok <- Exqlite.Sqlite3.release(db, stmt) do
      :ok
    else
      {:error, reason} ->
        Logger.debug("[Graph] Edge direct insert skipped: #{inspect(reason)}")
        :ok
    end
  end

  defp context_workspace(context) do
    case struct_or_map_get(context, :workspace_id) do
      ws when is_binary(ws) and ws != "" -> ws
      _ -> "default"
    end
  end

  defp build_edges_where(id, :out, nil), do: {"source_id = ?1", [id]}
  defp build_edges_where(id, :in, nil), do: {"target_id = ?1", [id]}
  defp build_edges_where(id, :both, nil), do: {"source_id = ?1 OR target_id = ?1", [id]}
  defp build_edges_where(id, :out, rel), do: {"source_id = ?1 AND relation = ?2", [id, rel]}
  defp build_edges_where(id, :in, rel), do: {"target_id = ?1 AND relation = ?2", [id, rel]}

  defp build_edges_where(id, :both, rel),
    do: {"(source_id = ?1 OR target_id = ?1) AND relation = ?2", [id, rel]}

  defp row_to_edge([source_id, target_id, relation, weight]) do
    %{source_id: source_id, target_id: target_id, relation: relation, weight: weight}
  end

  defp decode_json_list(nil), do: []
  defp decode_json_list(""), do: []

  defp decode_json_list(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, list} when is_list(list) -> list
      _ -> []
    end
  end

  # Works for both plain maps (%{key: val}) and structs (which don't support Access)
  defp struct_or_map_get(%_{} = struct, key), do: Map.get(struct, key)
  defp struct_or_map_get(map, key) when is_map(map), do: Map.get(map, key)
  defp struct_or_map_get(_, _), do: nil
end
