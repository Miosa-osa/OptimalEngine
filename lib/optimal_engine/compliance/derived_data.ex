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
    * the context's signal file, its summary sidecars and the cross-reference copies
      intake wrote to the other nodes, with the contexts that index them
      (`Compliance.ContextFiles`)

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
  context whose text was redacted in place; the context's own signal file and its
  sidecars are rewritten through `Compliance.Redact` instead of removed. `preview/2` counts what
  `erase_contexts/2` would remove, and removes nothing.

  Not touched: shared canonical entities and aliases, which are not specific to a
  context; replication ledgers (`sync_mutations`, `sync_capture`), which are
  append-only; backups.
  """

  require Logger

  alias OptimalEngine.Compliance.{Artifacts, ContextFiles}
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
      with {:ok, plan} <- ContextFiles.plan(tenant_id, batch),
           batch = Enum.uniq(batch ++ plan.copy_ids),
           :ok <- remove_objects(tenant_id, batch),
           {:ok, _removed} <- ContextFiles.remove(plan.files ++ plan.wiki_files) do
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
      files =
        case ContextFiles.plan(tenant_id, batch) do
          {:ok, plan} -> length(plan.files) + length(plan.wiki_files)
          {:error, _} -> 0
        end

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
        {:error, {:preview, removed}} -> {:ok, Map.put(removed, :context_files, files)}
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

    with {:ok, plan} <- ContextFiles.plan(nil, ids, copies: false),
         :ok <- remove_objects(nil, ids),
         {:ok, _redacted} <- ContextFiles.redact(plan.files),
         {:ok, _removed} <- ContextFiles.remove(plan.wiki_files) do
      Store.transaction(&delete_in(&1, ids, true), @timeout)
    end
  end

  @typedoc """
  The files that go with the contexts that refer to one source package, as rows: the runs
  `[id, checkpoint, workspace]` and assets `[id, path, workspace]` of the package, and the
  workspaces the deleted contexts were in with their tenants.
  """
  @type file_entry :: %{
          package: String.t(),
          contexts: [String.t()],
          assets: [[term()]],
          runs: [[term()]],
          scope: %{String.t() => String.t()}
        }

  @doc """
  The files `erase_contexts/2` would remove with these contexts of a workspace, read now
  and removed by no one: for a caller whose rows go some other way, a replica applying a
  peer's delete, where the derived rows arrive as deletes of their own and what this Engine
  made itself (its decomposition checkpoints, its assets) stays.

  One entry per source package that no context outside `context_ids` refers to, with the
  contexts of `context_ids` that refer to it and the rows of its runs and assets. Nothing is
  removed: hand the entries to `remove_planned_files/1` once the contexts are gone. What the
  plan says is true when it is read, not when the files go, so `remove_planned_files/1`
  asks again.
  """
  @spec file_plan(String.t(), String.t(), [String.t()]) ::
          {:ok, [file_entry()]} | {:error, term()}
  def file_plan(tenant_id, workspace_id, context_ids)
      when is_binary(tenant_id) and is_binary(workspace_id) and is_list(context_ids) do
    Store.transaction(
      &plan_files(&1, tenant_id, workspace_id, Enum.uniq(context_ids)),
      @timeout
    )
  end

  @doc """
  Removes the files of `file_plan/3` entries, after the contexts they were planned for went.

  Each entry is checked against what is committed now, in the same Store transaction as the
  removal, so no write can come between the check and the removal: an entry is kept (its
  files stay) when any context's `source_package_id` or any claim's names its package, and
  an asset file is kept when an asset outside the entry names the same path, spelled the same
  way or another. A delete that was not applied, a context created in the same batch on the
  package, and a write that came after the plan are all caught here. The checkpoint
  pointers of the files that are gone are cleared.

  Answers how many entries were removed and kept, and how many files went.
  """
  @spec remove_planned_files([file_entry()]) ::
          {:ok, %{entries: non_neg_integer(), kept: non_neg_integer(), files: non_neg_integer()}}
          | {:error, term()}
  def remove_planned_files([]), do: {:ok, %{entries: 0, kept: 0, files: 0}}

  def remove_planned_files(entries) when is_list(entries),
    do: Store.transaction(&remove_entries(&1, entries), @timeout)

  defp remove_entries(txn, entries) do
    with {:ok, referenced} <-
           column(
             txn,
             """
             SELECT DISTINCT p FROM (
               SELECT CASE WHEN json_valid(metadata) THEN json_extract(metadata, '$.source_package_id') END AS p
                 FROM contexts
               UNION
               SELECT source_package_id AS p FROM claims
             ) WHERE p IN #{set(1)}
             """,
             [entries |> Enum.map(& &1.package) |> json()]
           ) do
      referenced = MapSet.new(referenced)
      {kept, going} = Enum.split_with(entries, &MapSet.member?(referenced, &1.package))

      going
      |> Enum.reduce_while({:ok, 0}, fn entry, {:ok, files} ->
        case remove_entry_files(txn, entry) do
          {:ok, count} -> {:cont, {:ok, files + count}}
          {:error, _} = error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, files} -> {:ok, %{entries: length(going), kept: length(kept), files: files}}
        {:error, _} = error -> error
      end
    end
  end

  defp remove_entry_files(txn, entry) do
    with {:ok, shared} <- shared_paths(txn, entry.assets, entry.scope),
         artifacts = file_artifacts(entry.assets, entry.runs, shared, entry.scope),
         {:ok, removed} <- Artifacts.remove(artifacts),
         :ok <- forget_checkpoints(txn, artifacts) do
      {:ok, removed.files}
    end
  end

  # The files are gone; a pointer to one would only mislead. A file that was left alone
  # keeps its pointer.
  defp forget_checkpoints(txn, artifacts) do
    runs =
      for {:checkpoint, run_id, uri, _workspace_id} <- artifacts,
          is_binary(uri),
          match?({:error, :enoent}, File.lstat(uri)),
          do: run_id

    if runs == [] do
      :ok
    else
      case Store.txn_execute(
             txn,
             "UPDATE decomposition_runs SET checkpoint_uri = NULL WHERE id IN #{set(1)}",
             [json(runs)]
           ) do
        {:ok, _} -> :ok
        {:error, _} = error -> error
      end
    end
  end

  defp plan_files(_txn, _tenant_id, _workspace_id, []), do: {:ok, []}

  defp plan_files(txn, tenant_id, workspace_id, ids) do
    with {:ok, found} <-
           column(
             txn,
             "SELECT id FROM contexts WHERE tenant_id = ?1 AND workspace_id = ?2 AND id IN #{set(3)}",
             [tenant_id, workspace_id, json(ids)]
           ),
         {:ok, entries} <- plan_found(txn, found) do
      {:ok, entries}
    end
  end

  defp plan_found(_txn, []), do: {:ok, []}

  defp plan_found(txn, found) do
    ctx = json(found)

    with {:ok, scope} <- erased_scope(txn, ctx),
         {:ok, packages} <- exclusive_packages(txn, ctx),
         pkgs = json(packages),
         {:ok, owners} <-
           rows(
             txn,
             """
             SELECT DISTINCT id, p FROM (
               SELECT c.id AS id, CASE WHEN json_valid(c.metadata) THEN json_extract(c.metadata, '$.source_package_id') END AS p
                 FROM contexts c WHERE c.id IN #{set(1)}
               UNION
               SELECT signal_id AS id, source_package_id AS p FROM claims WHERE signal_id IN #{set(1)}
             ) WHERE p IN #{set(2)}
             """,
             [ctx, pkgs]
           ),
         {:ok, assets} <-
           rows(
             txn,
             "SELECT id, storage_path, workspace_id, source_package_id FROM assets WHERE source_package_id IN #{set(1)}",
             [pkgs]
           ),
         {:ok, runs} <-
           rows(
             txn,
             "SELECT id, checkpoint_uri, workspace_id, source_package_id FROM decomposition_runs " <>
               "WHERE source_package_id IN #{set(1)} AND checkpoint_uri IS NOT NULL",
             [pkgs]
           ),
         {:ok, shared} <- shared_paths(txn, Enum.map(assets, &Enum.take(&1, 3)), scope) do
      entries =
        for package <- packages,
            package_assets = for([id, path, ws, ^package] <- assets, do: [id, path, ws]),
            package_runs = for([id, uri, ws, ^package] <- runs, do: [id, uri, ws]),
            file_artifacts(package_assets, package_runs, shared, scope) != [] do
          %{
            package: package,
            contexts: for([id, ^package] <- owners, do: id),
            assets: package_assets,
            runs: package_runs,
            scope: scope
          }
        end

      {:ok, entries}
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
      case Artifacts.remove(file_artifacts(assets, runs, shared, scope)) do
        {:ok, _removed} -> :ok
        {:error, _} = error -> error
      end
    end
  end

  # The files of these asset rows (id, path, workspace) and run rows (id, checkpoint,
  # workspace): not one shared with an asset that stays, and only for a workspace in `scope`.
  defp file_artifacts(assets, runs, shared, scope) do
    files =
      for [_id, path, workspace_id] <- assets,
          Map.has_key?(scope, workspace_id),
          not shared?(shared, path),
          do: asset_artifact(path, scope, workspace_id)

    checkpoints =
      for [run_id, uri, workspace_id] <- runs,
          Map.has_key?(scope, workspace_id),
          do: {:checkpoint, run_id, uri, workspace_id}

    files ++ checkpoints
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
