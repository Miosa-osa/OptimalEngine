defmodule OptimalEngine.HierarchyAudit do
  @moduledoc "Read-only verification of the Tenant -> Organization -> Workspace -> Node hierarchy."

  alias OptimalEngine.Store

  def run(tenant_id \\ "default") do
    checks = [
      check("workspace_organization", &workspace_organization/0),
      check("workspace_identifiers", fn -> workspace_identifiers(tenant_id) end),
      check("node_parents", &node_parents/0),
      check("node_workspace_scope", &node_workspace_scope/0),
      check("node_types", &node_types/0),
      check("relationship_scope", &relationship_scope/0)
    ]

    {:ok,
     %{
       tenant_id: tenant_id,
       ok: Enum.all?(checks, & &1.ok),
       checks: checks,
       issue_count: Enum.sum(Enum.map(checks, & &1.issue_count))
     }}
  end

  defp workspace_organization do
    query_issues("""
    SELECT w.id, w.organization_id, 'missing_or_wrong_tenant_organization'
    FROM workspaces w
    LEFT JOIN organizations o ON o.id=w.organization_id AND o.tenant_id=w.tenant_id
    WHERE w.status='active' AND (o.id IS NULL OR o.status='archived')
    UNION ALL
    SELECT w.id, w.organization_id, 'active_compatibility_owner'
    FROM workspaces w
    WHERE w.status='active' AND w.organization_id='default'
    """)
  end

  defp workspace_identifiers(tenant_id) do
    query_issues(
      "SELECT id, slug, 'noncanonical_workspace_id' FROM workspaces WHERE tenant_id=?1 AND status='active' AND id != tenant_id || ':' || slug",
      [tenant_id]
    )
  end

  defp node_parents do
    query_issues("""
    SELECT n.id, n.parent_id, 'missing_parent'
    FROM nodes n JOIN workspaces w ON w.id=n.workspace_id AND w.status='active'
    LEFT JOIN nodes p ON p.id=n.parent_id
    WHERE n.lifecycle_state='active' AND n.parent_id IS NOT NULL AND p.id IS NULL
    UNION ALL
    SELECT n.id, n.parent_id, 'self_parent'
    FROM nodes n JOIN workspaces w ON w.id=n.workspace_id AND w.status='active'
    WHERE n.lifecycle_state='active' AND n.id=n.parent_id
    """)
  end

  defp node_workspace_scope do
    query_issues("""
    SELECT n.id, n.workspace_id, 'missing_workspace'
    FROM nodes n LEFT JOIN workspaces w ON w.id=n.workspace_id
    WHERE n.lifecycle_state='active' AND w.id IS NULL
    UNION ALL
    SELECT n.id, n.parent_id, 'cross_workspace_parent'
    FROM nodes n JOIN nodes p ON p.id=n.parent_id
    WHERE n.lifecycle_state='active' AND p.workspace_id != n.workspace_id
    """)
  end

  defp node_types do
    query_issues("""
    SELECT n.id, COALESCE(n.node_type_id, n.kind), 'missing_or_cross_workspace_node_type'
    FROM nodes n JOIN workspaces w ON w.id=n.workspace_id AND w.status='active'
    LEFT JOIN node_types t ON t.id=n.node_type_id
    WHERE n.lifecycle_state='active'
      AND (t.id IS NULL OR t.workspace_id != n.workspace_id OR t.lifecycle_state != 'active')
    """)
  end

  defp relationship_scope do
    query_issues("""
    SELECT r.id, r.workspace_id, 'relationship_endpoint_scope_mismatch'
    FROM node_relationships r
    JOIN nodes s ON s.id=r.source_node_id
    JOIN nodes t ON t.id=r.target_node_id
    WHERE r.lifecycle_state='active'
      AND (s.workspace_id != r.workspace_id OR t.workspace_id != r.workspace_id)
    """)
  end

  defp query_issues(sql, params \\ []) do
    case Store.raw_query(sql, params) do
      {:ok, rows} ->
        {:ok,
         Enum.map(rows, fn [id, related, reason] ->
           %{id: id, related_id: related, reason: reason}
         end)}

      error ->
        error
    end
  end

  defp check(name, fun) do
    case fun.() do
      {:ok, issues} ->
        %{name: name, ok: issues == [], issue_count: length(issues), issues: issues}

      {:error, reason} ->
        %{name: name, ok: false, issue_count: 1, issues: [%{reason: inspect(reason)}]}
    end
  end
end
