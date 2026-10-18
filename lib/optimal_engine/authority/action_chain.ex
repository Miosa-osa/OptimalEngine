defmodule OptimalEngine.Authority.ActionChain do
  @moduledoc """
  The evidence chain of an agent action: request, approval or denial,
  action, result, and reply, linked in one place.

  Each step is recorded three ways at once:

    * a row in `authority_action_steps`, numbered within its correlation id
      and pointing at the step it follows (`causation_id`);
    * an Engine Signal (genre `audit-trail`, node `agent-actions`) whose
      metadata carries the envelope's correlation and causation ids, so the
      chain is searchable and readable like any other Signal;
    * an `agent_action.step` entry in the signed authority evidence chain,
      carrying the step's canonical SHA-256 and the evidence hash of the step
      before it.

  Steps can be reported by an outside approval system (MIOSA) or by the
  Engine's own callers. `trace/2` also follows the Engine's native authority
  flow (approval request, approval, grant, admission, release) by request id
  or grant id, so both kinds of chain read the same way.
  """

  alias OptimalEngine.Authority.{CanonicalJSON, Evidence}
  alias OptimalEngine.Store

  @stages ~w(request approval denial action result reply)
  @signal_types %{
    "request" => "direct",
    "approval" => "decide",
    "denial" => "decide",
    "action" => "commit",
    "result" => "inform",
    "reply" => "inform"
  }

  @doc "The step stages."
  @spec stages() :: [String.t()]
  def stages, do: @stages

  @doc """
  Records a step. `attrs`: `workspace_id`, `stage`, `correlation_id`
  (generated for a `request`), and optionally `agent`, `action`, `resource`,
  `summary`, `detail` (map; `jti` and `request_id` link native authority
  evidence), `causation_id`, `occurred_at`.
  """
  @spec record(String.t(), map(), String.t()) :: {:ok, map()} | {:error, atom()}
  def record(tenant_id, attrs, recorded_by) do
    attrs = Map.new(attrs, fn {key, value} -> {to_string(key), value} end)

    with {:ok, workspace_id} <-
           present(attrs["workspace_id"] || attrs["workspace"], :workspace_required),
         {:ok, stage} <- stage(attrs["stage"]),
         {:ok, correlation_id} <- correlation(stage, attrs["correlation_id"]),
         previous = steps(tenant_id, correlation_id),
         :ok <- order(stage, previous, workspace_id),
         {:ok, occurred_at} <- occurred_at(attrs["occurred_at"]) do
      last = List.last(previous)
      first = List.first(previous)
      detail = if is_map(attrs["detail"]), do: attrs["detail"], else: %{}

      step = %{
        "id" => "stp_" <> random_id(),
        "workspace_id" => workspace_id,
        "correlation_id" => correlation_id,
        "seq" => length(previous) + 1,
        "stage" => stage,
        "agent" => attrs["agent"] || (first && first["agent"]) || recorded_by,
        "action" => attrs["action"] || (first && first["action"]),
        "resource" => attrs["resource"] || (first && first["resource"]),
        "summary" => attrs["summary"] || default_summary(stage, attrs, first),
        "detail" => detail,
        "causation_id" => attrs["causation_id"] || (last && last["id"]),
        "occurred_at" => occurred_at
      }

      step_hash = CanonicalJSON.hash(step)
      context_id = "sig_" <> step["id"]

      {:ok, _} =
        Store.transaction(fn txn -> insert(txn, tenant_id, step, context_id, recorded_by) end)

      evidence =
        Evidence.append(tenant_id, "agent_action.step", %{
          jti: detail["jti"],
          subject: step["agent"],
          action: step["action"],
          resource: step["resource"],
          workspace_id: workspace_id,
          detail: %{
            "correlation_id" => correlation_id,
            "causation_id" => step["causation_id"],
            "stage" => stage,
            "seq" => step["seq"],
            "step_id" => step["id"],
            "context_id" => context_id,
            "step_sha256" => step_hash,
            "prev_step_evidence" => last && last["evidence_hash"],
            "request_id" => detail["request_id"],
            "recorded_by" => recorded_by
          }
        })

      case evidence do
        {:ok, entry} ->
          {:ok, _} =
            Store.raw_query(
              "UPDATE authority_action_steps SET evidence_id = ?2, evidence_hash = ?3 WHERE id = ?1",
              [step["id"], entry["id"], entry["hash"]]
            )

          {:ok,
           step
           |> Map.merge(%{
             "context_id" => context_id,
             "step_sha256" => step_hash,
             "evidence_id" => entry["id"],
             "evidence_hash" => entry["hash"],
             "recorded_by" => recorded_by
           })}

        {:error, reason} ->
          {:error, {:evidence_failed, reason}}
      end
    end
  end

  @doc """
  The chain for a correlation id, an Engine approval request id, or a grant
  id: ordered steps, stage coverage, verification, and findings.
  """
  @spec trace(String.t(), String.t()) :: {:ok, map()} | {:error, :not_found}
  def trace(tenant_id, id) do
    steps =
      case steps(tenant_id, id) do
        [] -> tenant_id |> correlation_for(id) |> then(&if(&1, do: steps(tenant_id, &1), else: []))
        found -> found
      end

    linked = linked_ids(steps, id)
    native = native_entries(tenant_id, linked)

    if steps == [] and native == [] do
      {:error, :not_found}
    else
      step_entries = step_evidence(tenant_id, steps)

      reported =
        Enum.map(steps, fn step ->
          entry = Map.get(step_entries, step["evidence_id"])

          step
          |> Map.put("source", "reported")
          |> Map.put("verified", verified(tenant_id, entry, step))
        end)

      native_steps =
        native
        |> Enum.map(&native_step(tenant_id, &1))
        |> Enum.reject(&is_nil/1)

      ordered = Enum.sort_by(reported ++ native_steps, & &1["occurred_at"])
      stages = MapSet.new(ordered, & &1["stage"])

      {:ok,
       %{
         id: id,
         correlation_id: steps |> List.first() |> then(&(&1 && &1["correlation_id"])),
         workspace_id: Enum.find_value(ordered, & &1["workspace_id"]),
         stages: Map.new(@stages, &{&1, MapSet.member?(stages, &1)}),
         complete: complete?(stages),
         verified: Enum.all?(ordered, &(&1["verified"] == true)),
         findings: findings(ordered, stages),
         steps: ordered
       }}
    end
  end

  @doc "Recent chains for workspaces, newest first."
  @spec list(String.t(), [String.t()], keyword()) :: [map()]
  def list(tenant_id, workspace_ids, opts \\ []) do
    limit = opts |> Keyword.get(:limit, 50) |> max(1) |> min(500)
    placeholders = Enum.map_join(1..length(workspace_ids), ", ", &"?#{&1 + 1}")

    {:ok, rows} =
      Store.raw_query(
        """
        SELECT correlation_id, workspace_id, MIN(occurred_at), MAX(occurred_at), COUNT(*),
               group_concat(stage), MAX(agent), MAX(action)
        FROM authority_action_steps
        WHERE tenant_id = ?1 AND workspace_id IN (#{placeholders})
        GROUP BY correlation_id, workspace_id
        ORDER BY MAX(occurred_at) DESC LIMIT #{limit}
        """,
        [tenant_id | workspace_ids]
      )

    Enum.map(rows, fn [correlation, ws, first, last, count, stages, agent, action] ->
      stage_set = stages |> String.split(",") |> MapSet.new()

      %{
        correlation_id: correlation,
        workspace_id: ws,
        started_at: first,
        last_at: last,
        steps: count,
        stages: MapSet.to_list(stage_set),
        complete: complete?(stage_set),
        agent: agent,
        action: action
      }
    end)
  end

  # -- recording ---------------------------------------------------------------

  defp insert(txn, tenant_id, step, context_id, recorded_by) do
    title =
      "Agent action #{step["stage"]}: #{step["action"] || "action"}" <>
        if(step["resource"], do: " on #{step["resource"]}", else: "")

    content =
      step["summary"] <>
        if(step["detail"] == %{},
          do: "",
          else: "\n\n" <> Jason.encode!(step["detail"], pretty: true)
        )

    metadata = %{
      "agent_action" => %{
        "correlation_id" => step["correlation_id"],
        "causation_id" => step["causation_id"],
        "stage" => step["stage"],
        "seq" => step["seq"],
        "step_id" => step["id"]
      },
      "correlation_id" => step["correlation_id"],
      "causation_id" => step["causation_id"],
      "agent" => step["agent"]
    }

    {:ok, _} =
      Store.txn_execute(
        txn,
        """
        INSERT INTO contexts
          (id, uri, type, title, l0_abstract, content, mode, genre, signal_type, format, structure,
           node, sn_ratio, created_at, modified_at, metadata, tenant_id, workspace_id, created_by)
        VALUES (?1, ?2, 'signal', ?3, ?4, ?5, 'linguistic', 'audit-trail', ?6, 'markdown', '',
                'agent-actions', 0.8, ?7, ?7, ?8, ?9, ?10, ?11)
        """,
        [
          context_id,
          "optimal://agent-actions/#{step["correlation_id"]}/#{step["seq"]}",
          title,
          step["summary"],
          content,
          Map.fetch!(@signal_types, step["stage"]),
          step["occurred_at"],
          Jason.encode!(metadata),
          tenant_id,
          step["workspace_id"],
          recorded_by
        ]
      )

    Store.txn_execute(
      txn,
      """
      INSERT INTO authority_action_steps
        (id, tenant_id, workspace_id, correlation_id, seq, stage, agent, action, resource, summary,
         detail, causation_id, context_id, recorded_by, occurred_at)
      VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15)
      """,
      [
        step["id"],
        tenant_id,
        step["workspace_id"],
        step["correlation_id"],
        step["seq"],
        step["stage"],
        step["agent"],
        step["action"],
        step["resource"],
        step["summary"],
        Jason.encode!(step["detail"]),
        step["causation_id"],
        context_id,
        recorded_by,
        step["occurred_at"]
      ]
    )
  end

  defp order("request", [], _workspace_id), do: :ok
  defp order("request", _previous, _workspace_id), do: {:error, :already_requested}
  defp order(_stage, [], _workspace_id), do: {:error, :request_required}

  defp order(_stage, [first | _], workspace_id) do
    if first["workspace_id"] == workspace_id, do: :ok, else: {:error, :workspace_mismatch}
  end

  defp default_summary(stage, attrs, first) do
    action = attrs["action"] || (first && first["action"]) || "an action"
    "#{String.capitalize(stage)} for #{action}."
  end

  # -- tracing -----------------------------------------------------------------

  defp steps(tenant_id, correlation_id) do
    {:ok, rows} =
      Store.raw_query(
        """
        SELECT id, workspace_id, correlation_id, seq, stage, agent, action, resource, summary,
               detail, causation_id, context_id, evidence_id, evidence_hash, recorded_by, occurred_at
        FROM authority_action_steps WHERE tenant_id = ?1 AND correlation_id = ?2 ORDER BY seq
        """,
        [tenant_id, correlation_id]
      )

    Enum.map(rows, fn [
                        id,
                        ws,
                        corr,
                        seq,
                        stage,
                        agent,
                        action,
                        resource,
                        summary,
                        detail,
                        cause,
                        ctx,
                        ev_id,
                        ev_hash,
                        by,
                        at
                      ] ->
      %{
        "id" => id,
        "workspace_id" => ws,
        "correlation_id" => corr,
        "seq" => seq,
        "stage" => stage,
        "agent" => agent,
        "action" => action,
        "resource" => resource,
        "summary" => summary,
        "detail" => Jason.decode!(detail),
        "causation_id" => cause,
        "context_id" => ctx,
        "evidence_id" => ev_id,
        "evidence_hash" => ev_hash,
        "recorded_by" => by,
        "occurred_at" => at
      }
    end)
  end

  # The correlation id of reported steps that name a request id or grant id.
  defp correlation_for(tenant_id, id) do
    case Store.raw_query(
           """
           SELECT correlation_id FROM authority_action_steps
           WHERE tenant_id = ?1 AND (json_extract(detail, '$.jti') = ?2 OR json_extract(detail, '$.request_id') = ?2)
           ORDER BY occurred_at LIMIT 1
           """,
           [tenant_id, id]
         ) do
      {:ok, [[correlation_id]]} -> correlation_id
      _ -> nil
    end
  end

  # Request ids and grant ids a chain points at, plus the id traced.
  defp linked_ids(steps, id) do
    from_steps =
      Enum.flat_map(steps, fn step -> [step["detail"]["jti"], step["detail"]["request_id"]] end)

    [id | from_steps] |> Enum.reject(&is_nil/1) |> Enum.uniq()
  end

  defp native_entries(_tenant_id, []), do: []

  defp native_entries(tenant_id, ids) do
    marks = Enum.map_join(0..(length(ids) - 1), ", ", &"?#{&1 + 2}")

    requests =
      Evidence.where(
        tenant_id,
        "kind <> 'agent_action.step' AND (json_extract(detail, '$.request_id') IN (#{marks}) OR json_extract(detail, '$.approval') IN (#{marks}) OR jti IN (#{marks}))",
        ids
      )

    jtis =
      requests
      |> Enum.filter(&(&1["kind"] in ["grant.issued", "grant.narrowed"]))
      |> Enum.map(& &1["jti"])
      |> Enum.reject(&(&1 in ids or is_nil(&1)))

    more =
      case jtis do
        [] ->
          []

        _ ->
          jti_marks = Enum.map_join(0..(length(jtis) - 1), ", ", &"?#{&1 + 2}")
          Evidence.where(tenant_id, "kind <> 'agent_action.step' AND jti IN (#{jti_marks})", jtis)
      end

    Enum.uniq_by(requests ++ more, & &1["id"])
  end

  @native_stages %{
    "approval.requested" => "request",
    "approval.approved" => "approval",
    "approval.denied" => "denial",
    "decision.denied" => "denial",
    "grant.issued" => "approval",
    "grant.denied" => "denial",
    "grant.admitted" => "action",
    "action.completed" => "result",
    "action.withheld" => "result"
  }

  defp native_step(tenant_id, entry) do
    case Map.get(@native_stages, entry["kind"]) do
      nil ->
        nil

      stage ->
        %{
          "id" => entry["id"],
          "stage" => stage,
          "evidence_kind" => entry["kind"],
          "workspace_id" => entry["workspace_id"],
          "agent" => entry["subject"],
          "action" => entry["action"],
          "resource" => entry["resource"],
          "jti" => entry["jti"],
          "detail" => entry["detail"],
          "evidence_id" => entry["id"],
          "evidence_hash" => entry["hash"],
          "occurred_at" => entry["recorded_at"],
          "source" => "engine",
          "verified" => Evidence.verify_one(tenant_id, entry) == :ok
        }
    end
  end

  defp step_evidence(_tenant_id, []), do: %{}

  defp step_evidence(tenant_id, steps) do
    ids = steps |> Enum.map(& &1["evidence_id"]) |> Enum.reject(&is_nil/1)

    case ids do
      [] ->
        %{}

      _ ->
        marks = Enum.map_join(0..(length(ids) - 1), ", ", &"?#{&1 + 2}")

        tenant_id
        |> Evidence.where("id IN (#{marks})", ids)
        |> Map.new(&{&1["id"], &1})
    end
  end

  # A reported step is verified when its evidence entry exists, is intact and
  # signed, and still matches the step row.
  defp verified(_tenant_id, nil, _step), do: false

  defp verified(tenant_id, entry, step) do
    canonical =
      step
      |> Map.take(
        ~w(id workspace_id correlation_id seq stage agent action resource summary detail causation_id occurred_at)
      )
      |> CanonicalJSON.hash()

    Evidence.verify_one(tenant_id, entry) == :ok and
      entry["detail"]["step_sha256"] == canonical and
      entry["detail"]["step_id"] == step["id"]
  end

  defp complete?(stages) do
    request? = MapSet.member?(stages, "request")

    cond do
      request? and MapSet.member?(stages, "denial") ->
        true

      request? and MapSet.member?(stages, "approval") and MapSet.member?(stages, "action") and
          MapSet.member?(stages, "result") ->
        true

      true ->
        false
    end
  end

  defp findings(ordered, stages) do
    [
      if(not MapSet.member?(stages, "request"), do: "No request step is recorded."),
      if(MapSet.member?(stages, "action") and not MapSet.member?(stages, "approval"),
        do: "An action is recorded without an approval."
      ),
      if(MapSet.member?(stages, "denial") and MapSet.member?(stages, "action"),
        do: "An action is recorded after a denial."
      ),
      if(MapSet.member?(stages, "action") and not MapSet.member?(stages, "result"),
        do: "The action has no recorded result yet."
      ),
      if(Enum.any?(ordered, &(&1["verified"] != true)),
        do: "At least one step does not verify against the signed evidence."
      )
    ]
    |> Enum.reject(&is_nil/1)
  end

  # ---------------------------------------------------------------------------

  defp present(value, _error) when is_binary(value) and value != "", do: {:ok, value}
  defp present(_value, error), do: {:error, error}

  defp stage(stage) when stage in @stages, do: {:ok, stage}
  defp stage(_stage), do: {:error, :invalid_stage}

  defp correlation(_stage, id) when is_binary(id) and id != "" do
    if Regex.match?(~r/^[A-Za-z0-9._:-]{1,128}$/, id),
      do: {:ok, id},
      else: {:error, :invalid_correlation_id}
  end

  defp correlation("request", _id), do: {:ok, "act_" <> random_id()}
  defp correlation(_stage, _id), do: {:error, :correlation_required}

  defp occurred_at(nil),
    do: {:ok, DateTime.utc_now() |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601()}

  defp occurred_at(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _offset} -> {:ok, DateTime.to_iso8601(at)}
      _ -> {:error, :invalid_occurred_at}
    end
  end

  defp occurred_at(_value), do: {:error, :invalid_occurred_at}

  defp random_id, do: :crypto.strong_rand_bytes(12) |> Base.encode16(case: :lower)
end
