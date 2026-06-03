defmodule OptimalEngine.MemoryCore.Store do
  @moduledoc """
  Storage adapter for governed memory objects.

  The base `OptimalEngine.Store` still owns the SQLite connection. This module
  keeps Memory Core writes typed. Lifecycle operations belong in domain modules
  such as `SourcePackageService`, `KnowledgeLifecycle`, and
  `RetrievalCoordinator`.
  """

  alias OptimalEngine.Store
  alias OptimalEngine.MemoryCore.{DerivationLedgerEntry, JSON, SourcePackage}

  @spec insert_source_package(SourcePackage.t()) :: :ok | {:error, term()}
  def insert_source_package(%SourcePackage{} = source_package) do
    sql = """
    INSERT OR IGNORE INTO source_packages (
      id, tenant_id, workspace_id, source_type, source_class, source_system,
      source_uri, source_time, received_at, content_hash, raw_text,
      verbatim_archive_uri, trust_label, retention_class, access_policy_id,
      security_labels, partition_ids, quarantine_state, metadata, created_by,
      created_at, updated_at
    ) VALUES (
      ?1, ?2, ?3, ?4, ?5, ?6,
      ?7, ?8, ?9, ?10, ?11,
      ?12, ?13, ?14, ?15,
      ?16, ?17, ?18, ?19, ?20,
      ?21, ?22
    )
    """

    Store.raw_execute(sql, [
      source_package.id,
      source_package.tenant_id,
      source_package.workspace_id,
      source_package.source_type,
      source_package.source_class,
      source_package.source_system,
      source_package.source_uri,
      source_package.source_time,
      source_package.received_at,
      source_package.content_hash,
      source_package.raw_text,
      source_package.verbatim_archive_uri,
      source_package.trust_label,
      source_package.retention_class,
      source_package.access_policy_id,
      JSON.list(source_package.security_labels),
      JSON.list(source_package.partition_ids),
      source_package.quarantine_state,
      JSON.map(source_package.metadata),
      source_package.created_by,
      source_package.created_at,
      source_package.updated_at
    ])
  end

  @spec insert_derivation_entry(DerivationLedgerEntry.t()) :: :ok | {:error, term()}
  def insert_derivation_entry(%DerivationLedgerEntry{} = entry) do
    sql = """
    INSERT INTO derivation_ledger (
      id, tenant_id, workspace_id, activity_type, derivation_stage,
      input_object_links, output_object_links, source_package_links, evidence_links,
      actor_id, evaluator_id, parser_id, model_id, model_version, prompt_template_id,
      tool_call_links, confidence_delta, precision_delta, scoring_policy_version,
      access_policy_id, security_labels, partition_ids, lifecycle_state, replay_status,
      activity_time, transaction_time_start, transaction_time_end, audit_event_links,
      policy_version, metadata, created_at
    ) VALUES (
      ?1, ?2, ?3, ?4, ?5,
      ?6, ?7, ?8, ?9,
      ?10, ?11, ?12, ?13, ?14, ?15,
      ?16, ?17, ?18, ?19,
      ?20, ?21, ?22, ?23, ?24,
      ?25, ?26, ?27, ?28,
      ?29, ?30, ?31
    )
    """

    Store.raw_execute(sql, [
      entry.id,
      entry.tenant_id,
      entry.workspace_id,
      entry.activity_type,
      entry.derivation_stage,
      JSON.list(entry.input_object_links),
      JSON.list(entry.output_object_links),
      JSON.list(entry.source_package_links),
      JSON.list(entry.evidence_links),
      entry.actor_id,
      entry.evaluator_id,
      entry.parser_id,
      entry.model_id,
      entry.model_version,
      entry.prompt_template_id,
      JSON.list(entry.tool_call_links),
      entry.confidence_delta,
      entry.precision_delta,
      entry.scoring_policy_version,
      entry.access_policy_id,
      JSON.list(entry.security_labels),
      JSON.list(entry.partition_ids),
      entry.lifecycle_state,
      entry.replay_status,
      entry.activity_time,
      entry.transaction_time_start,
      entry.transaction_time_end,
      JSON.list(entry.audit_event_links),
      entry.policy_version,
      JSON.map(entry.metadata),
      entry.created_at
    ])
  end

  @spec insert_claim(map()) :: :ok | {:error, term()}
  def insert_claim(claim) when is_map(claim) do
    sql = """
    INSERT OR IGNORE INTO claims (
      id, tenant_id, workspace_id, source_package_id, signal_id,
      claim_text, claim_type, subject_anchor, action_class, object_anchor,
      semantic_frame, source_span, extraction_run_id, evaluator_id,
      aggregate_confidence, aggregate_precision, raw_component_scores,
      calibration_dataset_version, access_policy_id, security_labels,
      partition_ids, lifecycle_state, review_status, valid_time_start,
      valid_time_end, transaction_time_start, transaction_time_end,
      stale_after, metadata
    ) VALUES (
      ?1, ?2, ?3, ?4, ?5,
      ?6, ?7, ?8, ?9, ?10,
      ?11, ?12, ?13, ?14,
      ?15, ?16, ?17,
      ?18, ?19, ?20,
      ?21, ?22, ?23, ?24,
      ?25, ?26, ?27,
      ?28, ?29
    )
    """

    Store.raw_execute(sql, [
      claim.id,
      claim.tenant_id,
      claim.workspace_id,
      claim.source_package_id,
      Map.get(claim, :signal_id),
      claim.claim_text,
      Map.get(claim, :claim_type, "assertion"),
      Map.get(claim, :subject_anchor),
      Map.get(claim, :action_class),
      Map.get(claim, :object_anchor),
      JSON.map(Map.get(claim, :semantic_frame, %{})),
      JSON.map(Map.get(claim, :source_span, %{})),
      Map.get(claim, :extraction_run_id),
      Map.get(claim, :evaluator_id),
      Map.get(claim, :aggregate_confidence, 0.5),
      Map.get(claim, :aggregate_precision, 0.5),
      JSON.map(Map.get(claim, :raw_component_scores, %{})),
      Map.get(claim, :calibration_dataset_version),
      Map.get(claim, :access_policy_id),
      JSON.list(Map.get(claim, :security_labels, [])),
      JSON.list(Map.get(claim, :partition_ids, [])),
      Map.get(claim, :lifecycle_state, "pending"),
      Map.get(claim, :review_status, "unreviewed"),
      Map.get(claim, :valid_time_start),
      Map.get(claim, :valid_time_end),
      Map.get(claim, :transaction_time_start, timestamp()),
      Map.get(claim, :transaction_time_end),
      Map.get(claim, :stale_after),
      JSON.map(Map.get(claim, :metadata, %{}))
    ])
  end

  @spec insert_fact(map()) :: :ok | {:error, term()}
  def insert_fact(fact) when is_map(fact) do
    sql = """
    INSERT OR IGNORE INTO facts (
      id, tenant_id, workspace_id, fact_text, fact_type, subject_anchor,
      action_class, object_anchor, scope, accepted_claim_ids,
      supporting_evidence_links, contradicting_evidence_links, verifier_id,
      verification_status, aggregate_confidence, aggregate_precision,
      raw_component_scores, access_policy_id, security_labels, partition_ids,
      lifecycle_state, contradiction_status, event_time, valid_time_start,
      valid_time_end, transaction_time_start, transaction_time_end,
      verification_time, stale_after, metadata
    ) VALUES (
      ?1, ?2, ?3, ?4, ?5, ?6,
      ?7, ?8, ?9, ?10,
      ?11, ?12, ?13,
      ?14, ?15, ?16,
      ?17, ?18, ?19, ?20,
      ?21, ?22, ?23, ?24,
      ?25, ?26, ?27,
      ?28, ?29, ?30
    )
    """

    Store.raw_execute(sql, [
      fact.id,
      fact.tenant_id,
      fact.workspace_id,
      fact.fact_text,
      Map.get(fact, :fact_type, "assertion"),
      Map.get(fact, :subject_anchor),
      Map.get(fact, :action_class),
      Map.get(fact, :object_anchor),
      JSON.map(Map.get(fact, :scope, %{})),
      JSON.list(Map.get(fact, :accepted_claim_ids, [])),
      JSON.list(Map.get(fact, :supporting_evidence_links, [])),
      JSON.list(Map.get(fact, :contradicting_evidence_links, [])),
      Map.get(fact, :verifier_id),
      Map.get(fact, :verification_status, "unverified"),
      Map.get(fact, :aggregate_confidence, 0.5),
      Map.get(fact, :aggregate_precision, 0.5),
      JSON.map(Map.get(fact, :raw_component_scores, %{})),
      Map.get(fact, :access_policy_id),
      JSON.list(Map.get(fact, :security_labels, [])),
      JSON.list(Map.get(fact, :partition_ids, [])),
      Map.get(fact, :lifecycle_state, "candidate"),
      Map.get(fact, :contradiction_status, "none"),
      Map.get(fact, :event_time),
      Map.get(fact, :valid_time_start),
      Map.get(fact, :valid_time_end),
      Map.get(fact, :transaction_time_start, timestamp()),
      Map.get(fact, :transaction_time_end),
      Map.get(fact, :verification_time),
      Map.get(fact, :stale_after),
      JSON.map(Map.get(fact, :metadata, %{}))
    ])
  end

  @spec insert_memory_object(map()) :: :ok | {:error, term()}
  def insert_memory_object(memory_object) when is_map(memory_object) do
    sql = """
    INSERT OR IGNORE INTO memory_objects (
      id, tenant_id, workspace_id, memory_type, summary, subject_anchor,
      action_class, semantic_frame, salience, fact_links, claim_links,
      source_package_links, evidence_links, aggregate_confidence,
      aggregate_precision, access_policy_id, security_labels, partition_ids,
      lifecycle_state, staleness_status, supersession_status, event_time,
      valid_time_start, valid_time_end, transaction_time_start,
      transaction_time_end, stale_after, metadata
    ) VALUES (
      ?1, ?2, ?3, ?4, ?5, ?6,
      ?7, ?8, ?9, ?10, ?11,
      ?12, ?13, ?14,
      ?15, ?16, ?17, ?18,
      ?19, ?20, ?21, ?22,
      ?23, ?24, ?25,
      ?26, ?27, ?28
    )
    """

    Store.raw_execute(sql, [
      memory_object.id,
      memory_object.tenant_id,
      memory_object.workspace_id,
      Map.get(memory_object, :memory_type, "general"),
      memory_object.summary,
      Map.get(memory_object, :subject_anchor),
      Map.get(memory_object, :action_class),
      JSON.map(Map.get(memory_object, :semantic_frame, %{})),
      Map.get(memory_object, :salience, 0.5),
      JSON.list(Map.get(memory_object, :fact_links, [])),
      JSON.list(Map.get(memory_object, :claim_links, [])),
      JSON.list(Map.get(memory_object, :source_package_links, [])),
      JSON.list(Map.get(memory_object, :evidence_links, [])),
      Map.get(memory_object, :aggregate_confidence, 0.5),
      Map.get(memory_object, :aggregate_precision, 0.5),
      Map.get(memory_object, :access_policy_id),
      JSON.list(Map.get(memory_object, :security_labels, [])),
      JSON.list(Map.get(memory_object, :partition_ids, [])),
      Map.get(memory_object, :lifecycle_state, "candidate"),
      Map.get(memory_object, :staleness_status, "current"),
      Map.get(memory_object, :supersession_status, "none"),
      Map.get(memory_object, :event_time),
      Map.get(memory_object, :valid_time_start),
      Map.get(memory_object, :valid_time_end),
      Map.get(memory_object, :transaction_time_start, timestamp()),
      Map.get(memory_object, :transaction_time_end),
      Map.get(memory_object, :stale_after),
      JSON.map(Map.get(memory_object, :metadata, %{}))
    ])
  end

  @spec insert_relationship_edge(map()) :: :ok | {:error, term()}
  def insert_relationship_edge(edge) when is_map(edge) do
    sql = """
    INSERT OR IGNORE INTO relationship_edges (
      id, tenant_id, workspace_id, from_object_type, from_object_id,
      to_object_type, to_object_id, relationship_type, confidence,
      precision_score, evidence_links, access_policy_id, security_labels,
      partition_ids, lifecycle_state, valid_time_start, valid_time_end,
      transaction_time_start, transaction_time_end, metadata
    ) VALUES (
      ?1, ?2, ?3, ?4, ?5,
      ?6, ?7, ?8, ?9,
      ?10, ?11, ?12, ?13,
      ?14, ?15, ?16, ?17,
      ?18, ?19, ?20
    )
    """

    Store.raw_execute(sql, [
      edge.id,
      edge.tenant_id,
      edge.workspace_id,
      edge.from_object_type,
      edge.from_object_id,
      edge.to_object_type,
      edge.to_object_id,
      edge.relationship_type,
      Map.get(edge, :confidence, 0.5),
      Map.get(edge, :precision_score, 0.5),
      JSON.list(Map.get(edge, :evidence_links, [])),
      Map.get(edge, :access_policy_id),
      JSON.list(Map.get(edge, :security_labels, [])),
      JSON.list(Map.get(edge, :partition_ids, [])),
      Map.get(edge, :lifecycle_state, "current"),
      Map.get(edge, :valid_time_start),
      Map.get(edge, :valid_time_end),
      Map.get(edge, :transaction_time_start, timestamp()),
      Map.get(edge, :transaction_time_end),
      JSON.map(Map.get(edge, :metadata, %{}))
    ])
  end

  @spec insert_context_package(map()) :: :ok | {:error, term()}
  def insert_context_package(context_package) when is_map(context_package) do
    sql = """
    INSERT INTO context_packages (
      id, tenant_id, workspace_id, request_id, request_intent,
      requesting_actor_id, active_memory_pool_id, time_mode, detail_depth,
      memory_links, fact_links, workflow_links, skill_package_links,
      source_package_links, evidence_links, retrieval_plan,
      package_confidence_summary, package_precision_summary,
      filtered_object_summary, returned_object_links, redacted_object_links,
      authorization_envelope, lifecycle_state, refresh_state,
      invalidation_reason, valid_time_start, valid_time_end,
      transaction_time_start, transaction_time_end, stale_after, refresh_time,
      access_policy_id, security_labels, partition_ids, audit_event_links,
      policy_version, metadata
    ) VALUES (
      ?1, ?2, ?3, ?4, ?5,
      ?6, ?7, ?8, ?9,
      ?10, ?11, ?12, ?13,
      ?14, ?15, ?16,
      ?17, ?18,
      ?19, ?20, ?21,
      ?22, ?23, ?24,
      ?25, ?26, ?27,
      ?28, ?29, ?30, ?31,
      ?32, ?33, ?34, ?35,
      ?36, ?37
    )
    """

    Store.raw_execute(sql, [
      context_package.id,
      context_package.tenant_id,
      context_package.workspace_id,
      Map.get(context_package, :request_id),
      Map.get(context_package, :request_intent),
      Map.get(context_package, :requesting_actor_id),
      Map.get(context_package, :active_memory_pool_id),
      Map.get(context_package, :time_mode, "current_valid"),
      Map.get(context_package, :detail_depth, 1),
      JSON.list(Map.get(context_package, :memory_links, [])),
      JSON.list(Map.get(context_package, :fact_links, [])),
      JSON.list(Map.get(context_package, :workflow_links, [])),
      JSON.list(Map.get(context_package, :skill_package_links, [])),
      JSON.list(Map.get(context_package, :source_package_links, [])),
      JSON.list(Map.get(context_package, :evidence_links, [])),
      JSON.map(Map.get(context_package, :retrieval_plan, %{})),
      JSON.map(Map.get(context_package, :package_confidence_summary, %{})),
      JSON.map(Map.get(context_package, :package_precision_summary, %{})),
      JSON.map(Map.get(context_package, :filtered_object_summary, %{})),
      JSON.list(Map.get(context_package, :returned_object_links, [])),
      JSON.list(Map.get(context_package, :redacted_object_links, [])),
      JSON.map(Map.get(context_package, :authorization_envelope, %{})),
      Map.get(context_package, :lifecycle_state, "assembled"),
      Map.get(context_package, :refresh_state, "fresh"),
      Map.get(context_package, :invalidation_reason),
      Map.get(context_package, :valid_time_start),
      Map.get(context_package, :valid_time_end),
      Map.get(context_package, :transaction_time_start, timestamp()),
      Map.get(context_package, :transaction_time_end),
      Map.get(context_package, :stale_after),
      Map.get(context_package, :refresh_time, timestamp()),
      Map.get(context_package, :access_policy_id),
      JSON.list(Map.get(context_package, :security_labels, [])),
      JSON.list(Map.get(context_package, :partition_ids, [])),
      JSON.list(Map.get(context_package, :audit_event_links, [])),
      Map.get(context_package, :policy_version),
      JSON.map(Map.get(context_package, :metadata, %{}))
    ])
  end

  @spec insert_active_memory_pool(map()) :: :ok | {:error, term()}
  def insert_active_memory_pool(pool) when is_map(pool) do
    sql = """
    INSERT INTO active_memory_pools (
      id, tenant_id, workspace_id, pool_scope, task_type, subject_anchor,
      time_mode, loaded_context_links, source_package_links, evidence_links,
      context_package_links, promotion_candidate_links,
      context_confidence_summary, context_precision_summary, member_links,
      agent_links, tool_links, membership_policy, delegation_chain_links,
      lifecycle_state, refresh_state, archive_state, opened_at, closed_at,
      valid_time_start, valid_time_end, transaction_time_start,
      transaction_time_end, stale_after, access_policy_id, security_labels,
      partition_ids, audit_event_links, policy_version, metadata
    ) VALUES (
      ?1, ?2, ?3, ?4, ?5, ?6,
      ?7, ?8, ?9, ?10,
      ?11, ?12,
      ?13, ?14, ?15,
      ?16, ?17, ?18, ?19,
      ?20, ?21, ?22, ?23, ?24,
      ?25, ?26, ?27,
      ?28, ?29, ?30, ?31,
      ?32, ?33, ?34, ?35
    )
    """

    Store.raw_execute(sql, active_memory_pool_params(pool))
  end

  @spec update_active_memory_pool(map()) :: :ok | {:error, term()}
  def update_active_memory_pool(pool) when is_map(pool) do
    sql = """
    UPDATE active_memory_pools
    SET tenant_id = ?2,
        workspace_id = ?3,
        pool_scope = ?4,
        task_type = ?5,
        subject_anchor = ?6,
        time_mode = ?7,
        loaded_context_links = ?8,
        source_package_links = ?9,
        evidence_links = ?10,
        context_package_links = ?11,
        promotion_candidate_links = ?12,
        context_confidence_summary = ?13,
        context_precision_summary = ?14,
        member_links = ?15,
        agent_links = ?16,
        tool_links = ?17,
        membership_policy = ?18,
        delegation_chain_links = ?19,
        lifecycle_state = ?20,
        refresh_state = ?21,
        archive_state = ?22,
        opened_at = ?23,
        closed_at = ?24,
        valid_time_start = ?25,
        valid_time_end = ?26,
        transaction_time_start = ?27,
        transaction_time_end = ?28,
        stale_after = ?29,
        access_policy_id = ?30,
        security_labels = ?31,
        partition_ids = ?32,
        audit_event_links = ?33,
        policy_version = ?34,
        metadata = ?35,
        updated_at = datetime('now')
    WHERE id = ?1
    """

    Store.raw_execute(sql, active_memory_pool_params(pool))
  end

  defp active_memory_pool_params(pool) do
    [
      pool.id,
      pool.tenant_id,
      pool.workspace_id,
      JSON.map(Map.get(pool, :pool_scope, %{})),
      Map.get(pool, :task_type),
      Map.get(pool, :subject_anchor),
      Map.get(pool, :time_mode, "current_valid"),
      JSON.list(Map.get(pool, :loaded_context_links, [])),
      JSON.list(Map.get(pool, :source_package_links, [])),
      JSON.list(Map.get(pool, :evidence_links, [])),
      JSON.list(Map.get(pool, :context_package_links, [])),
      JSON.list(Map.get(pool, :promotion_candidate_links, [])),
      JSON.map(Map.get(pool, :context_confidence_summary, %{})),
      JSON.map(Map.get(pool, :context_precision_summary, %{})),
      JSON.list(Map.get(pool, :member_links, [])),
      JSON.list(Map.get(pool, :agent_links, [])),
      JSON.list(Map.get(pool, :tool_links, [])),
      JSON.map(Map.get(pool, :membership_policy, %{})),
      JSON.list(Map.get(pool, :delegation_chain_links, [])),
      Map.get(pool, :lifecycle_state, "open"),
      Map.get(pool, :refresh_state, "fresh"),
      Map.get(pool, :archive_state, "active"),
      Map.get(pool, :opened_at, timestamp()),
      Map.get(pool, :closed_at),
      Map.get(pool, :valid_time_start),
      Map.get(pool, :valid_time_end),
      Map.get(pool, :transaction_time_start, timestamp()),
      Map.get(pool, :transaction_time_end),
      Map.get(pool, :stale_after),
      Map.get(pool, :access_policy_id),
      JSON.list(Map.get(pool, :security_labels, [])),
      JSON.list(Map.get(pool, :partition_ids, [])),
      JSON.list(Map.get(pool, :audit_event_links, [])),
      Map.get(pool, :policy_version),
      JSON.map(Map.get(pool, :metadata, %{}))
    ]
  end

  defp timestamp, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
