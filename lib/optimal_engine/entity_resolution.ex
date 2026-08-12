defmodule OptimalEngine.EntityResolution do
  @moduledoc "Creates immutable mentions and records explicit, auditable identity decisions."

  alias OptimalEngine.{DataContract, EntityRegistry, Store}

  def resolve(attrs) when is_map(attrs) do
    workspace = value(attrs, :workspace_id)
    surface = value(attrs, :surface_text)
    normalized = EntityRegistry.normalize(surface || "")

    with {:ok, _contract} <- DataContract.validate(:mention, attrs),
         :ok <- required(workspace, :workspace_id),
         :ok <- required(surface, :surface_text),
         {:ok, candidates} <- candidates(workspace, normalized, value(attrs, :proposed_kind)),
         {:ok, mention} <- persist_mention(attrs, normalized, candidates) do
      {:ok, Map.put(mention, :candidates, candidates)}
    end
  end

  def decide(mention_id, decision, opts) when decision in [:link, :new_entity, :reject] do
    workspace = Keyword.fetch!(opts, :workspace_id)
    actor = Keyword.fetch!(opts, :actor_id)

    with {:ok, opts} <- prepare_entity(mention_id, decision, workspace, actor, opts) do
      Store.transaction(fn tx ->
        with {:ok, [[surface, proposed_kind, state]]} <-
               Store.txn_query(
                 tx,
                 "SELECT surface_text, proposed_kind, resolution_state FROM entity_mentions WHERE id=?1 AND workspace_id=?2",
                 [mention_id, workspace]
               ),
             :ok <- ensure_unresolved(state),
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

  def queue(workspace_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    with {:ok, rows} <-
           Store.raw_query(
             "SELECT id, surface_text, proposed_kind, resolution_state, confidence, source_package_id, context_id, created_at FROM entity_mentions WHERE workspace_id=?1 AND resolution_state IN ('unresolved','ambiguous') ORDER BY created_at LIMIT ?2",
             [workspace_id, limit]
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

  defp candidates(workspace, normalized, kind) do
    kind_clause = if kind in [nil, ""], do: "", else: "AND e.entity_kind = ?3"
    params = if kind in [nil, ""], do: [workspace, normalized], else: [workspace, normalized, kind]

    with {:ok, rows} <-
           Store.raw_query(
             """
             SELECT DISTINCT e.id, e.canonical_name, e.entity_kind,
               CASE WHEN e.normalized_name = ?2 THEN 1.0 ELSE MAX(a.confidence) END AS score
             FROM canonical_entities e
             LEFT JOIN entity_aliases a ON a.entity_id=e.id AND a.workspace_id=e.workspace_id AND a.lifecycle_state='active'
             WHERE e.workspace_id=?1 AND e.lifecycle_state='active'
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

  defp persist_mention(attrs, normalized, candidates) do
    id = value(attrs, :id) || id("mention")
    state = if length(candidates) > 1, do: "ambiguous", else: "unresolved"

    case Store.raw_execute(
           "INSERT INTO entity_mentions (id, workspace_id, source_package_id, context_id, surface_text, normalized_text, proposed_kind, source_span, extraction_run_id, resolution_state, confidence, metadata) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)",
           [
             id,
             value(attrs, :workspace_id),
             value(attrs, :source_package_id),
             value(attrs, :context_id),
             value(attrs, :surface_text),
             normalized,
             value(attrs, :proposed_kind),
             Jason.encode!(value(attrs, :source_span) || %{}),
             value(attrs, :extraction_run_id),
             state,
             value(attrs, :confidence) || 0.5,
             Jason.encode!(value(attrs, :metadata) || %{})
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

  defp prepare_entity(_mention_id, decision, _workspace, _actor, opts)
       when decision != :new_entity,
       do: {:ok, opts}

  defp prepare_entity(mention_id, :new_entity, workspace, actor, opts) do
    with {:ok, [[surface, kind, state]]} <-
           Store.raw_query(
             "SELECT surface_text, proposed_kind, resolution_state FROM entity_mentions WHERE id=?1 AND workspace_id=?2",
             [mention_id, workspace]
           ),
         :ok <- ensure_unresolved(state),
         {:ok, entity} <-
           EntityRegistry.register(%{
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

  defp ensure_unresolved(state) when state in ["unresolved", "ambiguous"], do: :ok
  defp ensure_unresolved(state), do: {:error, {:already_decided, state}}
  defp required(value, field) when value in [nil, ""], do: {:error, {:required, field}}
  defp required(_, _), do: :ok
  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp id(prefix),
    do: "#{prefix}_" <> (:crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower))
end
