defmodule OptimalEngine.MemoryCore.ToolModelGovernance do
  @moduledoc """
  First Tool/Model governance runtime slice.

  This module does not execute external tools or models. It proves the control
  plane:

  * definitions are registered as governed catalog objects;
  * attempted calls are validated before they are allowed;
  * allowed and rejected attempts are recorded as durable run rows;
  * optional outputs can become Active Memory Pool observations.
  """

  alias OptimalEngine.Audit.Logger, as: AuditLogger

  alias OptimalEngine.MemoryCore.{
    ActiveMemoryPool,
    ID,
    Store
  }

  @spec register_model_call_operation(keyword()) :: {:ok, map()} | {:error, term()}
  def register_model_call_operation(opts) when is_list(opts) do
    tenant_id = string_opt(opts, :tenant_id, "default")
    workspace_id = string_opt(opts, :workspace_id, "default")
    function_name = string_opt(opts, :function_name, nil)
    model_task_type = string_opt(opts, :model_task_type, "generation")

    operation = %{
      id:
        ID.content_id("mco", [
          tenant_id,
          ":",
          workspace_id,
          ":",
          function_name,
          ":",
          model_task_type
        ]),
      tenant_id: tenant_id,
      workspace_id: workspace_id,
      function_name: function_name,
      model_task_type: model_task_type,
      execution_mode: string_opt(opts, :execution_mode, "sync"),
      risk_class: string_opt(opts, :risk_class, "low"),
      model_id: string_or_nil(Keyword.get(opts, :model_id)),
      model_version: string_or_nil(Keyword.get(opts, :model_version)),
      prompt_template_id: string_or_nil(Keyword.get(opts, :prompt_template_id)),
      input_schema: Keyword.get(opts, :input_schema, %{}),
      output_contract: Keyword.get(opts, :output_contract, %{}),
      execution_policy: Keyword.get(opts, :execution_policy, %{}),
      storage_target: Keyword.get(opts, :storage_target, %{}),
      prompt_policy_id: string_or_nil(Keyword.get(opts, :prompt_policy_id)),
      cost_policy: Keyword.get(opts, :cost_policy, %{}),
      expected_confidence_behavior: Keyword.get(opts, :expected_confidence_behavior, %{}),
      required_privileges: list_opt(opts, :required_privileges),
      allowed_partitions: list_opt(opts, :allowed_partitions),
      lifecycle_state: string_opt(opts, :lifecycle_state, "active"),
      rollout_state: string_opt(opts, :rollout_state, "enabled"),
      suspension_reason: string_or_nil(Keyword.get(opts, :suspension_reason)),
      retirement_status: string_opt(opts, :retirement_status, "active"),
      transaction_time_start: timestamp(),
      access_policy_id: string_or_nil(Keyword.get(opts, :access_policy_id)),
      security_labels: list_opt(opts, :security_labels),
      partition_ids: list_opt(opts, :partition_ids),
      metadata: Keyword.get(opts, :metadata, %{})
    }

    with :ok <- Store.insert_model_call_operation(operation) do
      {:ok, operation}
    end
  end

  @spec register_mcp_tool_definition(keyword()) :: {:ok, map()} | {:error, term()}
  def register_mcp_tool_definition(opts) when is_list(opts) do
    tenant_id = string_opt(opts, :tenant_id, "default")
    workspace_id = string_opt(opts, :workspace_id, "default")
    tool_name = string_opt(opts, :tool_name, nil)
    protocol_adapter_id = string_opt(opts, :protocol_adapter_id, "mcp")

    definition = %{
      id:
        ID.content_id("mcp_tool", [
          tenant_id,
          ":",
          workspace_id,
          ":",
          protocol_adapter_id,
          ":",
          tool_name
        ]),
      tenant_id: tenant_id,
      workspace_id: workspace_id,
      tool_name: tool_name,
      protocol_adapter_id: protocol_adapter_id,
      implementation_type: string_opt(opts, :implementation_type, "external"),
      enabled_state: string_opt(opts, :enabled_state, "enabled"),
      registration_source: string_or_nil(Keyword.get(opts, :registration_source)),
      documentation_links: list_opt(opts, :documentation_links),
      required_privileges: list_opt(opts, :required_privileges),
      allowed_partitions: list_opt(opts, :allowed_partitions),
      input_schema: Keyword.get(opts, :input_schema, %{}),
      output_schema: Keyword.get(opts, :output_schema, %{}),
      execution_policy: Keyword.get(opts, :execution_policy, %{}),
      routing_policy: Keyword.get(opts, :routing_policy, %{}),
      timeout_policy: Keyword.get(opts, :timeout_policy, %{}),
      cost_policy: Keyword.get(opts, :cost_policy, %{}),
      audit_policy: Keyword.get(opts, :audit_policy, %{}),
      lifecycle_state: string_opt(opts, :lifecycle_state, "active"),
      suspension_reason: string_or_nil(Keyword.get(opts, :suspension_reason)),
      retirement_status: string_opt(opts, :retirement_status, "active"),
      transaction_time_start: timestamp(),
      access_policy_id: string_or_nil(Keyword.get(opts, :access_policy_id)),
      security_labels: list_opt(opts, :security_labels),
      partition_ids: list_opt(opts, :partition_ids),
      policy_version: string_or_nil(Keyword.get(opts, :policy_version)),
      metadata: Keyword.get(opts, :metadata, %{})
    }

    with :ok <- Store.insert_mcp_tool_definition(definition) do
      {:ok, definition}
    end
  end

  @spec record_model_call(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def record_model_call(function_name, input_payload, opts \\ [])
      when is_binary(function_name) and is_map(input_payload) do
    workspace_id = string_opt(opts, :workspace_id, "default")

    case Store.get_model_call_operation(workspace_id, function_name) do
      {:ok, operation} ->
        decision = decide(operation, input_payload, opts, :model)
        run = build_model_run(operation, input_payload, decision, opts)
        persist_run(run, decision, opts, :model)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec record_tool_call(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def record_tool_call(tool_name, input_payload, opts \\ [])
      when is_binary(tool_name) and is_map(input_payload) do
    workspace_id = string_opt(opts, :workspace_id, "default")
    protocol_adapter_id = string_opt(opts, :protocol_adapter_id, "mcp")

    case Store.get_mcp_tool_definition(workspace_id, tool_name, protocol_adapter_id) do
      {:ok, definition} ->
        decision = decide(definition, input_payload, opts, :tool)
        run = build_tool_run(definition, input_payload, decision, opts)
        persist_run(run, decision, opts, :tool)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp persist_run(run, decision, opts, kind) do
    run =
      if decision.allowed? do
        attach_observation(run, opts)
      else
        run
      end

    insert_result =
      case kind do
        :model -> Store.insert_model_call_run(run)
        :tool -> Store.insert_tool_call_run(run)
      end

    with :ok <- insert_result do
      log_audit(run, kind)
      {:ok, run}
    end
  end

  defp attach_observation(run, opts) do
    observation_text = Keyword.get(opts, :observation_text)
    pool_id = Map.get(run, :active_memory_pool_id)

    cond do
      is_nil(observation_text) or observation_text == "" ->
        run

      is_nil(pool_id) ->
        run

      true ->
        case ActiveMemoryPool.publish_observation(pool_id, observation_text,
               actor_id: Map.get(run, :requesting_actor_id),
               source_type: "tool_model_output",
               claim_text: Keyword.get(opts, :claim_text, observation_text),
               subject_anchor: Keyword.get(opts, :subject_anchor),
               action_class: Keyword.get(opts, :action_class),
               object_anchor: Keyword.get(opts, :object_anchor),
               observation_kind: "tool_model_output"
             ) do
          {:ok, observation} ->
            run
            |> Map.put(:source_package_links, [
              %{type: "source_package", id: observation.source_package.id}
            ])
            |> Map.put(:observation_links, [%{type: "claim", id: observation.pending_claim.id}])

          _ ->
            run
        end
    end
  end

  defp decide(definition, input_payload, opts, kind) do
    state_check = state_check(definition, kind)
    privilege_check = subset_check(Map.get(definition, :required_privileges, []), list_opt(opts, :granted_privileges))
    partition_check = subset_check(list_opt(opts, :requested_partitions), Map.get(definition, :allowed_partitions, []))
    input_check = required_input_check(input_payload, Map.get(definition, :input_schema, %{}))

    checks = [
      state_check,
      privilege_check,
      partition_check,
      input_check
    ]

    reasons =
      checks
      |> Enum.reject(&elem(&1, 0))
      |> Enum.map(&elem(&1, 1))

    %{
      allowed?: reasons == [],
      rejection_reason: Enum.join(reasons, "; "),
      checks: %{
        state: elem(state_check, 0),
        privileges: elem(privilege_check, 0),
        partitions: elem(partition_check, 0),
        input_schema: elem(input_check, 0)
      }
    }
  end

  defp state_check(%{lifecycle_state: "active", rollout_state: "enabled"}, :model), do: {true, nil}
  defp state_check(%{lifecycle_state: "active", enabled_state: "enabled"}, :tool), do: {true, nil}
  defp state_check(_definition, _kind), do: {false, "definition_not_enabled"}

  defp subset_check([], _available), do: {true, nil}

  defp subset_check(required, available) do
    missing = Enum.reject(required, &(&1 in available))

    case missing do
      [] -> {true, nil}
      _ -> {false, "missing:#{Enum.join(missing, ",")}"}
    end
  end

  defp required_input_check(payload, schema) do
    required = Map.get(schema, "required") || Map.get(schema, :required) || []
    payload_keys = Enum.map(Map.keys(payload), &to_string/1)
    missing = required |> Enum.map(&to_string/1) |> Enum.reject(&(&1 in payload_keys))

    case missing do
      [] -> {true, nil}
      _ -> {false, "missing_input:#{Enum.join(missing, ",")}"}
    end
  end

  defp build_model_run(operation, input_payload, decision, opts) do
    output_payload = Keyword.get(opts, :output_payload, %{})

    %{
      id: ID.random_id("modelrun"),
      tenant_id: operation.tenant_id,
      workspace_id: operation.workspace_id,
      model_call_operation_id: operation.id,
      function_name: operation.function_name,
      requesting_actor_id: string_or_nil(Keyword.get(opts, :actor_id)),
      active_memory_pool_id: string_or_nil(Keyword.get(opts, :active_memory_pool_id)),
      decision_state: decision_state(decision),
      run_status: run_status(decision, output_payload),
      rejection_reason: reject_reason(decision),
      input_payload: input_payload,
      output_payload: output_payload,
      input_hash: payload_hash(input_payload),
      output_hash: payload_hash(output_payload),
      required_privileges: operation.required_privileges,
      granted_privileges: list_opt(opts, :granted_privileges),
      requested_partitions: list_opt(opts, :requested_partitions),
      allowed_partitions: operation.allowed_partitions,
      policy_decision: decision,
      latency_ms: Keyword.get(opts, :latency_ms),
      cost_units: Keyword.get(opts, :cost_units),
      source_package_links: [],
      observation_links: [],
      access_policy_id: operation.access_policy_id,
      security_labels: operation.security_labels,
      partition_ids: operation.partition_ids,
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  defp build_tool_run(definition, input_payload, decision, opts) do
    output_payload = Keyword.get(opts, :output_payload, %{})

    %{
      id: ID.random_id("toolrun"),
      tenant_id: definition.tenant_id,
      workspace_id: definition.workspace_id,
      mcp_tool_definition_id: definition.id,
      tool_name: definition.tool_name,
      requesting_actor_id: string_or_nil(Keyword.get(opts, :actor_id)),
      active_memory_pool_id: string_or_nil(Keyword.get(opts, :active_memory_pool_id)),
      decision_state: decision_state(decision),
      run_status: run_status(decision, output_payload),
      rejection_reason: reject_reason(decision),
      input_payload: input_payload,
      output_payload: output_payload,
      input_hash: payload_hash(input_payload),
      output_hash: payload_hash(output_payload),
      required_privileges: definition.required_privileges,
      granted_privileges: list_opt(opts, :granted_privileges),
      requested_partitions: list_opt(opts, :requested_partitions),
      allowed_partitions: definition.allowed_partitions,
      policy_decision: decision,
      latency_ms: Keyword.get(opts, :latency_ms),
      cost_units: Keyword.get(opts, :cost_units),
      source_package_links: [],
      observation_links: [],
      access_policy_id: definition.access_policy_id,
      security_labels: definition.security_labels,
      partition_ids: definition.partition_ids,
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  defp decision_state(%{allowed?: true}), do: "allowed"
  defp decision_state(_decision), do: "rejected"

  defp run_status(%{allowed?: false}, _output_payload), do: "rejected"
  defp run_status(_decision, output_payload) when map_size(output_payload) == 0, do: "approved"
  defp run_status(_decision, _output_payload), do: "completed"

  defp reject_reason(%{allowed?: true}), do: nil
  defp reject_reason(%{rejection_reason: reason}), do: reason

  defp log_audit(run, kind) do
    AuditLogger.log("#{kind}.call.governed",
      tenant_id: run.tenant_id,
      principal: run.requesting_actor_id || "system",
      target_uri: "#{kind}:#{run.workspace_id}:#{run.id}",
      metadata: %{
        workspace_id: run.workspace_id,
        decision_state: run.decision_state,
        run_status: run.run_status,
        rejection_reason: run.rejection_reason
      }
    )
  end

  defp payload_hash(payload), do: Jason.encode!(payload) |> ID.sha256()

  defp timestamp, do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp list_opt(opts, key), do: Keyword.get(opts, key, []) |> List.wrap() |> Enum.map(&to_string/1)

  defp string_opt(opts, key, nil) do
    case Keyword.get(opts, key) do
      nil -> nil
      value -> to_string(value)
    end
  end

  defp string_opt(opts, key, default), do: Keyword.get(opts, key, default) |> to_string()

  defp string_or_nil(nil), do: nil
  defp string_or_nil(""), do: nil
  defp string_or_nil(value), do: to_string(value)
end
