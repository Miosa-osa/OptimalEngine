defmodule OptimalEngine.Viability.Systems do
  @moduledoc """
  The five systems of Beer's Viable System Model, read from what a workspace
  or an org actually has and does in the Engine.

  | System | Looks for |
  | --- | --- |
  | 1 Operations | units (nodes, or workspaces for an org) receiving Signals in the last 30 days |
  | 2 Coordination | rhythm templates, routing rules, a declared repertoire, and their recent use |
  | 3 Control | open loops being closed, overdue share, daily rhythm notes |
  | 3* Audit | audit samples in the last 14 days and their review |
  | 4 Intelligence | outward Signals (market, customers, competitors, technology, risk) in the last 30 days |
  | 5 Policy | an active policy pack and an org protocol instead of Engine defaults |

  Each system is `present`, `degraded` (configured but idle or strained), or
  `missing`, with the evidence it was judged on. A system that is not present
  carries the failure mode it predicts: the paper's prediction P3 where the
  paper names one (Systems 2, 4, 5), otherwise the Engine's diagnosis.
  """

  alias OptimalEngine.Operating.Protocol
  alias OptimalEngine.Store

  @failures %{
    "s1" => {"No operations: Signals arrive but no unit acts on them.", "engine"},
    "s2" => {"Cross-team misalignment.", "paper P3"},
    "s3" =>
      {"Drift: commitments and priorities go unmanaged and overdue work accumulates.", "engine"},
    "s3_star" => {"Undetected decay: problems surface only when something fails.", "engine"},
    "s4" => {"Blindsided by change.", "paper P3"},
    "s5" => {"Inconsistent encoding standards.", "paper P3"}
  }

  @doc """
  Evaluates the systems. `scope` is `:workspace` or `:org`; `today` is the
  reference date.
  """
  @spec evaluate(String.t(), [String.t()], :workspace | :org, Date.t()) :: [map()]
  def evaluate(_tenant_id, [], _scope, _today), do: []

  def evaluate(tenant_id, workspace_ids, scope, today) do
    q = query(tenant_id, workspace_ids)

    [
      operations(q, scope, today),
      coordination(q, today),
      control(q, today),
      audit(q, today),
      intelligence(q, today),
      policy(q, scope)
    ]
  end

  @doc "The failure mode each system predicts when it is not present."
  @spec failures() :: map()
  def failures, do: @failures

  # -- System 1 ----------------------------------------------------------------

  defp operations(q, scope, today) do
    unit = if scope == :org, do: "c.workspace_id", else: "c.node"

    rows =
      q.all.(
        """
        SELECT #{unit}, COUNT(*) FROM contexts c
        WHERE c.workspace_id IN (#{q.ws}) AND c.type = 'signal' AND c.archived_at IS NULL
          AND substr(COALESCE(c.created_at, c.indexed_at), 1, 10) >= ?#{q.next}
        GROUP BY 1 ORDER BY 2 DESC
        """,
        [days_ago(today, 30)]
      )

    total = Enum.reduce(rows, 0, fn [_unit, count], acc -> acc + count end)
    units = Enum.map(rows, fn [unit, count] -> %{unit: unit, signals: count} end)

    findings =
      case units do
        [%{signals: top} = first, _ | _] when top / total > 0.5 ->
          [
            "One unit (#{first.unit}) carries #{round(top / total * 100)} percent of Signals in 30 days: a bottleneck."
          ]

        _ ->
          []
      end

    status = if units == [], do: "missing", else: "present"

    system("s1", "System 1: Operations", status, %{
      evidence:
        if(units == [],
          do: ["No unit received Signals in 30 days."],
          else: ["#{length(units)} active units, #{total} Signals in 30 days."]
        ),
      findings: findings,
      units: Enum.take(units, 20)
    })
  end

  # -- System 2 ----------------------------------------------------------------

  defp coordination(q, today) do
    templates =
      q.one.(
        "SELECT COUNT(*) FROM rhythm_templates WHERE tenant_id = ?1 AND workspace_id IN (#{q.ws})",
        []
      )

    notes =
      q.one.(
        """
        SELECT COUNT(*) FROM rhythm_notes WHERE tenant_id = ?1 AND workspace_id IN (#{q.ws})
          AND substr(updated_at, 1, 10) >= ?#{q.next}
        """,
        [days_ago(today, 14)]
      )

    rules =
      q.one.(
        "SELECT COUNT(*) FROM routing_rules WHERE tenant_id = ?1 AND workspace_id IN (#{q.ws})",
        []
      )

    accepted =
      q.one.(
        "SELECT COALESCE(SUM(accepted), 0) FROM routing_rules WHERE tenant_id = ?1 AND workspace_id IN (#{q.ws})",
        []
      )

    repertoire = Enum.count(q.workspace_ids, &custom_document?(q.tenant_id, &1, "repertoire"))
    configured = templates + rules + repertoire
    in_use = notes + accepted

    status =
      cond do
        configured == 0 -> "missing"
        in_use == 0 -> "degraded"
        true -> "present"
      end

    system("s2", "System 2: Coordination", status, %{
      evidence: [
        "#{templates} rhythm templates, #{notes} rhythm notes in 14 days.",
        "#{rules} routing rules (#{accepted} accepted routings).",
        "#{repertoire} declared repertoires; the Engine genre registry is always available."
      ],
      findings:
        if(status == "degraded",
          do: ["Coordination is configured but not in use in the last 14 days."],
          else: []
        )
    })
  end

  # -- System 3 ----------------------------------------------------------------

  defp control(q, today) do
    today_iso = Date.to_iso8601(today)

    [open, overdue, closed_30, total] =
      q.row.(
        """
        SELECT
          COALESCE(SUM(CASE WHEN state = 'open' THEN 1 ELSE 0 END), 0),
          COALESCE(SUM(CASE WHEN state = 'open' AND due_at IS NOT NULL AND substr(due_at, 1, 10) < ?#{q.next} THEN 1 ELSE 0 END), 0),
          COALESCE(SUM(CASE WHEN state = 'closed' AND substr(closed_at, 1, 10) >= ?#{q.next + 1} THEN 1 ELSE 0 END), 0),
          COUNT(*)
        FROM open_loops WHERE tenant_id = ?1 AND workspace_id IN (#{q.ws})
        """,
        [today_iso, days_ago(today, 30)]
      )

    briefs =
      q.one.(
        """
        SELECT COUNT(*) FROM rhythm_notes WHERE tenant_id = ?1 AND workspace_id IN (#{q.ws})
          AND cadence = 'daily' AND substr(updated_at, 1, 10) >= ?#{q.next}
        """,
        [days_ago(today, 7)]
      )

    overdue_share = if open > 0, do: overdue / open, else: 0.0

    status =
      cond do
        total == 0 and briefs == 0 -> "missing"
        closed_30 == 0 or overdue_share > 0.5 -> "degraded"
        true -> "present"
      end

    findings =
      [
        if(overdue_share > 0.5,
          do: "#{overdue} of #{open} open loops are overdue."
        ),
        if(total > 0 and closed_30 == 0, do: "No loop was closed in 30 days.")
      ]
      |> Enum.reject(&is_nil/1)

    system("s3", "System 3: Control", status, %{
      evidence: [
        "#{open} open loops, #{overdue} overdue, #{closed_30} closed in 30 days.",
        "#{briefs} daily rhythm notes in 7 days."
      ],
      findings: findings
    })
  end

  # -- System 3* ---------------------------------------------------------------

  defp audit(q, today) do
    recent =
      q.one.(
        "SELECT COUNT(*) FROM audit_samples WHERE tenant_id = ?1 AND workspace_id IN (#{q.ws}) AND substr(created_at, 1, 10) >= ?#{q.next}",
        [days_ago(today, 14)]
      )

    stale_flagged =
      q.one.(
        "SELECT COUNT(*) FROM audit_samples WHERE tenant_id = ?1 AND workspace_id IN (#{q.ws}) AND state = 'flagged' AND substr(created_at, 1, 10) < ?#{q.next}",
        [days_ago(today, 7)]
      )

    last =
      q.one.(
        "SELECT MAX(created_at) FROM audit_samples WHERE tenant_id = ?1 AND workspace_id IN (#{q.ws})",
        []
      )

    status =
      cond do
        recent == 0 -> "missing"
        stale_flagged > 0 -> "degraded"
        true -> "present"
      end

    system("s3_star", "System 3*: Audit", status, %{
      evidence: [
        "#{recent} audit samples in 14 days (last audit: #{last || "never"}).",
        "#{stale_flagged} flagged samples unreviewed for more than 7 days."
      ],
      findings:
        if(stale_flagged > 0, do: ["Flagged audit samples are waiting for review."], else: [])
    })
  end

  # -- System 4 ----------------------------------------------------------------

  defp intelligence(q, today) do
    since = days_ago(today, 30)

    rows =
      q.all.(
        """
        SELECT topic, COUNT(*) FROM (
          SELECT (CASE WHEN json_valid(c.metadata) THEN json_extract(c.metadata, '$.outward') END) AS topic FROM contexts c
          WHERE c.workspace_id IN (#{q.ws}) AND c.archived_at IS NULL
            AND (CASE WHEN json_valid(c.metadata) THEN json_extract(c.metadata, '$.outward') END) IS NOT NULL
            AND substr(COALESCE(c.created_at, c.indexed_at), 1, 10) >= ?#{q.next}
          UNION ALL
          SELECT topic FROM signal_events
          WHERE tenant_id = ?1 AND workspace_id IN (#{q.ws}) AND kind = 'outward'
            AND substr(occurred_at, 1, 10) >= ?#{q.next}
        ) GROUP BY topic ORDER BY 2 DESC
        """,
        [since]
      )

    last =
      q.one.(
        """
        SELECT MAX(at) FROM (
          SELECT COALESCE(c.created_at, c.indexed_at) AS at FROM contexts c
          WHERE c.workspace_id IN (#{q.ws})
            AND (CASE WHEN json_valid(c.metadata) THEN json_extract(c.metadata, '$.outward') END) IS NOT NULL
          UNION ALL
          SELECT occurred_at FROM signal_events
          WHERE tenant_id = ?1 AND workspace_id IN (#{q.ws}) AND kind = 'outward'
        )
        """,
        []
      )

    count = Enum.reduce(rows, 0, fn [_topic, n], acc -> acc + n end)

    system("s4", "System 4: Intelligence", if(count == 0, do: "missing", else: "present"), %{
      evidence:
        if(count == 0,
          do: ["No outward-scan Signals in 30 days (last: #{last || "never"})."],
          else: ["#{count} outward Signals in 30 days (last: #{last})."]
        ),
      findings: [],
      topics: Map.new(rows, fn [topic, n] -> {topic, n} end)
    })
  end

  # -- System 5 ----------------------------------------------------------------

  defp policy(q, scope) do
    packs =
      q.all.(
        """
        SELECT scope_type, scope_id, name, version FROM authority_policies
        WHERE tenant_id = ?1 AND status = 'active'
          AND (scope_type = 'tenant' OR (scope_type = 'workspace' AND scope_id IN (#{q.ws})))
        """,
        []
      )

    protocols =
      if scope == :org,
        do: if(custom_document?(q.tenant_id, nil, "protocol"), do: 1, else: 0),
        else: Enum.count(q.workspace_ids, &custom_document?(q.tenant_id, &1, "protocol"))

    status =
      cond do
        packs == [] and protocols == 0 -> "missing"
        packs == [] or protocols == 0 -> "degraded"
        true -> "present"
      end

    system("s5", "System 5: Policy", status, %{
      evidence: [
        "#{length(packs)} active policy packs.",
        if(protocols > 0,
          do: "An org protocol is set.",
          else: "The protocol is the Engine default."
        )
      ],
      findings:
        case status do
          "missing" -> ["Policy is dormant: only Engine defaults apply."]
          "degraded" -> ["Only one of policy pack and protocol is set."]
          _ -> []
        end,
      packs:
        Enum.map(packs, fn [type, id, name, version] ->
          %{scope: "#{type}:#{id}", name: name, version: version}
        end)
    })
  end

  # ---------------------------------------------------------------------------

  defp system(id, name, status, attrs) do
    base = Map.merge(%{id: id, name: name, status: status}, attrs)

    if status == "present" do
      base
    else
      {failure, source} = Map.fetch!(@failures, id)
      Map.put(base, :predicted_failure, %{failure: failure, source: source})
    end
  end

  defp custom_document?(tenant_id, workspace_id, kind) do
    match?(
      {:ok, %{source: source}} when source != "default",
      Protocol.get(tenant_id, workspace_id, kind)
    )
  end

  # Positional parameters: ?1 tenant, ?2.. workspaces, extra parameters after.
  defp query(tenant_id, workspace_ids) do
    count = length(workspace_ids)
    base = [tenant_id | workspace_ids]
    ws = Enum.map_join(2..(count + 1), ", ", &"?#{&1}")

    all = fn sql, extra ->
      {:ok, rows} = Store.raw_query(sql, base ++ extra)
      rows
    end

    row = fn sql, extra ->
      [row] = all.(sql, extra)
      row
    end

    %{
      tenant_id: tenant_id,
      workspace_ids: workspace_ids,
      ws: ws,
      next: count + 2,
      all: all,
      row: row,
      one: fn sql, extra -> sql |> row.(extra) |> hd() end
    }
  end

  defp days_ago(today, days), do: today |> Date.add(-days) |> Date.to_iso8601()
end
