defmodule OptimalEngine.Graph.Backfill do
  @moduledoc """
  Builds the relationship edges of contexts and claims that are already
  indexed.

  For each context in scope it writes, through
  `OptimalEngine.Graph.create_edges_for_context/1`:

    * `entity --mentioned_in--> context`
    * `entity --co_occurs--> entity` (both directions, for each shared pair)
    * `context --lives_in--> node`
    * `context --cross_ref--> node` (extra routed-to destinations)
    * `context --supersedes--> context`

  and its semantic edges, through
  `OptimalEngine.Graph.create_semantic_edges_for_context/1`:

    * `context --mentions--> entity`
    * `entity --co_occurs_with--> entity` (both directions, for each shared pair)

  Then, for each claim with a source context, `claim --about--> entity` for
  the entities of that context (`OptimalEngine.Graph.create_claim_edges/3`).
  Every edge carries the tenant and workspace of the row it was derived from.

  Every edge is written through `OptimalEngine.Graph.backfill_row/2`, as
  `OptimalEngine.Graph.backfill/1` writes it, and a failed write is counted
  in `:failed_edges`. A run is recorded in `graph_backfills`, which
  `OptimalEngine.Graph.backfill_status/1` reads, on the terms
  `Graph.backfill/1` records one: it covered a workspace, or every workspace,
  in one go (no `:after`) to the end, with the claim pass and no failed
  write. A run over one tenant's workspaces is not recorded there.

  Every insert is `INSERT OR IGNORE`, so a run is idempotent. Contexts, then
  claims, are read a page at a time in id order, and every edge is its own
  Store call, so other callers keep getting the single-writer Store.

  Options for `run/1` and `status/1`:

    * `:workspace_id` or `:tenant_id` narrow the scope (default: every tenant);
    * `:claims` set to false skips the claim pass (default true);
    * `:limit` caps the contexts and claims one run processes, or
      `:infinity` (the default);
    * `:page` is how many rows one Store call reads (default 200);
    * `:after` resumes a run: `{:contexts, id}` or `{:claims, id}` (`run/1`
      returns `:next`); `{:claims, ""}` runs the claim pass alone;
    * `:count` set to false leaves out `:edges_before` and `:edges_after`,
      two counts over the scope's edges (default true);
    * `:pause_ms` sleeps after each page (default 0);
    * `:on_page` is called after each page with `{:contexts, total}` or
      `{:claims, total}`.

  A workspace's contexts and claims are read through their
  `(workspace_id, id)` indexes. The SQL is SQLite's (`?N` parameters); a
  Postgres store ports it with `$N` parameters.
  """

  alias OptimalEngine.Graph
  alias OptimalEngine.Store
  alias OptimalEngine.Workspace

  @page 200

  @type cursor :: {:contexts | :claims, String.t()}

  @type result :: %{
          contexts: non_neg_integer(),
          claims: non_neg_integer(),
          failed_edges: non_neg_integer(),
          recorded: boolean(),
          edges_before: non_neg_integer() | nil,
          edges_after: non_neg_integer() | nil,
          next: cursor() | nil
        }

  @doc "How many contexts, claims with a source context, and edges are in scope."
  @spec status(keyword()) ::
          {:ok, %{contexts: non_neg_integer(), claims: non_neg_integer(), edges: non_neg_integer()}}
          | {:error, term()}
  def status(opts \\ []) do
    {context_where, context_params} = scope(opts, :contexts)
    {claim_where, claim_params} = scope(opts, :claims)

    with {:ok, [[contexts]]} <-
           Store.raw_query(
             "SELECT COUNT(*) FROM contexts c WHERE #{context_where}",
             context_params
           ),
         {:ok, [[claims]]} <-
           Store.raw_query(
             """
             SELECT COUNT(*) FROM claims cl JOIN contexts c ON c.id = cl.signal_id
             WHERE cl.signal_id IS NOT NULL AND #{claim_where}
             """,
             claim_params
           ),
         {:ok, edges} <- edge_count(opts) do
      {:ok, %{contexts: contexts, claims: claims, edges: edges}}
    end
  end

  @doc """
  Writes the edges of up to `:limit` contexts and claims in scope. See the
  module doc.

  `:next` is where to resume when the run stopped at its limit, or nil when
  it finished.
  """
  @spec run(keyword()) :: {:ok, result()} | {:error, term()}
  def run(opts \\ []) do
    pass = %{
      opts: opts,
      claims?: Keyword.get(opts, :claims, true),
      page: max(Keyword.get(opts, :page, @page), 1),
      pause: Keyword.get(opts, :pause_ms, 0),
      on_page: Keyword.get(opts, :on_page, fn _progress -> :ok end)
    }

    {phase, after_id} = Keyword.get(opts, :after) || {:contexts, ""}
    limit = Keyword.get(opts, :limit, :infinity)

    count? = Keyword.get(opts, :count, true)

    counts = %{contexts: 0, claims: 0, failed_edges: 0}

    with {:ok, before} <- maybe_count(count?, opts),
         {:ok, counts, next} <- walk(pass, phase, after_id, limit, counts),
         {:ok, edges_after} <- maybe_count(count?, opts),
         recorded = recorded?(opts, pass, counts, next),
         result =
           Map.merge(counts, %{
             recorded: recorded,
             edges_before: before,
             edges_after: edges_after,
             next: next
           }),
         :ok <- record(recorded, opts, result) do
      {:ok, result}
    end
  end

  # Graph.backfill/1's terms, for a run that read its whole scope itself: a
  # resumed run cannot see the failures of the runs before it.
  defp recorded?(opts, pass, counts, next) do
    next == nil and opts[:after] == nil and pass.claims? and counts.failed_edges == 0 and
      not tenant_scope?(opts)
  end

  # A run over one tenant's workspaces names neither one workspace nor all.
  defp tenant_scope?(opts), do: opts[:workspace_id] == nil and opts[:tenant_id] != nil

  defp record(false, _opts, _result), do: :ok

  defp record(true, opts, result) do
    case opts[:workspace_id] do
      nil -> insert_record(nil, nil, result)
      workspace_id -> insert_record(Workspace.tenant_of(workspace_id), workspace_id, result)
    end
  end

  defp insert_record(tenant_id, workspace_id, result) do
    case Store.raw_query(
           """
           INSERT INTO graph_backfills
             (tenant_id, workspace_id, contexts, claims, edges_before, edges_after)
           VALUES (?1, ?2, ?3, ?4, ?5, ?6)
           """,
           [
             tenant_id,
             workspace_id,
             result.contexts,
             result.claims,
             result.edges_before,
             result.edges_after
           ]
         ) do
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end

  # ── the walk ────────────────────────────────────────────────────────────

  defp walk(_pass, phase, after_id, limit, counts) when is_integer(limit) and limit <= 0,
    do: {:ok, counts, {phase, after_id}}

  defp walk(%{claims?: false}, :claims, _after_id, _limit, counts), do: {:ok, counts, nil}

  defp walk(pass, phase, after_id, limit, counts) do
    take = if limit == :infinity, do: pass.page, else: min(pass.page, limit)

    case read_page(pass.opts, phase, after_id, take) do
      {:ok, []} when phase == :contexts ->
        walk(pass, :claims, "", limit, counts)

      {:ok, []} ->
        {:ok, counts, nil}

      {:ok, rows} ->
        failed = rows |> Enum.map(&Graph.backfill_row(phase, &1)) |> Enum.sum()

        counts =
          counts
          |> Map.update!(phase, &(&1 + length(rows)))
          |> Map.update!(:failed_edges, &(&1 + failed))

        pass.on_page.({phase, Map.fetch!(counts, phase)})
        if pass.pause > 0, do: Process.sleep(pass.pause)
        last = rows |> List.last() |> hd()
        walk(pass, phase, last, spend(limit, length(rows)), counts)

      {:error, _} = error ->
        error
    end
  end

  defp spend(:infinity, _n), do: :infinity
  defp spend(limit, n), do: limit - n

  defp read_page(opts, phase, after_id, take) do
    {where, params} = scope(opts, phase)
    n = length(params)
    Store.raw_query(page_sql(phase, where, n), params ++ [after_id, take])
  end

  defp page_sql(:contexts, where, n) do
    """
    SELECT c.id, c.node, c.entities, c.routed_to, c.supersedes, c.workspace_id, c.tenant_id
    FROM contexts c
    WHERE c.id > ?#{n + 1} AND #{where}
    ORDER BY c.id
    LIMIT ?#{n + 2}
    """
  end

  # Claims link to their source context through signal_id; the entities come
  # from that context.
  defp page_sql(:claims, where, n) do
    """
    SELECT cl.id, c.entities, cl.workspace_id, cl.tenant_id
    FROM claims cl
    JOIN contexts c ON c.id = cl.signal_id
    WHERE cl.signal_id IS NOT NULL AND cl.id > ?#{n + 1} AND #{where}
    ORDER BY cl.id
    LIMIT ?#{n + 2}
    """
  end

  @doc false
  # The page statements of a workspace scope, with sample parameters, so a
  # test can check their query plans.
  @spec page_statements(String.t()) :: [{atom(), String.t(), [term()]}]
  def page_statements(workspace_id) do
    for phase <- [:contexts, :claims] do
      {where, params} = scope([workspace_id: workspace_id], phase)
      {phase, page_sql(phase, where, length(params)), params ++ ["", @page]}
    end
  end

  # ── scope and counts ────────────────────────────────────────────────────

  defp scope(opts, table) do
    prefix = if table == :contexts, do: "c", else: "cl"

    cond do
      workspace_id = opts[:workspace_id] -> {"#{prefix}.workspace_id = ?1", [workspace_id]}
      tenant_id = opts[:tenant_id] -> {"#{prefix}.tenant_id = ?1", [tenant_id]}
      true -> {"1 = 1", []}
    end
  end

  defp maybe_count(true, opts), do: edge_count(opts)
  defp maybe_count(false, _opts), do: {:ok, nil}

  # A workspace's edges are counted under the workspace's own tenant.
  defp edge_count(opts) do
    cond do
      workspace_id = opts[:workspace_id] -> Graph.count(workspace_id: workspace_id)
      tenant_id = opts[:tenant_id] -> Graph.count(tenant_id: tenant_id)
      true -> Graph.count()
    end
  end
end
