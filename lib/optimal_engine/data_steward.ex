defmodule OptimalEngine.DataSteward do
  @moduledoc """
  Governed interface for inspecting and reducing live data-quality backlogs.

  Planning is read-only.
  Mutations require explicit item identifiers and never infer acceptance.
  """

  alias OptimalEngine.Authority.{Evidence, WorkspaceRekeys}

  alias OptimalEngine.DataSteward.HierarchyRepair

  alias OptimalEngine.{
    ContextHealth,
    CorpusOrganizer,
    EntityQuality,
    EntityResolution,
    HierarchyAudit,
    MemoryCore,
    ReviewQueue,
    Store,
    URI,
    Workspace
  }

  alias OptimalEngine.Portability.WorkspaceBundle
  alias OptimalEngine.Store.FileCache.Maintenance, as: Cache
  alias OptimalEngine.UriRepair.References
  alias OptimalEngine.Workspace.Filesystem

  require Logger

  @default_limit 100

  # A rename that moves a workspace's directory rewrites the path of every file in it.
  @rename_timeout 300_000

  # Where a rename that is about to move a directory notes it (under the Engine root), until
  # the transaction has committed or the directory is back.
  @rename_marker_dir ".optimal-rename"

  # How many moved addresses are re-pointed in one statement.
  @address_chunk 200

  # A batch of route decisions is one request; more than this is several.
  @max_route_items 500

  # Tables a change of workspace id does not re-key. `workspaces` is the
  # record being replaced, and the handles move by their own step.
  # `authority_evidence` is hashed and signed over the workspace id each entry
  # names, so a rewritten row no longer verifies: an entry keeps the id the
  # workspace had when it was written. Rows that point at signed evidence
  # (`authority_action_steps`) do move, and the move is recorded as signed
  # evidence too (`OptimalEngine.Authority.WorkspaceRekeys`), which is what
  # lets a step be verified against the id it was signed with.
  @not_rekeyed ~w(workspaces workspace_handles authority_evidence)

  # Tables with a `workspace_id` column and no `tenant_id` column. An orphan
  # repair cannot tell whose a row is by its workspace id, so each row of the
  # tables listed here is traced to a tenant through the rows it points at
  # (`trace_sql/2`), and moves only when they are the tenant's and in the
  # workspace being repaired. The list is in the order the tables move: a table
  # whose parent is another table of the list comes before it (a proposal
  # before its paths), or is moved after them (a decision before its mention,
  # which has a tenant column), because the trace looks at where the parent
  # still is.
  @traced_tables ~w(resolution_decisions memory_consolidation_proposals entity_aliases
                    entity_identifiers entity_lineage memory_association_paths
                    memory_reconstruction_outcomes)

  # The others have nothing to trace by and are left, and reported.
  # `sync_capture` could be traced through the row inside each captured change,
  # but moving a capture row would ship a change that still names the old id
  # inside it; the rows that did move are captured afresh under the new id.
  @untraced ~w(memory_path_feedback sync_capture)

  @doc false
  # The tables with no tenant column an orphan repair traces to a tenant, and
  # the ones it cannot; the schema test ties them to the database.
  @spec unscoped_tables() :: %{traced: [String.t()], untraced: [String.t()]}
  def unscoped_tables do
    %{traced: Enum.sort(@traced_tables), untraced: @untraced}
  end

  # What none of the re-keyed tables carry, and so what an operator must redo
  # after a repair: workspace policy packs (`authority_policies.scope_id`, and
  # patterns inside their signed documents) and API keys (`api_keys.workspace_scope`,
  # fingerprinted when minted) name the workspace by id in content that is
  # hashed and recorded. Rewriting them would be exactly the unrecorded change
  # the integrity scan reports, so they are published and minted again for the
  # new id, which leaves evidence. Grants already issued keep working
  # (`OptimalEngine.Authority.Admission`).

  @doc false
  # Tables a workspace id repair does not re-key; the schema test ties its
  # classification of signed tables to this list.
  @spec not_rekeyed_tables() :: [String.t()]
  def not_rekeyed_tables, do: @not_rekeyed

  @doc """
  The steward's overview of a tenant. Options: `:tenant_id` (default
  tenant), and `intake: false` for a caller that may not see the tenant's
  intake workspace, whose `route_clusters` are then empty.
  """
  def dashboard(workspace_id, opts \\ []) do
    tenant_id = Keyword.get(opts, :tenant_id, "default")

    with {:ok, entity_quality} <- EntityQuality.run(workspace_id, tenant_id: tenant_id),
         {:ok, orphan_scopes} <- orphan_scopes(tenant_id),
         {:ok, claims} <- claim_clusters(workspace_id, tenant_id, @default_limit),
         {:ok, routes} <-
           if(Keyword.get(opts, :intake, true),
             do: route_clusters(tenant_id, @default_limit),
             else: {:ok, []}
           ),
         {:ok, entities} <- entity_clusters(workspace_id, tenant_id, @default_limit),
         {:ok, hierarchy} <- HierarchyAudit.run(tenant_id) do
      {:ok,
       %{
         workspace_id: workspace_id,
         tenant_id: tenant_id,
         context_health: ContextHealth.run(workspace_id: workspace_id, tenant_id: tenant_id),
         entity_quality: entity_quality,
         orphan_scopes: orphan_scopes,
         claim_clusters: claims,
         route_clusters: routes,
         entity_clusters: entities,
         hierarchy: hierarchy,
         invariants: [
           "source evidence is preserved",
           "acceptance requires explicit identifiers",
           "bulk decisions are workspace scoped",
           "memory candidates and actionable claims remain distinct"
         ]
       }}
    end
  end

  def claim_clusters(workspace_id, tenant_id \\ "default", limit \\ @default_limit) do
    with {:ok, rows} <-
           Store.raw_query(
             """
             SELECT id, claim_type, claim_text, source_package_id, created_at
             FROM claims
             WHERE tenant_id=?1 AND workspace_id=?2 AND lifecycle_state='pending'
             ORDER BY created_at DESC, id LIMIT ?3
             """,
             [tenant_id, workspace_id, limit]
           ) do
      clusters =
        rows
        |> Enum.map(fn [id, type, text, source_id, created_at] ->
          %{id: id, kind: type, text: text, source_package_id: source_id, created_at: created_at}
        end)
        |> Enum.group_by(fn item -> {item.kind, fingerprint(item.text)} end)
        |> Enum.map(fn {{kind, fingerprint}, items} ->
          %{
            kind: kind,
            fingerprint: fingerprint,
            count: length(items),
            representative: hd(items).text,
            ids: Enum.map(items, & &1.id),
            source_package_ids: items |> Enum.map(& &1.source_package_id) |> Enum.uniq()
          }
        end)
        |> Enum.sort_by(&{-&1.count, &1.fingerprint})

      {:ok, clusters}
    end
  end

  @doc """
  Records of the tenant's intake workspace waiting in the routing review
  queue, grouped by state and proposed workspace.
  """
  def route_clusters(tenant_id, limit \\ @default_limit) when is_binary(tenant_id) do
    with {:ok, rows} <-
           Store.raw_query(
             """
             SELECT id, title, json_extract(metadata, '$.routing_review.state'),
                    json_extract(metadata, '$.routing_review.proposed_workspace_id')
             FROM contexts
             WHERE tenant_id=?1 AND workspace_id=?2 AND archived_at IS NULL
               AND json_extract(metadata, '$.routing_review.state') IN ('review','unresolved')
             ORDER BY modified_at DESC, uri, id LIMIT ?3
             """,
             [tenant_id, CorpusOrganizer.source_workspace(tenant_id), limit]
           ) do
      {:ok,
       rows
       |> Enum.map(fn [id, title, state, target] ->
         %{id: id, title: title, state: state, proposed_workspace_id: target}
       end)
       |> Enum.group_by(&{&1.state, &1.proposed_workspace_id})
       |> Enum.map(fn {{state, target}, items} ->
         %{state: state, proposed_workspace_id: target, count: length(items), items: items}
       end)
       |> Enum.sort_by(&{-&1.count, &1.state})}
    end
  end

  @doc """
  The unresolved mentions of the tenant in a workspace, grouped by kind and
  name. A mention is the tenant's by the context or source package it was
  found in (`OptimalEngine.EntityResolution`).
  """
  def entity_clusters(workspace_id, tenant_id \\ "default", limit \\ @default_limit)
      when is_binary(tenant_id) do
    with {:ok, rows} <-
           Store.raw_query(
             """
             SELECT id, surface_text, normalized_text, proposed_kind, confidence, context_id
             FROM entity_mentions
             WHERE workspace_id=?2 AND resolution_state IN ('unresolved','ambiguous')
               AND #{EntityResolution.owned_mention_sql()}
             ORDER BY normalized_text, confidence DESC, id LIMIT ?1
             """,
             [limit, workspace_id, tenant_id]
           ) do
      {:ok,
       rows
       |> Enum.map(fn [id, text, normalized, kind, confidence, context_id] ->
         %{
           id: id,
           surface_text: text,
           normalized_text: normalized,
           proposed_kind: kind,
           confidence: confidence,
           context_id: context_id
         }
       end)
       |> Enum.group_by(&{&1.proposed_kind, &1.normalized_text})
       |> Enum.map(fn {{kind, normalized}, items} ->
         %{
           proposed_kind: kind,
           normalized_text: normalized,
           count: length(items),
           mentions: items
         }
       end)
       |> Enum.sort_by(&{-&1.count, &1.normalized_text})}
    end
  end

  def decide_claims(ids, decision, opts)
      when is_list(ids) and ids != [] and decision in [:accept, :reject] do
    workspace_id = Keyword.fetch!(opts, :workspace_id)
    tenant_id = Keyword.get(opts, :tenant_id, "default")
    actor_id = Keyword.fetch!(opts, :actor_id)

    apply_explicit(ids, fn id ->
      ReviewQueue.decide_claim(id, decision,
        workspace_id: workspace_id,
        tenant_id: tenant_id,
        actor_id: actor_id
      )
    end)
  end

  @doc """
  Accepts or rejects routing review entries of the tenant's intake workspace,
  each item `%{id: ..., target_workspace_id: ...}` (the target is needed to
  accept). Options: `:actor_id`, `:tenant_id` (both required).

  An item is decided on its own: a record that is not the tenant's, or not in
  its intake, or a target that is not an active workspace of the tenant,
  fails that item and nothing else. A batch holds at most 500 items
  (`{:error, {:too_many_items, 500}}`).
  """
  def decide_routes(items, decision, opts)
      when is_list(items) and items != [] and decision in [:accept, :reject] do
    actor_id = Keyword.fetch!(opts, :actor_id)
    tenant_id = Keyword.fetch!(opts, :tenant_id)

    if length(items) > @max_route_items,
      do: {:error, {:too_many_items, @max_route_items}},
      else: {:ok, decide_each(items, decision, actor_id, tenant_id)}
  end

  defp decide_each(items, decision, actor_id, tenant_id) do
    results =
      Enum.map(items, fn item ->
        id = item_id(item)
        target = item_target(item)

        result =
          cond do
            not is_binary(id) ->
              {:error, :id_required}

            decision == :accept and is_nil(target) ->
              {:error, :target_workspace_required}

            true ->
              ReviewQueue.decide_route(id, decision, target,
                actor_id: actor_id,
                tenant_id: tenant_id
              )
          end

        %{id: id, target_workspace_id: target, result: normalize_result(result)}
      end)

    summarize(results)
  end

  @doc """
  Workspace ids that own records of `tenant_id` and are not registered as a
  workspace, with how many records each owns. Only the tenant's own records
  are counted.
  """
  def orphan_scopes(tenant_id) do
    with {:ok, rows} <-
           Store.raw_query(
             """
             SELECT owned.workspace_id, owned.record_count
             FROM (
               SELECT workspace_id, COUNT(*) record_count FROM (
                 SELECT workspace_id FROM contexts WHERE archived_at IS NULL AND tenant_id=?1
                 UNION ALL SELECT workspace_id FROM memories WHERE is_latest=1 AND is_forgotten=0 AND tenant_id=?1
                 UNION ALL SELECT workspace_id FROM claims WHERE tenant_id=?1
               ) GROUP BY workspace_id
             ) owned
             LEFT JOIN workspaces registered ON registered.id=owned.workspace_id
             WHERE registered.id IS NULL
             ORDER BY owned.record_count DESC, owned.workspace_id
             """,
             [tenant_id]
           ) do
      {:ok,
       Enum.map(rows, fn [workspace_id, count] ->
         %{workspace_id: workspace_id, records: count}
       end)}
    end
  end

  @doc """
  Moves the rows of `tenant_id` that name an unregistered workspace id to a
  registered workspace of the same tenant. Options: `:actor_id`, `:tenant_id`
  (both required).

  The target must be an active workspace of the tenant. The source must not be
  registered: not in another tenant, in any state, and not an active workspace
  of this one (an archived workspace of the tenant itself can still be repaired
  from). Only the tenant's rows move. A table with a `tenant_id` column is
  bound to it (a mention written before its column, which records no tenant,
  is traced through its context or source package instead). A table without
  one cannot be told apart by tenant for an id
  nobody owns, so each of its rows is traced to a tenant through a row it
  points at (see `unscoped_tables/0`) and moves when that row is the
  tenant's. A row that cannot be traced stays, and the answer lists the
  tables that cannot be traced at all (`unscoped_tables`) with the rows they
  hold.

  The checks and the move run in one transaction. A repair with nothing of the
  tenant's to move answers `{:error, :nothing_to_repair}` and says nothing of
  what other tenants hold under the id.
  """
  def repair_orphan_scope(source_workspace_id, target_workspace_id, opts) do
    actor_id = Keyword.fetch!(opts, :actor_id)
    tenant = Keyword.fetch!(opts, :tenant_id)

    with {:ok, tables} <- workspace_tables(),
         {:ok, evidence_key} <- recording_key(tenant, source_workspace_id) do
      {scoped, unscoped} = Enum.split_with(tables, & &1.tenant_scoped?)
      # A mention that records no tenant is traced through its context or
      # source package, so it moves before they do.
      {mentions, scoped} = Enum.split_with(scoped, &(&1.name == "entity_mentions"))
      untraced = Enum.reject(unscoped, &(&1.name in @traced_tables))
      traced = for name <- @traced_tables, table <- unscoped, table.name == name, do: table

      Store.transaction(fn txn ->
        with :ok <- check_target(txn, tenant, target_workspace_id),
             :ok <- check_orphan_source(txn, tenant, source_workspace_id),
             {:ok, moved_traced} <-
               move_rows(txn, traced, source_workspace_id, target_workspace_id, tenant),
             {:ok, moved_mentions} <-
               move_rows(txn, mentions, source_workspace_id, target_workspace_id, tenant),
             {:ok, moved_scoped} <-
               move_rows(txn, scoped, source_workspace_id, target_workspace_id, tenant),
             # A repair is only a repair if rows of the tenant itself moved; rows
             # that merely hang off them do not make one.
             :ok <-
               if(rows_moved(moved_mentions) + rows_moved(moved_scoped) > 0,
                 do: :ok,
                 else: {:error, :nothing_to_repair}
               ),
             # Signed rows keep the id they were written with; the move is
             # recorded so they can still be followed to the target.
             :ok <-
               WorkspaceRekeys.record(
                 txn,
                 evidence_key,
                 tenant,
                 source_workspace_id,
                 target_workspace_id,
                 actor_id,
                 :merge
               ),
             {:ok, left} <- rows_left(txn, untraced, source_workspace_id) do
          moved = moved_traced ++ moved_mentions ++ moved_scoped

          {:ok,
           %{
             source_workspace_id: source_workspace_id,
             target_workspace_id: target_workspace_id,
             actor_id: actor_id,
             updated_records: rows_moved(moved),
             tables: Enum.filter(moved, &(&1.updated > 0)),
             unscoped_tables: left,
             rekey_recorded: not is_nil(evidence_key)
           }}
        end
      end)
      |> purge_vacated_cache(source_workspace_id, :repair)
    end
  end

  @doc """
  Makes a workspace's id match its slug, moving its rows. Options:
  `:actor_id`, `:tenant_id` (both required). The source must be a workspace
  of the tenant; one of another tenant is not found.

  The target must be `<tenant>:<slug>` and unregistered, and must hold no rows
  (`target_workspace_has_rows`): merge those into the workspace first. The
  source id must not hold rows of another tenant (`workspace_id_shared`),
  which a rename could not take with it. The source is read again inside the
  transaction that moves it, so a change made meanwhile is not lost.

  A workspace's directory is keyed by its id (`Workspace.Filesystem.path/2`), so the
  rename moves it: the files, `contexts.path` and `contexts.uri` of the files, and
  `assets.storage_path` of local assets all follow the id, in the same transaction, and
  only for rows of this tenant and workspace. A path is matched as the file system sees
  it (expanded), whether the row stores it absolute or relative to a relative root path,
  and is written back in the form it had. An address that follows its file takes with it
  everything that names it: the access rules (`acls`, a deny rule included), the
  memories' `citation_uri`, the open loops' `source_uri` and `close_source_uri`, and the
  events' `target_uri`. An address that another context also holds keeps its rules, and
  the moved context gets a copy (`UriRepair.References`).
  The move is the last step, so a rename that fails earlier leaves the directory where
  it was, and a commit that fails after it moves the directory back. A crash between
  the move and the commit leaves a marker under `<root>/.optimal-rename`;
  `recover_interrupted_renames/0` reads the markers and puts the directory back when
  the rename did not commit (it runs at the start of every rename, and an operator can
  call it). It is refused, with nothing changed, when the directory cannot be moved
  safely: the same test as a move to another Engine (`WorkspaceBundle.movable/1`, so
  never the Engine root, a directory the root uses for itself or one that holds more
  than the workspace), a target directory that already holds files
  (`workspace_directory_exists`), or an entry at the source that is not a directory
  (`workspace_directory_unusual`). A workspace that has no directory yet is renamed with
  nothing to move. Text that quotes an `optimal://` address of a moved file (wiki
  bodies) is not rewritten. The answer says whether the directory moved
  (`directory_moved`) and how many paths and addresses were rewritten
  (`paths_rewritten`).
  """
  def rename_workspace(source_workspace_id, target_workspace_id, opts) do
    actor_id = Keyword.fetch!(opts, :actor_id)
    tenant = Keyword.fetch!(opts, :tenant_id)

    with :ok <- source_registered(tenant, source_workspace_id),
         {:ok, tables} <- workspace_tables(),
         {:ok, evidence_key} <- recording_key(tenant, source_workspace_id) do
      # A crash during an earlier rename may have left a directory under the id its rows
      # do not have; put it back before looking at the directory again.
      _ = recover_interrupted_renames()

      # What the filesystem says is read now; a refusal is raised below, after the checks
      # of the rows, so a target of the wrong shape is still refused for its shape.
      directory = plan_directory_move(source_workspace_id, target_workspace_id)
      move = with {:ok, planned} <- directory, do: planned, else: (_refused -> nil)

      Store.transaction(
        fn txn ->
          with {:ok, workspace} <- read_source(txn, tenant, source_workspace_id),
               :ok <- check_rename_target(txn, workspace, tenant, target_workspace_id),
               :ok <- target_free_of_rows(txn, tables, target_workspace_id),
               :ok <- check_id_not_shared(txn, tables, source_workspace_id, tenant),
               {:ok, _planned} <- directory,
               {:ok, renamed} <-
                 rename_in(
                   txn,
                   workspace,
                   tables,
                   evidence_key,
                   tenant,
                   source_workspace_id,
                   target_workspace_id,
                   actor_id
                 ),
               {:ok, rewritten} <-
                 move_directory(txn, move, %{
                   tenant: tenant,
                   source: source_workspace_id,
                   target: target_workspace_id
                 }) do
            {:ok,
             renamed
             |> Map.put(:directory_moved, move != nil)
             |> Map.put(:paths_rewritten, rewritten)}
          end
        end,
        @rename_timeout
      )
      |> settle_move(move)
      |> purge_vacated_cache(source_workspace_id, :rename)
    end
  end

  # ── the directory goes with the id ─────────────────────────────────────────

  # Decided before the transaction opens, so a refusal changes nothing. `stored_new` is
  # the new directory written the way rows write a path under the configured root, which
  # may be a relative one.
  defp plan_directory_move(source, target) do
    configured = Application.get_env(:optimal_engine, :root_path, File.cwd!())
    root = Path.expand(configured)
    old = Path.expand(Filesystem.path(root, source))
    new = Path.expand(Filesystem.path(root, target))

    if old == new do
      {:ok, nil}
    else
      case File.lstat(old) do
        {:error, :enoent} ->
          {:ok, nil}

        {:ok, %{type: :directory}} ->
          with :ok <- WorkspaceBundle.movable(source),
               :ok <- WorkspaceBundle.movable(target),
               :ok <- target_directory_free(new) do
            {:ok,
             %{old: old, new: new, root: root, stored_new: Filesystem.path(configured, target)}}
          end

        _link_file_or_unreadable ->
          {:error, :workspace_directory_unusual}
      end
    end
  end

  # The target may hold directories nothing was ever written to (a workspace is
  # provisioned with an empty tree); any file or link in it is somebody's.
  defp target_directory_free(path) do
    case File.lstat(path) do
      {:error, :enoent} -> :ok
      {:ok, %{type: :directory}} -> if only_empty_directories?(path), do: :ok, else: exists()
      _other -> exists()
    end
  end

  defp exists, do: {:error, :workspace_directory_exists}

  defp only_empty_directories?(dir) do
    case File.ls(dir) do
      {:ok, names} ->
        Enum.all?(names, fn name ->
          child = Path.join(dir, name)
          match?({:ok, %{type: :directory}}, File.lstat(child)) and only_empty_directories?(child)
        end)

      {:error, _} ->
        false
    end
  end

  defp move_directory(_txn, nil, _rename), do: {:ok, %{contexts: 0, assets: 0, addresses: 0}}

  defp move_directory(txn, move, %{tenant: tenant, target: workspace} = rename) do
    with {:ok, rewritten} <- rewrite_paths(txn, move, tenant, workspace),
         :ok <- note_intent(move, rename),
         :ok <- remove_empty_tree(move.new),
         :ok <- File.mkdir_p(Path.dirname(move.new)),
         :ok <- File.rename(move.old, move.new) do
      {:ok, rewritten}
    else
      {:error, reason} when is_atom(reason) -> {:error, {:workspace_directory_not_moved, reason}}
      {:error, _} = error -> error
    end
  end

  # The rows of this tenant and workspace that name a file under the old directory: where it
  # is, and the address derived from where it is. A path is read as the file system reads it,
  # so a relative one is found, and it is written back the way it was written.
  defp rewrite_paths(txn, move, tenant, workspace) do
    with {:ok, contexts} <-
           Store.txn_query(
             txn,
             """
             SELECT id, path, uri FROM contexts
              WHERE tenant_id = ?1 AND workspace_id = ?2 AND path IS NOT NULL AND path != ''
             """,
             [tenant, workspace]
           ),
         moved = relocated_contexts(contexts, move),
         :ok <- each_ok(moved, &move_context(txn, tenant, workspace, &1)),
         {:ok, assets} <-
           Store.txn_query(
             txn,
             """
             SELECT id, storage_path FROM assets
              WHERE tenant_id = ?1 AND workspace_id = ?2 AND storage_path NOT LIKE 's3://%'
             """,
             [tenant, workspace]
           ),
         relocated = relocated_assets(assets, move),
         :ok <- each_ok(relocated, &move_asset(txn, tenant, workspace, &1)),
         addresses = for(%{uri: uri, new_uri: new_uri} = c <- moved, uri != new_uri, do: c),
         :ok <- move_addresses(txn, tenant, workspace, addresses) do
      {:ok, %{contexts: length(moved), assets: length(relocated), addresses: length(addresses)}}
    end
  end

  defp relocated_contexts(rows, move) do
    for [id, path, uri] <- rows, {new_path, stored} <- [relocate(path, move)] do
      # An address that is not the one the old path gives was not made from the path, and
      # stays what it is.
      new_uri = if uri == URI.from_path(path), do: URI.from_path(stored), else: uri
      %{id: id, new_path: new_path, uri: uri, new_uri: new_uri}
    end
  end

  defp relocated_assets(rows, move) do
    for [id, path] <- rows, {new_path, _stored} <- [relocate(path, move)] do
      %{id: id, new_path: new_path}
    end
  end

  # Where a file under the old directory goes: in the form the row has (absolute, or the
  # configured root's), and in the form addresses are made from. Nil for any other path.
  defp relocate(path, %{old: old, new: new, stored_new: stored_new}) when is_binary(path) do
    expanded = if String.contains?(path, <<0>>), do: nil, else: Path.expand(path)

    if expanded && String.starts_with?(expanded, old <> "/") do
      rest = Path.relative_to(expanded, old)
      stored = Path.join(stored_new, rest)
      {if(Path.type(path) == :absolute, do: Path.join(new, rest), else: stored), stored}
    end
  end

  defp relocate(_path, _move), do: nil

  defp move_context(txn, tenant, workspace, %{id: id, new_path: path, new_uri: uri}) do
    case Store.txn_execute(
           txn,
           """
           UPDATE contexts SET path = ?2, uri = ?3
            WHERE id = ?1 AND tenant_id = ?4 AND workspace_id = ?5
           """,
           [id, path, uri, tenant, workspace]
         ) do
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end

  defp move_asset(txn, tenant, workspace, %{id: id, new_path: path}) do
    case Store.txn_execute(
           txn,
           """
           UPDATE assets SET storage_path = ?2
            WHERE id = ?1 AND tenant_id = ?3 AND workspace_id = ?4
           """,
           [id, path, tenant, workspace]
         ) do
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end

  # What names an address that moved follows it: the access rules, the memories' citations,
  # the open loops' sources and the events' targets. A rule left on the old address would
  # leave the file with none, and a file with none is open (`acl_absent: :allow`).
  defp move_addresses(_txn, _tenant, _workspace, []), do: :ok

  defp move_addresses(txn, tenant, workspace, moved) do
    with {:ok, held} <- held_addresses(txn, tenant, moved) do
      moved
      |> Enum.chunk_every(@address_chunk)
      |> each_ok(&move_address_chunk(txn, tenant, workspace, &1, held))
    end
  end

  # By now the contexts hold their new addresses, so an old address that a context still
  # holds is shared with it. One look at the table per few thousand addresses.
  defp held_addresses(txn, tenant, moved) do
    moved
    |> Enum.map(& &1.uri)
    |> Enum.uniq()
    |> Enum.chunk_every(2_000)
    |> Enum.reduce_while({:ok, MapSet.new()}, fn olds, {:ok, held} ->
      case Store.txn_query(
             txn,
             """
             SELECT DISTINCT uri FROM contexts
              WHERE tenant_id = ?1 AND uri IN (SELECT value FROM json_each(?2))
             """,
             [tenant, Jason.encode!(olds)]
           ) do
        {:ok, rows} -> {:cont, {:ok, rows |> List.flatten() |> MapSet.new() |> MapSet.union(held)}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp move_address_chunk(txn, tenant, workspace, chunk, held) do
    {shared, own} = Enum.split_with(chunk, &MapSet.member?(held, &1.uri))

    with :ok <- each_ok(shared, &share_address(txn, tenant, workspace, &1)),
         :ok <- each_ok(own, &move_acls(txn, tenant, &1)) do
      repoint(txn, tenant, workspace, own)
    end
  end

  # The old address is still another context's: it keeps its rules, the moved context gets
  # a copy, and what names the context by id moves (the rest keeps resolving to the other).
  defp share_address(txn, tenant, workspace, %{id: id, uri: old, new_uri: new}) do
    case References.move(txn, tenant, workspace, id, old, new) do
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end

  defp move_acls(txn, tenant, %{uri: old, new_uri: new}) do
    with {:ok, _} <-
           Store.txn_execute(
             txn,
             """
             INSERT INTO acls (tenant_id, resource_uri, principal_id, group_id, permission, granted_at)
             SELECT a.tenant_id, ?1, a.principal_id, a.group_id, a.permission, a.granted_at
               FROM acls a
              WHERE a.tenant_id = ?2 AND a.resource_uri = ?3
                AND NOT EXISTS (
                  SELECT 1 FROM acls b
                   WHERE b.tenant_id = a.tenant_id AND b.resource_uri = ?1
                     AND b.permission = a.permission
                     AND COALESCE(b.principal_id, '') = COALESCE(a.principal_id, '')
                     AND COALESCE(b.group_id, '') = COALESCE(a.group_id, ''))
             """,
             [new, tenant, old]
           ),
         {:ok, _} <-
           Store.txn_execute(
             txn,
             "DELETE FROM acls WHERE tenant_id = ?1 AND resource_uri = ?2",
             [tenant, old]
           ) do
      :ok
    end
  end

  # Records that name an address no other context holds. The rows are found with one look at
  # the table for the whole chunk (these columns have no index, so one scan per address would
  # be a scan per file moved) and each is then updated by its key.
  defp repoint(_txn, _tenant, _workspace, []), do: :ok

  defp repoint(txn, tenant, workspace, own) do
    new_for = Map.new(own, &{&1.uri, &1.new_uri})
    olds = Jason.encode!(Map.keys(new_for))

    with :ok <- repoint_column(txn, "memories", "citation_uri", {tenant, workspace}, olds, new_for),
         :ok <- repoint_column(txn, "open_loops", "source_uri", {tenant, workspace}, olds, new_for),
         :ok <-
           repoint_column(txn, "open_loops", "close_source_uri", {tenant, workspace}, olds, new_for) do
      # Events carry no workspace of their own to rely on: the tenant's, as the repair of
      # shared addresses counts them.
      repoint_column(txn, "events", "target_uri", {tenant, nil}, olds, new_for)
    end
  end

  defp repoint_column(txn, table, column, {tenant, workspace}, olds, new_for) do
    {scope, params} =
      if workspace,
        do:
          {"tenant_id = ?1 AND workspace_id = ?2 AND #{column} IN #{set(3)}",
           [tenant, workspace, olds]},
        else: {"tenant_id = ?1 AND #{column} IN #{set(2)}", [tenant, olds]}

    with {:ok, rows} <-
           Store.txn_query(txn, "SELECT id, #{column} FROM #{table} WHERE #{scope}", params) do
      each_ok(rows, fn [id, old] ->
        case Store.txn_execute(txn, "UPDATE #{table} SET #{column} = ?2 WHERE id = ?1", [
               id,
               Map.fetch!(new_for, old)
             ]) do
          {:ok, _} -> :ok
          {:error, _} = error -> error
        end
      end)
    end
  end

  defp set(n), do: "(SELECT value FROM json_each(?#{n}))"

  defp each_ok(list, fun) do
    Enum.reduce_while(list, :ok, fn item, :ok ->
      case fun.(item) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  # Deepest first: `rmdir` refuses a directory that still has an entry.
  defp remove_empty_tree(path) do
    case File.lstat(path) do
      {:ok, %{type: :directory}} ->
        {:ok, names} = File.ls(path)
        Enum.each(names, &remove_empty_tree(Path.join(path, &1)))
        File.rmdir(path)

      _gone ->
        :ok
    end
  end

  # ── a crash between the move and the commit ────────────────────────────────

  # Written before the directory moves, removed once the transaction is settled. The
  # directory and the rows cannot change together, so a crash in between would leave
  # the directory under an id the rows do not have; the marker says what to put back.
  defp note_intent(move, %{tenant: tenant, source: source, target: target}) do
    marker = marker_path(move)
    tmp = marker <> ".tmp"

    body =
      Jason.encode!(%{
        tenant_id: tenant,
        source: source,
        target: target,
        started_at: DateTime.utc_now() |> DateTime.to_iso8601()
      })

    with :ok <- File.mkdir_p(Path.dirname(marker)),
         :ok <- write_synced(tmp, body),
         :ok <- File.rename(tmp, marker) do
      :ok
    end
  end

  # The note has to be on disk before the directory moves, or a crash that takes the
  # machine with it leaves the move without its note.
  defp write_synced(path, body) do
    with {:ok, file} <- File.open(path, [:write, :binary]) do
      try do
        with :ok <- IO.binwrite(file, body), do: :file.sync(file)
      after
        File.close(file)
      end
    end
  end

  defp directory_home?(old, new) do
    cond do
      File.dir?(new) and not File.exists?(old) -> File.rename(new, old) == :ok
      File.dir?(old) and not File.exists?(new) -> true
      true -> false
    end
  end

  defp clear_intent(nil), do: :ok
  defp clear_intent(move), do: File.rm(marker_path(move))

  @doc false
  def marker_path(%{root: root, old: old, new: new}) do
    name = Base.url_encode64(:crypto.hash(:sha256, [old, 0, new]), padding: false)
    Path.join([root, @rename_marker_dir, name <> ".json"])
  end

  # The transaction is settled. When it did not commit after the directory moved, the rows
  # are as they were, so the directory goes back to where they say it is. The note stays
  # unless the directory is back or never left: a note that outlives a stranded directory
  # is what `recover_interrupted_renames/0` reads.
  @doc false
  def settle_move({:error, _} = error, %{old: old, new: new} = move) do
    if directory_home?(old, new), do: clear_intent(move)
    error
  end

  def settle_move(result, move) do
    clear_intent(move)
    result
  end

  @doc """
  Puts back the directory of a rename that did not commit. A rename notes what it is
  about to do under `<root>/.optimal-rename` before it moves a directory and removes the
  note when the transaction has committed (or the directory is back), so a note that is
  still there means the process stopped in between. For each note: when the target
  workspace exists the rename committed and the note goes; when it does not and the
  directory is under the target's id, it is moved back to the source's; when it is where
  the rows say, the note goes. Anything else (both directories exist) is left for the
  operator and reported. Returns what was done for each note.
  """
  @spec recover_interrupted_renames() :: {:ok, [map()]} | {:error, term()}
  def recover_interrupted_renames do
    root = Path.expand(Application.get_env(:optimal_engine, :root_path, File.cwd!()))
    dir = Path.join(root, @rename_marker_dir)

    case File.ls(dir) do
      {:ok, names} ->
        {:ok,
         for name <- Enum.sort(names), String.ends_with?(name, ".json") do
           recover_one(root, Path.join(dir, name))
         end}

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error, {:rename_notes_unreadable, reason}}
    end
  end

  defp recover_one(root, marker) do
    with {:ok, body} <- File.read(marker),
         {:ok, %{"source" => source, "target" => target}}
         when is_binary(source) and is_binary(target) <- Jason.decode(body),
         :ok <- WorkspaceBundle.movable(source),
         :ok <- WorkspaceBundle.movable(target) do
      # The directories are the ones the ids name, never paths read from the note.
      old = Path.expand(Filesystem.path(root, source))
      new = Path.expand(Filesystem.path(root, target))
      action = recovery_action(target, old, new)
      if action != :needs_attention, do: File.rm(marker)
      %{source: source, target: target, action: action}
    else
      _unreadable -> %{source: nil, target: nil, action: :needs_attention}
    end
  end

  # Workspace ids are unique across tenants, so the id says whether the rename committed;
  # the tenant the note names is for the operator and decides nothing.
  defp recovery_action(target, old, new) do
    case workspace_row(target) do
      {:ok, [_ | _]} ->
        :committed

      {:ok, []} ->
        cond do
          File.dir?(new) and not File.exists?(old) ->
            if File.rename(new, old) == :ok, do: :moved_back, else: :needs_attention

          File.dir?(old) and not File.exists?(new) ->
            :nothing_moved

          true ->
            :needs_attention
        end

      {:error, _} ->
        :needs_attention
    end
  end

  # A Store that does not answer in time exits the caller; the note waits for the next run.
  defp workspace_row(id) do
    Store.raw_query("SELECT 1 FROM workspaces WHERE id = ?1", [id])
  catch
    :exit, _timeout -> {:error, :store_unavailable}
  end

  defp rename_in(txn, workspace, tables, evidence_key, tenant, source, target, actor_id) do
    temporary_slug =
      "__renaming__" <>
        workspace.slug <> "__" <> Integer.to_string(System.unique_integer([:positive]))

    # The source gives up its slug and external id before the target takes
    # them, so neither unique index sees both rows at once.
    with {:ok, _} <-
           Store.txn_execute(
             txn,
             "UPDATE workspaces SET slug=?1, external_id=NULL WHERE id=?2",
             [temporary_slug, source]
           ),
         {:ok, _} <-
           Store.txn_execute(
             txn,
             "INSERT INTO workspaces(id,tenant_id,slug,name,description,status,organization_id,metadata,external_id) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9)",
             [
               target,
               tenant,
               workspace.slug,
               workspace.name,
               workspace.description,
               workspace.status,
               workspace.organization_id,
               workspace.metadata,
               workspace.external_id
             ]
           ),
         {:ok, results} <- rename_tables(txn, tables, source, target, tenant),
         # Every slug the workspace holds goes with it; deleting the old
         # record would otherwise delete them (workspace_handles cascades).
         {:ok, handles_moved} <-
           Store.txn_execute(
             txn,
             "UPDATE workspace_handles SET workspace_id=?1 WHERE workspace_id=?2",
             [target, source]
           ),
         {:ok, _} <- Store.txn_execute(txn, "DELETE FROM workspaces WHERE id=?1", [source]),
         # Signed rows keep the id they were written with; the move is
         # recorded so they can still be followed to the target.
         :ok <-
           WorkspaceRekeys.record(txn, evidence_key, tenant, source, target, actor_id, :rename) do
      {:ok,
       %{
         source_workspace_id: source,
         target_workspace_id: target,
         actor_id: actor_id,
         tables: results,
         handles_moved: handles_moved,
         rekey_recorded: not is_nil(evidence_key)
       }}
    end
  end

  @doc """
  Gives the nodes of the tenant's active workspaces the node type their kind
  names, where they have none or a type that is not an active one of their own
  workspace. Options: `:actor_id`, `:tenant_id` (both required). Only the
  tenant's nodes change. Returns `{:ok, updated_nodes}`.
  """
  def repair_node_types(opts) do
    actor_id = Keyword.fetch!(opts, :actor_id)
    tenant_id = Keyword.fetch!(opts, :tenant_id)

    Store.transaction(fn txn ->
      Store.txn_execute(
        txn,
        """
        UPDATE nodes
        SET node_type_id = (
              SELECT t.id FROM node_types t
              WHERE t.workspace_id=nodes.workspace_id AND t.tenant_id=?2
                AND t.slug=CASE nodes.kind WHEN 'org' THEN 'entity' WHEN 'unit' THEN 'department' ELSE nodes.kind END
                AND t.lifecycle_state='active' LIMIT 1
            ),
            updated_at = datetime('now'),
            metadata = json_set(COALESCE(metadata,'{}'), '$.hierarchy_repaired_by', ?1)
        WHERE tenant_id=?2 AND lifecycle_state='active'
          AND workspace_id IN (SELECT id FROM workspaces WHERE tenant_id=?2 AND status='active')
          AND EXISTS (
            SELECT 1 FROM node_types t
            WHERE t.workspace_id=nodes.workspace_id AND t.tenant_id=?2
              AND t.slug=CASE nodes.kind WHEN 'org' THEN 'entity' WHEN 'unit' THEN 'department' ELSE nodes.kind END
              AND t.lifecycle_state='active'
          )
          AND (node_type_id IS NULL OR NOT EXISTS (
            SELECT 1 FROM node_types current
            WHERE current.id=nodes.node_type_id AND current.workspace_id=nodes.workspace_id
              AND current.lifecycle_state='active'
          ))
        """,
        [actor_id, tenant_id]
      )
    end)
  end

  @doc """
  Repairs a tenant's workspace owners and node kinds as a mapping the caller
  supplies. Options: `:actor_id`, `:tenant_id`, `:mapping` (all required).
  See `OptimalEngine.DataSteward.HierarchyRepair` for the mapping.
  """
  defdelegate repair_deterministic_hierarchy(opts), to: HierarchyRepair, as: :run

  @doc false
  def relabel_bare_scope(_workspace_id, _opts), do: {:error, :not_implemented}

  def recheck(workspace_id, opts \\ []) do
    tenant_id = Keyword.get(opts, :tenant_id, "default")
    actor_id = Keyword.get(opts, :actor_id, "system:data-steward")

    scope =
      MemoryCore.ScopeEnvelope.resolve(%{
        tenant_id: tenant_id,
        workspace_id: workspace_id,
        actor_id: actor_id
      })

    with {:ok, projection} <- MemoryCore.AssociativeProjection.rebuild(scope),
         {:ok, dashboard} <- dashboard(workspace_id, tenant_id: tenant_id) do
      {:ok, %{projection: projection, dashboard: dashboard}}
    end
  end

  defp apply_explicit(ids, fun) do
    results = Enum.map(Enum.uniq(ids), fn id -> %{id: id, result: normalize_result(fun.(id))} end)
    {:ok, summarize(results)}
  end

  defp summarize(results) do
    accepted = Enum.count(results, &match?(%{result: %{ok: true}}, &1))

    %{
      requested: length(results),
      completed: accepted,
      failed: length(results) - accepted,
      results: results
    }
  end

  defp normalize_result({:ok, value}), do: %{ok: true, value: value}
  defp normalize_result({:error, reason}), do: %{ok: false, error: inspect(reason)}
  defp normalize_result(value), do: %{ok: true, value: value}

  defp item_id(%{"id" => id}), do: id
  defp item_id(%{id: id}), do: id
  defp item_id(_), do: nil
  defp item_target(%{"target_workspace_id" => target}), do: target
  defp item_target(%{target_workspace_id: target}), do: target
  defp item_target(_), do: nil

  defp fingerprint(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s]/u, " ")
    |> String.split()
    |> Enum.reject(&(String.length(&1) < 3))
    |> Enum.take(18)
    |> Enum.sort()
    |> Enum.join(" ")
  end

  # The key that signs the record of the repair, fetched before the
  # transaction opens (creating a key writes to the Store). Without one the
  # repair would leave the workspace's action steps unverifiable for good, so
  # it is refused when there are any; otherwise it goes ahead with a warning
  # and no record.
  defp recording_key(tenant, source_workspace_id) do
    case Evidence.signing_key(tenant) do
      nil ->
        case action_steps?(tenant, source_workspace_id) do
          {:ok, true} ->
            {:error, :evidence_key_unavailable}

          {:ok, false} ->
            Logger.warning(
              "[DataSteward] the repair of #{source_workspace_id} will not be recorded as evidence: the Engine cannot sign evidence"
            )

            {:ok, nil}

          {:error, _} = error ->
            error
        end

      key ->
        {:ok, key}
    end
  end

  # The workspace id the rows moved away from no longer holds them, and whatever the
  # filesystem cache holds under it can never be reached again, so it is removed. The
  # target workspace builds its own entries as its text is embedded.
  defp purge_vacated_cache({:ok, result}, source_workspace_id, reason) do
    purged = Cache.summary(Cache.purge_workspace(source_workspace_id, reason))
    {:ok, Map.put(result, :cache_purged, purged)}
  end

  defp purge_vacated_cache(other, _source_workspace_id, _reason), do: other

  # `{:ok, boolean}`, or the error: a question that cannot be answered is not
  # a "no".
  defp action_steps?(tenant, workspace_id) do
    Store.transaction(fn txn ->
      query = "SELECT 1 FROM authority_action_steps WHERE tenant_id = ?2 AND workspace_id = ?3"

      case any_row?(txn, [query], [nil, tenant, workspace_id], :action_steps) do
        :ok -> {:ok, false}
        {:error, :action_steps} -> {:ok, true}
        {:error, _} = error -> error
      end
    end)
  end

  # The source of a rename is a workspace of the caller's tenant; one of
  # another tenant is not found. Checked before anything is prepared, and read
  # again inside the transaction.
  defp source_registered(tenant, workspace_id) do
    case Store.raw_query("SELECT 1 FROM workspaces WHERE id=?1 AND tenant_id=?2", [
           workspace_id,
           tenant
         ]) do
      {:ok, [_]} -> :ok
      {:ok, []} -> {:error, :source_workspace_not_found}
      error -> error
    end
  end

  defp read_source(txn, tenant, workspace_id) do
    case Store.txn_query(
           txn,
           "SELECT slug,name,description,status,organization_id,metadata,external_id FROM workspaces WHERE id=?1 AND tenant_id=?2",
           [workspace_id, tenant]
         ) do
      {:ok, [[slug, name, description, status, organization_id, metadata, external_id]]} ->
        {:ok,
         %{
           slug: slug,
           name: name,
           description: description,
           status: status,
           organization_id: organization_id,
           metadata: metadata,
           external_id: external_id
         }}

      {:ok, []} ->
        {:error, :source_workspace_not_found}

      error ->
        error
    end
  end

  # The target is the tenant:slug of the source as it is now, and nobody's.
  # Its shape is checked first, so a refusal does not say whether a workspace
  # of that id exists.
  defp check_rename_target(txn, %{slug: slug}, tenant, target) do
    # The target is `<tenant>:<slug>`, and an id `Workspace.check_id/2` takes: a
    # workspace from before ids were checked may hold a slug that is not
    # one, and the id would name a directory that is not its own.
    with true <- target == tenant <> ":" <> slug || {:error, :target_must_match_tenant_and_slug},
         :ok <- Workspace.check_id(target, tenant) do
      case Store.txn_query(txn, "SELECT 1 FROM workspaces WHERE id=?1", [target]) do
        {:ok, []} -> :ok
        {:ok, _} -> {:error, :target_workspace_exists}
        error -> error
      end
    end
  end

  # A rename moves the tenant's rows only, so rows another tenant wrote under
  # the source id would be left under an id that no longer exists. That is a
  # row of a tenant-scoped table with another tenant's `tenant_id`, or a row of
  # a table with no tenant column that hangs off another tenant's rows
  # (`trace_sql/2`). A check that cannot be answered stops the rename.
  @doc false
  def check_id_not_shared(txn, tables, source, tenant) do
    scoped =
      for %{tenant_scoped?: true, name: name} <- tables,
          do: "SELECT 1 FROM \"#{name}\" WHERE workspace_id=?2 AND #{foreign_rows(name)}"

    foreign =
      for %{tenant_scoped?: false, name: name} <- tables,
          name in @traced_tables,
          do: "SELECT 1 FROM \"#{name}\" WHERE workspace_id=?2 AND (#{trace_sql(name, :foreign)})"

    any_row?(txn, scoped ++ foreign, [nil, source, tenant], :workspace_id_shared)
  end

  # The condition that a row of a table with a tenant column is another
  # tenant's.
  defp foreign_rows("entity_mentions"), do: mention_tenant("entity_mentions", :foreign)
  defp foreign_rows(_name), do: "tenant_id<>?3"

  # `:ok` when none of the queries finds a row, `{:error, reason}` when one
  # does, and the error itself when one fails.
  defp any_row?(txn, queries, params, reason) do
    Enum.reduce_while(queries, :ok, fn sql, :ok ->
      case Store.txn_query(txn, "SELECT EXISTS (#{sql})", params) do
        {:ok, [[0]]} -> {:cont, :ok}
        {:ok, [[1]]} -> {:halt, {:error, reason}}
        {:error, _} = error -> {:halt, error}
        other -> {:halt, {:error, {:unexpected_answer, other}}}
      end
    end)
  end

  # The target of a repair is an active workspace of the caller's tenant; one
  # of another tenant is not registered as far as the caller can tell.
  defp check_target(txn, tenant, workspace_id) do
    case Store.txn_query(txn, "SELECT tenant_id FROM workspaces WHERE id=?1 AND status='active'", [
           workspace_id
         ]) do
      {:ok, [[^tenant]]} -> :ok
      {:ok, _} -> {:error, :target_workspace_not_registered}
      error -> error
    end
  end

  # An orphan source has no workspace record. A record of another tenant, in
  # any state, or an active one of this tenant, is a registered workspace
  # whose rows are not to be taken; an archived workspace of this tenant is
  # still repaired from.
  defp check_orphan_source(txn, tenant, workspace_id) do
    case Store.txn_query(txn, "SELECT tenant_id, status FROM workspaces WHERE id=?1", [
           workspace_id
         ]) do
      {:ok, []} -> :ok
      {:ok, [[^tenant, "archived"]]} -> :ok
      {:ok, _} -> {:error, :source_workspace_is_registered}
      error -> error
    end
  end

  # The tenant's rows of each table, to the target. A table with a tenant
  # column is bound to it; one without is bound by the rows it points at.
  defp move_rows(txn, tables, source, target, tenant) do
    Enum.reduce_while(tables, {:ok, []}, fn table, {:ok, results} ->
      case Store.txn_execute(txn, move_sql(table), [target, source, tenant]) do
        {:ok, count} -> {:cont, {:ok, [%{table: table.name, updated: count} | results]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  # A mention records its tenant; one written before the column, and naming
  # nothing the migration could fill it from, has none and is traced to a
  # tenant through its context or source package, as it is read
  # (`OptimalEngine.EntityResolution`).
  defp move_sql(%{tenant_scoped?: true, name: "entity_mentions"}),
    do:
      "UPDATE entity_mentions SET workspace_id=?1 WHERE workspace_id=?2 AND #{mention_tenant("entity_mentions", :own)}"

  defp move_sql(%{tenant_scoped?: true, name: name}),
    do: "UPDATE \"#{name}\" SET workspace_id=?1 WHERE workspace_id=?2 AND tenant_id=?3"

  defp move_sql(%{name: name}),
    do:
      "UPDATE \"#{name}\" SET workspace_id=?1 WHERE workspace_id=?2 AND (#{trace_sql(name, :own)})"

  defp rows_moved(results), do: results |> Enum.map(& &1.updated) |> Enum.sum()

  # The condition that a row of `table` hangs off rows of the tenant (`?3`) in
  # the workspace being repaired (`?2`); with `:foreign`, off a row of any
  # other tenant, in any workspace.
  defp trace_sql("entity_aliases", side),
    do: parent("canonical_entities", "e", "entity_aliases.entity_id", side)

  defp trace_sql("entity_identifiers", side),
    do: parent("canonical_entities", "e", "entity_identifiers.entity_id", side)

  defp trace_sql("entity_lineage", side) do
    joiner = if side == :own, do: " AND ", else: " OR "

    "(" <>
      parent("canonical_entities", "p", "entity_lineage.predecessor_entity_id", side) <>
      joiner <> parent("canonical_entities", "s", "entity_lineage.successor_entity_id", side) <> ")"
  end

  defp trace_sql("resolution_decisions", side) do
    here = if side == :own, do: "m.workspace_id = ?2 AND ", else: ""

    "EXISTS (SELECT 1 FROM entity_mentions m WHERE m.id = resolution_decisions.mention_id AND #{here}#{mention_tenant("m", side)})"
  end

  defp trace_sql("memory_association_paths", side),
    do: parent("memory_reconstruction_runs", "r", "memory_association_paths.run_id", side)

  defp trace_sql("memory_reconstruction_outcomes", side),
    do: parent("memory_reconstruction_runs", "r", "memory_reconstruction_outcomes.run_id", side)

  defp trace_sql("memory_consolidation_proposals", side) do
    "EXISTS (SELECT 1 FROM json_each(CASE WHEN json_valid(memory_consolidation_proposals.metadata) THEN memory_consolidation_proposals.metadata ELSE '{}' END, '$.path_ids') j JOIN memory_association_paths a ON a.id = j.value WHERE #{parent("memory_reconstruction_runs", "r", "a.run_id", side)})"
  end

  # The condition that a mention is the tenant's (`:own`, in the workspace
  # being repaired) or another tenant's (`:foreign`): by the tenant it
  # records, else by the rows it hangs off.
  defp mention_tenant(mention, :own),
    do:
      "(#{mention}.tenant_id = ?3 OR (#{mention}.tenant_id IS NULL AND #{mention_parents(mention, :own)}))"

  defp mention_tenant(mention, :foreign),
    do:
      "(#{mention}.tenant_id <> ?3 OR (#{mention}.tenant_id IS NULL AND #{mention_parents(mention, :foreign)}))"

  # A mention hangs off its context or its source package.
  defp mention_parents(mention, side) do
    "(" <>
      parent("contexts", "c", "#{mention}.context_id", side) <>
      " OR " <> parent("source_packages", "s", "#{mention}.source_package_id", side) <> ")"
  end

  defp parent(table, alias_, column, side) do
    tenant =
      if side == :own,
        do: "#{alias_}.tenant_id = ?3 AND #{alias_}.workspace_id = ?2",
        else: "#{alias_}.tenant_id <> ?3"

    "EXISTS (SELECT 1 FROM #{table} #{alias_} WHERE #{alias_}.id = #{column} AND #{tenant})"
  end

  # Rows an orphan repair leaves because their table cannot be traced to a
  # tenant at all. Counted only after the caller's own rows moved, and of the
  # tables nothing points from, so it does not reveal what others hold.
  defp rows_left(txn, tables, workspace_id) do
    tables
    |> Enum.reduce_while({:ok, []}, fn table, {:ok, left} ->
      case Store.txn_query(
             txn,
             "SELECT COUNT(*) FROM \"#{table.name}\" WHERE workspace_id=?1",
             [workspace_id]
           ) do
        {:ok, [[rows]]} when rows > 0 -> {:cont, {:ok, [%{table: table.name, rows: rows} | left]}}
        {:ok, [[_none]]} -> {:cont, {:ok, left}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, left} -> {:ok, Enum.reverse(left)}
      error -> error
    end
  end

  # The tables an id repair re-keys: those with a workspace_id column that are
  # not left alone (@not_rekeyed), with whether they also have a tenant_id
  # column to bind the move to the caller's tenant.
  defp workspace_tables do
    with {:ok, rows} <-
           Store.raw_query(
             "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name",
             []
           ) do
      tables =
        rows
        |> List.flatten()
        |> Enum.filter(&safe_identifier?/1)
        |> Enum.reject(&(&1 in @not_rekeyed))
        |> Enum.flat_map(fn table ->
          case Store.raw_query("PRAGMA table_info(\"#{table}\")", []) do
            {:ok, columns} ->
              names = Enum.map(columns, &Enum.at(&1, 1))

              if "workspace_id" in names,
                do: [%{name: table, tenant_scoped?: "tenant_id" in names}],
                else: []

            _ ->
              []
          end
        end)

      {:ok, tables}
    end
  end

  defp safe_identifier?(value), do: is_binary(value) and Regex.match?(~r/^[a-zA-Z0-9_]+$/, value)

  # A rename gives the same workspace a new id. An id that already holds rows
  # is where some other data was written, and moving the workspace onto it
  # would make that data part of the workspace without saying so; merging it
  # in first (`repair_orphan_scope/3`) says so, and records it as a merge. A
  # check that cannot be answered stops the rename.
  @doc false
  def target_free_of_rows(txn, tables, target) do
    queries = for %{name: name} <- tables, do: "SELECT 1 FROM \"#{name}\" WHERE workspace_id=?1"
    any_row?(txn, queries, [target], :target_workspace_has_rows)
  end

  # The rows of a table with a tenant column that a rename takes: the
  # tenant's, and, of a mention, one that records none (written before the
  # column), which in a registered workspace is the workspace's tenant's.
  defp renamed_rows("entity_mentions"), do: "(tenant_id=?3 OR tenant_id IS NULL)"
  defp renamed_rows(_name), do: "tenant_id=?3"

  # A registered source belongs to one tenant, so a table without a tenant
  # column holds only that workspace's rows; a table with one is bound to the
  # tenant as well, so rows another tenant wrote under the id stay put.
  defp rename_tables(txn, tables, source, target, tenant) do
    Enum.reduce_while(tables, {:ok, []}, fn table, {:ok, results} ->
      {sql, params} =
        if table.tenant_scoped? do
          {"UPDATE \"#{table.name}\" SET workspace_id=?1 WHERE workspace_id=?2 AND #{renamed_rows(table.name)}",
           [target, source, tenant]}
        else
          {"UPDATE \"#{table.name}\" SET workspace_id=?1 WHERE workspace_id=?2", [target, source]}
        end

      case Store.txn_execute(txn, sql, params) do
        {:ok, count} -> {:cont, {:ok, [%{table: table.name, updated: count} | results]}}
        error -> {:halt, error}
      end
    end)
  end
end
