defmodule OptimalEngine.MemoryCore.AssociativeProjection do
  @moduledoc """
  Rebuildable Cue-Tag-Content projection over governed Memory Core objects.

  The projection accelerates traversal but never becomes truth. Every endpoint
  resolves to a governed object or Relationship Edge, retains policy and time
  metadata, and is filtered during candidate expansion.
  """

  alias OptimalEngine.MemoryCore.{ID, JSON, ScopeEnvelope}
  alias OptimalEngine.Store

  @version "associative-v1"
  @stopwords ~w[a an and are as at be by for from how in is it of on or that the this to was what when where which who why with]

  @doc "Returns the rebuildable association schema version."
  @spec version() :: String.t()
  def version, do: @version

  @doc "Rebuilds all associations for one tenant and workspace from canonical rows."
  @spec rebuild(ScopeEnvelope.t()) :: {:ok, map()} | {:error, term()}
  def rebuild(%ScopeEnvelope{} = scope) do
    Store.transaction(fn txn ->
      with {:ok, _} <-
             Store.txn_execute(
               txn,
               "DELETE FROM memory_associations WHERE tenant_id = ?1 AND workspace_id = ?2",
               [scope.tenant_id, scope.workspace_id]
             ),
           {:ok, facts} <- query_objects(txn, :facts, scope),
           {:ok, memories} <- query_objects(txn, :memory_objects, scope),
           {:ok, episodes} <- query_objects(txn, :episodes, scope),
           {:ok, edges} <- query_edges(txn, scope),
           :ok <- insert_all(txn, facts ++ memories ++ episodes ++ edges) do
        {:ok,
         %{
           tenant_id: scope.tenant_id,
           workspace_id: scope.workspace_id,
           projection_version: @version,
           associations: length(facts) + length(memories) + length(episodes) + length(edges)
         }}
      end
    end)
  end

  @doc "Expands cues into authorized, current association paths."
  @spec expand([String.t()], ScopeEnvelope.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def expand(cues, %ScopeEnvelope{} = scope, opts \\ []) do
    normalized = cues |> Enum.flat_map(&terms/1) |> Enum.uniq() |> Enum.take(16)
    limit = Keyword.get(opts, :limit, 40)
    time_mode = Keyword.get(opts, :time_mode, "current_valid")
    allowed_labels = Keyword.get(opts, :allowed_security_labels, [])
    allowed_partitions = Keyword.get(opts, :allowed_partitions, [])

    if normalized == [] do
      {:ok, []}
    else
      matches =
        normalized
        |> Enum.with_index(1)
        |> Enum.map_join(" OR ", fn {_cue, index} -> "normalized_cue = ?#{index}" end)

      cue_params = normalized
      base = length(cue_params) + 3

      temporal =
        if time_mode == "all_valid",
          do: "",
          else:
            " AND (valid_time_end IS NULL OR valid_time_end > datetime('now')) AND transaction_time_end IS NULL"

      sql = """
      SELECT id, cue, tag, from_object_type, from_object_id, to_object_type,
             to_object_id, relationship_type, content, source_package_links,
             evidence_links, confidence, precision_score, security_labels,
             partition_ids, valid_time_start, valid_time_end, projection_version
      FROM memory_associations a
      WHERE tenant_id = ?#{length(cue_params) + 1}
        AND workspace_id = ?#{length(cue_params) + 2}
        AND (#{matches})
        AND NOT EXISTS (
          SELECT 1 FROM json_each(a.security_labels) required
          WHERE required.value NOT IN (SELECT value FROM json_each(?#{base}))
        )
        AND NOT EXISTS (
          SELECT 1 FROM json_each(a.partition_ids) required
          WHERE required.value NOT IN (SELECT value FROM json_each(?#{base + 1}))
        )
        #{temporal}
      ORDER BY confidence DESC, precision_score DESC, updated_at DESC
      LIMIT ?#{base + 2}
      """

      params =
        cue_params ++
          [
            scope.tenant_id,
            scope.workspace_id,
            JSON.list(allowed_labels),
            JSON.list(allowed_partitions),
            limit
          ]

      case Store.raw_query(sql, params) do
        {:ok, rows} -> {:ok, Enum.map(rows, &from_row/1)}
        error -> error
      end
    end
  end

  defp query_objects(txn, :facts, scope) do
    sql = """
    SELECT id, 'fact', fact_type, fact_text, supporting_evidence_links,
           aggregate_confidence, aggregate_precision, access_policy_id,
           security_labels, partition_ids, valid_time_start, valid_time_end,
           transaction_time_start, transaction_time_end
    FROM facts
    WHERE tenant_id = ?1 AND workspace_id = ?2 AND lifecycle_state = 'accepted'
    """

    object_rows(txn, sql, scope)
  end

  defp query_objects(txn, :memory_objects, scope) do
    sql = """
    SELECT id, 'memory_object', memory_type, summary, evidence_links,
           aggregate_confidence, aggregate_precision, access_policy_id,
           security_labels, partition_ids, valid_time_start, valid_time_end,
           transaction_time_start, transaction_time_end
    FROM memory_objects
    WHERE tenant_id = ?1 AND workspace_id = ?2 AND lifecycle_state = 'accepted'
      AND staleness_status = 'current' AND supersession_status = 'none'
    """

    object_rows(txn, sql, scope)
  end

  defp query_objects(txn, :episodes, scope) do
    sql = """
    SELECT id, 'episode', kind, summary, provenance, 0.7, 0.7, NULL,
           security_labels, partition_ids, occurred_at, NULL, created_at, NULL
    FROM episodes
    WHERE tenant_id = ?1 AND workspace_id = ?2 AND lifecycle_state = 'recorded'
    """

    object_rows(txn, sql, scope)
  end

  defp object_rows(txn, sql, scope) do
    with {:ok, rows} <- Store.txn_query(txn, sql, [scope.tenant_id, scope.workspace_id]) do
      associations =
        Enum.flat_map(rows, fn [
                                 id,
                                 type,
                                 tag,
                                 content,
                                 evidence,
                                 confidence,
                                 precision,
                                 policy,
                                 labels,
                                 partitions,
                                 valid_start,
                                 valid_end,
                                 tx_start,
                                 tx_end
                               ] ->
          content
          |> terms()
          |> Enum.map(fn cue ->
            association(scope, cue, tag, type, id, type, id, "describes", content,
              evidence: evidence,
              confidence: confidence,
              precision: precision,
              policy: policy,
              labels: labels,
              partitions: partitions,
              valid_start: valid_start,
              valid_end: valid_end,
              tx_start: tx_start,
              tx_end: tx_end
            )
          end)
        end)

      {:ok, associations}
    end
  end

  defp query_edges(txn, scope) do
    sql = """
    SELECT id, from_object_type, from_object_id, to_object_type, to_object_id,
           relationship_type, confidence, precision_score, evidence_links,
           access_policy_id, security_labels, partition_ids, valid_time_start,
           valid_time_end, transaction_time_start, transaction_time_end
    FROM relationship_edges
    WHERE tenant_id = ?1 AND workspace_id = ?2 AND lifecycle_state = 'current'
    """

    with {:ok, rows} <- Store.txn_query(txn, sql, [scope.tenant_id, scope.workspace_id]) do
      {:ok,
       Enum.map(rows, fn [
                           id,
                           from_type,
                           from_id,
                           to_type,
                           to_id,
                           relation,
                           confidence,
                           precision,
                           evidence,
                           policy,
                           labels,
                           partitions,
                           valid_start,
                           valid_end,
                           tx_start,
                           tx_end
                         ] ->
         association(
           scope,
           relation,
           relation,
           from_type,
           from_id,
           to_type,
           to_id,
           relation,
           "#{from_type}:#{from_id} #{relation} #{to_type}:#{to_id}",
           id: id,
           evidence: evidence,
           confidence: confidence,
           precision: precision,
           policy: policy,
           labels: labels,
           partitions: partitions,
           valid_start: valid_start,
           valid_end: valid_end,
           tx_start: tx_start,
           tx_end: tx_end
         )
       end)}
    end
  end

  defp association(scope, cue, tag, from_type, from_id, to_type, to_id, relationship, content, opts) do
    %{
      id:
        Keyword.get(opts, :id) ||
          ID.content_id("assoc", [
            scope.workspace_id,
            cue,
            from_type,
            from_id,
            to_type,
            to_id,
            relationship
          ]),
      tenant_id: scope.tenant_id,
      workspace_id: scope.workspace_id,
      cue: cue,
      normalized_cue: normalize(cue),
      tag: to_string(tag || relationship),
      from_object_type: from_type,
      from_object_id: from_id,
      to_object_type: to_type,
      to_object_id: to_id,
      relationship_type: relationship,
      content: content || "",
      source_package_links: "[]",
      evidence_links: Keyword.get(opts, :evidence) || "[]",
      confidence: Keyword.get(opts, :confidence) || 0.5,
      precision_score: Keyword.get(opts, :precision) || 0.5,
      access_policy_id: Keyword.get(opts, :policy),
      security_labels: Keyword.get(opts, :labels) || "[]",
      partition_ids: Keyword.get(opts, :partitions) || "[]",
      valid_time_start: Keyword.get(opts, :valid_start),
      valid_time_end: Keyword.get(opts, :valid_end),
      transaction_time_start: Keyword.get(opts, :tx_start),
      transaction_time_end: Keyword.get(opts, :tx_end)
    }
  end

  defp insert_all(txn, associations) do
    Enum.reduce_while(associations, :ok, fn a, :ok ->
      sql = """
      INSERT OR REPLACE INTO memory_associations (
        id, tenant_id, workspace_id, cue, normalized_cue, tag,
        from_object_type, from_object_id, to_object_type, to_object_id,
        relationship_type, content, source_package_links, evidence_links,
        confidence, precision_score, access_policy_id, security_labels,
        partition_ids, valid_time_start, valid_time_end,
        transaction_time_start, transaction_time_end, projection_version,
        updated_at
      ) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18,?19,?20,?21,?22,?23,?24,datetime('now'))
      """

      params = [
        a.id,
        a.tenant_id,
        a.workspace_id,
        a.cue,
        a.normalized_cue,
        a.tag,
        a.from_object_type,
        a.from_object_id,
        a.to_object_type,
        a.to_object_id,
        a.relationship_type,
        a.content,
        a.source_package_links,
        a.evidence_links,
        a.confidence,
        a.precision_score,
        a.access_policy_id,
        a.security_labels,
        a.partition_ids,
        a.valid_time_start,
        a.valid_time_end,
        a.transaction_time_start,
        a.transaction_time_end,
        @version
      ]

      case Store.txn_execute(txn, sql, params) do
        {:ok, _} -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp from_row([
         id,
         cue,
         tag,
         from_type,
         from_id,
         to_type,
         to_id,
         relation,
         content,
         sources,
         evidence,
         confidence,
         precision,
         labels,
         partitions,
         valid_start,
         valid_end,
         version
       ]) do
    %{
      id: id,
      cue: cue,
      tag: tag,
      from: %{type: from_type, id: from_id},
      to: %{type: to_type, id: to_id},
      relationship_type: relation,
      content: content,
      source_package_links: decode(sources),
      evidence_links: decode(evidence),
      confidence: confidence,
      precision: precision,
      security_labels: decode(labels),
      partition_ids: decode(partitions),
      valid_time_start: valid_start,
      valid_time_end: valid_end,
      projection_version: version
    }
  end

  defp terms(text) do
    text
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^\p{L}\p{N}-]+/u, " ")
    |> String.split()
    |> Enum.reject(&(&1 in @stopwords or String.length(&1) < 3))
    |> Enum.uniq()
    |> Enum.take(24)
  end

  defp normalize(value), do: value |> to_string() |> String.downcase() |> String.trim()
  defp decode(nil), do: []

  defp decode(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> decoded
      _ -> []
    end
  end
end
