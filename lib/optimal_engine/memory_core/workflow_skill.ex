defmodule OptimalEngine.MemoryCore.WorkflowSkill do
  @moduledoc """
  Workflow and Skill Package lifecycle for Memory Core.

  This module turns observed work into governed procedural knowledge. It keeps
  each step conservative:

  * Active Pool state becomes a Workflow Trace.
  * A trace can become a candidate Generalized Workflow.
  * A generalized workflow can become a candidate Procedural Memory Object.
  * A procedure can become a draft Skill Package.

  None of those steps makes a skill executable by default. A package starts
  disabled until review/policy enables it.
  """

  alias OptimalEngine.MemoryCore.{
    ActiveMemoryPool,
    DerivationLedgerEntry,
    ID,
    Store
  }

  @spec capture_trace_from_pool(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def capture_trace_from_pool(pool_id, opts \\ []) when is_binary(pool_id) do
    with {:ok, pool} <- ActiveMemoryPool.get(pool_id) do
      now = timestamp()
      pool_ref = ref("active_memory_pool", pool.id)

      trace = %{
        id:
          ID.content_id("wft", [
            pool.tenant_id,
            ":",
            pool.workspace_id,
            ":",
            pool.id,
            ":",
            Keyword.get(opts, :workflow_family) || pool.task_type || "workflow"
          ]),
        tenant_id: pool.tenant_id,
        workspace_id: pool.workspace_id,
        case_id: string_opt(opts, :case_id, pool.id),
        workflow_family: string_opt(opts, :workflow_family, pool.task_type || "workflow"),
        subject_anchor: string_or_nil(Keyword.get(opts, :subject_anchor) || pool.subject_anchor),
        action_class: string_or_nil(Keyword.get(opts, :action_class)),
        outcome: string_or_nil(Keyword.get(opts, :outcome)),
        episode_links: normalize_links(Keyword.get(opts, :episode_links, [])),
        step_links: normalize_links(Keyword.get(opts, :step_links, [])),
        actor_links:
          normalize_links(
            pool.member_links ++ pool.agent_links ++ Keyword.get(opts, :actor_links, [])
          ),
        input_links:
          normalize_links(
            pool.loaded_context_links ++
              pool.context_package_links ++ Keyword.get(opts, :input_links, [])
          ),
        output_links:
          normalize_links(pool.promotion_candidate_links ++ Keyword.get(opts, :output_links, [])),
        source_package_links:
          normalize_links(pool.source_package_links ++ Keyword.get(opts, :source_package_links, [])),
        evidence_links:
          normalize_links(pool.evidence_links ++ Keyword.get(opts, :evidence_links, [])),
        aggregate_confidence: Keyword.get(opts, :aggregate_confidence, 0.55),
        aggregate_precision: Keyword.get(opts, :aggregate_precision, 0.55),
        lifecycle_state: string_opt(opts, :lifecycle_state, "extracted"),
        validation_status: string_opt(opts, :validation_status, "unvalidated"),
        event_time_start: Keyword.get(opts, :event_time_start) || pool.opened_at,
        event_time_end: Keyword.get(opts, :event_time_end) || pool.closed_at,
        valid_time_start: Keyword.get(opts, :valid_time_start),
        valid_time_end: Keyword.get(opts, :valid_time_end),
        transaction_time_start: now,
        transaction_time_end: nil,
        stale_after: Keyword.get(opts, :stale_after),
        access_policy_id: pool.access_policy_id,
        security_labels: pool.security_labels,
        partition_ids: pool.partition_ids,
        metadata:
          Map.merge(Keyword.get(opts, :metadata, %{}), %{
            active_memory_pool_id: pool.id,
            source: "active_memory_pool"
          })
      }

      trace_ref = ref("workflow_trace", trace.id)

      ledger =
        ledger(
          "memory_core.capture_workflow_trace",
          "active_pool_to_workflow_trace",
          [pool_ref],
          [trace_ref],
          trace,
          opts,
          evidence_links: trace.evidence_links,
          metadata: %{workflow_family: trace.workflow_family}
        )

      with :ok <- Store.insert_workflow_trace(trace),
           :ok <- Store.insert_derivation_entry(ledger) do
        {:ok, trace}
      end
    end
  end

  @spec generalize_workflow(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def generalize_workflow(trace, opts \\ []) when is_map(trace) do
    now = timestamp()
    trace_ref = ref("workflow_trace", trace.id)

    workflow = %{
      id:
        ID.content_id("gwf", [
          trace.tenant_id,
          ":",
          trace.workspace_id,
          ":",
          trace.workflow_family,
          ":",
          trace.subject_anchor || "",
          ":",
          Keyword.get(opts, :version_basis, trace.id)
        ]),
      tenant_id: trace.tenant_id,
      workspace_id: trace.workspace_id,
      workflow_family: string_opt(opts, :workflow_family, trace.workflow_family),
      scope: Keyword.get(opts, :scope, %{}),
      applicability_conditions: Keyword.get(opts, :applicability_conditions, %{}),
      outcome_class: string_or_nil(Keyword.get(opts, :outcome_class) || trace.outcome),
      workflow_trace_links: [trace_ref],
      supporting_episode_links: Keyword.get(opts, :supporting_episode_links, []),
      contradicting_trace_links: Keyword.get(opts, :contradicting_trace_links, []),
      step_pattern_links: Keyword.get(opts, :step_pattern_links, trace.step_links || []),
      aggregate_confidence: Keyword.get(opts, :aggregate_confidence, trace.aggregate_confidence),
      aggregate_precision: Keyword.get(opts, :aggregate_precision, trace.aggregate_precision),
      validation_score: Keyword.get(opts, :validation_score, 0.0),
      lifecycle_state: string_opt(opts, :lifecycle_state, "candidate"),
      validation_status: string_opt(opts, :validation_status, "unvalidated"),
      supersession_status: string_opt(opts, :supersession_status, "none"),
      valid_time_start: Keyword.get(opts, :valid_time_start),
      valid_time_end: Keyword.get(opts, :valid_time_end),
      transaction_time_start: now,
      transaction_time_end: nil,
      stale_after: Keyword.get(opts, :stale_after),
      access_policy_id: Map.get(trace, :access_policy_id),
      security_labels: Map.get(trace, :security_labels, []),
      partition_ids: Map.get(trace, :partition_ids, []),
      metadata: Keyword.get(opts, :metadata, %{})
    }

    workflow_ref = ref("generalized_workflow", workflow.id)

    with :ok <- Store.insert_generalized_workflow(workflow),
         :ok <-
           Store.insert_derivation_entry(
             ledger(
               "memory_core.generalize_workflow",
               "workflow_trace_to_generalized_workflow",
               [trace_ref],
               [workflow_ref],
               workflow,
               opts,
               evidence_links: Map.get(trace, :evidence_links, []),
               metadata: %{workflow_family: workflow.workflow_family}
             )
           ) do
      {:ok, workflow}
    end
  end

  @spec create_procedural_memory(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def create_procedural_memory(workflow, opts \\ []) when is_map(workflow) do
    now = timestamp()
    workflow_ref = ref("generalized_workflow", workflow.id)
    capability_name = string_opt(opts, :capability_name, workflow.workflow_family)

    procedure = %{
      id:
        ID.content_id("pmo", [
          workflow.tenant_id,
          ":",
          workflow.workspace_id,
          ":",
          capability_name,
          ":",
          workflow.id
        ]),
      tenant_id: workflow.tenant_id,
      workspace_id: workflow.workspace_id,
      capability_name: capability_name,
      task_family: string_or_nil(Keyword.get(opts, :task_family) || workflow.workflow_family),
      applicability_conditions:
        Keyword.get(opts, :applicability_conditions, workflow.applicability_conditions || %{}),
      risk_class: string_opt(opts, :risk_class, "low"),
      generalized_workflow_links: [workflow_ref],
      step_links: Keyword.get(opts, :step_links, workflow.step_pattern_links || []),
      validation_links: Keyword.get(opts, :validation_links, []),
      evidence_links: Keyword.get(opts, :evidence_links, [workflow_ref]),
      aggregate_confidence: Keyword.get(opts, :aggregate_confidence, workflow.aggregate_confidence),
      aggregate_precision: Keyword.get(opts, :aggregate_precision, workflow.aggregate_precision),
      validation_confidence: Keyword.get(opts, :validation_confidence, workflow.validation_score),
      required_privileges: Keyword.get(opts, :required_privileges, []),
      lifecycle_state: string_opt(opts, :lifecycle_state, "candidate"),
      validation_status: string_opt(opts, :validation_status, "unvalidated"),
      retirement_status: string_opt(opts, :retirement_status, "active"),
      valid_time_start: Keyword.get(opts, :valid_time_start),
      valid_time_end: Keyword.get(opts, :valid_time_end),
      transaction_time_start: now,
      transaction_time_end: nil,
      stale_after: Keyword.get(opts, :stale_after),
      access_policy_id: Map.get(workflow, :access_policy_id),
      security_labels: Map.get(workflow, :security_labels, []),
      partition_ids: Map.get(workflow, :partition_ids, []),
      metadata: Keyword.get(opts, :metadata, %{})
    }

    procedure_ref = ref("procedural_memory_object", procedure.id)

    with :ok <- Store.insert_procedural_memory_object(procedure),
         :ok <-
           Store.insert_derivation_entry(
             ledger(
               "memory_core.create_procedural_memory",
               "generalized_workflow_to_procedural_memory",
               [workflow_ref],
               [procedure_ref],
               procedure,
               opts,
               evidence_links: procedure.evidence_links,
               metadata: %{capability_name: procedure.capability_name}
             )
           ) do
      {:ok, procedure}
    end
  end

  @spec package_skill(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def package_skill(procedure, opts \\ []) when is_map(procedure) do
    now = timestamp()
    procedure_ref = ref("procedural_memory_object", procedure.id)
    version = Keyword.get(opts, :version, 1)
    name = string_opt(opts, :skill_package_name, procedure.capability_name)

    skill_package = %{
      id:
        ID.content_id("skillpkg", [
          procedure.tenant_id,
          ":",
          procedure.workspace_id,
          ":",
          name,
          ":",
          version
        ]),
      tenant_id: procedure.tenant_id,
      workspace_id: procedure.workspace_id,
      version: version,
      skill_package_name: name,
      task_family: string_or_nil(Keyword.get(opts, :task_family) || procedure.task_family),
      competency_links: Keyword.get(opts, :competency_links, []),
      risk_class: string_opt(opts, :risk_class, procedure.risk_class || "low"),
      procedural_memory_links: [procedure_ref],
      workflow_links:
        Keyword.get(opts, :workflow_links, procedure.generalized_workflow_links || []),
      validation_links: Keyword.get(opts, :validation_links, procedure.validation_links || []),
      evidence_links:
        Keyword.get(opts, :evidence_links, procedure.evidence_links || [procedure_ref]),
      input_contract: Keyword.get(opts, :input_contract, %{}),
      output_contract: Keyword.get(opts, :output_contract, %{}),
      execution_policy: Keyword.get(opts, :execution_policy, %{}),
      required_privileges:
        Keyword.get(opts, :required_privileges, procedure.required_privileges || []),
      tool_requirements: Keyword.get(opts, :tool_requirements, []),
      model_policy_id: string_or_nil(Keyword.get(opts, :model_policy_id)),
      aggregate_confidence:
        Keyword.get(opts, :aggregate_confidence, procedure.aggregate_confidence),
      aggregate_precision: Keyword.get(opts, :aggregate_precision, procedure.aggregate_precision),
      review_status: string_opt(opts, :review_status, "draft"),
      enabled_state: string_opt(opts, :enabled_state, "disabled"),
      suspension_reason: string_or_nil(Keyword.get(opts, :suspension_reason)),
      retirement_status: string_opt(opts, :retirement_status, "active"),
      valid_time_start: Keyword.get(opts, :valid_time_start),
      valid_time_end: Keyword.get(opts, :valid_time_end),
      transaction_time_start: now,
      transaction_time_end: nil,
      stale_after: Keyword.get(opts, :stale_after),
      access_policy_id: Map.get(procedure, :access_policy_id),
      security_labels: Map.get(procedure, :security_labels, []),
      partition_ids: Map.get(procedure, :partition_ids, []),
      metadata: Keyword.get(opts, :metadata, %{})
    }

    skill_ref = ref("skill_package", skill_package.id)

    with :ok <- Store.insert_skill_package(skill_package),
         :ok <-
           Store.insert_derivation_entry(
             ledger(
               "memory_core.package_skill",
               "procedural_memory_to_skill_package",
               [procedure_ref],
               [skill_ref],
               skill_package,
               opts,
               evidence_links: skill_package.evidence_links,
               metadata: %{
                 skill_package_name: skill_package.skill_package_name,
                 enabled_state: skill_package.enabled_state
               }
             )
           ) do
      {:ok, skill_package}
    end
  end

  defp ledger(activity_type, stage, input_links, output_links, scope, opts, extra_opts) do
    DerivationLedgerEntry.new(
      activity_type,
      stage,
      input_links,
      output_links,
      tenant_id: scope.tenant_id,
      workspace_id: scope.workspace_id,
      evidence_links: Keyword.get(extra_opts, :evidence_links, []),
      actor_id: Keyword.get(opts, :actor_id),
      evaluator_id: Keyword.get(opts, :evaluator_id),
      confidence_delta: Map.get(scope, :aggregate_confidence),
      precision_delta: Map.get(scope, :aggregate_precision),
      access_policy_id: Map.get(scope, :access_policy_id),
      security_labels: Map.get(scope, :security_labels, []),
      partition_ids: Map.get(scope, :partition_ids, []),
      metadata: Keyword.get(extra_opts, :metadata, %{})
    )
  end

  defp ref(type, id), do: %{type: type, id: id}

  defp normalize_links(values) do
    values
    |> List.wrap()
    |> Enum.map(&normalize_link/1)
    |> Enum.uniq()
  end

  defp normalize_link(%{type: type, id: id}), do: ref(to_string(type), to_string(id))
  defp normalize_link(%{"type" => type, "id" => id}), do: ref(to_string(type), to_string(id))
  defp normalize_link(value), do: value

  defp timestamp, do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp string_opt(opts, key, default), do: Keyword.get(opts, key, default) |> to_string()

  defp string_or_nil(nil), do: nil
  defp string_or_nil(""), do: nil
  defp string_or_nil(value), do: to_string(value)
end
