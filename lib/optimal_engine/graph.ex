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

  Edges live in the `graph_edges` table, which has no FK constraints so
  that entity, node, and context IDs can all coexist as edge endpoints.

  ## Tenant and workspace scoping

  Every edge row carries the `workspace_id` of the context it was derived from
  and that workspace's `tenant_id` (`"default"` for a workspace that is not
  registered), and an edge is unique within its tenant and workspace: the same
  entity pair in two workspaces is two edges. Read functions accept a
  `:workspace_id` option (default: `"default"`) and a `:tenant_id` option,
  which defaults to the workspace's own tenant; a caller that knows whose
  request it serves passes it, so a workspace of another tenant reads as
  empty (see `scope/1`). `rebuild/1` re-attributes every edge to its
  context's workspace and tenant.

  The baseline `edges` table, keyed by endpoints and relation only, is no
  longer read or written (the migration that created `graph_edges` copied it there).
  """

  require Logger

  alias OptimalEngine.Store
  alias OptimalEngine.Store.Migrations

  # Name of the default Knowledge.Store that mirrors the SQLite graph_edges table.
  @default_triple_store "default"

  @doc """
  Asserts a semantic edge: writes to both the SQLite `graph_edges` table and the
  default in-memory triple store (`Knowledge.Store`).

  This is the primary public API for adding domain predicates (e.g.
  `"mentions"`, `"co_occurs_with"`, `"authored_by"`) from ingest pipelines
  or external callers.

  Returns `:ok` on success. Edge insert failures are logged and swallowed;
  triple-store failures are logged and swallowed so they never block the caller.

  Options:
  - `:workspace_id` - workspace to attribute the edge to (default: `"default"`);
    the edge takes that workspace's tenant
  - `:weight`       - edge weight (default: `1.0`)
  """
  @spec assert_edge(String.t(), String.t(), String.t(), keyword()) :: :ok
  def assert_edge(source, target, predicate, opts \\ [])
      when is_binary(source) and is_binary(target) and is_binary(predicate) do
    ws = Keyword.get(opts, :workspace_id, "default")
    weight = Keyword.get(opts, :weight, 1.0)
    now = DateTime.to_iso8601(DateTime.utc_now())

    insert_edge_via_store(source, target, predicate, weight, now, ws)
    maybe_feed_triple_store(source, predicate, target, ws)

    :ok
  end

  @doc """
  Retracts an edge asserted with `assert_edge/4`: removes the workspace's
  `graph_edges` row and the matching triple. An importer uses it when a
  re-import shows that a relation no longer holds (a page moved to another
  parent).

  Options: `:workspace_id` (default `"default"`) and `:tenant_id` (default:
  the workspace's tenant, as `scope/1` describes). Returns `:ok`; a missing
  edge is not an error.
  """
  @spec retract_edge(String.t(), String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def retract_edge(source, target, predicate, opts \\ [])
      when is_binary(source) and is_binary(target) and is_binary(predicate) do
    {tenant_id, ws} = scope(opts)

    case Store.raw_query(
           "DELETE FROM graph_edges WHERE tenant_id = ?1 AND workspace_id = ?2 AND source_id = ?3 AND target_id = ?4 AND relation = ?5",
           [tenant_id, ws, source, target, predicate]
         ) do
      {:error, reason} ->
        {:error, reason}

      _ ->
        maybe_retract_triple(source, predicate, target, ws)
        :ok
    end
  end

  @doc """
  Hydrates a `Knowledge.Store` from all rows in the SQLite `graph_edges` table.

  Called on application start (and optionally per-workspace) so the in-memory
  triple store reflects durable edge data after a restart. Each edge row is
  asserted as a quad `{workspace_id, source_id, relation, target_id}`.

  `store` must be a running `Knowledge.Store` GenServer (pid or via-name).

  Options:
  - `:workspace_id` - only hydrate edges from this workspace (default: all),
    within `:tenant_id` (default: the workspace's tenant)
  - `:after_id`     - only edges with a larger id (default: 0, every edge)
  - `:limit`        - max rows to load (default: `:all`; a cap leaves the
    newest edges out of the store)
  - `:batch_size`   - rows fetched per Store call (default: 1_000)

  Returns `{:ok, count}` or `{:error, reason}`.
  """
  @spec hydrate_triple_store(GenServer.server(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def hydrate_triple_store(store, opts \\ []) do
    scope = if Keyword.get(opts, :workspace_id), do: scope(opts)
    limit = Keyword.get(opts, :limit, :all)
    after_id = Keyword.get(opts, :after_id, 0)
    batch_size = Keyword.get(opts, :batch_size, 1_000) |> max(1)
    batch_size = if is_integer(limit), do: batch_size |> min(limit) |> max(1), else: batch_size

    case hydrate_triple_store_pages(store, scope, limit, batch_size, after_id, 0) do
      {:ok, count} = result ->
        Logger.info("[Graph] Hydrated #{count} triples into Knowledge.Store from SQLite edges")
        result

      {:error, reason} = error ->
        Logger.warning("[Graph] hydrate_triple_store query failed: #{inspect(reason)}")
        error
    end
  rescue
    error ->
      Logger.warning("[Graph] hydrate_triple_store exception: #{inspect(error)}")
      {:error, error}
  end

  defp hydrate_triple_store_pages(_store, _scope, limit, _batch_size, _last_id, count)
       when is_integer(limit) and count >= limit,
       do: {:ok, count}

  defp hydrate_triple_store_pages(store, scope, limit, batch_size, last_id, count) do
    page_size = if limit == :all, do: batch_size, else: min(batch_size, limit - count)

    {sql, params} =
      case scope do
        nil ->
          {"SELECT id, source_id, relation, target_id, workspace_id FROM graph_edges WHERE id > ?1 ORDER BY id LIMIT ?2",
           [last_id, page_size]}

        {tenant_id, workspace_id} ->
          {"SELECT id, source_id, relation, target_id, workspace_id FROM graph_edges WHERE tenant_id = ?1 AND workspace_id = ?2 AND id > ?3 ORDER BY id LIMIT ?4",
           [tenant_id, workspace_id, last_id, page_size]}
      end

    case Store.raw_query(sql, params) do
      {:ok, []} ->
        {:ok, count}

      {:ok, rows} ->
        Enum.each(rows, fn [_id, source, predicate, target, graph] ->
          OptimalEngine.Knowledge.Store.assert(store, graph, source, predicate, target)
        end)

        [last_row | _] = Enum.reverse(rows)
        [next_id | _] = last_row

        hydrate_triple_store_pages(
          store,
          scope,
          limit,
          batch_size,
          next_id,
          count + length(rows)
        )

      {:error, reason} ->
        {:error, reason}
    end
  end

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
        maybe_feed_triple_store(entity, "mentioned_in", id, ws)
      end)

      # entity ↔ entity (co_occurs) — every unordered pair sharing this context
      Enum.each(co_occurrence_pairs(entities), fn {a, b} ->
        insert_edge_via_store(a, b, "co_occurs", 0.5, now, ws)
        insert_edge_via_store(b, a, "co_occurs", 0.5, now, ws)
        maybe_feed_triple_store(a, "co_occurs", b, ws)
        maybe_feed_triple_store(b, "co_occurs", a, ws)
      end)

      # context → node (lives_in)
      if is_binary(node) and node != "" do
        insert_edge_via_store(id, node, "lives_in", 1.0, now, ws)
        maybe_feed_triple_store(id, "lives_in", node, ws)
      end

      # context → context (cross_ref) — extra destinations beyond the primary node
      cross_refs = Enum.reject(routed_to, fn dest -> dest == node end)

      Enum.each(cross_refs, fn dest ->
        insert_edge_via_store(id, dest, "cross_ref", 0.8, now, ws)
        maybe_feed_triple_store(id, "cross_ref", dest, ws)
      end)

      # context → context (supersedes)
      if is_binary(supersedes) and supersedes != "" do
        insert_edge_via_store(id, supersedes, "supersedes", 1.0, now, ws)
        maybe_feed_triple_store(id, "supersedes", supersedes, ws)
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
    Enum.each(context_edges(context), &insert_edge_direct(db, &1))
  end

  @doc """
  The edges a context implies, as parameter lists for `edge_insert_sql/0`:
  `[source, target, relation, weight, valid_from, workspace_id]`.

  Entities are `mentioned_in` the context and `co_occurs` with each other, the
  context `lives_in` its node, has a `cross_ref` to every other destination,
  and `supersedes` the context it replaces. Every canonical store writes these
  edges with the context.
  """
  @spec context_edges(map() | struct()) :: [[term()]]
  def context_edges(context) do
    id = struct_or_map_get(context, :id)

    if is_binary(id) do
      node = struct_or_map_get(context, :node)
      entities = struct_or_map_get(context, :entities) || []
      routed_to = struct_or_map_get(context, :routed_to) || []
      supersedes = struct_or_map_get(context, :supersedes)
      ws = context_workspace(context)

      now = DateTime.to_iso8601(DateTime.utc_now())

      mentions = Enum.map(entities, &[&1, id, "mentioned_in", 1.0, now, ws])

      co_occurs =
        Enum.flat_map(co_occurrence_pairs(entities), fn {a, b} ->
          [[a, b, "co_occurs", 0.5, now, ws], [b, a, "co_occurs", 0.5, now, ws]]
        end)

      lives_in =
        if is_binary(node) and node != "", do: [[id, node, "lives_in", 1.0, now, ws]], else: []

      cross_refs =
        routed_to
        |> Enum.reject(&(&1 == node))
        |> Enum.map(&[id, &1, "cross_ref", 0.8, now, ws])

      supersession =
        if is_binary(supersedes) and supersedes != "",
          do: [[id, supersedes, "supersedes", 1.0, now, ws]],
          else: []

      mentions ++ co_occurs ++ lives_in ++ cross_refs ++ supersession
    else
      []
    end
  end

  @doc """
  Seeds `works_on` edges from topology — entity → node relationships.

  These encode which people work on which nodes. Idempotent (INSERT OR IGNORE).

  Options:
  - `:workspace_id` - workspace to attribute the edges to (default: "default";
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
  1. Clears the graph edges (one workspace, or all)
  2. Iterates contexts and creates their edges, attributed to each context's
     own `workspace_id` and that workspace's tenant
  3. Seeds topology works_on edges (into the "default" workspace)

  Options:
  - `:workspace_id` - rebuild only this workspace's edges. When omitted, ALL
    edges are rebuilt; because attribution is taken per-context, a full
    rebuild also repairs the workspace and tenant of every edge.
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
  - `:direction`    - `:out` (default), `:in`, or `:both`
  - `:relation`     - filter by relation type
  - `:workspace_id` - workspace to scope to (default: "default")
  - `:tenant_id`    - tenant to scope to (default: the workspace's tenant)
  """
  @spec edges_for(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def edges_for(id, opts \\ []) when is_binary(id) do
    direction = Keyword.get(opts, :direction, :out)
    relation = Keyword.get(opts, :relation)
    {tenant_id, ws} = scope(opts)

    {where_clause, params} = build_edges_where(id, direction, relation)
    n = length(params)
    where_clause = "(#{where_clause}) AND tenant_id = ?#{n + 1} AND workspace_id = ?#{n + 2}"

    sql = "SELECT source_id, target_id, relation, weight FROM graph_edges WHERE #{where_clause}"

    case Store.raw_query(sql, params ++ [tenant_id, ws]) do
      {:ok, rows} ->
        edges = Enum.map(rows, &row_to_edge/1)
        {:ok, edges}

      err ->
        err
    end
  end

  @doc """
  Returns every edge of the given relations in a workspace, as maps with
  `:source_id`, `:target_id` and `:relation`. Importers use it to compare the
  edges they mean to hold with the edges already there.

  Options: `:workspace_id` (default: `"default"`) and `:tenant_id` (default:
  the workspace's tenant, as `scope/1` describes).
  """
  @spec edges_by_relation([String.t()], keyword()) :: {:ok, [map()]} | {:error, term()}
  def edges_by_relation(relations, opts \\ []) when is_list(relations) do
    {tenant_id, ws} = scope(opts)

    if relations == [] do
      {:ok, []}
    else
      placeholders = Enum.map_join(1..length(relations), ", ", &"?#{&1 + 2}")

      case Store.raw_query(
             "SELECT source_id, target_id, relation FROM graph_edges WHERE tenant_id = ?1 AND workspace_id = ?2 AND relation IN (#{placeholders})",
             [tenant_id, ws | relations]
           ) do
        {:ok, rows} ->
          {:ok,
           Enum.map(rows, fn [source, target, relation] ->
             %{source_id: source, target_id: target, relation: relation}
           end)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Returns all contexts that mention a given entity (traverse mentioned_in edges).

  Options:
  - `:workspace_id` - workspace to scope to (default: "default")
  - `:tenant_id`    - tenant to scope to (default: the workspace's tenant)
  """
  @spec related_contexts(String.t(), keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def related_contexts(entity_name, opts \\ []) when is_binary(entity_name) do
    {tenant_id, ws} = scope(opts)

    sql = """
    SELECT target_id FROM graph_edges
    WHERE tenant_id = ?2 AND workspace_id = ?3 AND source_id = ?1 AND relation = 'mentioned_in'
    """

    case Store.raw_query(sql, [entity_name, tenant_id, ws]) do
      {:ok, rows} -> {:ok, Enum.map(rows, fn [id] -> id end)}
      err -> err
    end
  end

  @doc """
  Returns the 1-hop subgraph around a context ID.
  Returns all edges where source_id OR target_id equals the context_id.

  Options:
  - `:workspace_id` - workspace to scope to (default: "default")
  - `:tenant_id`    - tenant to scope to (default: the workspace's tenant)
  """
  @spec subgraph(String.t(), pos_integer(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def subgraph(context_id, _depth \\ 1, opts \\ []) when is_binary(context_id) do
    {tenant_id, ws} = scope(opts)

    sql = """
    SELECT source_id, target_id, relation, weight FROM graph_edges
    WHERE tenant_id = ?2 AND workspace_id = ?3 AND (source_id = ?1 OR target_id = ?1)
    """

    case Store.raw_query(sql, [context_id, tenant_id, ws]) do
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
  - `:workspace_id` - workspace to scope to (default: "default")
  - `:tenant_id`    - tenant to scope to (default: the workspace's tenant)
  """
  @spec stats(keyword()) :: {:ok, map()} | {:error, term()}
  def stats(opts \\ []) do
    {tenant_id, ws} = scope(opts)
    scoped = "FROM graph_edges WHERE tenant_id = ?1 AND workspace_id = ?2"

    queries = [
      {"total_edges", "SELECT COUNT(*) #{scoped}"},
      {"mentioned_in", "SELECT COUNT(*) #{scoped} AND relation = 'mentioned_in'"},
      {"lives_in", "SELECT COUNT(*) #{scoped} AND relation = 'lives_in'"},
      {"works_on", "SELECT COUNT(*) #{scoped} AND relation = 'works_on'"},
      {"cross_ref", "SELECT COUNT(*) #{scoped} AND relation = 'cross_ref'"},
      {"supersedes", "SELECT COUNT(*) #{scoped} AND relation = 'supersedes'"}
    ]

    result =
      Enum.reduce_while(queries, %{}, fn {key, sql}, acc ->
        case Store.raw_query(sql, [tenant_id, ws]) do
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
  - `:workspace_id` - workspace to scope to (default: "default")
  - `:tenant_id`    - tenant to scope to (default: the workspace's tenant)
  """
  @spec top_entities(pos_integer(), keyword()) ::
          {:ok, [{String.t(), non_neg_integer()}]} | {:error, term()}
  def top_entities(limit \\ 10, opts \\ []) do
    {tenant_id, ws} = scope(opts)

    sql = """
    SELECT source_id, COUNT(*) as cnt
    FROM graph_edges
    WHERE tenant_id = ?2 AND workspace_id = ?3 AND relation IN ('mentioned_in', 'works_on')
    GROUP BY source_id
    ORDER BY cnt DESC
    LIMIT ?1
    """

    case Store.raw_query(sql, [limit, tenant_id, ws]) do
      {:ok, rows} -> {:ok, Enum.map(rows, fn [id, cnt] -> {id, cnt} end)}
      err -> err
    end
  end

  @doc """
  Returns sample edges for display.

  Options:
  - `:workspace_id` - workspace to scope to (default: "default")
  - `:tenant_id`    - tenant to scope to (default: the workspace's tenant)
  """
  @spec sample_edges(pos_integer(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def sample_edges(limit \\ 10, opts \\ []) do
    {tenant_id, ws} = scope(opts)

    sql = """
    SELECT source_id, target_id, relation, weight
    FROM graph_edges
    WHERE tenant_id = ?2 AND workspace_id = ?3
    ORDER BY ROWID DESC
    LIMIT ?1
    """

    case Store.raw_query(sql, [limit, tenant_id, ws]) do
      {:ok, rows} -> {:ok, Enum.map(rows, &row_to_edge/1)}
      err -> err
    end
  end

  @doc """
  The `{tenant_id, workspace_id}` an edge read covers.

  `:workspace_id` defaults to `"default"`. `:tenant_id` defaults to the
  workspace's own tenant, the tenant its edges were written with: for a
  workspace that is not registered, the tenant its `"<tenant>:"` prefix
  names, else `"default"`. A caller serving a request passes
  the requester's tenant, so another tenant's workspace reads as empty.
  """
  @spec scope(keyword()) :: {String.t(), String.t()}
  def scope(opts) do
    ws = Keyword.get(opts, :workspace_id) || "default"
    {Keyword.get(opts, :tenant_id) || workspace_tenant(ws), ws}
  end

  @doc """
  Counts edges: every edge, one tenant's (`:tenant_id` alone), or one
  workspace's (`:workspace_id`, scoped as `scope/1` describes).
  """
  @spec count(keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def count(opts \\ []) do
    {sql, params} =
      cond do
        Keyword.get(opts, :workspace_id) ->
          {tenant_id, ws} = scope(opts)

          {"SELECT COUNT(*) FROM graph_edges WHERE tenant_id = ?1 AND workspace_id = ?2",
           [tenant_id, ws]}

        tenant_id = Keyword.get(opts, :tenant_id) ->
          {"SELECT COUNT(*) FROM graph_edges WHERE tenant_id = ?1", [tenant_id]}

        true ->
          {"SELECT COUNT(*) FROM graph_edges", []}
      end

    case Store.raw_query(sql, params) do
      {:ok, [[count]]} -> {:ok, count}
      {:ok, []} -> {:ok, 0}
      err -> err
    end
  end

  # The tenant edges are written with (@edge_insert_sql).
  defp workspace_tenant(ws) do
    sql = """
    SELECT COALESCE((SELECT w.tenant_id FROM workspaces w WHERE w.id = ?1),
                    (SELECT t.id FROM tenants t WHERE t.id = substr(?1, 1, instr(?1, ':') - 1)),
                    'default')
    """

    case Store.raw_query(sql, [ws]) do
      {:ok, [[tenant_id]]} when is_binary(tenant_id) -> tenant_id
      _ -> "default"
    end
  end

  @doc """
  Creates `claim --about--> entity` edges for an extracted claim.

  Idempotent (INSERT OR IGNORE). Used by the intake pipeline after claim
  extraction to link a Claim to the entities its source signal mentions.
  Additive: failures are logged and swallowed, never raised.

  Options:
  - `:workspace_id` - workspace to attribute the edges to (default: "default");
    the edges take that workspace's tenant
  """
  @spec create_claim_edges(String.t(), [String.t()], keyword()) :: :ok
  def create_claim_edges(claim_id, entities, opts \\ [])
      when is_binary(claim_id) and is_list(entities) do
    ws = Keyword.get(opts, :workspace_id, "default")
    now = DateTime.to_iso8601(DateTime.utc_now())

    entities
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
    |> Enum.each(fn entity ->
      insert_edge_via_store(claim_id, entity, "about", 1.0, now, ws)
    end)

    :ok
  end

  @doc """
  Writes a context's semantic edges: `context --mentions--> entity` for each
  of its entities, and `entity --co_occurs_with--> entity` in both directions
  for each pair of them (`assert_edge/4`). Intake writes them when it files a
  signal, beside the structural edges of `create_edges_for_context/1`, and
  `backfill/1` writes them again for indexed contexts.
  """
  @spec create_semantic_edges_for_context(map() | struct()) :: :ok
  def create_semantic_edges_for_context(context) do
    id = struct_or_map_get(context, :id)
    entities = struct_or_map_get(context, :entities) || []
    opts = [workspace_id: context_workspace(context)]

    if is_binary(id) do
      entities
      |> Enum.filter(&(is_binary(&1) and &1 != ""))
      |> Enum.uniq()
      |> Enum.each(&assert_edge(id, &1, "mentions", opts))

      Enum.each(co_occurrence_pairs(entities), fn {a, b} ->
        assert_edge(a, b, "co_occurs_with", opts)
        assert_edge(b, a, "co_occurs_with", opts)
      end)
    end

    :ok
  end

  @doc """
  Writes the edges of the contexts and claims already indexed, as ingest
  writes them: each context's structural edges (`create_edges_for_context/1`)
  and semantic edges (`create_semantic_edges_for_context/1`), then
  `claim --about--> entity` for each claim with a source context
  (`create_claim_edges/3`). Every insert is `INSERT OR IGNORE`, so a run adds
  only what is missing and is safe to repeat.

  A completed run is recorded in `graph_backfills` (for its workspace, or for
  every workspace when none is given), which `backfill_status/1` reads.

  Options:
  - `:workspace_id` - only that workspace's contexts and claims (default: every
    workspace)
  - `:claims`       - false skips the claim pass (default: true)
  - `:batch`        - rows per progress report (default: 200)
  - `:on_progress`  - called with `{:contexts | :claims, rows_so_far}` after
    each batch

  Returns `{:ok, %{contexts:, claims:, edges_before:, edges_after:}}`, the
  edge counts taken over the run's scope.
  """
  @spec backfill(keyword()) :: {:ok, map()} | {:error, term()}
  def backfill(opts \\ []) do
    ws = Keyword.get(opts, :workspace_id)
    pass = {ws, max(Keyword.get(opts, :batch, 200), 1), Keyword.get(opts, :on_progress)}
    count_opts = if ws, do: [workspace_id: ws], else: []
    tenant_id = if ws, do: elem(scope(count_opts), 0)

    with {:ok, before} <- count(count_opts),
         {:ok, contexts} <- backfill_pass(:contexts, pass),
         {:ok, claims} <-
           if(Keyword.get(opts, :claims, true), do: backfill_pass(:claims, pass), else: {:ok, 0}),
         {:ok, after_count} <- count(count_opts),
         result = %{
           contexts: contexts,
           claims: claims,
           edges_before: before,
           edges_after: after_count
         },
         {:ok, _} <-
           Store.raw_query(
             """
             INSERT INTO graph_backfills
               (tenant_id, workspace_id, contexts, claims, edges_before, edges_after)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6)
             """,
             [tenant_id, ws, contexts, claims, before, after_count]
           ) do
      {:ok, result}
    end
  end

  @doc """
  Whether a workspace still needs the graph backfill its upgrade calls for.

  The migration that created `graph_edges` copied the legacy `edges` table,
  whose key had dropped every edge a second workspace shared with a first;
  `backfill/1` writes them again. `backfill_needed` is true while the legacy
  table holds rows of the workspace and no backfill has completed for it or
  for every workspace since; an Engine that never had legacy edges reads
  false. `legacy_edges` counts the workspace's rows in the legacy table (0
  when the table is absent).
  """
  @spec backfill_status(String.t()) ::
          {:ok, %{backfill_needed: boolean(), legacy_edges: non_neg_integer()}}
          | {:error, term()}
  def backfill_status(workspace_id) when is_binary(workspace_id) do
    with {:ok, legacy} <- Migrations.superseded_row_count("edges", workspace_id),
         {:ok, [[runs]]} <-
           Store.raw_query(
             "SELECT COUNT(*) FROM graph_backfills WHERE workspace_id IS NULL OR workspace_id = ?1",
             [workspace_id]
           ) do
      {:ok, %{backfill_needed: legacy > 0 and runs == 0, legacy_edges: legacy}}
    end
  end

  defp backfill_pass(phase, {ws, batch, on_progress}) do
    {sql, params} = backfill_select(phase, ws)

    with {:ok, rows} <- Store.raw_query(sql, params) do
      total =
        rows
        |> Enum.chunk_every(batch)
        |> Enum.reduce(0, fn chunk, done ->
          Enum.each(chunk, &backfill_row(phase, &1))
          done = done + length(chunk)
          if on_progress, do: on_progress.({phase, done})
          done
        end)

      {:ok, total}
    end
  end

  defp backfill_select(:contexts, ws) do
    {"SELECT id, node, entities, routed_to, supersedes, workspace_id FROM contexts" <>
       if(ws, do: " WHERE workspace_id = ?1", else: ""), List.wrap(ws)}
  end

  # Claims link to their source context through signal_id; the entities come
  # from that context.
  defp backfill_select(:claims, ws) do
    {"""
     SELECT cl.id, c.entities, cl.workspace_id
     FROM claims cl
     JOIN contexts c ON c.id = cl.signal_id
     WHERE cl.signal_id IS NOT NULL
     """ <> if(ws, do: " AND cl.workspace_id = ?1", else: ""), List.wrap(ws)}
  end

  defp backfill_row(:contexts, [id, node, entities, routed_to, supersedes, ws]) do
    context = %{
      id: id,
      node: node,
      entities: decode_json_list(entities),
      routed_to: decode_json_list(routed_to),
      supersedes: supersedes,
      workspace_id: ws || "default"
    }

    create_edges_for_context(context)
    create_semantic_edges_for_context(context)
  end

  defp backfill_row(:claims, [claim_id, entities, ws]) do
    case decode_json_list(entities) do
      [] -> :ok
      list -> create_claim_edges(claim_id, list, workspace_id: ws || "default")
    end
  end

  @doc """
  Returns candidate context IDs reachable from a set of query entities by
  traversing the graph up to `hops` hops.

  This is a graph candidate generator for retrieval fusion. Starting from the
  query entities, it follows `mentioned_in` edges (entity → context) to gather
  contexts, and `co_occurs` edges (entity → entity) to expand the entity
  frontier for additional hops.

  Returns `{:ok, [context_id]}` ranked by how many query-reachable entities
  mention each context (descending), so densely-connected contexts surface first.

  Options:
  - `:workspace_id` - workspace to scope to (default: "default")
  - `:tenant_id`    - tenant to scope to (default: the workspace's tenant)
  - `:limit`        - max context IDs to return (default: 20)
  """
  @spec graph_candidates([String.t()], pos_integer(), keyword()) ::
          {:ok, [String.t()]} | {:error, term()}
  def graph_candidates(query_entities, hops \\ 1, opts \\ [])
      when is_list(query_entities) and is_integer(hops) and hops >= 1 do
    scope = scope(opts)
    limit = Keyword.get(opts, :limit, 20)

    seed =
      query_entities
      |> Enum.filter(&(is_binary(&1) and &1 != ""))
      |> MapSet.new()

    {entities, context_scores} = expand_frontier(seed, hops, scope)
    _ = entities

    ranked =
      context_scores
      |> Enum.sort_by(fn {_id, score} -> score end, :desc)
      |> Enum.map(fn {id, _score} -> id end)
      |> Enum.take(limit)

    {:ok, ranked}
  rescue
    error -> {:error, error}
  end

  # Breadth-first expansion: accumulate mentioned_in contexts (scored by mention
  # count) and grow the entity frontier via co_occurs for each remaining hop.
  defp expand_frontier(seed_entities, hops, scope) do
    Enum.reduce(1..hops, {seed_entities, MapSet.new(), %{}}, fn _hop, {frontier, visited, scores} ->
      to_visit = MapSet.difference(frontier, visited)

      {next_frontier, new_scores} =
        Enum.reduce(to_visit, {MapSet.new(), scores}, fn entity, {nf, sc} ->
          ctx_ids = entity_contexts(entity, scope)
          sc = Enum.reduce(ctx_ids, sc, fn cid, acc -> Map.update(acc, cid, 1, &(&1 + 1)) end)
          neighbors = co_occurring_entities(entity, scope)
          {MapSet.union(nf, MapSet.new(neighbors)), sc}
        end)

      {next_frontier, MapSet.union(visited, to_visit), new_scores}
    end)
    |> then(fn {_frontier, _visited, scores} -> {MapSet.new(), scores} end)
  end

  defp entity_contexts(entity, {tenant_id, ws}) do
    sql =
      "SELECT target_id FROM graph_edges WHERE tenant_id = ?2 AND workspace_id = ?3 AND source_id = ?1 AND relation = 'mentioned_in'"

    case Store.raw_query(sql, [entity, tenant_id, ws]) do
      {:ok, rows} -> Enum.map(rows, fn [id] -> id end)
      _ -> []
    end
  end

  defp co_occurring_entities(entity, {tenant_id, ws}) do
    sql =
      "SELECT target_id FROM graph_edges WHERE tenant_id = ?2 AND workspace_id = ?3 AND source_id = ?1 AND relation = 'co_occurs'"

    case Store.raw_query(sql, [entity, tenant_id, ws]) do
      {:ok, rows} -> Enum.map(rows, fn [id] -> id end)
      _ -> []
    end
  end

  # Unordered distinct pairs of entities (for co_occurs edges). Filters blanks
  # and self-pairs; returns each pair once as {a, b}.
  defp co_occurrence_pairs(entities) do
    clean =
      entities
      |> Enum.filter(&(is_binary(&1) and &1 != ""))
      |> Enum.uniq()

    for {a, i} <- Enum.with_index(clean),
        {b, j} <- Enum.with_index(clean),
        i < j,
        do: {a, b}
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

  # nil workspace = full rebuild across all workspaces. A workspace's rebuild
  # clears every edge filed under it, whatever tenant it was written with, so
  # the rebuilt edges are attributed afresh.
  defp clear_edges(nil) do
    case Store.raw_query("DELETE FROM graph_edges", []) do
      {:ok, _} -> :ok
      :ok -> :ok
      err -> err
    end
  end

  defp clear_edges(ws) when is_binary(ws) do
    case Store.raw_query("DELETE FROM graph_edges WHERE workspace_id = ?1", [ws]) do
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
        if ws, do: count(workspace_id: ws), else: count()

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

  # An edge takes the tenant of its workspace, as a context does
  # (`Store.insert_context`): for a workspace that is not registered, the
  # tenant its "<tenant>:" prefix names, else `"default"`.
  @edge_insert_sql """
  INSERT OR IGNORE INTO graph_edges
    (source_id, target_id, relation, weight, valid_from, workspace_id, tenant_id)
  VALUES (?1, ?2, ?3, ?4, ?5, ?6,
          COALESCE((SELECT w.tenant_id FROM workspaces w WHERE w.id = ?6),
                   (SELECT t.id FROM tenants t WHERE t.id = substr(?6, 1, instr(?6, ':') - 1)),
                   'default'))
  """

  @doc "The statement that writes one edge and ignores a duplicate."
  @spec edge_insert_sql() :: String.t()
  def edge_insert_sql, do: @edge_insert_sql

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

  # Insert directly via db reference (for use inside Store callbacks, which
  # avoids a deadlock)
  defp insert_edge_direct(db, params) do
    with {:ok, stmt} <- Exqlite.Sqlite3.prepare(db, @edge_insert_sql),
         :ok <- Exqlite.Sqlite3.bind(stmt, params),
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

  # ---------------------------------------------------------------------------
  # Private: triple-store feed
  # ---------------------------------------------------------------------------

  # Feeds a single edge into the default Knowledge.Store as a quad
  # {workspace_id, source, predicate, object}. Silently swallows any error
  # (the triple store is a secondary index — SQLite edges are the source of
  # truth). Uses GenServer call only when the store is registered and alive.
  defp maybe_feed_triple_store(source, predicate, target, workspace) do
    store_name = {:via, Registry, {OptimalEngine.Knowledge.Registry, @default_triple_store}}

    case Registry.lookup(OptimalEngine.Knowledge.Registry, @default_triple_store) do
      [{_pid, _value}] ->
        OptimalEngine.Knowledge.Store.assert(store_name, workspace, source, predicate, target)

      [] ->
        :noop
    end
  rescue
    _ -> :noop
  end

  defp maybe_retract_triple(source, predicate, target, workspace) do
    store_name = {:via, Registry, {OptimalEngine.Knowledge.Registry, @default_triple_store}}

    case Registry.lookup(OptimalEngine.Knowledge.Registry, @default_triple_store) do
      [{_pid, _value}] ->
        OptimalEngine.Knowledge.Store.retract(store_name, workspace, source, predicate, target)

      [] ->
        :noop
    end
  rescue
    _ -> :noop
  end
end
