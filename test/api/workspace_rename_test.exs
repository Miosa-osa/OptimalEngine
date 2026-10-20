defmodule OptimalEngine.API.WorkspaceRenameTest do
  @moduledoc """
  Renaming a workspace changes its slug and keeps its id. Every row, key, and
  link that names the id keeps working, a link written with any slug the
  workspace has held resolves to the id, the slugs it held stay its own, and
  a request that names a slug where an id belongs is told the id.
  """

  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias OptimalEngine.API.Router
  alias OptimalEngine.{HierarchyAudit, Store, Workspace}
  alias OptimalEngine.Auth.ApiKey
  alias OptimalEngine.Authority.Evidence
  alias OptimalEngine.Identity.Principal
  alias OptimalEngine.Topology.Portable

  setup do
    n = System.unique_integer([:positive])
    slug = "rename-#{n}"
    {:ok, workspace} = Workspace.create(%{slug: slug, name: "Rename #{n}"})
    uri = "optimal://inbox/renewal-#{n}.md"

    {:ok, _} =
      Store.raw_query(
        """
        INSERT INTO contexts (id, tenant_id, workspace_id, uri, title, node, type, content,
                              created_at, metadata)
        VALUES (?1, 'default', ?2, ?3, 'Renewal', 'inbox', 'signal', 'Renewal moved to the 14th.',
                '2026-10-18T09:00:00Z', '{}')
        """,
        ["ctx-#{n}", workspace.id, uri]
      )

    %{n: n, workspace: workspace, slug: slug, renamed: "renamed-#{n}", uri: uri}
  end

  defp request(method, path, body \\ nil, token \\ nil) do
    connection =
      if body,
        do:
          conn(method, path, Jason.encode!(body))
          |> put_req_header("content-type", "application/json"),
        else: conn(method, path)

    connection =
      if token,
        do: put_req_header(connection, "authorization", "Bearer " <> token),
        else: connection

    response = Router.call(connection, Router.init([]))
    {response.status, Jason.decode!(response.resp_body)}
  end

  defp rename(workspace, slug, token \\ nil) do
    request(:patch, "/api/workspaces/#{workspace.id}", %{slug: slug, name: "Renamed"}, token)
  end

  defp key(principal, scopes, workspaces) do
    {:ok, _} =
      Principal.upsert(%{id: principal, tenant_id: "default", kind: :user, display_name: principal})

    {:ok, %{key: key}} =
      ApiKey.mint(%{
        tenant_id: "default",
        name: "rename",
        scopes: scopes,
        workspace_scope: workspaces,
        principal_id: principal
      })

    key
  end

  test "a rename changes the slug and keeps the id", %{
    workspace: workspace,
    slug: slug,
    renamed: renamed
  } do
    assert {200, body} = rename(workspace, renamed)
    assert body["id"] == workspace.id
    assert body["slug"] == renamed
    assert body["name"] == "Renamed"

    {:ok, stored} = Workspace.get(workspace.id)
    assert stored.slug == renamed
    assert Enum.sort(Workspace.handles(workspace.id)) == Enum.sort([slug, renamed])
    assert {:ok, %{id: id}} = Workspace.get_by_handle(slug, "default")
    assert id == workspace.id
  end

  test "old links keep resolving after a rename", %{
    n: n,
    workspace: workspace,
    slug: slug,
    renamed: renamed,
    uri: uri
  } do
    assert {200, _} = rename(workspace, renamed)

    assert {200, %{"id" => id}} =
             request(:get, "/api/read?" <> URI.encode_query(%{uri: uri, workspace: workspace.id}))

    assert id == "ctx-#{n}"

    by_id = "optimal://#{workspace.id}/inbox/renewal-#{n}.md"

    assert {200, %{"status" => "local", "uri" => ^by_id}} =
             request(:get, "/api/resolve?" <> URI.encode_query(%{uri: by_id}))

    # A link written with the new slug, or with the slug it had, names the id.
    for handle <- [renamed, slug] do
      link = "optimal://default:#{handle}/inbox/renewal-#{n}.md"

      assert {200, %{"status" => "local", "uri" => ^by_id}} =
               request(:get, "/api/resolve?" <> URI.encode_query(%{uri: link}))
    end
  end

  test "a request that names the new slug where an id belongs is told the id", %{
    workspace: workspace,
    renamed: renamed,
    n: n
  } do
    assert {200, _} = rename(workspace, renamed)

    assert {409, %{"error" => "not_a_workspace_id", "workspace_id" => id}} =
             request(:get, "/api/boot?workspace=default:#{renamed}")

    assert id == workspace.id

    # A key that covers the workspace is told the id; any other key is refused.
    covering = key("user:rename-reader-#{n}", ["read"], [workspace.id])
    {:ok, other} = Workspace.create(%{slug: "rename-other-#{n}", name: "Other"})
    elsewhere = key("user:rename-outsider-#{n}", ["read"], [other.id])

    assert {409, %{"workspace_id" => ^id}} =
             request(:get, "/api/boot?workspace=default:#{renamed}", nil, covering)

    assert {403, %{"error" => "workspace_scope_denied"}} =
             request(:get, "/api/boot?workspace=default:#{renamed}", nil, elsewhere)
  end

  test "every rename is recorded as evidence with who renamed it, from and to", %{
    workspace: workspace,
    slug: slug,
    renamed: renamed,
    n: n
  } do
    renamer = "user:renamer-#{n}"
    token = key(renamer, ["read", "topology:write"], [workspace.id])
    assert {200, _} = rename(workspace, renamed, token)

    assert [entry] =
             "default"
             |> Evidence.list(kind: "workspace.renamed")
             |> Enum.filter(&(&1["workspace_id"] == workspace.id))

    assert entry["subject"] == renamer
    assert entry["detail"]["from"] == slug
    assert entry["detail"]["to"] == renamed
  end

  test "a rename onto a slug whose id already holds rows is refused", %{
    workspace: workspace,
    n: n
  } do
    taken = "rename-held-#{n}"

    # Rows written to the unregistered id "default:<slug>" before any
    # workspace had that slug.
    {:ok, _} =
      Store.raw_query(
        "INSERT INTO contexts (id, tenant_id, workspace_id, uri, title, content, created_at, metadata) VALUES (?1, 'default', ?2, ?3, 'Held', 'Held.', '2026-10-18T09:00:00Z', '{}')",
        ["held-#{n}", "default:" <> taken, "optimal://inbox/held-#{n}.md"]
      )

    assert {409, %{"error" => "slug_has_data"}} = rename(workspace, taken)
  end

  test "slugs that name the root layout are reserved", %{workspace: workspace} do
    for reserved <- ~w(nodes assets architectures tenants cache) do
      assert {409, %{"error" => "slug_reserved"}} = rename(workspace, reserved)

      assert {409, %{"error" => "slug_reserved"}} =
               request(:post, "/api/workspaces", %{slug: reserved, name: "Reserved"})
    end
  end

  test "the slugs a workspace held stay its own", %{
    workspace: workspace,
    slug: slug,
    renamed: renamed,
    n: n
  } do
    assert {200, _} = rename(workspace, renamed)

    assert {409, %{"error" => "slug_taken"}} =
             request(:post, "/api/workspaces", %{slug: slug, name: "Taken"})

    {:ok, other} = Workspace.create(%{slug: "other-#{n}", name: "Other"})
    assert {409, %{"error" => "slug_taken"}} = rename(other, slug)
    assert {409, %{"error" => "slug_taken"}} = rename(other, renamed)
    assert {400, %{"error" => "invalid_slug"}} = rename(other, "not a slug")

    # Renaming back to a slug it held is allowed.
    assert {200, %{"slug" => ^slug}} = rename(workspace, slug)
  end

  test "a topology document carries a renamed workspace's id and an import keeps it", %{n: n} do
    tenant = "rename-tenant-#{n}"
    {:ok, _} = OptimalEngine.Tenancy.Tenant.create(%{id: tenant, name: "Rename #{n}"})

    {:ok, _} =
      Portable.import(tenant, %{
        "schema_version" => 1,
        "organizations" => [%{"slug" => "acme", "name" => "Acme", "workspaces" => ["sales"]}]
      })

    {:ok, _} = Workspace.update("#{tenant}:sales", %{slug: "revenue"})
    document = Portable.export(tenant)
    acme = Enum.find(document["organizations"], &(&1["slug"] == "acme"))
    assert acme["workspaces"] == [%{"slug" => "revenue", "id" => "#{tenant}:sales"}]

    # Another Engine that has never seen the workspace.
    {:ok, _} = Store.raw_query("DELETE FROM workspaces WHERE id = ?1", ["#{tenant}:sales"])
    assert {:ok, _} = Portable.import(tenant, document)

    {:ok, imported} = Workspace.get("#{tenant}:sales")
    assert imported.slug == "revenue"
    assert Workspace.handles(imported.id) == ["revenue"]
    assert Portable.export(tenant) == document
  end

  test "a topology file written before the rename still names the workspace", %{
    workspace: workspace,
    slug: slug,
    renamed: renamed,
    n: n
  } do
    assert {200, _} = rename(workspace, renamed)
    person = "user:rename-#{n}"

    assert {:ok, _} =
             Portable.import("default", %{
               "schema_version" => 1,
               "people" => [%{"id" => person, "kind" => "user", "workspaces" => [slug]}]
             })

    exported = Portable.export("default")
    entry = Enum.find(exported["people"], &(&1["id"] == person))
    assert entry["workspaces"] == [renamed]

    {:ok, audit} = HierarchyAudit.run("default")
    identifiers = Enum.find(audit.checks, &(&1.name == "workspace_identifiers"))
    refute Enum.any?(identifiers.issues, &(&1[:id] == workspace.id))
  end
end
