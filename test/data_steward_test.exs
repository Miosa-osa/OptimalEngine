defmodule OptimalEngine.DataStewardTest do
  use ExUnit.Case, async: false

  alias OptimalEngine.Authority.Evidence
  alias OptimalEngine.{DataSteward, Workspace}

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

  test "renaming a workspace's id moves every slug it holds to the new id" do
    n = System.unique_integer([:positive])
    old = "steward-old-#{n}"
    new = "steward-new-#{n}"
    {:ok, workspace} = Workspace.create(%{slug: old, name: "Steward #{n}"})

    # A rename changes the slug and keeps the id; the steward then makes the
    # id match the slug.
    {:ok, _} = Workspace.update(workspace.id, %{slug: new})
    target = "default:" <> new

    assert {:ok, result} =
             DataSteward.rename_workspace(workspace.id, target, actor_id: "user:test")

    assert result.handles_moved == 2
    assert Enum.sort(Workspace.handles(target)) == Enum.sort([old, new])
    assert Workspace.handles(workspace.id) == []
    assert {:ok, %{id: ^target, slug: ^new}} = Workspace.get_by_handle(old, "default")
    assert {:ok, %{id: ^target}} = Workspace.get_by_handle(new, "default")

    # The handles are moved by their own step, not as one more table.
    assert Enum.count(result.tables, &(&1.table == "workspace_handles")) == 0
  end

  test "renaming a workspace's id leaves its signed evidence as it was written" do
    n = System.unique_integer([:positive])
    {:ok, workspace} = Workspace.create(%{slug: "steward-ev-old-#{n}", name: "Steward #{n}"})

    # The rename is recorded in the evidence chain, naming the workspace's id.
    {:ok, _} = Workspace.update(workspace.id, %{slug: "steward-ev-new-#{n}"})

    assert {:ok, result} =
             DataSteward.rename_workspace(workspace.id, "default:steward-ev-new-#{n}",
               actor_id: "user:test"
             )

    # An evidence entry is hashed and signed over the workspace id it names, so
    # it keeps the id it had; a rewritten row would no longer verify.
    assert Enum.count(result.tables, &(&1.table == "authority_evidence")) == 0

    assert [entry] =
             "default"
             |> Evidence.list(kind: "workspace.renamed")
             |> Enum.filter(&(&1["workspace_id"] == workspace.id))

    assert :ok = Evidence.verify_one("default", entry)
    assert {:ok, _} = Evidence.verify("default")
  end
end
