defmodule OptimalEngine.Compliance.DerivedData do
  @moduledoc """
  Everything derived from a context, removed when the context is.

  Most of it is not tied to the context by a foreign key, so deleting a context
  row alone leaves its text behind in these tables:

    * `vectors` (the document vector), `chunks` and `chunk_embeddings` (with
      `intents`, `classifications`, `cluster_members` and `citations`, which
      cascade from a chunk)
    * `entity_mentions` (`surface_text`) and the `resolution_decisions` that
      point at them, `entities`
    * `claims` and the `facts` that accepted them
    * the context's `source_packages` (`raw_text`, and the optional
      `source_packages_fts` index where an older database has one), and with them
      their `decomposition_runs`, `assets` and the asset extractions, transcripts
      and OCR spans, and the files those rows point at
    * `wiki_pages` that cite one of the context's chunks, and their citations
    * `episodes`, `processor_runs`, `decisions` and `graph_edges` that name the context

  A source package is removed only if no context that stays refers to it: the
  same text ingested twice in a workspace is one package. A wiki page is removed
  when any of its citations is to a deleted chunk, because its body was written
  from that text; the wiki scheduler writes it again from what is left. A fact is
  removed when any claim it accepted is.

  `erase_contexts/2` deletes the contexts too, in batches of 200 contexts, each
  batch one transaction: a batch either goes whole or not at all, a failure stops
  the run with the earlier batches done, and running it again finishes the rest.
  Files go first, inside the transaction, so a file that cannot be removed leaves
  the rows (and the pointer to the file) in place. The objects of the deleted assets
  in the object store go before the transaction (a request to a bucket must not hold
  the Store), with the same effect when one cannot be deleted.

  `delete_derived/1` removes the same rows and files but keeps the contexts, for a
  context whose text was redacted in place. `preview/2` counts what
  `erase_contexts/2` would remove, and removes nothing.

  Not touched: shared canonical entities and aliases, which are not specific to a
  context; replication ledgers (`sync_mutations`, `sync_capture`), which are
  append-only; backups.
  """

  require Logger

  alias OptimalEngine.Compliance.Artifacts
  alias OptimalEngine.Storage.S3
  alias OptimalEngine.Store

  @batch_size 200
  @timeout 120_000

  @type removed :: %{atom() => non_neg_integer()}

  @doc "How many contexts one erasure transaction covers."
  @spec batch_size() :: pos_integer()
  def batch_size, do: @batch_size

  @doc """
  Delete the contexts `context_ids` of `tenant_id` with everything derived from
  them. Returns how many rows went from each table. Ids that are not the tenant's
  are ignored.
  """
  @spec erase_contexts(String.t(), [String.t()]) :: {:ok, removed()} | {:error, term()}
  def erase_contexts(tenant_id, context_ids) when is_binary(tenant_id) and is_list(context_ids) do
    in_batches(context_ids, fn batch ->
      with :ok <- remove_objects(tenant_id, batch) do
        Store.transaction(&erase_batch(&1, tenant_id, batch, true), @timeout)
      end
    end)
  end

  @doc """
  What `erase_contexts/2` would remove, per table, without removing it: the
  deletes run and are rolled back, files are left alone.
  """
  @spec preview(String.t(), [String.t()]) :: {:ok, removed()} | {:error, term()}
  def preview(tenant_id, context_ids) when is_binary(tenant_id) and is_list(context_ids) do
    in_batches(context_ids, fn batch ->
      result =
        Store.transaction(
          fn txn ->
            case erase_batch(txn, tenant_id, batch, false) do
              {:ok, removed} -> {:error, {:preview, removed}}
              {:error, _} = error -> error
            end
          end,
          @timeout
        )

      case result do
        {:error, {:preview, removed}} -> {:ok, removed}
        other -> other
      end
    end)
  end

  @doc """
  Delete what is derived from `context_ids`, and keep the contexts. For a
  context whose text was redacted in place: nothing derived from the original
  text may stay. One transaction, so pass a batch.
  """
  @spec delete_derived([String.t()]) :: {:ok, removed()} | {:error, term()}
  def delete_derived(context_ids) when is_list(context_ids) do
    ids = Enum.uniq(context_ids)

    with :ok <- remove_objects(nil, ids) do
      Store.transaction(&delete_in(&1, ids, true), @timeout)
    end
  end

  defp in_batches(context_ids, fun) do
    context_ids
    |> Enum.uniq()
    |> Enum.chunk_every(@batch_size)
    |> Enum.reduce_while({:ok, %{}}, fn batch, {:ok, total} ->
      case fun.(batch) do
        {:ok, removed} -> {:cont, {:ok, merge(total, removed)}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp erase_batch(txn, tenant_id, batch, files?) do
    with {:ok, rows} <-
           Store.txn_query(
             txn,
             "SELECT id FROM contexts WHERE tenant_id = ?1 AND id IN #{set(2)}",
             [tenant_id, json(batch)]
           ),
         ids = List.flatten(rows),
         {:ok, removed} <- delete_in(txn, ids, files?),
         {:ok, contexts} <-
           Store.txn_execute(
             txn,
             "DELETE FROM contexts WHERE tenant_id = ?1 AND id IN #{set(2)}",
             [tenant_id, json(ids)]
           ) do
      {:ok, Map.put(removed, :contexts, contexts)}
    end
  end

  # ── one batch ──────────────────────────────────────────────────────────────

  defp delete_in(_txn, [], _files?), do: {:ok, %{}}

  defp delete_in(txn, ids, files?) do
    ctx = json(ids)

    with {:ok, scope} <- erased_scope(txn, ctx),
         {:ok, packages} <- exclusive_packages(txn, ctx),
         pkgs = json(packages),
         {:ok, claims} <-
           column(
             txn,
             "SELECT id FROM claims WHERE signal_id IN #{set(1)} OR source_package_id IN #{set(2)}",
             [ctx, pkgs]
           ),
         {:ok, mentions} <-
           column(
             txn,
             "SELECT id FROM entity_mentions WHERE context_id IN #{set(1)} OR source_package_id IN #{set(2)}",
             [ctx, pkgs]
           ),
         {:ok, assets} <-
           rows(
             txn,
             "SELECT id, storage_path, workspace_id FROM assets WHERE source_package_id IN #{set(1)}",
             [pkgs]
           ),
         {:ok, runs} <-
           rows(
             txn,
             "SELECT id, checkpoint_uri, workspace_id FROM decomposition_runs " <>
               "WHERE source_package_id IN #{set(1)} AND checkpoint_uri IS NOT NULL",
             [pkgs]
           ),
         {:ok, pages} <-
           rows(
             txn,
             "SELECT DISTINCT tenant_id, wiki_slug, wiki_audience FROM citations " <>
               "WHERE chunk_id IN (SELECT id FROM chunks WHERE signal_id IN #{set(1)})",
             [ctx]
           ),
         :ok <- remove_files(txn, assets, runs, scope, files?),
         {:ok, wiki} <- delete_pages(txn, pages),
         {:ok, removed} <- run_steps(txn, steps(ctx, pkgs, claims, mentions, assets), %{}) do
      {:ok, Map.merge(removed, wiki)}
    end
  end

  # The workspaces these contexts are in, each with its tenant: the only workspaces whose
  # files this delete may remove. A row of a bundle can name any workspace, so a file is
  # removed for a row only when the row's workspace is one of these.
  defp erased_scope(reader, ctx) do
    with {:ok, found} <-
           rows(
             reader,
             "SELECT DISTINCT workspace_id, tenant_id FROM contexts WHERE id IN #{set(1)}",
             [ctx]
           ) do
      {:ok, Map.new(found, fn [workspace_id, tenant_id] -> {workspace_id, tenant_id} end)}
    end
  end

  # The packages of these contexts that no remaining context refers to, by the
  # package id in a context's metadata or in a claim's signal.
  defp exclusive_packages(reader, ctx) do
    column(
      reader,
      """
      SELECT DISTINCT p FROM (
        SELECT CASE WHEN json_valid(c.metadata) THEN json_extract(c.metadata, '$.source_package_id') END AS p
          FROM contexts c WHERE c.id IN #{set(1)}
        UNION
        SELECT source_package_id FROM claims WHERE signal_id IN #{set(1)}
      )
      WHERE p IS NOT NULL AND p != ''
        AND p NOT IN (
          SELECT CASE WHEN json_valid(o.metadata) THEN json_extract(o.metadata, '$.source_package_id') END
            FROM contexts o
           WHERE o.id NOT IN #{set(1)}
             AND CASE WHEN json_valid(o.metadata) THEN json_extract(o.metadata, '$.source_package_id') END IS NOT NULL)
        AND p NOT IN (
          SELECT source_package_id FROM claims
           WHERE signal_id IS NOT NULL AND signal_id NOT IN #{set(1)})
      """,
      [ctx]
    )
  end

  # Children before parents. Each statement takes only the parameters it names.
  defp steps(ctx, pkgs, claims, mentions, assets) do
    claim_set = json(claims)
    mention_set = json(mentions)
    asset_set = assets |> Enum.map(&hd/1) |> json()

    [
      {:resolution_decisions, "DELETE FROM resolution_decisions WHERE mention_id IN #{set(1)}",
       [mention_set]},
      {:entity_mentions, "DELETE FROM entity_mentions WHERE id IN #{set(1)}", [mention_set]},
      {:asset_ocr_spans, "DELETE FROM asset_ocr_spans WHERE asset_id IN #{set(1)}", [asset_set]},
      {:asset_transcripts, "DELETE FROM asset_transcripts WHERE asset_id IN #{set(1)}",
       [asset_set]},
      {:asset_extractions, "DELETE FROM asset_extractions WHERE asset_id IN #{set(1)}",
       [asset_set]},
      {:assets, "DELETE FROM assets WHERE id IN #{set(1)}", [asset_set]},
      {:facts,
       """
       DELETE FROM facts WHERE EXISTS (
         SELECT 1
           FROM json_each(CASE WHEN json_valid(facts.accepted_claim_ids) THEN facts.accepted_claim_ids ELSE '[]' END) j
          WHERE j.value IN #{set(1)})
       """, [claim_set]},
      {:claims, "DELETE FROM claims WHERE id IN #{set(1)}", [claim_set]},
      {:episodes,
       """
       DELETE FROM episodes
        WHERE (CASE WHEN json_valid(provenance) THEN json_extract(provenance, '$.signal_id') END) IN #{set(1)}
           OR (CASE WHEN json_valid(provenance) THEN json_extract(provenance, '$.source_package_id') END) IN #{set(2)}
       """, [ctx, pkgs]},
      {:decomposition_runs, "DELETE FROM decomposition_runs WHERE source_package_id IN #{set(1)}",
       [pkgs]},
      {:source_packages_fts, :package_fts, [pkgs]},
      {:source_packages, "DELETE FROM source_packages WHERE id IN #{set(1)}", [pkgs]},
      {:processor_runs, "DELETE FROM processor_runs WHERE context_id IN #{set(1)}", [ctx]},
      {:decisions, "DELETE FROM decisions WHERE context_id IN #{set(1)}", [ctx]},
      {:entities, "DELETE FROM entities WHERE context_id IN #{set(1)}", [ctx]},
      {:graph_edges,
       "DELETE FROM graph_edges WHERE source_id IN #{set(1)} OR target_id IN #{set(1)}", [ctx]},
      {:vectors, "DELETE FROM vectors WHERE context_id IN #{set(1)}", [ctx]},
      {:chunk_embeddings,
       "DELETE FROM chunk_embeddings WHERE chunk_id IN (SELECT id FROM chunks WHERE signal_id IN #{set(1)})",
       [ctx]},
      {:chunks, "DELETE FROM chunks WHERE signal_id IN #{set(1)}", [ctx]}
    ]
  end

  defp run_steps(_txn, [], removed), do: {:ok, removed}

  defp run_steps(txn, [{key, :package_fts, params} | rest], removed) do
    run_steps(txn, rest, Map.put(removed, key, delete_package_fts(txn, params)))
  end

  defp run_steps(txn, [{key, sql, params} | rest], removed) do
    case Store.txn_execute(txn, sql, params) do
      {:ok, count} -> run_steps(txn, rest, Map.put(removed, key, count))
      {:error, reason} -> {:error, {:derived_delete_failed, key, reason}}
    end
  end

  # The optional full-text index over source packages exists only on databases that
  # created it in an earlier version, and its triggers are gone, so its rows are
  # removed here, before the packages they were made from. An index that cannot be
  # deleted from (a contentless table) is logged, not fatal: erasure must not be
  # blocked by an index this version no longer maintains.
  defp delete_package_fts(txn, [pkgs]) do
    with {:ok, [[_]]} <-
           Store.txn_query(
             txn,
             "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'source_packages_fts'"
           ),
         {:ok, count} <-
           Store.txn_execute(
             txn,
             "DELETE FROM source_packages_fts WHERE rowid IN " <>
               "(SELECT rowid FROM source_packages WHERE id IN #{set(1)})",
             [pkgs]
           ) do
      count
    else
      {:ok, []} ->
        0

      {:error, reason} ->
        Logger.warning(
          "[DerivedData] could not delete from source_packages_fts: #{inspect(reason)}"
        )

        0
    end
  end

  # A page and its citations, before the chunks the citations cascade from: the page is
  # rebuilt from the chunks that remain.
  defp delete_pages(txn, pages) do
    Enum.reduce_while(pages, {:ok, %{wiki_pages: 0, citations: 0}}, fn
      [tenant_id, slug, audience], {:ok, acc} ->
        with {:ok, page_count} <-
               Store.txn_execute(
                 txn,
                 "DELETE FROM wiki_pages WHERE tenant_id = ?1 AND slug = ?2 AND audience = ?3",
                 [tenant_id, slug, audience]
               ),
             {:ok, citation_count} <-
               Store.txn_execute(
                 txn,
                 "DELETE FROM citations WHERE tenant_id = ?1 AND wiki_slug = ?2 AND wiki_audience = ?3",
                 [tenant_id, slug, audience]
               ) do
          {:cont,
           {:ok,
            %{
              acc
              | wiki_pages: acc.wiki_pages + page_count,
                citations: acc.citations + citation_count
            }}}
        else
          {:error, reason} -> {:halt, {:error, {:derived_delete_failed, :wiki_pages, reason}}}
        end
    end)
  end

  # ── files ──────────────────────────────────────────────────────────────────

  # The files of the rows about to go. A file shared with a row that stays (two
  # assets of one content hash share their bytes) is left alone, whichever way that row
  # spells the path. A row's file is removed only for a workspace this delete is of,
  # and only if it is the file this Engine names for the row (`Compliance.Artifacts`).
  defp remove_files(_txn, _assets, _runs, _scope, false), do: :ok

  defp remove_files(txn, assets, runs, scope, true) do
    with {:ok, shared} <- shared_paths(txn, assets, scope) do
      files =
        for [_id, path, workspace_id] <- assets,
            Map.has_key?(scope, workspace_id),
            not shared?(shared, path),
            do: asset_artifact(path, scope, workspace_id)

      checkpoints =
        for [run_id, uri, workspace_id] <- runs,
            Map.has_key?(scope, workspace_id),
            do: {:checkpoint, run_id, uri, workspace_id}

      case Artifacts.remove(files ++ checkpoints) do
        {:ok, _removed} -> :ok
        {:error, _} = error -> error
      end
    end
  end

  defp asset_artifact(path, scope, workspace_id) do
    if S3.uri?(path),
      do: {:asset_copy, path, Map.fetch!(scope, workspace_id), workspace_id},
      else: {:asset_file, path, workspace_id}
  end

  # The paths a row that stays also names: the same string (an index lookup), or the
  # same file spelled another way (`a/./b`, `a/c/../b`) by a remaining asset of one of
  # the workspaces, which is looked at only when a local file is about to go.
  defp shared_paths(reader, assets, scope) do
    ids = assets |> Enum.map(&hd/1) |> json()
    paths = assets |> Enum.map(&Enum.at(&1, 1)) |> Enum.uniq() |> json()

    with {:ok, same} <-
           column(
             reader,
             "SELECT DISTINCT storage_path FROM assets " <>
               "WHERE storage_path IN #{set(2)} AND id NOT IN #{set(1)}",
             [ids, paths]
           ),
         {:ok, spelled} <- spelled_differently(reader, ids, assets, scope) do
      {:ok, %{same: MapSet.new(same), expanded: spelled}}
    end
  end

  defp spelled_differently(reader, ids, assets, scope) do
    wanted =
      for [_id, path, workspace_id] <- assets,
          Map.has_key?(scope, workspace_id),
          plain_path?(path),
          not S3.uri?(path),
          into: MapSet.new(),
          do: Path.expand(path)

    if MapSet.size(wanted) == 0 do
      {:ok, MapSet.new()}
    else
      with {:ok, remaining} <-
             column(
               reader,
               "SELECT storage_path FROM assets WHERE id NOT IN #{set(1)} " <>
                 "AND workspace_id IN #{set(2)} AND storage_path NOT LIKE 's3://%'",
               [ids, json(Map.keys(scope))]
             ) do
        {:ok,
         for(
           path <- remaining,
           plain_path?(path),
           expanded = Path.expand(path),
           MapSet.member?(wanted, expanded),
           into: MapSet.new(),
           do: expanded
         )}
      end
    end
  end

  defp plain_path?(path), do: is_binary(path) and not String.contains?(path, <<0>>)

  defp shared?(shared, path) do
    MapSet.member?(shared.same, path) or
      (plain_path?(path) and not S3.uri?(path) and
         MapSet.member?(shared.expanded, Path.expand(path)))
  end

  # ── objects ────────────────────────────────────────────────────────────────

  # The objects of the assets that go with these contexts, in the object store the
  # Engine is configured for. They go before the transaction, not in it: a request to a
  # bucket must not hold the Store, and an object that cannot be deleted leaves the rows
  # (and the pointer to it) in place for the next run. An object another asset still uses,
  # one in another bucket, one outside the erased workspace's own prefix, one of an asset
  # whose row names a workspace the contexts are not in, and every object when no object
  # store is configured are left alone (`Compliance.Artifacts`).
  # `tenant_id` limits the contexts to a tenant's; nil means the ids are already known to be.
  defp remove_objects(tenant_id, context_ids) do
    with {:ok, ids} <- in_tenant(tenant_id, context_ids),
         ctx = json(ids),
         {:ok, scope} <- erased_scope(:store, ctx),
         {:ok, packages} <- exclusive_packages(:store, ctx),
         {:ok, assets} <-
           rows(
             :store,
             "SELECT id, storage_path, workspace_id FROM assets " <>
               "WHERE source_package_id IN #{set(1)} AND storage_path LIKE 's3://%'",
             [json(packages)]
           ),
         {:ok, shared} <- shared_paths(:store, assets, scope) do
      objects =
        for [_id, path, workspace_id] <- assets,
            Map.has_key?(scope, workspace_id),
            not shared?(shared, path),
            do: {:asset_object, path, Map.fetch!(scope, workspace_id), workspace_id}

      case Artifacts.remove(objects) do
        {:ok, _removed} -> :ok
        {:error, _} = error -> error
      end
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp set(n), do: "(SELECT value FROM json_each(?#{n}))"

  defp json(list), do: Jason.encode!(list)

  defp column(txn, sql, params) do
    with {:ok, found} <- rows(txn, sql, params), do: {:ok, List.flatten(found)}
  end

  # `:store` reads outside any transaction; a transaction handle reads inside it.
  defp rows(:store, sql, params), do: selected(Store.raw_query(sql, params))
  defp rows(txn, sql, params), do: selected(Store.txn_query(txn, sql, params))

  defp selected({:ok, found}), do: {:ok, found}
  defp selected({:error, reason}), do: {:error, {:derived_select_failed, reason}}

  defp in_tenant(nil, ids), do: {:ok, ids}

  defp in_tenant(tenant_id, ids) do
    column(:store, "SELECT id FROM contexts WHERE tenant_id = ?1 AND id IN #{set(2)}", [
      tenant_id,
      json(ids)
    ])
  end

  defp merge(left, right), do: Map.merge(left, right, fn _key, a, b -> a + b end)
end
