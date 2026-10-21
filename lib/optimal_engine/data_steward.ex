defmodule OptimalEngine.DataSteward do
  @moduledoc """
  Governed interface for inspecting and reducing live data-quality backlogs.

  Planning is read-only.
  Mutations require explicit item identifiers and never infer acceptance.
  """

  alias OptimalEngine.Authority.{Evidence, WorkspaceRekeys}

  alias OptimalEngine.{
    ContextHealth,
    EntityQuality,
    EntityResolution,
    HierarchyAudit,
    MemoryCore,
    ReviewQueue,
    Store
  }

  require Logger

  @default_limit 100

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
  # whose parent is another table of the list comes before it (a decision
  # before its mention, a proposal before its paths), because the trace looks
  # at where the parent still is.
  @traced_tables ~w(resolution_decisions memory_consolidation_proposals entity_aliases
                    entity_identifiers entity_lineage entity_mentions memory_association_paths
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

  def dashboard(workspace_id, opts \\ []) do
    tenant_id = Keyword.get(opts, :tenant_id, "default")

    with {:ok, entity_quality} <- EntityQuality.run(workspace_id),
         {:ok, orphan_scopes} <- orphan_scopes(tenant_id),
         {:ok, claims} <- claim_clusters(workspace_id, tenant_id, @default_limit),
         {:ok, routes} <- route_clusters(@default_limit),
         {:ok, entities} <- entity_clusters(workspace_id, tenant_id, @default_limit),
         {:ok, hierarchy} <- HierarchyAudit.run(tenant_id) do
      {:ok,
       %{
         workspace_id: workspace_id,
         tenant_id: tenant_id,
         context_health: ContextHealth.run(workspace_id: workspace_id),
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
             ORDER BY created_at DESC LIMIT ?3
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

  def route_clusters(limit \\ @default_limit) do
    with {:ok, rows} <-
           Store.raw_query(
             """
             SELECT id, title, json_extract(metadata, '$.routing_review.state'),
                    json_extract(metadata, '$.routing_review.proposed_workspace_id')
             FROM contexts
             WHERE workspace_id='default:knowledge-intake' AND archived_at IS NULL
               AND json_extract(metadata, '$.routing_review.state') IN ('review','unresolved')
             ORDER BY modified_at DESC LIMIT ?1
             """,
             [limit]
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
             ORDER BY normalized_text, confidence DESC LIMIT ?1
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

  def decide_routes(items, decision, opts)
      when is_list(items) and items != [] and decision in [:accept, :reject] do
    actor_id = Keyword.fetch!(opts, :actor_id)

    results =
      Enum.map(items, fn item ->
        id = item_id(item)
        target = item_target(item)

        result =
          if decision == :accept and is_nil(target),
            do: {:error, :target_workspace_required},
            else: ReviewQueue.decide_route(id, decision, target, actor_id: actor_id)

        %{id: id, target_workspace_id: target, result: normalize_result(result)}
      end)

    {:ok, summarize(results)}
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
             ORDER BY owned.record_count DESC
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
  bound to it. A table without one cannot be told apart by tenant for an id
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
      untraced = Enum.reject(unscoped, &(&1.name in @traced_tables))
      traced = for name <- @traced_tables, table <- unscoped, table.name == name, do: table

      Store.transaction(fn txn ->
        with :ok <- check_target(txn, tenant, target_workspace_id),
             :ok <- check_orphan_source(txn, tenant, source_workspace_id),
             {:ok, moved_traced} <-
               move_rows(txn, traced, source_workspace_id, target_workspace_id, tenant),
             {:ok, moved_scoped} <-
               move_rows(txn, scoped, source_workspace_id, target_workspace_id, tenant),
             # A repair is only a repair if rows of the tenant itself moved; rows
             # that merely hang off them do not make one.
             :ok <- if(rows_moved(moved_scoped) > 0, do: :ok, else: {:error, :nothing_to_repair}),
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
          moved = moved_traced ++ moved_scoped

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
  """
  def rename_workspace(source_workspace_id, target_workspace_id, opts) do
    actor_id = Keyword.fetch!(opts, :actor_id)
    tenant = Keyword.fetch!(opts, :tenant_id)

    with :ok <- source_registered(tenant, source_workspace_id),
         {:ok, tables} <- workspace_tables(),
         {:ok, evidence_key} <- recording_key(tenant, source_workspace_id) do
      Store.transaction(fn txn ->
        with {:ok, workspace} <- read_source(txn, tenant, source_workspace_id),
             :ok <- check_rename_target(txn, workspace, tenant, target_workspace_id),
             :ok <- target_free_of_rows(txn, tables, target_workspace_id),
             :ok <- check_id_not_shared(txn, tables, source_workspace_id, tenant) do
          rename_in(
            txn,
            workspace,
            tables,
            evidence_key,
            tenant,
            source_workspace_id,
            target_workspace_id,
            actor_id
          )
        end
      end)
    end
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

  def repair_node_types(opts) do
    actor_id = Keyword.fetch!(opts, :actor_id)

    with {:ok, _workspaces} <-
           Store.raw_query("SELECT id,tenant_id FROM workspaces WHERE status='active'", []) do
      Store.raw_query(
        """
        UPDATE nodes
        SET node_type_id = (
              SELECT t.id FROM node_types t
              WHERE t.workspace_id=nodes.workspace_id
                AND t.slug=CASE nodes.kind WHEN 'org' THEN 'entity' WHEN 'unit' THEN 'department' ELSE nodes.kind END
                AND t.lifecycle_state='active' LIMIT 1
            ),
            updated_at = datetime('now'),
            metadata = json_set(COALESCE(metadata,'{}'), '$.hierarchy_repaired_by', ?1)
        WHERE lifecycle_state='active'
          AND workspace_id IN (SELECT id FROM workspaces WHERE status='active')
          AND EXISTS (
            SELECT 1 FROM node_types t
            WHERE t.workspace_id=nodes.workspace_id
              AND t.slug=CASE nodes.kind WHEN 'org' THEN 'entity' WHEN 'unit' THEN 'department' ELSE nodes.kind END
              AND t.lifecycle_state='active'
          )
          AND (node_type_id IS NULL OR NOT EXISTS (
            SELECT 1 FROM node_types current
            WHERE current.id=nodes.node_type_id AND current.workspace_id=nodes.workspace_id
              AND current.lifecycle_state='active'
          ))
        """,
        [actor_id]
      )
    end
  end

  def repair_deterministic_hierarchy(opts) do
    actor_id = Keyword.fetch!(opts, :actor_id)

    Store.transaction(fn txn ->
      with {:ok, owner_count} <-
             Store.txn_execute(
               txn,
               "UPDATE workspaces SET organization_id='miosa', metadata=json_set(COALESCE(metadata,'{}'),'$.hierarchy_repaired_by',?1) WHERE status='active' AND organization_id='default' AND (name LIKE '%BusinessOS%' OR description LIKE '%BusinessOS%')",
               [actor_id]
             ),
           {:ok, node_count} <-
             Store.txn_execute(
               txn,
               """
               UPDATE nodes
               SET kind=CASE
                     WHEN slug='18-clients' THEN 'customer'
                     WHEN slug='17-team' THEN 'team'
                     WHEN slug='11-tasks' THEN 'operation'
                     WHEN slug='12-projects' THEN 'project'
                   END,
                   node_type_id=workspace_id || ':' || CASE
                     WHEN slug='18-clients' THEN 'customer'
                     WHEN slug='17-team' THEN 'team'
                     WHEN slug='11-tasks' THEN 'operation'
                     WHEN slug='12-projects' THEN 'project'
                   END,
                   updated_at=datetime('now'),
                   metadata=json_set(COALESCE(metadata,'{}'),'$.hierarchy_repaired_by',?1)
               WHERE workspace_id='default:businessos' AND kind='workspace'
                 AND slug IN ('18-clients','17-team','11-tasks','12-projects')
               """,
               [actor_id]
             ) do
        {:ok,
         %{workspace_owners_updated: owner_count, nodes_retyped: node_count, actor_id: actor_id}}
      end
    end)
  end

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
    if target == tenant <> ":" <> slug do
      case Store.txn_query(txn, "SELECT 1 FROM workspaces WHERE id=?1", [target]) do
        {:ok, []} -> :ok
        {:ok, _} -> {:error, :target_workspace_exists}
        error -> error
      end
    else
      {:error, :target_must_match_tenant_and_slug}
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
          do: "SELECT 1 FROM \"#{name}\" WHERE workspace_id=?2 AND tenant_id<>?3"

    foreign =
      for %{tenant_scoped?: false, name: name} <- tables,
          name in @traced_tables,
          do: "SELECT 1 FROM \"#{name}\" WHERE workspace_id=?2 AND (#{trace_sql(name, :foreign)})"

    any_row?(txn, scoped ++ foreign, [nil, source, tenant], :workspace_id_shared)
  end

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

  defp trace_sql("entity_mentions", side), do: mention_parents("entity_mentions", side)

  defp trace_sql("resolution_decisions", side) do
    here = if side == :own, do: "m.workspace_id = ?2 AND ", else: ""

    "EXISTS (SELECT 1 FROM entity_mentions m WHERE m.id = resolution_decisions.mention_id AND #{here}#{mention_parents("m", side)})"
  end

  defp trace_sql("memory_association_paths", side),
    do: parent("memory_reconstruction_runs", "r", "memory_association_paths.run_id", side)

  defp trace_sql("memory_reconstruction_outcomes", side),
    do: parent("memory_reconstruction_runs", "r", "memory_reconstruction_outcomes.run_id", side)

  defp trace_sql("memory_consolidation_proposals", side) do
    "EXISTS (SELECT 1 FROM json_each(CASE WHEN json_valid(memory_consolidation_proposals.metadata) THEN memory_consolidation_proposals.metadata ELSE '{}' END, '$.path_ids') j JOIN memory_association_paths a ON a.id = j.value WHERE #{parent("memory_reconstruction_runs", "r", "a.run_id", side)})"
  end

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

  # A registered source belongs to one tenant, so a table without a tenant
  # column holds only that workspace's rows; a table with one is bound to the
  # tenant as well, so rows another tenant wrote under the id stay put.
  defp rename_tables(txn, tables, source, target, tenant) do
    Enum.reduce_while(tables, {:ok, []}, fn table, {:ok, results} ->
      {sql, params} =
        if table.tenant_scoped? do
          {"UPDATE \"#{table.name}\" SET workspace_id=?1 WHERE workspace_id=?2 AND tenant_id=?3",
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
