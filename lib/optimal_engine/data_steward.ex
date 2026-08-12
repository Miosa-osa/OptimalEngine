defmodule OptimalEngine.DataSteward do
  @moduledoc """
  Governed interface for inspecting and reducing live data-quality backlogs.

  Planning is read-only.
  Mutations require explicit item identifiers and never infer acceptance.
  """

  alias OptimalEngine.{
    ContextHealth,
    EntityQuality,
    HierarchyAudit,
    MemoryCore,
    ReviewQueue,
    Store
  }

  @default_limit 100

  def dashboard(workspace_id, opts \\ []) do
    tenant_id = Keyword.get(opts, :tenant_id, "default")

    with {:ok, entity_quality} <- EntityQuality.run(workspace_id),
         {:ok, orphan_scopes} <- orphan_scopes(),
         {:ok, claims} <- claim_clusters(workspace_id, tenant_id, @default_limit),
         {:ok, routes} <- route_clusters(@default_limit),
         {:ok, entities} <- entity_clusters(workspace_id, @default_limit),
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

  def entity_clusters(workspace_id, limit \\ @default_limit) do
    with {:ok, rows} <-
           Store.raw_query(
             """
             SELECT id, surface_text, normalized_text, proposed_kind, confidence, context_id
             FROM entity_mentions
             WHERE workspace_id=?1 AND resolution_state IN ('unresolved','ambiguous')
             ORDER BY normalized_text, confidence DESC LIMIT ?2
             """,
             [workspace_id, limit]
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

  def orphan_scopes do
    with {:ok, rows} <-
           Store.raw_query(
             """
             SELECT owned.workspace_id, owned.record_count
             FROM (
               SELECT workspace_id, COUNT(*) record_count FROM (
                 SELECT workspace_id FROM contexts WHERE archived_at IS NULL
                 UNION ALL SELECT workspace_id FROM memories WHERE is_latest=1 AND is_forgotten=0
                 UNION ALL SELECT workspace_id FROM claims
               ) GROUP BY workspace_id
             ) owned
             LEFT JOIN workspaces registered ON registered.id=owned.workspace_id
             WHERE registered.id IS NULL
             ORDER BY owned.record_count DESC
             """,
             []
           ) do
      {:ok,
       Enum.map(rows, fn [workspace_id, count] ->
         %{workspace_id: workspace_id, records: count}
       end)}
    end
  end

  def repair_orphan_scope(source_workspace_id, target_workspace_id, opts) do
    actor_id = Keyword.fetch!(opts, :actor_id)

    with {:ok, [_]} <- registered_workspace(target_workspace_id),
         {:ok, []} <- registered_workspace(source_workspace_id),
         {:ok, tables} <- workspace_tables() do
      Store.transaction(fn txn ->
        outcome =
          Enum.reduce_while(tables, {:ok, []}, fn table, {:ok, results} ->
            case Store.txn_execute(
                   txn,
                   "UPDATE \"#{table}\" SET workspace_id=?1 WHERE workspace_id=?2",
                   [target_workspace_id, source_workspace_id]
                 ) do
              {:ok, count} -> {:cont, {:ok, [%{table: table, updated: count} | results]}}
              {:error, _} = error -> {:halt, error}
            end
          end)

        case outcome do
          {:ok, results} ->
            {:ok,
             %{
               source_workspace_id: source_workspace_id,
               target_workspace_id: target_workspace_id,
               actor_id: actor_id,
               updated_records: Enum.sum(Enum.map(results, & &1.updated)),
               tables: Enum.filter(results, &(&1.updated > 0))
             }}

          error ->
            error
        end
      end)
    else
      {:ok, [_ | _]} -> {:error, :source_workspace_is_registered}
      {:ok, []} -> {:error, :target_workspace_not_registered}
      error -> error
    end
  end

  def rename_workspace(source_workspace_id, target_workspace_id, opts) do
    actor_id = Keyword.fetch!(opts, :actor_id)

    with {:ok, [[tenant, slug, name, description, status, organization_id, metadata]]} <-
           Store.raw_query(
             "SELECT tenant_id,slug,name,description,status,organization_id,metadata FROM workspaces WHERE id=?1",
             [source_workspace_id]
           ),
         {:ok, []} <-
           Store.raw_query("SELECT id FROM workspaces WHERE id=?1", [target_workspace_id]),
         true <- target_workspace_id == tenant <> ":" <> slug,
         {:ok, tables} <- workspace_tables() do
      Store.transaction(fn txn ->
        temporary_slug =
          "__renaming__" <> slug <> "__" <> Integer.to_string(System.unique_integer([:positive]))

        with {:ok, _} <-
               Store.txn_execute(txn, "UPDATE workspaces SET slug=?1 WHERE id=?2", [
                 temporary_slug,
                 source_workspace_id
               ]),
             {:ok, _} <-
               Store.txn_execute(
                 txn,
                 "INSERT INTO workspaces(id,tenant_id,slug,name,description,status,organization_id,metadata) VALUES (?1,?2,?3,?4,?5,?6,?7,?8)",
                 [
                   target_workspace_id,
                   tenant,
                   slug,
                   name,
                   description,
                   status,
                   organization_id,
                   metadata
                 ]
               ),
             {:ok, results} <-
               rename_tables(txn, tables, source_workspace_id, target_workspace_id),
             {:ok, _} <-
               Store.txn_execute(txn, "DELETE FROM workspaces WHERE id=?1", [source_workspace_id]) do
          {:ok,
           %{
             source_workspace_id: source_workspace_id,
             target_workspace_id: target_workspace_id,
             actor_id: actor_id,
             tables: results
           }}
        end
      end)
    else
      false -> {:error, :target_must_match_tenant_and_slug}
      {:ok, [_ | _]} -> {:error, :target_workspace_exists}
      {:ok, []} -> {:error, :source_workspace_not_found}
      error -> error
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

  defp registered_workspace(workspace_id) do
    Store.raw_query("SELECT id FROM workspaces WHERE id=?1 AND status='active'", [workspace_id])
  end

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
        |> Enum.filter(fn table ->
          case Store.raw_query("PRAGMA table_info(\"#{table}\")", []) do
            {:ok, columns} ->
              Enum.any?(columns, fn column -> Enum.at(column, 1) == "workspace_id" end)

            _ ->
              false
          end
        end)
        |> Enum.reject(&(&1 == "workspaces"))

      {:ok, tables}
    end
  end

  defp safe_identifier?(value), do: is_binary(value) and Regex.match?(~r/^[a-zA-Z0-9_]+$/, value)

  defp rename_tables(txn, tables, source, target) do
    Enum.reduce_while(tables, {:ok, []}, fn table, {:ok, results} ->
      case Store.txn_execute(
             txn,
             "UPDATE \"#{table}\" SET workspace_id=?1 WHERE workspace_id=?2",
             [
               target,
               source
             ]
           ) do
        {:ok, count} -> {:cont, {:ok, [%{table: table, updated: count} | results]}}
        error -> {:halt, error}
      end
    end)
  end
end
