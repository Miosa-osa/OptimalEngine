defmodule OptimalEngine.RelationshipRegistry do
  @moduledoc "Validates and records governed, temporal relationships between canonical entities."

  alias OptimalEngine.{DataContract, Store}

  @doc """
  Records a relationship between two entities of a workspace. Options:
  `:tenant_id` (default `"default"`): both entities have to be that tenant's
  (another tenant's, in a workspace id they share, is `{:error, :not_found}`),
  and the edge is recorded under it.
  """
  def relate(attrs, opts \\ []) when is_map(attrs) do
    tenant = Keyword.get(opts, :tenant_id, "default")

    with {:ok, %{attrs: attrs}} <- DataContract.validate(:relationship, attrs),
         workspace = value(attrs, :workspace_id),
         {:ok, from} <- entity(value(attrs, :from_entity_id), workspace, tenant),
         {:ok, to} <- entity(value(attrs, :to_entity_id), workspace, tenant),
         {:ok, relation} <- relation_type(value(attrs, :relationship_type)),
         :ok <- allowed_kind(from.entity_kind, relation.subject_kinds, :subject),
         :ok <- allowed_kind(to.entity_kind, relation.object_kinds, :object) do
      id = value(attrs, :id) || id("rel")

      case Store.raw_execute(
             """
             INSERT INTO relationship_edges
               (id, tenant_id, workspace_id, from_object_type, from_object_id,
                to_object_type, to_object_id, relationship_type, confidence,
                evidence_links, lifecycle_state, valid_time_start, valid_time_end,
                transaction_time_start, metadata)
             VALUES (?1, ?11, ?2, 'canonical_entity', ?3,
                     'canonical_entity', ?4, ?5, ?6, ?7, 'current', ?8, ?9,
                     datetime('now'), ?10)
             """,
             [
               id,
               workspace,
               from.id,
               to.id,
               relation.name,
               value(attrs, :confidence) || 1.0,
               Jason.encode!(value(attrs, :evidence_links) || []),
               value(attrs, :valid_time_start),
               value(attrs, :valid_time_end),
               Jason.encode!(%{
                 "actor_id" => value(attrs, :actor_id),
                 "relation_schema_version" => relation.schema_version
               }),
               tenant
             ]
           ) do
        :ok ->
          {:ok,
           %{id: id, from_entity_id: from.id, to_entity_id: to.id, relationship_type: relation.name}}

        error ->
          error
      end
    end
  end

  def list(entity_id, workspace_id, opts \\ []) do
    as_of = Keyword.get(opts, :as_of)

    time_clause =
      if as_of,
        do:
          "AND datetime(transaction_time_start) <= datetime(?3) AND (transaction_time_end IS NULL OR datetime(transaction_time_end) > datetime(?3)) AND (valid_time_start IS NULL OR datetime(valid_time_start) <= datetime(?3)) AND (valid_time_end IS NULL OR datetime(valid_time_end) > datetime(?3))",
        else: "AND lifecycle_state='current' AND transaction_time_end IS NULL"

    params = if as_of, do: [workspace_id, entity_id, as_of], else: [workspace_id, entity_id]

    with {:ok, rows} <-
           Store.raw_query(
             "SELECT id, from_object_id, to_object_id, relationship_type, confidence, valid_time_start, valid_time_end, transaction_time_start, transaction_time_end, evidence_links FROM relationship_edges WHERE workspace_id=?1 AND from_object_type='canonical_entity' AND to_object_type='canonical_entity' AND (from_object_id=?2 OR to_object_id=?2) #{time_clause} ORDER BY transaction_time_start",
             params
           ) do
      {:ok, Enum.map(rows, &row/1)}
    end
  end

  defp entity(id, workspace, tenant) do
    case Store.raw_query(
           "SELECT id, entity_kind FROM canonical_entities WHERE id=?1 AND workspace_id=?2 AND tenant_id=?3",
           [id, workspace, tenant]
         ) do
      {:ok, [[id, kind]]} -> {:ok, %{id: id, entity_kind: kind}}
      {:ok, []} -> {:error, :not_found}
      error -> error
    end
  end

  defp relation_type(name) do
    case Store.raw_query(
           "SELECT name, subject_kinds, object_kinds, schema_version FROM relation_types WHERE name=?1 AND lifecycle_state='active'",
           [name]
         ) do
      {:ok, [[relation, subject_kinds, object_kinds, version]]} ->
        {:ok,
         %{
           name: relation,
           subject_kinds: decode_list(subject_kinds),
           object_kinds: decode_list(object_kinds),
           schema_version: version
         }}

      {:ok, []} ->
        {:error, {:unknown_relationship_type, name}}

      error ->
        error
    end
  end

  defp allowed_kind(_kind, [], _role), do: :ok

  defp allowed_kind(kind, allowed, role) do
    if kind in allowed,
      do: :ok,
      else: {:error, {:invalid_relationship_kind, role, kind, allowed}}
  end

  defp decode_list(value),
    do:
      case(Jason.decode(value || "[]"),
        do: (
          {:ok, list} -> list
          _ -> []
        )
      )

  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp row([id, from, to, type, confidence, valid_from, valid_to, tx_from, tx_to, evidence]),
    do: %{
      id: id,
      from_entity_id: from,
      to_entity_id: to,
      relationship_type: type,
      confidence: confidence,
      valid_time_start: valid_from,
      valid_time_end: valid_to,
      transaction_time_start: tx_from,
      transaction_time_end: tx_to,
      evidence_links: decode_list(evidence)
    }

  defp id(prefix),
    do: "#{prefix}_" <> (:crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower))
end
