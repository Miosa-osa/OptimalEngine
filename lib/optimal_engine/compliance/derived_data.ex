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
  the rows (and the pointer to the file) in place.

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
      Store.transaction(&erase_batch(&1, tenant_id, batch, true), @timeout)
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
    Store.transaction(&delete_in(&1, Enum.uniq(context_ids), true), @timeout)
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

    with {:ok, packages} <- exclusive_packages(txn, ctx),
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
           rows(txn, "SELECT id, storage_path FROM assets WHERE source_package_id IN #{set(1)}", [
             pkgs
           ]),
         {:ok, runs} <-
           rows(
             txn,
             "SELECT id, checkpoint_uri FROM decomposition_runs " <>
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
         :ok <- remove_files(txn, assets, runs, files?),
         {:ok, wiki} <- delete_pages(txn, pages),
         {:ok, removed} <- run_steps(txn, steps(ctx, pkgs, claims, mentions, assets), %{}) do
      {:ok, Map.merge(removed, wiki)}
    end
  end

  # The packages of these contexts that no remaining context refers to, by the
  # package id in a context's metadata or in a claim's signal.
  defp exclusive_packages(txn, ctx) do
    column(
      txn,
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
  # assets of one content hash share their bytes) is left alone.
  defp remove_files(_txn, _assets, _runs, false), do: :ok

  defp remove_files(txn, assets, runs, true) do
    ids = assets |> Enum.map(&hd/1) |> json()
    paths = assets |> Enum.map(&List.last/1) |> Enum.uniq() |> json()

    with {:ok, shared} <-
           column(
             txn,
             "SELECT DISTINCT storage_path FROM assets " <>
               "WHERE storage_path IN #{set(2)} AND id NOT IN #{set(1)}",
             [ids, paths]
           ) do
      shared = MapSet.new(shared)

      kept = for [_id, path] <- assets, not MapSet.member?(shared, path), do: asset_artifact(path)
      checkpoints = for [run_id, uri] <- runs, do: {:checkpoint, run_id, uri}

      case Artifacts.remove(kept ++ checkpoints) do
        {:ok, _removed} -> :ok
        {:error, _} = error -> error
      end
    end
  end

  defp asset_artifact(path) do
    if S3.uri?(path), do: {:asset_copy, path}, else: {:asset_file, path}
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp set(n), do: "(SELECT value FROM json_each(?#{n}))"

  defp json(list), do: Jason.encode!(list)

  defp column(txn, sql, params) do
    with {:ok, found} <- rows(txn, sql, params), do: {:ok, List.flatten(found)}
  end

  defp rows(txn, sql, params) do
    case Store.txn_query(txn, sql, params) do
      {:ok, found} -> {:ok, found}
      {:error, reason} -> {:error, {:derived_select_failed, reason}}
    end
  end

  defp merge(left, right), do: Map.merge(left, right, fn _key, a, b -> a + b end)
end
