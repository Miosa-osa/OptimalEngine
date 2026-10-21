defmodule OptimalEngine.DataSteward.BareRelabel do
  @moduledoc """
  Gives a tenant back the rows it wrote under a bare workspace id and that were
  labelled `default`.

  Before 0.3.8 a context was filed under the tenant of its workspace row. A
  bare id has no workspace row, so what a tenant's key wrote under it was
  labelled `default`, and a tenant-scoped read does not see it. A write under
  a bare id names its tenant now (`OptimalEngine.Store.ContextTenant`); this
  moves the rows already there.

  A row is the tenant's when its provenance says so, and only then:

    * a **claim** points at a source package of the tenant in that workspace;
    * a **context** has a derivation ledger entry of intake (`intake.process`)
      that names a source package of the tenant and the context as its output,
      and no entry of another tenant's intake names it too (the same connector
      item on a shared id is one row, and whose it is cannot be told);
    * the **chunks**, **chunk embeddings**, **vectors**, **entities** and
      **decisions** of a context that is relabelled follow it;
    * a **graph edge** with a relabelled context or claim at one end follows
      it, unless its other end is a context or claim that stays. An edge that
      is already the tenant's makes the `default` copy a duplicate, which is
      dropped. An edge between two entities has no one context to answer for
      it and stays; running the graph backfill
      (`POST /api/maintenance/graph/backfill`) afterwards writes each
      context's edges for that context's tenant.

  A row with no source package (a batch import of signals, a file indexed on
  its own), one a source package of another tenant names, and one that is not
  `default` are left alone. The source packages and the ledger are the
  evidence, and they are not changed. The relabel is recorded in the tenant's
  evidence chain as `workspace.relabeled` (workspace, who, what moved), in the
  same transaction.

  The id must be bare (no `:`), name no workspace row (its owner decides what
  its rows are) and the tenant must exist and not be `default`. The relabel is
  one transaction. It answers `{:error, :nothing_to_relabel}` when the tenant
  has nothing under the id, and says nothing of what others hold there.

  An operator runs it from a remote shell, as for the other repairs:

      bin/optimal rpc 'OptimalEngine.DataSteward.relabel_bare_scope("shared-notes", tenant_id: "acme", actor_id: "user:ops")'
  """

  require Logger

  alias OptimalEngine.Authority.Evidence
  alias OptimalEngine.Store
  alias OptimalEngine.Tenancy.Tenant

  @timeout 120_000

  # Ids bound to one statement: well under SQLite's variable limit.
  @ids_per_statement 500

  @spec run(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(workspace_id, opts) when is_binary(workspace_id) do
    tenant = Keyword.fetch!(opts, :tenant_id)
    actor_id = Keyword.fetch!(opts, :actor_id)

    with :ok <- check_bare(workspace_id),
         :ok <- check_tenant(tenant),
         # Fetched before the transaction opens: creating a key writes to the Store.
         key = Evidence.signing_key(tenant),
         {:ok, counts} <-
           Store.transaction(
             fn txn ->
               with {:ok, counts} <- relabel(txn, workspace_id, tenant) do
                 record(txn, key, workspace_id, tenant, actor_id, counts)
               end
             end,
             @timeout
           ) do
      Logger.info(
        "[DataSteward] #{actor_id} relabelled the default rows of #{workspace_id} that #{tenant} wrote: #{inspect(counts)}"
      )

      {:ok, Map.merge(%{workspace_id: workspace_id, tenant_id: tenant, actor_id: actor_id}, counts)}
    end
  end

  defp check_bare(workspace_id) do
    if workspace_id != "" and not String.contains?(workspace_id, ":"),
      do: :ok,
      else: {:error, :not_a_bare_workspace_id}
  end

  defp check_tenant("default"), do: {:error, :tenant_is_default}

  defp check_tenant(tenant) do
    case Tenant.get(tenant) do
      {:ok, _tenant} -> :ok
      _ -> {:error, :unknown_tenant}
    end
  end

  defp relabel(txn, workspace, tenant) do
    with :ok <- check_unregistered(txn, workspace),
         {:ok, packages} <- packages(txn, workspace, tenant),
         {:ok, candidates} <- vouched_contexts(txn, workspace, tenant, packages),
         {:ok, shared} <- shared_contexts(txn, workspace, tenant),
         {:ok, contexts} <- default_contexts(txn, workspace, candidates -- shared),
         {:ok, claims} <- default_claims(txn, workspace, tenant),
         :ok <- something_to_relabel(contexts, claims) do
      move(txn, workspace, tenant, contexts, claims)
    end
  end

  defp check_unregistered(txn, workspace) do
    case Store.txn_query(txn, "SELECT 1 FROM workspaces WHERE id = ?1", [workspace]) do
      {:ok, []} -> :ok
      {:ok, _registered} -> {:error, :workspace_is_registered}
      {:error, _} = error -> error
    end
  end

  defp something_to_relabel([], []), do: {:error, :nothing_to_relabel}
  defp something_to_relabel(_contexts, _claims), do: :ok

  # The ids of the tenant's source packages in the workspace.
  defp packages(txn, workspace, tenant) do
    with {:ok, rows} <-
           Store.txn_query(
             txn,
             "SELECT id FROM source_packages WHERE tenant_id = ?1 AND workspace_id = ?2",
             [tenant, workspace]
           ) do
      {:ok, rows |> List.flatten() |> MapSet.new()}
    end
  end

  # The contexts that intake derived from one of those packages. A ledger entry
  # carries the tenant and the workspace of its package.
  defp vouched_contexts(txn, workspace, tenant, packages) do
    with {:ok, rows} <-
           Store.txn_query(
             txn,
             """
             SELECT source_package_links, output_object_links FROM derivation_ledger
             WHERE tenant_id = ?1 AND workspace_id = ?2
               AND activity_type = 'intake.process'
               AND derivation_stage = 'source_to_signal_context'
             """,
             [tenant, workspace]
           ) do
      ids =
        for [sources, outputs] <- rows,
            Enum.any?(link_ids(sources, "source_package"), &MapSet.member?(packages, &1)),
            id <- link_ids(outputs, "context"),
            uniq: true,
            do: id

      {:ok, ids}
    end
  end

  # The contexts that intake derived for another tenant in the workspace. A
  # connector item's context id is the same for every tenant that ingests it into
  # a shared bare id, so one of them is named by both.
  defp shared_contexts(txn, workspace, tenant) do
    with {:ok, rows} <-
           Store.txn_query(
             txn,
             """
             SELECT output_object_links FROM derivation_ledger
             WHERE workspace_id = ?1 AND tenant_id != ?2
               AND activity_type = 'intake.process'
               AND derivation_stage = 'source_to_signal_context'
             """,
             [workspace, tenant]
           ) do
      {:ok, for([outputs] <- rows, id <- link_ids(outputs, "context"), uniq: true, do: id)}
    end
  end

  defp link_ids(json, type) do
    case Jason.decode(json || "[]") do
      {:ok, links} when is_list(links) ->
        for %{"type" => ^type, "id" => id} when is_binary(id) <- links, do: id

      _ ->
        []
    end
  end

  # Of those, the ones that are `default` rows of the workspace.
  defp default_contexts(txn, workspace, candidates) do
    each_chunk(candidates, [], fn chunk, found ->
      with {:ok, rows} <-
             Store.txn_query(
               txn,
               "SELECT id FROM contexts WHERE tenant_id = 'default' AND workspace_id = ?1 AND id IN (#{in_list(chunk, 2)})",
               [workspace | chunk]
             ) do
        {:ok, List.flatten(rows) ++ found}
      end
    end)
  end

  defp default_claims(txn, workspace, tenant) do
    with {:ok, rows} <-
           Store.txn_query(
             txn,
             """
             SELECT id FROM claims
             WHERE tenant_id = 'default' AND workspace_id = ?1
               AND source_package_id IN
                 (SELECT id FROM source_packages WHERE tenant_id = ?2 AND workspace_id = ?1)
             """,
             [workspace, tenant]
           ) do
      {:ok, List.flatten(rows)}
    end
  end

  defp move(txn, workspace, tenant, contexts, claims) do
    ends = contexts ++ claims

    with {:ok, chunk_ids} <- default_chunks(txn, contexts),
         {:ok, edge_ids} <- followed_edges(txn, workspace, tenant, ends),
         {:ok, moved_contexts} <- update(txn, "contexts", "id", contexts, tenant),
         {:ok, moved_claims} <- update(txn, "claims", "id", claims, tenant),
         {:ok, chunks} <- update(txn, "chunks", "signal_id", contexts, tenant),
         {:ok, embeddings} <- update(txn, "chunk_embeddings", "chunk_id", chunk_ids, tenant),
         {:ok, vectors} <- update(txn, "vectors", "context_id", contexts, tenant),
         {:ok, entities} <- update(txn, "entities", "context_id", contexts, tenant),
         {:ok, decisions} <- update(txn, "decisions", "context_id", contexts, tenant),
         {:ok, duplicates} <- drop_duplicate_edges(txn, tenant, edge_ids),
         {:ok, edges} <- update(txn, "graph_edges", "id", edge_ids, tenant) do
      {:ok,
       %{
         contexts: moved_contexts,
         claims: moved_claims,
         chunks: chunks,
         chunk_embeddings: embeddings,
         vectors: vectors,
         entities: entities,
         decisions: decisions,
         graph_edges: edges,
         duplicate_edges: duplicates
       }}
    end
  end

  # The `default` chunks of the contexts, whose embeddings follow them.
  defp default_chunks(txn, contexts) do
    each_chunk(contexts, [], fn chunk, found ->
      with {:ok, rows} <-
             Store.txn_query(
               txn,
               "SELECT id FROM chunks WHERE tenant_id = 'default' AND signal_id IN (#{in_list(chunk, 1)})",
               chunk
             ) do
        {:ok, List.flatten(rows) ++ found}
      end
    end)
  end

  # The `default` edges of the workspace that follow the relabelled contexts and
  # claims (`ends`): those with one at an end, unless the other end is a context or
  # a claim that is not the tenant's and not relabelled with them. An edge between
  # two of the tenant's rows, or to an entity, follows.
  defp followed_edges(txn, workspace, tenant, ends) do
    ended = MapSet.new(ends)

    with {:ok, edges} <- edges_at(txn, workspace, ends),
         others = for({_id, s, t} <- edges, x <- [s, t], not MapSet.member?(ended, x), do: x),
         {:ok, staying} <- staying(txn, tenant, Enum.uniq(others)) do
      follows? = fn x -> MapSet.member?(ended, x) or not MapSet.member?(staying, x) end
      {:ok, for({id, s, t} <- edges, follows?.(s) and follows?.(t), do: id)}
    end
  end

  defp edges_at(txn, workspace, ends) do
    with {:ok, edges} <-
           each_chunk(ends, [], fn chunk, found ->
             with {:ok, rows} <-
                    Store.txn_query(
                      txn,
                      """
                      SELECT id, source_id, target_id FROM graph_edges
                      WHERE tenant_id = 'default' AND workspace_id = ?1
                        AND (source_id IN (#{in_list(chunk, 2)}) OR target_id IN (#{in_list(chunk, 2)}))
                      """,
                      [workspace | chunk]
                    ) do
               {:ok, Enum.map(rows, &List.to_tuple/1) ++ found}
             end
           end) do
      {:ok, Enum.uniq(edges)}
    end
  end

  # Of `ids`, the contexts and claims that belong to no one the relabel is for.
  # (The relabelled ones are the tenant's by now.)
  defp staying(txn, tenant, ids) do
    each_chunk(ids, MapSet.new(), fn chunk, found ->
      Enum.reduce_while(["contexts", "claims"], {:ok, found}, fn table, {:ok, found} ->
        case Store.txn_query(
               txn,
               "SELECT id FROM #{table} WHERE tenant_id != ?1 AND id IN (#{in_list(chunk, 2)})",
               [tenant | chunk]
             ) do
          {:ok, rows} ->
            {:cont, {:ok, rows |> List.flatten() |> MapSet.new() |> MapSet.union(found)}}

          {:error, _} = error ->
            {:halt, error}
        end
      end)
    end)
  end

  # The `default` rows of `table` that name one of `ids` in `column`. `table` and
  # `column` are the constants above.
  defp update(txn, table, column, ids, tenant) do
    each_chunk(ids, 0, fn chunk, total ->
      with {:ok, count} <-
             Store.txn_execute(
               txn,
               "UPDATE #{table} SET tenant_id = ?1 WHERE tenant_id = 'default' AND #{column} IN (#{in_list(chunk, 2)})",
               [tenant | chunk]
             ) do
        {:ok, total + count}
      end
    end)
  end

  # A `default` edge the tenant already has an identical one of (the unique key
  # is tenant, workspace, ends and relation) would collide when relabelled.
  defp drop_duplicate_edges(txn, tenant, edge_ids) do
    each_chunk(edge_ids, 0, fn chunk, total ->
      with {:ok, count} <-
             Store.txn_execute(
               txn,
               """
               DELETE FROM graph_edges
               WHERE tenant_id = 'default' AND id IN (#{in_list(chunk, 2)})
                 AND EXISTS (
                   SELECT 1 FROM graph_edges t
                   WHERE t.tenant_id = ?1 AND t.workspace_id = graph_edges.workspace_id
                     AND t.source_id = graph_edges.source_id
                     AND t.target_id = graph_edges.target_id
                     AND t.relation = graph_edges.relation)
               """,
               [tenant | chunk]
             ) do
        {:ok, total + count}
      end
    end)
  end

  # What was relabelled, appended to the tenant's evidence chain in the transaction
  # that relabelled it. Without a key (the Engine cannot sign) nothing is written.
  defp record(_txn, nil, workspace, tenant, actor, counts) do
    Logger.warning(
      "[DataSteward] the relabel of #{workspace} for #{tenant} by #{actor} is not recorded as evidence: the Engine cannot sign evidence"
    )

    {:ok, counts}
  end

  defp record(txn, key, workspace, tenant, actor, counts) do
    detail = Map.new(counts, fn {name, count} -> {Atom.to_string(name), count} end)

    {:ok, _entry} =
      Evidence.append_in(txn, key, tenant, "workspace.relabeled", %{
        subject: actor,
        action: "write",
        resource: "optimal://#{workspace}",
        workspace_id: workspace,
        detail: Map.merge(detail, %{"tenant" => tenant, "by" => actor})
      })

    {:ok, counts}
  end

  # Runs `fun.(chunk, acc)` over the ids a bounded number at a time; `fun` answers
  # `{:ok, acc}` or the error that stops it.
  defp each_chunk(ids, acc, fun) do
    ids
    |> Enum.chunk_every(@ids_per_statement)
    |> Enum.reduce_while({:ok, acc}, fn chunk, {:ok, acc} ->
      case fun.(chunk, acc) do
        {:ok, acc} -> {:cont, {:ok, acc}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  # `?3, ?4, ...` for the chunk, numbered from `first`.
  defp in_list(chunk, first),
    do: Enum.map_join(0..(length(chunk) - 1), ", ", &"?#{first + &1}")
end
