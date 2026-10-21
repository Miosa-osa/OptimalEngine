defmodule OptimalEngine.Bridge.Knowledge do
  @moduledoc """
  Bridge to OptimalEngine.Knowledge — stateless graph queries via SQLite, on-demand OWL reasoning.

  ## Design

  Graph queries (`graph_boost/3`, `context_for/2`) query SQLite graph edges
  directly: no GenServer hop, no ETS copy. Fast and simple.

  OWL reasoning (`materialize/1`) is on-demand only: lazily opens a OptimalEngine.Knowledge
  store, syncs edges, runs the reasoner, then returns. This is the ONE time we
  duplicate data into ETS, because OWL 2 RL needs a triple store to reason over.

  Every query reads one tenant's workspace (`:workspace_id`, default
  `"default"`, and `:tenant_id`, default the workspace's tenant; see
  `OptimalEngine.Graph.scope/1`), so another workspace's or tenant's edges
  never boost, describe, or feed reasoning about this one.

  ## Integration points

  - `graph_boost/3` - Boosts search results by graph connectivity (queries SQLite directly)
  - `context_for/2` - Builds markdown context for a topic (queries SQLite directly)
  - `materialize/1` - Syncs edges to OptimalEngine.Knowledge, runs OWL 2 RL, returns inferred count
  - `sync_and_materialize/1` - Same as materialize, explicit name for indexer use
  """

  require Logger

  alias OptimalEngine.Graph
  alias OptimalEngine.Retrieval.Ranking
  alias OptimalEngine.Store

  @store_name :optimal_knowledge

  # ---------------------------------------------------------------------------
  # Graph Boost — queries SQLite edges directly
  # ---------------------------------------------------------------------------

  @doc """
  Boosts search results that are connected in the knowledge graph.

  Queries the SQLite `graph_edges` table directly: no GenServer, no ETS copy.
  For each result, checks if its entities appear connected to the query terms
  in the results' workspace (`opts` as the moduledoc describes).
  Connected results get a score boost.

  The boost multiplies the exact score (`rank_score`), not the rounded one, and
  rounds only the displayed `score` (`OptimalEngine.Retrieval.Ranking`). It
  returns the results in the order it was given them and does not sort, so the
  scores of a boosted list are not necessarily in descending order. (The default
  `OptimalEngine.Retrieval.Search` merges the boosted contexts with memories
  afterwards and orders that list by the boosted scores.)
  """
  @spec graph_boost([map()], String.t(), keyword()) :: [map()]
  def graph_boost(results, query, opts \\ []) when is_list(results) and is_binary(query) do
    terms = query |> String.downcase() |> String.split(~r/\s+/, trim: true)

    connected_entities = find_connected_entities(terms, Graph.scope(opts))

    if MapSet.size(connected_entities) == 0 do
      results
    else
      Enum.map(results, fn result ->
        entities = Map.get(result, :entities, []) || []

        boost =
          entities
          |> Enum.count(&MapSet.member?(connected_entities, &1))
          |> then(fn count -> 1.0 + count * 0.1 end)

        if is_number(Map.get(result, :score)) do
          Ranking.put_score(result, Ranking.exact_score(result) * boost, 4)
        else
          result
        end
      end)
    end
  rescue
    _ -> results
  end

  # ---------------------------------------------------------------------------
  # Context For — queries SQLite edges directly
  # ---------------------------------------------------------------------------

  @doc """
  Builds a structured context snapshot for a given entity/topic.
  Returns a markdown-formatted string ready for LLM injection.

  Queries SQLite graph edges of one workspace directly for relationships
  (`opts` as the moduledoc describes), then formats as markdown.
  """
  @spec context_for(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def context_for(entity, opts \\ []) when is_binary(entity) do
    {tenant_id, ws} = Graph.scope(opts)
    scoped = "FROM graph_edges WHERE tenant_id = ?2 AND workspace_id = ?3"

    # Find all edges where entity is source or target
    outgoing_sql = "SELECT source_id, relation, target_id #{scoped} AND source_id LIKE ?1"
    incoming_sql = "SELECT source_id, relation, target_id #{scoped} AND target_id LIKE ?1"
    params = ["%#{entity}%", tenant_id, ws]

    with {:ok, out_rows} <- Store.raw_query(outgoing_sql, params),
         {:ok, in_rows} <- Store.raw_query(incoming_sql, params) do
      all_edges = out_rows ++ in_rows

      if all_edges == [] do
        {:ok, "No knowledge graph context found for: #{entity}"}
      else
        markdown = format_context_markdown(entity, all_edges)
        {:ok, markdown}
      end
    end
  rescue
    e -> {:error, e}
  end

  # ---------------------------------------------------------------------------
  # OWL Reasoning — on-demand only
  # ---------------------------------------------------------------------------

  @doc """
  Syncs SQLite edges into a temporary OptimalEngine.Knowledge store and runs OWL 2 RL
  materialization. This is the ONE time we sync, after full reindex.

  Returns `{:ok, inferred_count}` or `{:error, reason}`.
  """
  @spec materialize(keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def materialize(opts \\ []) do
    sync_and_materialize(opts)
  end

  @doc """
  Syncs edges from SQLite to OptimalEngine.Knowledge ETS store, then runs OWL reasoning.
  Called after full index to make the knowledge graph smarter.

  With `:workspace_id` it reasons over that workspace (`opts` as the
  moduledoc describes). Without it, every tenant's workspace is reasoned
  over in a store of its own, so no inference joins two workspaces' edges;
  the inferred counts are summed.
  """
  @spec sync_and_materialize(keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def sync_and_materialize(opts \\ []) do
    Logger.info("[Bridge.Knowledge] Starting on-demand OWL materialization...")

    scopes =
      if Keyword.get(opts, :workspace_id),
        do: {:ok, [Graph.scope(opts)]},
        else: edge_scopes()

    with {:ok, scopes} <- scopes do
      Enum.reduce_while(scopes, {:ok, 0}, fn scope, {:ok, total} ->
        case materialize_scope(scope) do
          {:ok, inferred} -> {:cont, {:ok, total + inferred}}
          {:error, _} = error -> {:halt, error}
        end
      end)
    end
  rescue
    e ->
      Logger.error("[Bridge.Knowledge] Materialization failed: #{inspect(e)}")
      {:error, e}
  end

  @doc """
  Returns the triple count by counting graph edges in SQLite: every edge, or
  those `OptimalEngine.Graph.count/1` selects with `opts`.
  """
  @spec count(keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def count(opts \\ []), do: Graph.count(opts)

  defp edge_scopes do
    case Store.raw_query("SELECT DISTINCT tenant_id, workspace_id FROM graph_edges", []) do
      {:ok, rows} -> {:ok, Enum.map(rows, fn [tenant_id, ws] -> {tenant_id, ws} end)}
      {:error, _} = err -> err
    end
  end

  defp materialize_scope(scope) do
    with {:ok, store} <- open_knowledge_store() do
      try do
        with {:ok, synced} <- sync_edges_to_store(store, scope) do
          result = run_materialization(store)
          Logger.info("[Bridge.Knowledge] Materialized #{synced} edges: #{inspect(result)}")
          result
        end
      after
        OptimalEngine.Knowledge.close(store)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Private: SQLite-based graph queries
  # ---------------------------------------------------------------------------

  defp find_connected_entities(terms, {tenant_id, ws}) do
    scoped = "FROM graph_edges WHERE tenant_id = ?2 AND workspace_id = ?3"

    terms
    |> Enum.flat_map(fn term ->
      params = ["%#{term}%", tenant_id, ws]

      # Find entities connected as objects (term is subject)
      objects =
        case Store.raw_query(
               "SELECT DISTINCT target_id #{scoped} AND LOWER(source_id) LIKE ?1",
               params
             ) do
          {:ok, rows} -> Enum.map(rows, fn [target] -> target end)
          _ -> []
        end

      # Find entities connected as subjects (term is object)
      subjects =
        case Store.raw_query(
               "SELECT DISTINCT source_id #{scoped} AND LOWER(target_id) LIKE ?1",
               params
             ) do
          {:ok, rows} -> Enum.map(rows, fn [source] -> source end)
          _ -> []
        end

      objects ++ subjects
    end)
    |> MapSet.new()
  end

  defp format_context_markdown(entity, edges) do
    grouped =
      Enum.group_by(edges, fn [_s, relation, _t] -> relation end)

    sections =
      Enum.map(grouped, fn {relation, rows} ->
        items =
          Enum.map(rows, fn [source, _rel, target] ->
            if String.contains?(String.downcase(source), String.downcase(entity)) do
              "  - → #{target}"
            else
              "  - ← #{source}"
            end
          end)

        "### #{relation}\n#{Enum.join(items, "\n")}"
      end)

    "## Knowledge Graph: #{entity}\n\n#{Enum.join(sections, "\n\n")}"
  end

  # ---------------------------------------------------------------------------
  # Private: On-demand OptimalEngine.Knowledge store
  # ---------------------------------------------------------------------------

  defp open_knowledge_store do
    OptimalEngine.Knowledge.open(@store_name,
      name: nil,
      backend: OptimalEngine.Knowledge.Backend.ETS
    )
  end

  defp sync_edges_to_store(store, {tenant_id, ws}) do
    case Store.raw_query(
           "SELECT source_id, relation, target_id FROM graph_edges WHERE tenant_id = ?1 AND workspace_id = ?2",
           [tenant_id, ws]
         ) do
      {:ok, rows} ->
        triples =
          Enum.map(rows, fn [source, relation, target] ->
            {source, relation, target}
          end)

        OptimalEngine.Knowledge.assert_many(store, triples)
        Logger.info("[Bridge.Knowledge] Synced #{length(triples)} edges as triples")
        {:ok, length(triples)}

      {:error, _} = err ->
        err
    end
  end

  defp run_materialization(store) do
    OptimalEngine.Knowledge.Store.materialize(store)
  end
end
