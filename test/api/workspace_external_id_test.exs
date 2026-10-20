defmodule OptimalEngine.API.WorkspaceExternalIdTest do
  @moduledoc """
  A workspace can carry the id another system knows it by (`external_id`),
  so a mirror finds it by that id whatever its slug or name becomes. The
  external id is opaque, held by at most one active workspace of a tenant,
  set at creation or once later, and never changed; archiving a workspace
  releases it.
  """

  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias OptimalEngine.API.Router
  alias OptimalEngine.Auth.ApiKey
  alias OptimalEngine.{DataSteward, Store}
  alias OptimalEngine.Tenancy.Tenant
  alias OptimalEngine.Topology.Portable
  alias OptimalEngine.Workspace

  setup do
    n = System.unique_integer([:positive])
    %{n: n, external: "ext-#{n}-0f3a"}
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

  defp create(slug, external_id) do
    request(:post, "/api/workspaces", %{slug: slug, name: slug, external_id: external_id})
  end

  defp lookup(external_id) do
    request(
      :get,
      "/api/workspaces?" <> URI.encode_query(%{external_id: external_id, status: "all"})
    )
  end

  test "a workspace created with an external id returns it and is found by it", %{
    n: n,
    external: external
  } do
    assert {201, created} = create("ext-a-#{n}", external)
    assert created["external_id"] == external

    assert {200, %{"external_id" => ^external}} =
             request(:get, "/api/workspaces/#{created["id"]}")

    assert {200, %{"workspaces" => [found], "pagination" => %{"total" => 1}}} = lookup(external)
    assert found["id"] == created["id"]
    assert found["external_id"] == external

    assert {200, %{"workspaces" => [], "pagination" => %{"total" => 0}}} =
             lookup(external <> "-unknown")
  end

  test "an external id is unique within a tenant", %{n: n, external: external} do
    assert {201, _} = create("ext-b-#{n}", external)
    assert {409, %{"error" => "external_id_taken"}} = create("ext-c-#{n}", external)

    tenant = "ext-tenant-#{n}"
    {:ok, _} = Tenant.create(%{id: tenant, name: "Other tenant #{n}"})

    assert {:ok, other} =
             Workspace.create(%{
               tenant_id: tenant,
               organization_id: OptimalEngine.Organization.default_for(tenant),
               slug: "ext-d-#{n}",
               name: "Other",
               external_id: external
             })

    assert other.external_id == external
    assert other.metadata["external_id"] == external
  end

  test "concurrent creates with one external id leave exactly one workspace", %{
    n: n,
    external: external
  } do
    results =
      1..5
      |> Enum.map(fn i ->
        Task.async(fn ->
          Workspace.create(%{slug: "ext-race-#{n}-#{i}", name: "Race", external_id: external})
        end)
      end)
      |> Enum.map(&Task.await(&1, 30_000))

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :external_id_taken})) == 4
  end

  test "an external id can be set once later and is never changed", %{n: n, external: external} do
    assert {201, plain} = create("ext-e-#{n}", nil)
    assert plain["external_id"] == nil
    path = "/api/workspaces/#{plain["id"]}"

    assert {200, %{"external_id" => ^external}} = request(:patch, path, %{external_id: external})
    assert {200, %{"external_id" => ^external}} = request(:patch, path, %{external_id: external})

    assert {409, %{"error" => "external_id_immutable"}} =
             request(:patch, path, %{external_id: external <> "-other"})

    assert {201, second} = create("ext-f-#{n}", nil)

    assert {409, %{"error" => "external_id_taken"}} =
             request(:patch, "/api/workspaces/#{second["id"]}", %{external_id: external})

    for bad <- ["", String.duplicate("x", 256), 42, false, "has space", "tab\there", "caf\u00e9"] do
      assert {400, %{"error" => "invalid_external_id"}} =
               request(:patch, "/api/workspaces/#{second["id"]}", %{external_id: bad})
    end

    # A rename keeps it.
    assert {200, renamed} = request(:patch, path, %{slug: "ext-e-renamed-#{n}"})
    assert renamed["external_id"] == external
    assert {200, %{"workspaces" => [%{"slug" => "ext-e-renamed-" <> _}]}} = lookup(external)
  end

  test "a key sees an external id only for workspaces it covers", %{n: n, external: external} do
    assert {201, created} = create("ext-g-#{n}", external)
    assert {201, other} = create("ext-h-#{n}", nil)

    {:ok, %{key: key}} =
      ApiKey.mint(%{
        tenant_id: "default",
        name: "external id",
        scopes: ["read"],
        workspace_scope: [other["id"]]
      })

    assert {200, %{"workspaces" => []}} =
             request(:get, "/api/workspaces?external_id=#{external}&status=all", nil, key)

    refute created["id"] == other["id"]
  end

  test "a key that covers the workspace finds it by its external id", %{n: n, external: external} do
    assert {201, created} = create("ext-i-#{n}", external)

    {:ok, %{key: key}} =
      ApiKey.mint(%{
        tenant_id: "default",
        name: "external id lookup",
        scopes: ["read"],
        workspace_scope: [created["id"]]
      })

    assert {200, %{"workspaces" => [found]}} =
             request(:get, "/api/workspaces?external_id=#{external}", nil, key)

    assert found["id"] == created["id"]
  end

  test "an external id is 1 to 255 printable ASCII bytes without spaces", %{n: n} do
    longest = String.duplicate("A", 254) <> "~"
    assert {201, %{"external_id" => ^longest}} = create("ext-j-#{n}", longest)

    for bad <- [
          String.duplicate("a", 256),
          "with space",
          "line\nbreak",
          "bell\u0007",
          "del\u007f",
          "caf\u00e9",
          false,
          0,
          ""
        ] do
      assert {400, %{"error" => "invalid_external_id"}} = create("ext-k-#{n}", bad)
    end

    assert {404, _} = request(:get, "/api/workspaces/default:ext-k-#{n}")
  end

  test "an external id lookup refuses a list and searches every status", %{
    n: n,
    external: external
  } do
    assert {400, %{"error" => "invalid_external_id"}} =
             request(:get, "/api/workspaces?external_id[]=#{external}")

    assert {400, %{"error" => "invalid_external_id"}} =
             request(:get, "/api/workspaces?" <> URI.encode_query(%{external_id: "a b"}))

    assert {201, created} = create("ext-l-#{n}", external)
    assert {204, _} = request_raw(:post, "/api/workspaces/#{created["id"]}/archive")

    assert {200, %{"workspaces" => [%{"status" => "archived", "id" => id}]}} =
             request(:get, "/api/workspaces?external_id=#{external}")

    assert id == created["id"]

    assert {200, %{"workspaces" => []}} =
             request(:get, "/api/workspaces?external_id=#{external}&status=active")
  end

  test "archiving a workspace releases its external id: a new workspace can be created with it",
       %{n: n, external: external} do
    assert {201, old} = create("ext-m-#{n}", external)
    assert {409, %{"error" => "external_id_taken"}} = create("ext-n-#{n}", external)
    assert {204, _} = request_raw(:post, "/api/workspaces/#{old["id"]}/archive")

    # The archived row keeps the value for history.
    assert {:ok, %{status: :archived, external_id: ^external}} = Workspace.get(old["id"])

    assert {201, rebound} = create("ext-n-#{n}", external)
    assert rebound["external_id"] == external

    assert {:ok, %{id: id, status: :active}} = Workspace.get_by_external_id(external, "default")
    assert id == rebound["id"]

    # The lookup lists both rows with their status; status=active only the binding.
    assert {200, %{"workspaces" => rows, "pagination" => %{"total" => 2}}} = lookup(external)

    assert Enum.sort(Enum.map(rows, &{&1["id"], &1["status"]})) ==
             Enum.sort([{old["id"], "archived"}, {rebound["id"], "active"}])

    assert {200, %{"workspaces" => [%{"id" => ^id}]}} =
             request(:get, "/api/workspaces?external_id=#{external}&status=active")

    # The new binding holds it now.
    assert {409, %{"error" => "external_id_taken"}} = create("ext-o-#{n}", external)
  end

  test "archiving a workspace releases its external id: another workspace can be bound to it", %{
    n: n,
    external: external
  } do
    assert {201, old} = create("ext-p-#{n}", external)
    assert {201, other} = create("ext-q-#{n}", nil)
    path = "/api/workspaces/#{other["id"]}"

    assert {409, %{"error" => "external_id_taken"}} =
             request(:patch, path, %{external_id: external})

    assert {204, _} = request_raw(:post, "/api/workspaces/#{old["id"]}/archive")
    assert {200, %{"external_id" => ^external}} = request(:patch, path, %{external_id: external})

    assert {:ok, %{id: id}} = Workspace.get_by_external_id(external, "default")
    assert id == other["id"]

    # The archived workspace keeps the value but can never take it back.
    assert {:ok, %{external_id: ^external}} = Workspace.get(old["id"])
  end

  test "an external id lookup inside the Engine never returns an archived workspace", %{
    n: n,
    external: external
  } do
    assert {201, created} = create("ext-r-#{n}", external)
    assert {:ok, %{id: id}} = Workspace.get_by_external_id(external, "default")
    assert id == created["id"]

    :ok = Workspace.archive(created["id"])
    assert {:error, :not_found} = Workspace.get_by_external_id(external, "default")

    assert {:ok, [%{id: ^id, status: :archived}]} =
             Workspace.list(external_id: external, status: :all)
  end

  test "two concurrent binds of different external ids have exactly one winner", %{n: n} do
    for i <- 1..10 do
      {:ok, workspace} = Workspace.create(%{slug: "ext-bind-#{n}-#{i}", name: "Bind"})
      first = "first-#{n}-#{i}"
      second = "second-#{n}-#{i}"

      results =
        [first, second]
        |> Enum.map(fn id ->
          Task.async(fn -> Workspace.update(workspace.id, %{external_id: id}) end)
        end)
        |> Enum.map(&Task.await(&1, 30_000))

      assert [{:ok, winner}] = Enum.filter(results, &match?({:ok, _}, &1))

      assert [{:error, reason}] = Enum.reject(results, &match?({:ok, _}, &1))
      assert reason in [:external_id_immutable, :external_id_taken]

      assert {:ok, stored} = Workspace.get(workspace.id)
      assert stored.external_id == winner.external_id
      assert stored.metadata["external_id"] == winner.external_id
    end
  end

  test "a bind racing a name change keeps the external id", %{n: n} do
    for i <- 1..10 do
      {:ok, workspace} = Workspace.create(%{slug: "ext-race-name-#{n}-#{i}", name: "Before"})
      external = "bound-#{n}-#{i}"

      [bind, rename] =
        [%{external_id: external}, %{name: "After"}]
        |> Enum.map(fn attrs -> Task.async(fn -> Workspace.update(workspace.id, attrs) end) end)
        |> Enum.map(&Task.await(&1, 30_000))

      assert {:ok, _} = bind
      assert {:ok, _} = rename

      assert {:ok, stored} = Workspace.get(workspace.id)
      assert stored.name == "After"
      assert stored.external_id == external

      assert {:ok, [[^external]]} =
               Store.raw_query(
                 "SELECT json_extract(metadata, '$.external_id') FROM workspaces WHERE id = ?1",
                 [workspace.id]
               )
    end
  end

  test "a metadata replacement keeps the external id and the slugs the workspace held", %{
    n: n,
    external: external
  } do
    slug = "ext-meta-#{n}"
    {:ok, workspace} = Workspace.create(%{slug: slug, name: "Meta", external_id: external})
    {:ok, _} = Workspace.update(workspace.id, %{slug: slug <> "-renamed"})

    for metadata <- [%{}, %{"note" => "kept", "external_id" => external, "previous_slugs" => []}] do
      assert {:ok, updated} = Workspace.update(workspace.id, %{metadata: metadata})
      assert updated.external_id == external
      assert updated.metadata["external_id"] == external
      assert updated.metadata["previous_slugs"] == [slug]

      assert {:ok, stored} = Workspace.get(workspace.id)
      assert stored.external_id == external
      assert stored.metadata["previous_slugs"] == [slug]
      assert {:ok, %{id: id}} = Workspace.get_by_handle(slug, "default")
      assert id == workspace.id
    end

    assert {:error, :external_id_immutable} =
             Workspace.update(workspace.id, %{metadata: %{"external_id" => external <> "-x"}})
  end

  test "an external id given inside metadata is validated and bound like external_id", %{
    n: n,
    external: external
  } do
    {:ok, workspace} = Workspace.create(%{slug: "ext-inner-#{n}", name: "Inner"})

    assert {:error, :invalid_external_id} =
             Workspace.update(workspace.id, %{metadata: %{"external_id" => "not valid"}})

    assert {:error, :invalid_external_id} =
             Workspace.create(%{
               slug: "ext-inner-bad-#{n}",
               name: "Inner",
               metadata: %{"external_id" => 7}
             })

    assert {:ok, bound} = Workspace.update(workspace.id, %{metadata: %{"external_id" => external}})
    assert bound.external_id == external
    assert {:ok, %{id: id}} = Workspace.get_by_external_id(external, "default")
    assert id == workspace.id
  end

  test "an update of a workspace that does not exist is not found" do
    assert {:error, :not_found} = Workspace.update("default:no-such-workspace", %{name: "x"})
  end

  test "the data steward's id rename moves the external id and the handles", %{
    n: n,
    external: external
  } do
    slug = "ext-legacy-#{n}"

    {:ok, _} =
      Workspace.create(%{id: "legacy-#{n}", slug: slug, name: "Legacy", external_id: external})

    assert {:ok, _} =
             DataSteward.rename_workspace("legacy-#{n}", "default:#{slug}", actor_id: "test")

    assert {:ok, %{id: id, external_id: ^external}} =
             Workspace.get_by_external_id(external, "default")

    assert id == "default:#{slug}"
    assert {:error, :not_found} = Workspace.get("legacy-#{n}")
    assert {:ok, %{id: ^id}} = Workspace.get_by_handle(slug, "default")
  end

  test "migration 72 moves external ids out of metadata, and runs again harmlessly", %{n: n} do
    rows = [
      {"m72-a-#{n}", "active", %{"external_id" => "m72-#{n}"}},
      {"m72-b-#{n}", "active", %{"external_id" => "m72-#{n}"}},
      {"m72-c-#{n}", "active", %{"external_id" => "bad id #{n}"}},
      {"m72-d-#{n}", "archived", %{"external_id" => "m72-moved-#{n}"}},
      {"m72-e-#{n}", "active", %{"external_id" => "m72-moved-#{n}"}}
    ]

    for {id, status, metadata} <- rows do
      {:ok, _} =
        Store.raw_query(
          "INSERT INTO workspaces (id, tenant_id, slug, name, status, metadata) VALUES (?1, 'default', ?1, ?1, ?2, ?3)",
          [id, status, Jason.encode!(metadata)]
        )
    end

    {72, _description, statements} = List.keyfind(OptimalEngine.Store.Migrations.all(), 72, 0)

    # Every statement runs twice, as a re-run would: the column add is a
    # duplicate (tolerated, as the migration runner does), the rest change
    # nothing the second time.
    for _run <- 1..2, {label, sql} <- statements do
      case Store.raw_query(sql, []) do
        {:ok, _} -> :ok
        {:error, message} -> assert message =~ "duplicate column", "#{label}: #{message}"
      end
    end

    # Among active workspaces the lower id keeps a duplicated id; an invalid
    # id stays in metadata only; an archived workspace keeps its value and
    # does not block the active one.
    assert {:ok, %{id: id}} = Workspace.get_by_external_id("m72-#{n}", "default")
    assert id == "m72-a-#{n}"
    assert {:ok, %{external_id: nil}} = Workspace.get("m72-b-#{n}")
    assert {:ok, %{external_id: nil}} = Workspace.get("m72-c-#{n}")

    assert {:ok, %{id: active}} = Workspace.get_by_external_id("m72-moved-#{n}", "default")
    assert active == "m72-e-#{n}"
    assert {:ok, %{external_id: "m72-moved-" <> _}} = Workspace.get("m72-d-#{n}")
  end

  test "a topology document carries an external id; an import sets it once", %{
    n: n,
    external: external
  } do
    tenant = "ext-topology-#{n}"
    {:ok, _} = Tenant.create(%{id: tenant, name: "Topology #{n}"})

    document = %{
      "schema_version" => 1,
      "organizations" => [
        %{
          "slug" => "acme",
          "name" => "Acme",
          "status" => "active",
          "workspaces" => [%{"slug" => "sales", "external_id" => external}, "delivery"]
        }
      ]
    }

    assert {:ok, %{workspaces_created: 2}} = Portable.import(tenant, document)
    assert {:ok, %{slug: "sales"}} = Workspace.get_by_external_id(external, tenant)
    assert Portable.export(tenant) == document

    # Imported again with another external id, the one already set stays.
    changed =
      put_in(document, ["organizations", Access.at(0), "workspaces"], [
        %{"slug" => "sales", "external_id" => external <> "-other"},
        %{"slug" => "delivery", "external_id" => external <> "-delivery"}
      ])

    assert {:ok, %{external_ids_set: 1}} = Portable.import(tenant, changed)
    assert {:ok, %{slug: "sales"}} = Workspace.get_by_external_id(external, tenant)

    assert {:ok, %{slug: "delivery"}} =
             Workspace.get_by_external_id(external <> "-delivery", tenant)

    bad =
      put_in(document, ["organizations", Access.at(0), "workspaces"], [
        %{"slug" => "x", "external_id" => "a b"}
      ])

    assert {:error, {:invalid_document, _}} = Portable.import(tenant, bad)
  end

  test "a topology import is refused when an active workspace holds the external id, not an archived one",
       %{n: n, external: external} do
    assert {201, holder} = create("ext-topo-holder-#{n}", external)
    slug = "ext-topo-new-#{n}"

    document = %{
      "schema_version" => 1,
      "organizations" => [
        %{
          "slug" => "ext-topo-org-#{n}",
          "name" => "Topology org",
          "workspaces" => [%{"slug" => slug, "external_id" => external}]
        }
      ]
    }

    # The same answer as the workspace routes, and nothing is written.
    assert {409, %{"error" => "external_id_taken"}} =
             request(:post, "/api/topology/import", document)

    assert {:error, :not_found} = Workspace.get_by_slug(slug, "default")
    assert {:error, :external_id_taken} = Portable.import("default", document)

    # One document naming the id twice is refused the same way.
    twice =
      put_in(document, ["organizations", Access.at(0), "workspaces"], [
        %{"slug" => slug <> "-a", "external_id" => external <> "-twice"},
        %{"slug" => slug <> "-b", "external_id" => external <> "-twice"}
      ])

    assert {:error, :external_id_taken} = Portable.import("default", twice)

    # Once the holder is archived the id is free for the import.
    assert {204, _} = request_raw(:post, "/api/workspaces/#{holder["id"]}/archive")
    assert {200, %{"workspaces_created" => 1}} = request(:post, "/api/topology/import", document)
    assert {:ok, %{slug: ^slug}} = Workspace.get_by_external_id(external, "default")
  end

  test "an id repair through the data steward route moves the external id", %{
    n: n,
    external: external
  } do
    tenant = "ext-repair-#{n}"
    {:ok, _} = Tenant.create(%{id: tenant, name: "Repair #{n}"})
    legacy = tenant <> "-legacy"
    canonical = tenant <> ":legacy"

    assert {:ok, _} =
             Workspace.create(%{
               id: legacy,
               tenant_id: tenant,
               organization_id: OptimalEngine.Organization.default_for(tenant),
               slug: "legacy",
               name: "Legacy",
               external_id: external
             })

    assert {200, %{"target_workspace_id" => ^canonical}} =
             request(:post, "/api/data-steward/workspaces/rename", %{
               source_workspace_id: legacy,
               target_workspace_id: canonical,
               actor_id: "user:test"
             })

    assert {:error, :not_found} = Workspace.get(legacy)
    assert {:ok, %{external_id: ^external}} = Workspace.get(canonical)
    assert {:ok, %{id: ^canonical}} = Workspace.get_by_external_id(external, tenant)
  end

  defp request_raw(method, path) do
    response = Router.call(conn(method, path), Router.init([]))
    {response.status, response.resp_body}
  end
end
