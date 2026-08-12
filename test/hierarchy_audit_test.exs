defmodule OptimalEngine.HierarchyAuditTest do
  use ExUnit.Case, async: false

  alias OptimalEngine.HierarchyAudit

  test "reports hierarchy invariants through one interface" do
    assert {:ok, audit} = HierarchyAudit.run("default")
    assert is_boolean(audit.ok)
    assert is_integer(audit.issue_count)

    assert Enum.map(audit.checks, & &1.name) == [
             "workspace_organization",
             "workspace_identifiers",
             "node_parents",
             "node_workspace_scope",
             "node_types",
             "relationship_scope"
           ]
  end
end
