defmodule OptimalEngine.EntityRegistry do
  @moduledoc """
  Owns durable real-world identity independently from source mentions.

  Entity IDs are permanent. Merges close the losing identity and preserve a
  lineage record, so historical references remain resolvable.
  """

  alias OptimalEngine.{DataContract, Store}

  @kinds ~w(person organization team product project account document place workspace)

  def register(attrs) when is_map(attrs) do
    workspace = value(attrs, :workspace_id)
    name = value(attrs, :canonical_name)
    kind = value(attrs, :entity_kind)

    with {:ok, _contract} <- DataContract.validate(:entity, attrs),
         :ok <- required(workspace, :workspace_id),
         :ok <- required(name, :canonical_name),
         :ok <- validate_kind(kind) do
      id = value(attrs, :id) || id("ent")
      normalized = normalize(name)
      aliases = value(attrs, :aliases) || []
      identifiers = value(attrs, :identifiers) || []

      Store.transaction(fn tx ->
        with {:ok, 1} <-
               Store.txn_execute(
                 tx,
                 """
                 INSERT INTO canonical_entities
                   (id, tenant_id, workspace_id, entity_kind, canonical_name, normalized_name,
                    valid_time_start, metadata, created_by)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
                 """,
                 [
                   id,
                   value(attrs, :tenant_id) || "default",
                   workspace,
                   kind,
                   name,
                   normalized,
                   value(attrs, :valid_time_start),
                   Jason.encode!(value(attrs, :metadata) || %{}),
                   value(attrs, :created_by)
                 ]
               ),
             :ok <- insert_alias(tx, workspace, id, name, "canonical", 1.0, nil),
             :ok <- insert_aliases(tx, workspace, id, aliases),
             :ok <- insert_identifiers(tx, workspace, id, identifiers) do
          {:ok, %{id: id, workspace_id: workspace, entity_kind: kind, canonical_name: name}}
        end
      end)
    end
  end

  def get(id, workspace_id, opts \\ []) do
    as_of = Keyword.get(opts, :as_of)

    temporal =
      if as_of,
        do:
          "AND datetime(transaction_time_start) <= datetime(?3) AND (transaction_time_end IS NULL OR datetime(transaction_time_end) > datetime(?3))",
        else: ""

    params = if as_of, do: [id, workspace_id, as_of], else: [id, workspace_id]

    with {:ok, rows} <-
           Store.raw_query(
             """
             SELECT id, workspace_id, entity_kind, canonical_name, lifecycle_state,
                    valid_time_start, valid_time_end, transaction_time_start,
                    transaction_time_end, successor_entity_id, metadata
             FROM canonical_entities WHERE id = ?1 AND workspace_id = ?2 #{temporal}
             """,
             params
           ) do
      case rows do
        [row] -> {:ok, entity(row)}
        [] -> {:error, :not_found}
      end
    end
  end

  def merge(loser_id, winner_id, opts) when loser_id != winner_id do
    workspace = Keyword.fetch!(opts, :workspace_id)
    actor = Keyword.fetch!(opts, :actor_id)
    reason = Keyword.fetch!(opts, :reason)
    now = now()

    Store.transaction(fn tx ->
      with {:ok, [[loser_state], [winner_state]]} <-
             Store.txn_query(
               tx,
               "SELECT lifecycle_state FROM canonical_entities WHERE workspace_id = ?1 AND id IN (?2, ?3) ORDER BY id",
               [workspace, loser_id, winner_id]
             )
             |> normalize_merge_rows(loser_id, winner_id, tx, workspace),
           :ok <- ensure_active(loser_state, :loser),
           :ok <- ensure_active(winner_state, :winner),
           {:ok, 1} <-
             Store.txn_execute(
               tx,
               "UPDATE canonical_entities SET lifecycle_state='merged', transaction_time_end=?1, successor_entity_id=?2, updated_at=?1 WHERE id=?3 AND workspace_id=?4 AND lifecycle_state='active'",
               [now, winner_id, loser_id, workspace]
             ),
           {:ok, _} <-
             Store.txn_execute(
               tx,
               "UPDATE entity_aliases SET entity_id=?1 WHERE entity_id=?2 AND workspace_id=?3 AND NOT EXISTS (SELECT 1 FROM entity_aliases a2 WHERE a2.entity_id=?1 AND a2.workspace_id=?3 AND a2.normalized_alias=entity_aliases.normalized_alias AND a2.alias_type=entity_aliases.alias_type)",
               [winner_id, loser_id, workspace]
             ),
           {:ok, _} <-
             Store.txn_execute(
               tx,
               "UPDATE entity_mentions SET resolved_entity_id=?1, updated_at=?2 WHERE resolved_entity_id=?3 AND workspace_id=?4",
               [winner_id, now, loser_id, workspace]
             ),
           {:ok, 1} <-
             Store.txn_execute(
               tx,
               "INSERT INTO entity_lineage (id, workspace_id, predecessor_entity_id, successor_entity_id, operation, reason, actor_id, transaction_time) VALUES (?1, ?2, ?3, ?4, 'merge', ?5, ?6, ?7)",
               [id("lin"), workspace, loser_id, winner_id, reason, actor, now]
             ) do
        {:ok, %{merged: loser_id, into: winner_id, transaction_time: now}}
      end
    end)
  end

  def history(id, workspace_id) do
    Store.raw_query(
      """
      SELECT operation, predecessor_entity_id, successor_entity_id, reason, actor_id, transaction_time
      FROM entity_lineage
      WHERE workspace_id = ?1 AND (predecessor_entity_id = ?2 OR successor_entity_id = ?2)
      ORDER BY transaction_time
      """,
      [workspace_id, id]
    )
    |> case do
      {:ok, rows} ->
        {:ok,
         Enum.map(rows, fn [operation, predecessor, successor, reason, actor, time] ->
           %{
             operation: operation,
             predecessor: predecessor,
             successor: successor,
             reason: reason,
             actor_id: actor,
             transaction_time: time
           }
         end)}

      error ->
        error
    end
  end

  def normalize(value) when is_binary(value) do
    value
    |> String.normalize(:nfd)
    |> String.replace(~r/[^\p{L}\p{N}@._+-]+/u, " ")
    |> String.downcase()
    |> String.trim()
  end

  defp insert_aliases(tx, workspace, entity_id, aliases) do
    Enum.reduce_while(aliases, :ok, fn alias_attrs, :ok ->
      alias_value = value(alias_attrs, :alias)

      case insert_alias(
             tx,
             workspace,
             entity_id,
             alias_value,
             value(alias_attrs, :alias_type) || "name",
             value(alias_attrs, :confidence) || 1.0,
             value(alias_attrs, :source_package_id)
           ) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp insert_alias(tx, workspace, entity_id, alias_value, type, confidence, source_id) do
    case Store.txn_execute(
           tx,
           "INSERT OR IGNORE INTO entity_aliases (id, workspace_id, entity_id, alias, normalized_alias, alias_type, confidence, source_package_id) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
           [
             id("alias"),
             workspace,
             entity_id,
             alias_value,
             normalize(alias_value),
             type,
             confidence,
             source_id
           ]
         ) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp insert_identifiers(tx, workspace, entity_id, identifiers) do
    Enum.reduce_while(identifiers, :ok, fn attrs, :ok ->
      namespace = value(attrs, :namespace)
      identifier = value(attrs, :value)

      case Store.txn_execute(
             tx,
             "INSERT INTO entity_identifiers (id, workspace_id, entity_id, namespace, identifier_value, normalized_value, verification_status, verified_at, source_package_id) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
             [
               id("eid"),
               workspace,
               entity_id,
               namespace,
               identifier,
               normalize(identifier),
               value(attrs, :verification_status) || "unverified",
               value(attrs, :verified_at),
               value(attrs, :source_package_id)
             ]
           ) do
        {:ok, 1} -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp normalize_merge_rows(_result, loser_id, winner_id, tx, workspace) do
    with {:ok, loser_rows} <-
           Store.txn_query(
             tx,
             "SELECT lifecycle_state FROM canonical_entities WHERE id=?1 AND workspace_id=?2",
             [loser_id, workspace]
           ),
         {:ok, winner_rows} <-
           Store.txn_query(
             tx,
             "SELECT lifecycle_state FROM canonical_entities WHERE id=?1 AND workspace_id=?2",
             [winner_id, workspace]
           ) do
      case {loser_rows, winner_rows} do
        {[[loser]], [[winner]]} -> {:ok, [[loser], [winner]]}
        _ -> {:error, :entity_not_found}
      end
    end
  end

  defp entity([
         id,
         workspace,
         kind,
         name,
         state,
         valid_from,
         valid_to,
         tx_from,
         tx_to,
         successor,
         metadata
       ]) do
    %{
      id: id,
      workspace_id: workspace,
      entity_kind: kind,
      canonical_name: name,
      lifecycle_state: state,
      valid_time_start: valid_from,
      valid_time_end: valid_to,
      transaction_time_start: tx_from,
      transaction_time_end: tx_to,
      successor_entity_id: successor,
      metadata: decode(metadata)
    }
  end

  defp validate_kind(kind) when kind in @kinds, do: :ok
  defp validate_kind(_), do: {:error, {:invalid_entity_kind, @kinds}}
  defp required(nil, field), do: {:error, {:required, field}}
  defp required("", field), do: {:error, {:required, field}}
  defp required(_, _field), do: :ok
  defp ensure_active("active", _role), do: :ok
  defp ensure_active(state, role), do: {:error, {role, :not_active, state}}
  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp decode(value),
    do:
      case(Jason.decode(value || "{}"),
        do: (
          {:ok, data} -> data
          _ -> %{}
        )
      )

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp id(prefix),
    do: "#{prefix}_" <> (:crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower))
end
