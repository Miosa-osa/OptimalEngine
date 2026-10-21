defmodule OptimalEngine.EntityResolution do
  @moduledoc """
  Creates immutable mentions and records explicit, auditable identity decisions.

  A mention records the tenant that wrote it (`tenant_id`), and a decision is
  made by that tenant (`decide/3`); a mention may only point at a context or
  source package of the writing tenant in its own workspace (`resolve/2`).

  A mention written before the column has no tenant. It belongs to the tenant
  of the context or source package it was found in, and one that points at
  neither belongs to its workspace.
  """

  alias OptimalEngine.{DataContract, EntityRegistry, Store}

  # A mention is the tenant's (`?3`) when it records that tenant. One that
  # records none (written before the column, and naming nothing the migration
  # could fill it from) is the tenant's when it hangs off a context or source
  # package of the tenant in the mention's workspace (`?2`), or off none. It
  # hangs off none when both ids are null or empty (an earlier version stored
  # an empty id), or name rows that no longer exist: such a mention could not
  # be decided by anyone otherwise.
  @owned_mention """
  (entity_mentions.tenant_id = ?3
   OR (entity_mentions.tenant_id IS NULL
    AND (((NULLIF(entity_mentions.context_id, '') IS NULL
       OR NOT EXISTS (SELECT 1 FROM contexts c WHERE c.id = entity_mentions.context_id))
      AND (NULLIF(entity_mentions.source_package_id, '') IS NULL
       OR NOT EXISTS (SELECT 1 FROM source_packages s WHERE s.id = entity_mentions.source_package_id)))
     OR EXISTS (SELECT 1 FROM contexts c WHERE c.id = entity_mentions.context_id AND c.tenant_id = ?3 AND c.workspace_id = ?2)
     OR EXISTS (SELECT 1 FROM source_packages s WHERE s.id = entity_mentions.source_package_id AND s.tenant_id = ?3 AND s.workspace_id = ?2))))
  """

  @doc false
  # The condition that a row of `entity_mentions` (unaliased) is the tenant's
  # (`?3`), for the queries that list mentions in workspace `?2`: they also
  # bind the row's workspace themselves.
  def owned_mention_sql, do: @owned_mention

  @doc """
  Records a mention. Options: `:tenant_id` (default `"default"`): the
  `context_id` and `source_package_id` a mention names must be that tenant's,
  in the mention's workspace (`{:error, :context_not_found}`,
  `{:error, :source_package_not_found}`).
  """
  def resolve(attrs, opts \\ []) when is_map(attrs) do
    workspace = value(attrs, :workspace_id)
    surface = value(attrs, :surface_text)
    normalized = EntityRegistry.normalize(surface || "")
    tenant = Keyword.get(opts, :tenant_id, "default")

    with {:ok, _contract} <- DataContract.validate(:mention, attrs),
         :ok <- required(workspace, :workspace_id),
         :ok <- required(surface, :surface_text),
         :ok <-
           parent(tenant, workspace, "contexts", value(attrs, :context_id), :context_not_found),
         :ok <-
           parent(
             tenant,
             workspace,
             "source_packages",
             value(attrs, :source_package_id),
             :source_package_not_found
           ),
         {:ok, candidates} <-
           candidates(tenant, workspace, normalized, value(attrs, :proposed_kind)),
         {:ok, mention} <- persist_mention(attrs, tenant, normalized, candidates) do
      {:ok, Map.put(mention, :candidates, candidates)}
    end
  end

  @doc """
  Decides a mention. Options include `:tenant_id` (default `"default"`): a
  mention of another tenant is not found.
  """
  def decide(mention_id, decision, opts) when decision in [:link, :new_entity, :reject] do
    workspace = Keyword.fetch!(opts, :workspace_id)
    actor = Keyword.fetch!(opts, :actor_id)
    tenant = Keyword.get(opts, :tenant_id, "default")

    with {:ok, opts} <- prepare_entity(mention_id, decision, workspace, actor, tenant, opts) do
      Store.transaction(fn tx ->
        with {:ok, [[surface, proposed_kind, state]]} <-
               Store.txn_query(
                 tx,
                 "SELECT surface_text, proposed_kind, resolution_state FROM entity_mentions WHERE id=?1 AND workspace_id=?2 AND #{@owned_mention}",
                 [mention_id, workspace, tenant]
               ),
             :ok <- ensure_unresolved(state),
             :ok <- link_target(tx, decision, Keyword.get(opts, :entity_id), tenant, workspace),
             {:ok, selected_id, next_state} <-
               selected_entity(decision, surface, proposed_kind, workspace, actor, opts),
             {:ok, 1} <-
               Store.txn_execute(
                 tx,
                 "UPDATE entity_mentions SET resolution_state=?1, resolved_entity_id=?2, confidence=?3, updated_at=datetime('now') WHERE id=?4 AND workspace_id=?5 AND resolution_state IN ('unresolved','ambiguous')",
                 [
                   next_state,
                   selected_id,
                   Keyword.get(opts, :confidence, 1.0),
                   mention_id,
                   workspace
                 ]
               ),
             {:ok, 1} <-
               Store.txn_execute(
                 tx,
                 "INSERT INTO resolution_decisions (id, workspace_id, mention_id, candidate_entity_ids, candidate_scores, decision, selected_entity_id, actor_id, policy_version, reason) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
                 [
                   id("res"),
                   workspace,
                   mention_id,
                   Jason.encode!(Keyword.get(opts, :candidate_entity_ids, [])),
                   Jason.encode!(Keyword.get(opts, :candidate_scores, %{})),
                   Atom.to_string(decision),
                   selected_id,
                   actor,
                   Keyword.get(opts, :policy_version, "entity-resolution-v1"),
                   Keyword.get(opts, :reason)
                 ]
               ) do
          {:ok, %{mention_id: mention_id, decision: decision, entity_id: selected_id}}
        else
          {:ok, []} -> {:error, :mention_not_found}
          error -> error
        end
      end)
    end
  end

  @doc """
  The mentions awaiting a decision in a workspace. Options: `:limit`,
  `:tenant_id` (default `"default"`): only that tenant's mentions are listed.
  """
  def queue(workspace_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    tenant = Keyword.get(opts, :tenant_id, "default")

    with {:ok, rows} <-
           Store.raw_query(
             "SELECT id, surface_text, proposed_kind, resolution_state, confidence, source_package_id, context_id, created_at FROM entity_mentions WHERE workspace_id=?2 AND resolution_state IN ('unresolved','ambiguous') AND #{@owned_mention} ORDER BY created_at LIMIT ?1",
             [limit, workspace_id, tenant]
           ) do
      {:ok,
       Enum.map(rows, fn [id, surface, kind, state, confidence, source_id, context_id, created_at] ->
         %{
           id: id,
           surface_text: surface,
           proposed_kind: kind,
           resolution_state: state,
           confidence: confidence,
           source_package_id: source_id,
           context_id: context_id,
           created_at: created_at
         }
       end)}
    end
  end

  defp candidates(tenant, workspace, normalized, kind) do
    kind_clause = if kind in [nil, ""], do: "", else: "AND e.entity_kind = ?4"

    params =
      if kind in [nil, ""],
        do: [workspace, normalized, tenant],
        else: [workspace, normalized, tenant, kind]

    with {:ok, rows} <-
           Store.raw_query(
             """
             SELECT DISTINCT e.id, e.canonical_name, e.entity_kind,
               CASE WHEN e.normalized_name = ?2 THEN 1.0 ELSE MAX(a.confidence) END AS score
             FROM canonical_entities e
             LEFT JOIN entity_aliases a ON a.entity_id=e.id AND a.workspace_id=e.workspace_id AND a.lifecycle_state='active'
             WHERE e.workspace_id=?1 AND e.tenant_id=?3 AND e.lifecycle_state='active'
               AND (e.normalized_name=?2 OR a.normalized_alias=?2) #{kind_clause}
             GROUP BY e.id, e.canonical_name, e.entity_kind, e.normalized_name
             ORDER BY score DESC
             """,
             params
           ) do
      {:ok,
       Enum.map(rows, fn [id, name, entity_kind, score] ->
         %{id: id, canonical_name: name, entity_kind: entity_kind, score: score}
       end)}
    end
  end

  defp persist_mention(attrs, tenant, normalized, candidates) do
    id = value(attrs, :id) || id("mention")
    state = if length(candidates) > 1, do: "ambiguous", else: "unresolved"

    case Store.raw_execute(
           "INSERT INTO entity_mentions (id, workspace_id, source_package_id, context_id, surface_text, normalized_text, proposed_kind, source_span, extraction_run_id, resolution_state, confidence, metadata, tenant_id) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)",
           [
             id,
             value(attrs, :workspace_id),
             present(value(attrs, :source_package_id)),
             present(value(attrs, :context_id)),
             value(attrs, :surface_text),
             normalized,
             value(attrs, :proposed_kind),
             Jason.encode!(value(attrs, :source_span) || %{}),
             value(attrs, :extraction_run_id),
             state,
             value(attrs, :confidence) || 0.5,
             Jason.encode!(value(attrs, :metadata) || %{}),
             tenant
           ]
         ) do
      :ok -> {:ok, %{id: id, resolution_state: state, surface_text: value(attrs, :surface_text)}}
      error -> error
    end
  end

  defp selected_entity(:link, _surface, _kind, _workspace, _actor, opts) do
    case Keyword.get(opts, :entity_id) do
      nil -> {:error, :entity_id_required}
      id -> {:ok, id, "linked"}
    end
  end

  defp selected_entity(:new_entity, _surface, _kind, _workspace, _actor, opts),
    do: {:ok, Keyword.fetch!(opts, :entity_id), "new_entity"}

  defp selected_entity(:reject, _surface, _kind, _workspace, _actor, _opts),
    do: {:ok, nil, "rejected"}

  defp prepare_entity(_mention_id, decision, _workspace, _actor, _tenant, opts)
       when decision != :new_entity,
       do: {:ok, opts}

  defp prepare_entity(mention_id, :new_entity, workspace, actor, tenant, opts) do
    with {:ok, [[surface, kind, state]]} <-
           Store.raw_query(
             "SELECT surface_text, proposed_kind, resolution_state FROM entity_mentions WHERE id=?1 AND workspace_id=?2 AND #{@owned_mention}",
             [mention_id, workspace, tenant]
           ),
         :ok <- ensure_unresolved(state),
         {:ok, entity} <-
           EntityRegistry.register(%{
             tenant_id: tenant,
             workspace_id: workspace,
             canonical_name: surface,
             entity_kind: kind || "person",
             created_by: actor,
             metadata: %{resolution_reason: Keyword.get(opts, :reason)}
           }) do
      {:ok, Keyword.put(opts, :entity_id, entity.id)}
    else
      {:ok, []} -> {:error, :mention_not_found}
      error -> error
    end
  end

  # The row a mention names must be the tenant's, in the mention's workspace.
  defp parent(_tenant, _workspace, _table, value, _reason) when value in [nil, ""], do: :ok

  defp parent(tenant, workspace, table, id, reason) do
    case Store.raw_query(
           "SELECT 1 FROM #{table} WHERE id=?1 AND tenant_id=?2 AND workspace_id=?3",
           [id, tenant, workspace]
         ) do
      {:ok, [_]} -> :ok
      {:ok, []} -> {:error, reason}
      error -> error
    end
  end

  # A mention is linked to an entity of its own tenant and workspace. No id is
  # `selected_entity/6`'s to refuse; an id that is not text names no entity,
  # and must not skip the check (SQLite would compare a number as its text).
  defp link_target(_tx, :link, nil, _tenant, _workspace), do: :ok

  defp link_target(tx, :link, entity_id, tenant, workspace) when is_binary(entity_id) do
    case Store.txn_query(
           tx,
           "SELECT 1 FROM canonical_entities WHERE id=?1 AND tenant_id=?2 AND workspace_id=?3",
           [entity_id, tenant, workspace]
         ) do
      {:ok, [_]} -> :ok
      {:ok, []} -> {:error, :entity_not_found}
      error -> error
    end
  end

  defp link_target(_tx, :link, _not_text, _tenant, _workspace), do: {:error, :entity_not_found}
  defp link_target(_tx, _decision, _entity_id, _tenant, _workspace), do: :ok

  # An empty id names nothing; it is stored as none.
  defp present(""), do: nil
  defp present(value), do: value

  defp ensure_unresolved(state) when state in ["unresolved", "ambiguous"], do: :ok
  defp ensure_unresolved(state), do: {:error, {:already_decided, state}}
  defp required(value, field) when value in [nil, ""], do: {:error, {:required, field}}
  defp required(_, _), do: :ok
  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp id(prefix),
    do: "#{prefix}_" <> (:crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower))
end
