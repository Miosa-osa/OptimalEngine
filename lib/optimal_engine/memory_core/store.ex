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

  @spec insert_workflow_trace(map()) :: :ok | {:error, term()}
  def insert_workflow_trace(trace) when is_map(trace) do
    sql = """
    INSERT OR IGNORE INTO workflow_traces (
      id, tenant_id, workspace_id, case_id, workflow_family, subject_anchor,
      action_class, outcome, episode_links, step_links, actor_links,
      input_links, output_links, source_package_links, evidence_links,
      aggregate_confidence, aggregate_precision, lifecycle_state,
      validation_status, event_time_start, event_time_end, valid_time_start,
      valid_time_end, transaction_time_start, transaction_time_end,
      stale_after, access_policy_id, security_labels, partition_ids, metadata
    ) VALUES (
      ?1, ?2, ?3, ?4, ?5, ?6,
      ?7, ?8, ?9, ?10, ?11,
      ?12, ?13, ?14, ?15,
      ?16, ?17, ?18,
      ?19, ?20, ?21, ?22,
      ?23, ?24, ?25,
      ?26, ?27, ?28, ?29, ?30
    )
    """

    Store.raw_execute(sql, [
      trace.id,
      trace.tenant_id,
      trace.workspace_id,
      Map.get(trace, :case_id),
      Map.get(trace, :workflow_family),
      Map.get(trace, :subject_anchor),
      Map.get(trace, :action_class),
      Map.get(trace, :outcome),
      JSON.list(Map.get(trace, :episode_links, [])),
      JSON.list(Map.get(trace, :step_links, [])),
      JSON.list(Map.get(trace, :actor_links, [])),
      JSON.list(Map.get(trace, :input_links, [])),
      JSON.list(Map.get(trace, :output_links, [])),
      JSON.list(Map.get(trace, :source_package_links, [])),
      JSON.list(Map.get(trace, :evidence_links, [])),
      Map.get(trace, :aggregate_confidence, 0.5),
      Map.get(trace, :aggregate_precision, 0.5),
      Map.get(trace, :lifecycle_state, "extracted"),
      Map.get(trace, :validation_status, "unvalidated"),
      Map.get(trace, :event_time_start),
      Map.get(trace, :event_time_end),
      Map.get(trace, :valid_time_start),
      Map.get(trace, :valid_time_end),
      Map.get(trace, :transaction_time_start, timestamp()),
      Map.get(trace, :transaction_time_end),
      Map.get(trace, :stale_after),
      Map.get(trace, :access_policy_id),
      JSON.list(Map.get(trace, :security_labels, [])),
      JSON.list(Map.get(trace, :partition_ids, [])),
      JSON.map(Map.get(trace, :metadata, %{}))
    ])
  end

  @spec insert_generalized_workflow(map()) :: :ok | {:error, term()}
  def insert_generalized_workflow(workflow) when is_map(workflow) do
    sql = """
    INSERT OR IGNORE INTO generalized_workflows (
      id, tenant_id, workspace_id, workflow_family, scope,
      applicability_conditions, outcome_class, workflow_trace_links,
      supporting_episode_links, contradicting_trace_links, step_pattern_links,
      aggregate_confidence, aggregate_precision, validation_score,
      lifecycle_state, validation_status, supersession_status,
      valid_time_start, valid_time_end, transaction_time_start,
      transaction_time_end, stale_after, access_policy_id, security_labels,
      partition_ids, metadata
    ) VALUES (
      ?1, ?2, ?3, ?4, ?5,
      ?6, ?7, ?8,
      ?9, ?10, ?11,
      ?12, ?13, ?14,
      ?15, ?16, ?17,
      ?18, ?19, ?20,
      ?21, ?22, ?23, ?24,
      ?25, ?26
    )
    """

    Store.raw_execute(sql, [
      workflow.id,
      workflow.tenant_id,
      workflow.workspace_id,
      workflow.workflow_family,
      JSON.map(Map.get(workflow, :scope, %{})),
      JSON.map(Map.get(workflow, :applicability_conditions, %{})),
      Map.get(workflow, :outcome_class),
      JSON.list(Map.get(workflow, :workflow_trace_links, [])),
      JSON.list(Map.get(workflow, :supporting_episode_links, [])),
      JSON.list(Map.get(workflow, :contradicting_trace_links, [])),
      JSON.list(Map.get(workflow, :step_pattern_links, [])),
      Map.get(workflow, :aggregate_confidence, 0.5),
      Map.get(workflow, :aggregate_precision, 0.5),
      Map.get(workflow, :validation_score, 0.0),
      Map.get(workflow, :lifecycle_state, "candidate"),
      Map.get(workflow, :validation_status, "unvalidated"),
      Map.get(workflow, :supersession_status, "none"),
      Map.get(workflow, :valid_time_start),
      Map.get(workflow, :valid_time_end),
      Map.get(workflow, :transaction_time_start, timestamp()),
      Map.get(workflow, :transaction_time_end),
      Map.get(workflow, :stale_after),
      Map.get(workflow, :access_policy_id),
      JSON.list(Map.get(workflow, :security_labels, [])),
      JSON.list(Map.get(workflow, :partition_ids, [])),
      JSON.map(Map.get(workflow, :metadata, %{}))
    ])
  end

  @spec insert_procedural_memory_object(map()) :: :ok | {:error, term()}
  def insert_procedural_memory_object(procedure) when is_map(procedure) do
    sql = """
    INSERT OR IGNORE INTO procedural_memory_objects (
      id, tenant_id, workspace_id, capability_name, task_family,
      applicability_conditions, risk_class, generalized_workflow_links,
      step_links, validation_links, evidence_links, aggregate_confidence,
      aggregate_precision, validation_confidence, required_privileges,
      lifecycle_state, validation_status, retirement_status, valid_time_start,
      valid_time_end, transaction_time_start, transaction_time_end,
      stale_after, access_policy_id, security_labels, partition_ids, metadata
    ) VALUES (
      ?1, ?2, ?3, ?4, ?5,
      ?6, ?7, ?8,
      ?9, ?10, ?11, ?12,
      ?13, ?14, ?15,
      ?16, ?17, ?18, ?19,
      ?20, ?21, ?22,
      ?23, ?24, ?25, ?26, ?27
    )
    """

    Store.raw_execute(sql, [
      procedure.id,
      procedure.tenant_id,
      procedure.workspace_id,
      procedure.capability_name,
      Map.get(procedure, :task_family),
      JSON.map(Map.get(procedure, :applicability_conditions, %{})),
      Map.get(procedure, :risk_class, "low"),
      JSON.list(Map.get(procedure, :generalized_workflow_links, [])),
      JSON.list(Map.get(procedure, :step_links, [])),
      JSON.list(Map.get(procedure, :validation_links, [])),
      JSON.list(Map.get(procedure, :evidence_links, [])),
      Map.get(procedure, :aggregate_confidence, 0.5),
      Map.get(procedure, :aggregate_precision, 0.5),
      Map.get(procedure, :validation_confidence, 0.0),
      JSON.list(Map.get(procedure, :required_privileges, [])),
      Map.get(procedure, :lifecycle_state, "candidate"),
      Map.get(procedure, :validation_status, "unvalidated"),
      Map.get(procedure, :retirement_status, "active"),
      Map.get(procedure, :valid_time_start),
      Map.get(procedure, :valid_time_end),
      Map.get(procedure, :transaction_time_start, timestamp()),
      Map.get(procedure, :transaction_time_end),
      Map.get(procedure, :stale_after),
      Map.get(procedure, :access_policy_id),
      JSON.list(Map.get(procedure, :security_labels, [])),
      JSON.list(Map.get(procedure, :partition_ids, [])),
      JSON.map(Map.get(procedure, :metadata, %{}))
    ])
  end

  @spec insert_skill_package(map()) :: :ok | {:error, term()}
  def insert_skill_package(skill_package) when is_map(skill_package) do
    sql = """
    INSERT OR IGNORE INTO skill_packages (
      id, tenant_id, workspace_id, version, skill_package_name, task_family,
      competency_links, risk_class, procedural_memory_links, workflow_links,
      validation_links, evidence_links, input_contract, output_contract,
      execution_policy, required_privileges, tool_requirements, model_policy_id,
      aggregate_confidence, aggregate_precision, review_status, enabled_state,
      suspension_reason, retirement_status, valid_time_start, valid_time_end,
      transaction_time_start, transaction_time_end, stale_after,
      access_policy_id, security_labels, partition_ids, metadata
    ) VALUES (
      ?1, ?2, ?3, ?4, ?5, ?6,
      ?7, ?8, ?9, ?10,
      ?11, ?12, ?13, ?14,
      ?15, ?16, ?17, ?18,
      ?19, ?20, ?21, ?22,
      ?23, ?24, ?25, ?26,
      ?27, ?28, ?29,
      ?30, ?31, ?32, ?33
    )
    """

    Store.raw_execute(sql, [
      skill_package.id,
      skill_package.tenant_id,
      skill_package.workspace_id,
      Map.get(skill_package, :version, 1),
      skill_package.skill_package_name,
      Map.get(skill_package, :task_family),
      JSON.list(Map.get(skill_package, :competency_links, [])),
      Map.get(skill_package, :risk_class, "low"),
      JSON.list(Map.get(skill_package, :procedural_memory_links, [])),
      JSON.list(Map.get(skill_package, :workflow_links, [])),
      JSON.list(Map.get(skill_package, :validation_links, [])),
      JSON.list(Map.get(skill_package, :evidence_links, [])),
      JSON.map(Map.get(skill_package, :input_contract, %{})),
      JSON.map(Map.get(skill_package, :output_contract, %{})),
      JSON.map(Map.get(skill_package, :execution_policy, %{})),
      JSON.list(Map.get(skill_package, :required_privileges, [])),
      JSON.list(Map.get(skill_package, :tool_requirements, [])),
      Map.get(skill_package, :model_policy_id),
      Map.get(skill_package, :aggregate_confidence, 0.5),
      Map.get(skill_package, :aggregate_precision, 0.5),
      Map.get(skill_package, :review_status, "draft"),
      Map.get(skill_package, :enabled_state, "disabled"),
      Map.get(skill_package, :suspension_reason),
      Map.get(skill_package, :retirement_status, "active"),
      Map.get(skill_package, :valid_time_start),
      Map.get(skill_package, :valid_time_end),
      Map.get(skill_package, :transaction_time_start, timestamp()),
      Map.get(skill_package, :transaction_time_end),
      Map.get(skill_package, :stale_after),
      Map.get(skill_package, :access_policy_id),
      JSON.list(Map.get(skill_package, :security_labels, [])),
      JSON.list(Map.get(skill_package, :partition_ids, [])),
      JSON.map(Map.get(skill_package, :metadata, %{}))
    ])
  end

  @spec insert_model_call_operation(map()) :: :ok | {:error, term()}
  def insert_model_call_operation(operation) when is_map(operation) do
    sql = """
    INSERT OR REPLACE INTO model_call_operations (
      id, tenant_id, workspace_id, function_name, model_task_type,
      execution_mode, risk_class, model_id, model_version, prompt_template_id,
      input_schema, output_contract, execution_policy, storage_target,
      prompt_policy_id, cost_policy, expected_confidence_behavior,
      required_privileges, allowed_partitions, lifecycle_state, rollout_state,
      suspension_reason, retirement_status, valid_time_start, valid_time_end,
      transaction_time_start, transaction_time_end, stale_after,
      access_policy_id, security_labels, partition_ids, metadata, updated_at
    ) VALUES (
      ?1, ?2, ?3, ?4, ?5,
      ?6, ?7, ?8, ?9, ?10,
      ?11, ?12, ?13, ?14,
      ?15, ?16, ?17,
      ?18, ?19, ?20, ?21,
      ?22, ?23, ?24, ?25,
      ?26, ?27, ?28,
      ?29, ?30, ?31, ?32, datetime('now')
    )
    """

    Store.raw_execute(sql, [
      operation.id,
      operation.tenant_id,
      operation.workspace_id,
      operation.function_name,
      operation.model_task_type,
      Map.get(operation, :execution_mode, "sync"),
      Map.get(operation, :risk_class, "low"),
      Map.get(operation, :model_id),
      Map.get(operation, :model_version),
      Map.get(operation, :prompt_template_id),
      JSON.map(Map.get(operation, :input_schema, %{})),
      JSON.map(Map.get(operation, :output_contract, %{})),
      JSON.map(Map.get(operation, :execution_policy, %{})),
      JSON.map(Map.get(operation, :storage_target, %{})),
      Map.get(operation, :prompt_policy_id),
      JSON.map(Map.get(operation, :cost_policy, %{})),
      JSON.map(Map.get(operation, :expected_confidence_behavior, %{})),
      JSON.list(Map.get(operation, :required_privileges, [])),
      JSON.list(Map.get(operation, :allowed_partitions, [])),
      Map.get(operation, :lifecycle_state, "draft"),
      Map.get(operation, :rollout_state, "disabled"),
      Map.get(operation, :suspension_reason),
      Map.get(operation, :retirement_status, "active"),
      Map.get(operation, :valid_time_start),
      Map.get(operation, :valid_time_end),
      Map.get(operation, :transaction_time_start, timestamp()),
      Map.get(operation, :transaction_time_end),
      Map.get(operation, :stale_after),
      Map.get(operation, :access_policy_id),
      JSON.list(Map.get(operation, :security_labels, [])),
      JSON.list(Map.get(operation, :partition_ids, [])),
      JSON.map(Map.get(operation, :metadata, %{}))
    ])
  end

  @spec insert_mcp_tool_definition(map()) :: :ok | {:error, term()}
  def insert_mcp_tool_definition(definition) when is_map(definition) do
    sql = """
    INSERT OR REPLACE INTO mcp_tool_definitions (
      id, tenant_id, workspace_id, tool_name, protocol_adapter_id,
      implementation_type, enabled_state, registration_source,
      documentation_links, required_privileges, allowed_partitions,
      input_schema, output_schema, execution_policy, routing_policy,
      timeout_policy, cost_policy, audit_policy, lifecycle_state,
      suspension_reason, retirement_status, valid_time_start, valid_time_end,
      transaction_time_start, transaction_time_end, stale_after,
      access_policy_id, security_labels, partition_ids, policy_version,
      metadata, updated_at
    ) VALUES (
      ?1, ?2, ?3, ?4, ?5,
      ?6, ?7, ?8,
      ?9, ?10, ?11,
      ?12, ?13, ?14, ?15,
      ?16, ?17, ?18, ?19,
      ?20, ?21, ?22, ?23,
      ?24, ?25, ?26,
      ?27, ?28, ?29, ?30,
      ?31, datetime('now')
    )
    """

    Store.raw_execute(sql, [
      definition.id,
      definition.tenant_id,
      definition.workspace_id,
      definition.tool_name,
      Map.get(definition, :protocol_adapter_id, "mcp"),
      definition.implementation_type,
      Map.get(definition, :enabled_state, "disabled"),
      Map.get(definition, :registration_source),
      JSON.list(Map.get(definition, :documentation_links, [])),
      JSON.list(Map.get(definition, :required_privileges, [])),
      JSON.list(Map.get(definition, :allowed_partitions, [])),
      JSON.map(Map.get(definition, :input_schema, %{})),
      JSON.map(Map.get(definition, :output_schema, %{})),
      JSON.map(Map.get(definition, :execution_policy, %{})),
      JSON.map(Map.get(definition, :routing_policy, %{})),
      JSON.map(Map.get(definition, :timeout_policy, %{})),
      JSON.map(Map.get(definition, :cost_policy, %{})),
      JSON.map(Map.get(definition, :audit_policy, %{})),
      Map.get(definition, :lifecycle_state, "draft"),
      Map.get(definition, :suspension_reason),
      Map.get(definition, :retirement_status, "active"),
      Map.get(definition, :valid_time_start),
      Map.get(definition, :valid_time_end),
      Map.get(definition, :transaction_time_start, timestamp()),
      Map.get(definition, :transaction_time_end),
      Map.get(definition, :stale_after),
      Map.get(definition, :access_policy_id),
      JSON.list(Map.get(definition, :security_labels, [])),
      JSON.list(Map.get(definition, :partition_ids, [])),
      Map.get(definition, :policy_version),
      JSON.map(Map.get(definition, :metadata, %{}))
    ])
  end

  @spec get_model_call_operation(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def get_model_call_operation(workspace_id, function_name)
      when is_binary(workspace_id) and is_binary(function_name) do
    sql = """
    SELECT id, tenant_id, workspace_id, function_name, model_task_type,
           execution_mode, risk_class, model_id, model_version, prompt_template_id,
           input_schema, output_contract, execution_policy, storage_target,
           prompt_policy_id, cost_policy, expected_confidence_behavior,
           required_privileges, allowed_partitions, lifecycle_state, rollout_state,
           suspension_reason, retirement_status, access_policy_id, security_labels,
           partition_ids, metadata
    FROM model_call_operations
    WHERE workspace_id = ?1 AND function_name = ?2
    """

    case Store.raw_query(sql, [workspace_id, function_name]) do
      {:ok, [row]} -> {:ok, model_call_operation_from_row(row)}
      {:ok, []} -> {:error, :not_found}
      other -> other
    end
  end

  @spec get_mcp_tool_definition(String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def get_mcp_tool_definition(workspace_id, tool_name, protocol_adapter_id \\ "mcp")
      when is_binary(workspace_id) and is_binary(tool_name) and is_binary(protocol_adapter_id) do
    sql = """
    SELECT id, tenant_id, workspace_id, tool_name, protocol_adapter_id,
           implementation_type, enabled_state, registration_source,
           documentation_links, required_privileges, allowed_partitions,
           input_schema, output_schema, execution_policy, routing_policy,
           timeout_policy, cost_policy, audit_policy, lifecycle_state,
           suspension_reason, retirement_status, access_policy_id, security_labels,
           partition_ids, policy_version, metadata
    FROM mcp_tool_definitions
    WHERE workspace_id = ?1 AND tool_name = ?2 AND protocol_adapter_id = ?3
    """

    case Store.raw_query(sql, [workspace_id, tool_name, protocol_adapter_id]) do
      {:ok, [row]} -> {:ok, mcp_tool_definition_from_row(row)}
      {:ok, []} -> {:error, :not_found}
      other -> other
    end
  end

  @spec insert_model_call_run(map()) :: :ok | {:error, term()}
  def insert_model_call_run(run) when is_map(run) do
    sql = """
    INSERT INTO model_call_runs (
      id, tenant_id, workspace_id, model_call_operation_id, function_name,
      requesting_actor_id, active_memory_pool_id, decision_state, run_status,
      rejection_reason, input_payload, output_payload, input_hash, output_hash,
      required_privileges, granted_privileges, requested_partitions,
      allowed_partitions, policy_decision, latency_ms, cost_units,
      source_package_links, observation_links, audit_event_links,
      access_policy_id, security_labels, partition_ids, metadata
    ) VALUES (
      ?1, ?2, ?3, ?4, ?5,
      ?6, ?7, ?8, ?9,
      ?10, ?11, ?12, ?13, ?14,
      ?15, ?16, ?17,
      ?18, ?19, ?20, ?21,
      ?22, ?23, ?24,
      ?25, ?26, ?27, ?28
    )
    """

    Store.raw_execute(sql, run_record_params(run, :model_call_operation_id, :function_name))
  end

  @spec insert_tool_call_run(map()) :: :ok | {:error, term()}
  def insert_tool_call_run(run) when is_map(run) do
    sql = """
    INSERT INTO tool_call_runs (
      id, tenant_id, workspace_id, mcp_tool_definition_id, tool_name,
      requesting_actor_id, active_memory_pool_id, decision_state, run_status,
      rejection_reason, input_payload, output_payload, input_hash, output_hash,
      required_privileges, granted_privileges, requested_partitions,
      allowed_partitions, policy_decision, latency_ms, cost_units,
      source_package_links, observation_links, audit_event_links,
      access_policy_id, security_labels, partition_ids, metadata
    ) VALUES (
      ?1, ?2, ?3, ?4, ?5,
      ?6, ?7, ?8, ?9,
      ?10, ?11, ?12, ?13, ?14,
      ?15, ?16, ?17,
      ?18, ?19, ?20, ?21,
      ?22, ?23, ?24,
      ?25, ?26, ?27, ?28
    )
    """

    Store.raw_execute(sql, run_record_params(run, :mcp_tool_definition_id, :tool_name))
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

  defp run_record_params(run, definition_id_key, operation_name_key) do
    [
      run.id,
      run.tenant_id,
      run.workspace_id,
      Map.get(run, definition_id_key),
      Map.get(run, operation_name_key),
      Map.get(run, :requesting_actor_id),
      Map.get(run, :active_memory_pool_id),
      run.decision_state,
      Map.get(run, :run_status, "recorded"),
      Map.get(run, :rejection_reason),
      JSON.map(Map.get(run, :input_payload, %{})),
      JSON.map(Map.get(run, :output_payload, %{})),
      Map.get(run, :input_hash),
      Map.get(run, :output_hash),
      JSON.list(Map.get(run, :required_privileges, [])),
      JSON.list(Map.get(run, :granted_privileges, [])),
      JSON.list(Map.get(run, :requested_partitions, [])),
      JSON.list(Map.get(run, :allowed_partitions, [])),
      JSON.map(Map.get(run, :policy_decision, %{})),
      Map.get(run, :latency_ms),
      Map.get(run, :cost_units),
      JSON.list(Map.get(run, :source_package_links, [])),
      JSON.list(Map.get(run, :observation_links, [])),
      JSON.list(Map.get(run, :audit_event_links, [])),
      Map.get(run, :access_policy_id),
      JSON.list(Map.get(run, :security_labels, [])),
      JSON.list(Map.get(run, :partition_ids, [])),
      JSON.map(Map.get(run, :metadata, %{}))
    ]
  end

  defp model_call_operation_from_row([
         id,
         tenant_id,
         workspace_id,
         function_name,
         model_task_type,
         execution_mode,
         risk_class,
         model_id,
         model_version,
         prompt_template_id,
         input_schema,
         output_contract,
         execution_policy,
         storage_target,
         prompt_policy_id,
         cost_policy,
         expected_confidence_behavior,
         required_privileges,
         allowed_partitions,
         lifecycle_state,
         rollout_state,
         suspension_reason,
         retirement_status,
         access_policy_id,
         security_labels,
         partition_ids,
         metadata
       ]) do
    %{
      id: id,
      tenant_id: tenant_id,
      workspace_id: workspace_id,
      function_name: function_name,
      model_task_type: model_task_type,
      execution_mode: execution_mode,
      risk_class: risk_class,
      model_id: model_id,
      model_version: model_version,
      prompt_template_id: prompt_template_id,
      input_schema: decode_map(input_schema),
      output_contract: decode_map(output_contract),
      execution_policy: decode_map(execution_policy),
      storage_target: decode_map(storage_target),
      prompt_policy_id: prompt_policy_id,
      cost_policy: decode_map(cost_policy),
      expected_confidence_behavior: decode_map(expected_confidence_behavior),
      required_privileges: decode_list(required_privileges),
      allowed_partitions: decode_list(allowed_partitions),
      lifecycle_state: lifecycle_state,
      rollout_state: rollout_state,
      suspension_reason: suspension_reason,
      retirement_status: retirement_status,
      access_policy_id: access_policy_id,
      security_labels: decode_list(security_labels),
      partition_ids: decode_list(partition_ids),
      metadata: decode_map(metadata)
    }
  end

  defp mcp_tool_definition_from_row([
         id,
         tenant_id,
         workspace_id,
         tool_name,
         protocol_adapter_id,
         implementation_type,
         enabled_state,
         registration_source,
         documentation_links,
         required_privileges,
         allowed_partitions,
         input_schema,
         output_schema,
         execution_policy,
         routing_policy,
         timeout_policy,
         cost_policy,
         audit_policy,
         lifecycle_state,
         suspension_reason,
         retirement_status,
         access_policy_id,
         security_labels,
         partition_ids,
         policy_version,
         metadata
       ]) do
    %{
      id: id,
      tenant_id: tenant_id,
      workspace_id: workspace_id,
      tool_name: tool_name,
      protocol_adapter_id: protocol_adapter_id,
      implementation_type: implementation_type,
      enabled_state: enabled_state,
      registration_source: registration_source,
      documentation_links: decode_list(documentation_links),
      required_privileges: decode_list(required_privileges),
      allowed_partitions: decode_list(allowed_partitions),
      input_schema: decode_map(input_schema),
      output_schema: decode_map(output_schema),
      execution_policy: decode_map(execution_policy),
      routing_policy: decode_map(routing_policy),
      timeout_policy: decode_map(timeout_policy),
      cost_policy: decode_map(cost_policy),
      audit_policy: decode_map(audit_policy),
      lifecycle_state: lifecycle_state,
      suspension_reason: suspension_reason,
      retirement_status: retirement_status,
      access_policy_id: access_policy_id,
      security_labels: decode_list(security_labels),
      partition_ids: decode_list(partition_ids),
      policy_version: policy_version,
      metadata: decode_map(metadata)
    }
  end

  defp decode_map(nil), do: %{}
  defp decode_map(""), do: %{}

  defp decode_map(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> %{}
    end
  end

  defp decode_list(nil), do: []
  defp decode_list(""), do: []

  defp decode_list(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} when is_list(decoded) -> decoded
      {:ok, decoded} -> [decoded]
      _ -> []
    end
  end

  defp timestamp, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
