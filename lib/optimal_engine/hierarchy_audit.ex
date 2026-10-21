defmodule OptimalEngine.HierarchyAudit do
  @moduledoc "Read-only verification of the Tenant -> Organization -> Workspace -> Node hierarchy."

  alias OptimalEngine.Store

  def run(tenant_id \\ "default") do
    checks = [
      check("workspace_organization", fn -> workspace_organization(tenant_id) end),
      check("workspace_identifiers", fn -> workspace_identifiers(tenant_id) end),
      check("node_parents", fn -> node_parents(tenant_id) end),
      check("node_workspace_scope", fn -> node_workspace_scope(tenant_id) end),
      check("node_types", fn -> node_types(tenant_id) end),
      check("relationship_scope", fn -> relationship_scope(tenant_id) end)
    ]

    {:ok,
     %{
       tenant_id: tenant_id,
       ok: Enum.all?(checks, & &1.ok),
       checks: checks,
       issue_count: Enum.sum(Enum.map(checks, & &1.issue_count))
     }}
  end

  defp workspace_organization(tenant_id) do
    query_issues(
      """
      SELECT w.id, w.organization_id, 'missing_or_wrong_tenant_organization'
      FROM workspaces w
      LEFT JOIN organizations o ON o.id=w.organization_id AND o.tenant_id=w.tenant_id
      WHERE w.tenant_id=?1 AND w.status='active' AND (o.id IS NULL OR o.status='archived')
      UNION ALL
      SELECT w.id, w.organization_id, 'active_compatibility_owner'
      FROM workspaces w
      WHERE w.tenant_id=?1 AND w.status='active' AND w.organization_id='default'
      """,
      [tenant_id]
    )
  end

  # A renamed workspace keeps its id (OptimalEngine.Workspace.update/2), so
  # an id that is canonical for a slug the workspace holds is canonical.
  defp workspace_identifiers(tenant_id) do
    query_issues(
      """
      SELECT id, slug, 'noncanonical_workspace_id' FROM workspaces
      WHERE tenant_id=?1 AND status='active' AND id != tenant_id || ':' || slug
        AND NOT EXISTS (
          SELECT 1 FROM workspace_handles h
          WHERE h.workspace_id = workspaces.id AND workspaces.id = workspaces.tenant_id || ':' || h.slug
        )
      """,
      [tenant_id]
    )
  end

  defp node_parents(tenant_id) do
    query_issues(
      """
      SELECT n.id, n.parent_id, 'missing_parent'
      FROM nodes n JOIN workspaces w ON w.id=n.workspace_id AND w.status='active'
      LEFT JOIN nodes p ON p.id=n.parent_id
      WHERE n.tenant_id=?1 AND n.lifecycle_state='active' AND n.parent_id IS NOT NULL AND p.id IS NULL
      UNION ALL
      SELECT n.id, n.parent_id, 'self_parent'
      FROM nodes n JOIN workspaces w ON w.id=n.workspace_id AND w.status='active'
      WHERE n.tenant_id=?1 AND n.lifecycle_state='active' AND n.id=n.parent_id
      """,
      [tenant_id]
    )
  end

  defp node_workspace_scope(tenant_id) do
    query_issues(
      """
      SELECT n.id, n.workspace_id, 'missing_workspace'
      FROM nodes n LEFT JOIN workspaces w ON w.id=n.workspace_id
      WHERE n.tenant_id=?1 AND n.lifecycle_state='active' AND w.id IS NULL
      UNION ALL
      SELECT n.id, n.parent_id, 'cross_workspace_parent'
      FROM nodes n JOIN nodes p ON p.id=n.parent_id
      WHERE n.tenant_id=?1 AND n.lifecycle_state='active' AND p.workspace_id != n.workspace_id
      """,
      [tenant_id]
    )
  end

  defp node_types(tenant_id) do
    query_issues(
      """
      SELECT n.id, COALESCE(n.node_type_id, n.kind), 'missing_or_cross_workspace_node_type'
      FROM nodes n JOIN workspaces w ON w.id=n.workspace_id AND w.status='active'
      LEFT JOIN node_types t ON t.id=n.node_type_id
      WHERE n.tenant_id=?1 AND n.lifecycle_state='active'
        AND (t.id IS NULL OR t.workspace_id != n.workspace_id OR t.lifecycle_state != 'active')
      """,
      [tenant_id]
    )
  end

  defp relationship_scope(tenant_id) do
    query_issues(
      """
      SELECT r.id, r.workspace_id, 'relationship_endpoint_scope_mismatch'
      FROM node_relationships r
      JOIN nodes s ON s.id=r.source_node_id
      JOIN nodes t ON t.id=r.target_node_id
      WHERE r.tenant_id=?1 AND r.lifecycle_state='active'
        AND (s.workspace_id != r.workspace_id OR t.workspace_id != r.workspace_id)
      """,
      [tenant_id]
    )
  end

  defp query_issues(sql, params) do
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
