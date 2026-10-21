defmodule OptimalEngine.Authority.EvidenceWhereTest do
  @moduledoc """
  `Evidence.where/3` returns every entry its condition matches, not the first
  thousand, so an agent action chain of any length verifies: a trace reads
  the evidence entry of each of its steps through it.
  """

  use ExUnit.Case, async: false

  alias OptimalEngine.Authority.{ActionChain, CanonicalJSON, Evidence}
  alias OptimalEngine.Store
  alias OptimalEngine.Tenancy.Tenant

  setup do
    n = System.unique_integer([:positive])
    tenant = "where-#{n}"
    {:ok, _} = Tenant.create(%{id: tenant, name: "Where #{n}"})
    %{tenant: tenant, workspace: "#{tenant}:ops"}
  end

  test "returns every matching entry, oldest first, past one page", %{tenant: tenant} do
    for i <- 1..1_500 do
      {:ok, _} = Evidence.append(tenant, "settings.changed", %{detail: %{"i" => i}})
      if rem(i, 500) == 0, do: {:ok, _} = Evidence.append(tenant, "key.rotated", %{detail: %{}})
    end

    entries = Evidence.where(tenant, "kind = 'settings.changed'", [])
    assert Enum.map(entries, & &1["detail"]["i"]) == Enum.to_list(1..1_500)

    assert length(Evidence.where(tenant, "json_extract(detail, '$.i') > ?2", [1_000])) == 500

    assert Evidence.where(
             tenant,
             "kind = 'settings.changed' AND json_extract(detail, '$.i') < 0",
             []
           ) == []

    assert length(Evidence.where(tenant, "kind = 'key.rotated'", [])) == 3
  end

  # Writes a chain the way `ActionChain.record/3` does (a row per step and a
  # signed `agent_action.step` entry carrying the step's SHA-256), without its
  # per-step read of the steps before, which would make 1,500 of them slow.
  defp seed_chain(tenant, workspace, steps) do
    correlation = "act_seeded"

    Enum.reduce(1..steps, nil, fn seq, previous ->
      step = %{
        "id" => "stp_seed_#{seq}",
        "workspace_id" => workspace,
        "correlation_id" => correlation,
        "seq" => seq,
        "stage" => if(seq == 1, do: "request", else: "reply"),
        "agent" => "agent:sweeper",
        "action" => "sweep",
        "resource" => nil,
        "summary" => "Step #{seq}.",
        "detail" => %{},
        "causation_id" => previous,
        "occurred_at" =>
          "2026-10-20T10:00:00.#{String.pad_leading(Integer.to_string(seq), 6, "0")}Z"
      }

      {:ok, entry} =
        Evidence.append(tenant, "agent_action.step", %{
          subject: step["agent"],
          action: step["action"],
          workspace_id: workspace,
          detail: %{
            "correlation_id" => correlation,
            "stage" => step["stage"],
            "seq" => seq,
            "step_id" => step["id"],
            "step_sha256" => CanonicalJSON.hash(step)
          }
        })

      {:ok, _} =
        Store.raw_query(
          """
          INSERT INTO authority_action_steps
            (id, tenant_id, workspace_id, correlation_id, seq, stage, agent, action, resource,
             summary, detail, causation_id, evidence_id, evidence_hash, recorded_by, occurred_at)
          VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, NULL, ?9, '{}', ?10, ?11, ?12, ?13, ?14)
          """,
          [
            step["id"],
            tenant,
            workspace,
            correlation,
            seq,
            step["stage"],
            step["agent"],
            step["action"],
            step["summary"],
            previous,
            entry["id"],
            entry["hash"],
            step["agent"],
            step["occurred_at"]
          ]
        )

      step["id"]
    end)

    correlation
  end

  test "a chain of 1,500 steps verifies, every step", %{tenant: tenant, workspace: workspace} do
    correlation = seed_chain(tenant, workspace, 1_500)

    {:ok, trace} = ActionChain.trace(tenant, correlation)
    assert length(trace.steps) == 1_500
    assert Enum.count(trace.steps, &(&1["verified"] != true)) == 0
    assert trace.verified
    assert {:ok, _} = Evidence.verify(tenant)
  end
end
