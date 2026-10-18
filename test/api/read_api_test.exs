defmodule OptimalEngine.API.ReadAPITest do
  @moduledoc """
  `GET /api/read`: one context by URI or id, workspace-scoped, at a tier.
  Each test runs in its own tenant.
  """

  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias OptimalEngine.API.Router
  alias OptimalEngine.Auth.ApiKey
  alias OptimalEngine.Store
  alias OptimalEngine.Tenancy.Tenant

  setup do
    n = System.unique_integer([:positive])
    tenant = "read-#{n}"
    {:ok, _} = Tenant.create(%{id: tenant, name: "Read #{n}"})
    workspace = "#{tenant}:sales"
    other = "#{tenant}:delivery"

    for {id, slug} <- [{workspace, "sales"}, {other, "delivery"}] do
      {:ok, _} =
        Store.raw_query(
          "INSERT INTO workspaces (id, tenant_id, slug, name, status, metadata) VALUES (?1, ?2, ?3, ?3, 'active', '{}')",
          [id, tenant, slug]
        )
    end

    insert(tenant, workspace, "ctx-#{n}", "optimal://nodes/sales/renewal-#{n}.md",
      l0: "Renewal abstract",
      l1: "Renewal overview",
      content: "Full renewal notes for Northwind"
    )

    insert(tenant, workspace, "ctx-thin-#{n}", "optimal://nodes/sales/thin-#{n}.md",
      l0: "",
      l1: "",
      content: "Only content"
    )

    insert(tenant, other, "ctx-other-#{n}", "optimal://nodes/delivery/plan-#{n}.md",
      l0: "Delivery abstract",
      l1: "Delivery overview",
      content: "Delivery plan"
    )

    sales_key = key(tenant, ["read"], [workspace])
    root_key = key(tenant, ["*"], ["*"])
    %{n: n, workspace: workspace, other: other, sales_key: sales_key, root_key: root_key}
  end

  defp insert(tenant, workspace, id, uri, texts) do
    {:ok, _} =
      Store.raw_query(
        """
        INSERT INTO contexts (id, tenant_id, workspace_id, uri, title, node, genre, content,
                              l0_abstract, l1_overview, created_at, metadata)
        VALUES (?1, ?2, ?3, ?4, ?5, 'sales', 'note', ?6, ?7, ?8, '2026-10-18T09:00:00Z', '{}')
        """,
        [id, tenant, workspace, uri, "Title #{id}", texts[:content], texts[:l0], texts[:l1]]
      )
  end

  defp key(tenant, scopes, workspaces) do
    {:ok, %{key: key}} =
      ApiKey.mint(%{tenant_id: tenant, name: "k", scopes: scopes, workspace_scope: workspaces})

    key
  end

  defp read(params, token) do
    conn(:get, "/api/read?" <> URI.encode_query(params))
    |> put_req_header("authorization", "Bearer " <> token)
    |> Router.call(Router.init([]))
  end

  defp body(conn), do: Jason.decode!(conn.resp_body)

  test "reads by URI at the default tier", ctx do
    uri = "optimal://nodes/sales/renewal-#{ctx.n}.md"
    conn = read(%{uri: uri, workspace: ctx.workspace}, ctx.sales_key)

    assert conn.status == 200

    assert %{
             "id" => "ctx-" <> _,
             "uri" => ^uri,
             "tier" => "l1",
             "served_tier" => "l1",
             "text" => "Renewal overview"
           } = body(conn)
  end

  test "reads by id at each tier and falls back to a fuller tier when one is empty", ctx do
    for {tier, text} <- [
          {"l0", "Renewal abstract"},
          {"l1", "Renewal overview"},
          {"full", "Full renewal notes for Northwind"}
        ] do
      conn = read(%{id: "ctx-#{ctx.n}", workspace: ctx.workspace, tier: tier}, ctx.sales_key)
      assert %{"tier" => ^tier, "served_tier" => ^tier, "text" => ^text} = body(conn)
    end

    conn = read(%{id: "ctx-thin-#{ctx.n}", workspace: ctx.workspace, tier: "l0"}, ctx.sales_key)
    assert %{"tier" => "l0", "served_tier" => "full", "text" => "Only content"} = body(conn)
  end

  test "a context in another workspace is never returned", ctx do
    uri = "optimal://nodes/delivery/plan-#{ctx.n}.md"

    assert read(%{uri: uri, workspace: ctx.other}, ctx.sales_key).status == 403
    assert read(%{uri: uri, workspace: ctx.workspace}, ctx.root_key).status == 404
    assert read(%{uri: uri, workspace: ctx.other}, ctx.root_key).status == 200
  end

  test "a key limited to named workspaces must name one", ctx do
    conn = read(%{id: "ctx-#{ctx.n}"}, ctx.sales_key)
    assert conn.status == 400
    assert body(conn) == %{"error" => "workspace_required"}
  end

  test "rejects a missing target, an unknown tier, and an unknown context", ctx do
    assert body(read(%{workspace: ctx.workspace}, ctx.sales_key)) == %{
             "error" => "uri_or_id_required"
           }

    conn = read(%{id: "ctx-#{ctx.n}", workspace: ctx.workspace, tier: "l9"}, ctx.sales_key)
    assert conn.status == 400
    assert body(conn) == %{"error" => "invalid_tier"}

    conn = read(%{uri: "optimal://nodes/sales/missing.md", workspace: ctx.workspace}, ctx.sales_key)
    assert conn.status == 404
  end
end
