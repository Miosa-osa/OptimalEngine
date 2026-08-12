defmodule OptimalEngine.DataStewardTest do
  use ExUnit.Case, async: false

  alias OptimalEngine.DataSteward

  test "dashboard exposes every governed remediation queue without mutation" do
    workspace = "default:miosa"

    assert {:ok, dashboard} = DataSteward.dashboard(workspace)
    assert dashboard.workspace_id == workspace
    assert is_list(dashboard.claim_clusters)
    assert is_list(dashboard.route_clusters)
    assert is_list(dashboard.entity_clusters)
    assert is_list(dashboard.orphan_scopes)
    assert "acceptance requires explicit identifiers" in dashboard.invariants
  end

  test "empty bulk decisions are rejected by the interface" do
    assert_raise FunctionClauseError, fn ->
      DataSteward.decide_claims([], :accept,
        workspace_id: "default:miosa",
        actor_id: "user:test"
      )
    end

    assert_raise FunctionClauseError, fn ->
      DataSteward.decide_routes([], :reject, actor_id: "user:test")
    end
  end
end
