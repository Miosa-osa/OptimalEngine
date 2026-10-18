defmodule OptimalEngine.RecipesTest do
  @moduledoc """
  The API side of each recipe in docs/guides/recipes.md, run against the
  in-process Engine in a tenant of its own.
  """

  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias OptimalEngine.API.Router
  alias OptimalEngine.Auth.ApiKey
  alias OptimalEngine.Tenancy.Tenant

  setup do
    n = System.unique_integer([:positive])
    tenant = "recipes-#{n}"
    {:ok, _} = Tenant.create(%{id: tenant, name: "Recipes #{n}"})

    {:ok, %{key: root}} =
      ApiKey.mint(%{tenant_id: tenant, name: "root", scopes: ["*"], workspace_scope: ["*"]})

    %{tenant: tenant, root: root, n: n}
  end

  defp call(method, path, token, body \\ nil) do
    conn =
      case body do
        nil ->
          conn(method, path)

        body ->
          conn(method, path, Jason.encode!(body))
          |> put_req_header("content-type", "application/json")
      end

    conn = if token, do: put_req_header(conn, "authorization", "Bearer " <> token), else: conn
    Router.call(conn, Router.init([]))
  end

  defp ok!(conn, status \\ 200) do
    assert conn.status == status, "#{conn.status}: #{conn.resp_body}"
    Jason.decode!(conn.resp_body)
  end

  defp key(ctx, attrs),
    do:
      call(:post, "/api/auth/keys", ctx.root, Map.put(attrs, "name", "k"))
      |> ok!(201)
      |> Map.fetch!("key")

  test "agent memory", ctx do
    ws = "#{ctx.tenant}:mailer"
    call(:post, "/api/init", ctx.root, %{"for" => "agent", "slug" => "mailer"}) |> ok!()

    call(:post, "/api/principals", ctx.root, %{"id" => "agent:mailer-#{ctx.n}", "kind" => "agent"})
    |> ok!(201)

    agent =
      key(ctx, %{
        "principal_id" => "agent:mailer-#{ctx.n}",
        "scopes" => ["read", "write"],
        "workspace_scope" => [ws]
      })

    call(:post, "/api/memory", agent, %{
      "workspace" => ws,
      "content" => "The customer prefers email over calls."
    })
    |> ok!(201)

    memories = call(:get, "/api/memory?workspace=#{ws}", agent) |> ok!()

    assert Enum.any?(
             memories["memories"] || memories["results"] || [],
             &(&1["content"] =~ "prefers email")
           )

    call(:post, "/api/init", ctx.root, %{"for" => "agent", "slug" => "other"}) |> ok!()
    assert call(:get, "/api/memory?workspace=#{ctx.tenant}:other", agent).status == 403

    step =
      call(:post, "/api/agent-actions", agent, %{
        "workspace" => ws,
        "stage" => "request",
        "action" => "send_email",
        "resource" => "mailto:customer"
      })
      |> ok!(201)

    assert step["agent"] == "agent:mailer-#{ctx.n}"
  end

  test "workspace brain", ctx do
    ws = "#{ctx.tenant}:client-a"
    call(:post, "/api/init", ctx.root, %{"for" => "workspace", "slug" => "client-a"}) |> ok!()

    call(:post, "/api/ingest", ctx.root, %{
      "workspace" => ws,
      "title" => "Pricing",
      "text" => "Can you confirm the pricing before Friday? We need it for the board pack."
    })
    |> ok!()

    call(:post, "/api/loops/extract", ctx.root, %{"workspace" => ws}) |> ok!()
    assert %{"date" => _} = call(:get, "/api/boot?workspace=#{ws}", ctx.root) |> ok!()
    assert %{"items" => _} = call(:get, "/api/brief?workspace=#{ws}", ctx.root) |> ok!()

    viability = call(:get, "/api/viability?workspace=#{ws}", ctx.root) |> ok!()
    assert viability["signals_received"] >= 1
  end

  test "org brain", ctx do
    for slug <- ~w(ops sales) do
      call(:post, "/api/init", ctx.root, %{"for" => "business", "slug" => slug}) |> ok!()
    end

    sales = "#{ctx.tenant}:sales"
    call(:put, "/api/workspaces/#{sales}/share", ctx.root, %{"share_up" => "read"}) |> ok!()

    call(:post, "/api/ingest", ctx.root, %{
      "workspace" => sales,
      "title" => "Renewal",
      "text" => "The renewal is due next month."
    })
    |> ok!()

    assert %{} = call(:get, "/api/federation/search?q=renewal", ctx.root) |> ok!()
    assert %{"items" => _} = call(:get, "/api/brief?workspaces=*", ctx.root) |> ok!()

    org = call(:get, "/api/viability?workspaces=*", ctx.root) |> ok!()
    assert Enum.sort(org["workspace_ids"]) == Enum.sort(["#{ctx.tenant}:ops", sales])

    scoped = key(ctx, %{"scopes" => ["read"], "workspace_scope" => [sales]})
    assert (call(:get, "/api/viability?workspaces=*", scoped) |> ok!())["workspace_ids"] == [sales]
  end

  test "one Engine per customer", ctx do
    ws = "#{ctx.tenant}:main"

    result =
      call(:post, "/api/init", ctx.root, %{"for" => "tenant-per-customer", "slug" => "main"})
      |> ok!()

    assert result["env"]["OPTIMAL_ENGINE_WORKSPACE"] == ws

    app = key(ctx, %{"scopes" => ["read", "write"], "workspace_scope" => [ws]})
    assert call(:get, "/api/boot?workspace=#{ws}", app).status == 200
    assert call(:post, "/api/auth/keys", app, %{"name" => "wider", "scopes" => ["*"]}).status == 403

    assert %{"entries" => _} = call(:get, "/api/authority/evidence/export", ctx.root) |> ok!()
    assert call(:post, "/api/workspaces/#{ws}/bundle", ctx.root, %{}).status == 201
  end

  test "search and RAG for an app", ctx do
    ws = "#{ctx.tenant}:docs"
    call(:post, "/api/init", ctx.root, %{"for" => "app", "slug" => "docs"}) |> ok!()

    ingested =
      call(:post, "/api/ingest", ctx.root, %{
        "workspace" => ws,
        "title" => "Refund policy",
        "text" => "Refunds are issued within 14 days of a returned order."
      })
      |> ok!()

    reader = key(ctx, %{"scopes" => ["read"], "workspace_scope" => [ws]})

    results = call(:get, "/api/search?q=refunds&workspace=#{ws}", reader) |> ok!()
    assert Enum.any?(results["results"], &((&1["title"] || "") =~ "Refund"))

    assert call(:post, "/api/ingest", reader, %{"workspace" => ws, "text" => "x"}).status == 403

    assert %{} =
             call(:post, "/api/assemble", reader, %{"workspace" => ws, "query" => "refunds"})
             |> ok!()

    read = call(:get, "/api/read?id=#{ingested["signal_id"]}&workspace=#{ws}", reader) |> ok!()
    assert read["title"] =~ "Refund" or get_in(read, ["context", "title"]) =~ "Refund"
  end
end
