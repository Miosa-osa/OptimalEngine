defmodule OptimalEngine.Embed.BackfillTest do
  use ExUnit.Case, async: false

  alias OptimalEngine.Embed.Backfill
  alias OptimalEngine.Store
  alias OptimalEngine.Store.Vectors
  alias OptimalEngine.Tenancy.Tenant
  alias OptimalEngine.Workspace

  setup do
    n = System.unique_integer([:positive])
    tenant = "backfill-#{n}"
    {:ok, _} = Tenant.create(%{id: tenant, name: "Backfill tenant"})
    org = "#{tenant}:org"

    {:ok, _} =
      OptimalEngine.Organization.create(%{id: org, tenant_id: tenant, slug: "org", name: "Org"})

    {:ok, ws} =
      Workspace.create(%{tenant_id: tenant, organization_id: org, slug: "notes", name: "Notes"})

    {:ok, other} =
      Workspace.create(%{tenant_id: tenant, organization_id: org, slug: "other", name: "Other"})

    %{n: n, tenant: tenant, ws: ws.id, other: other.id}
  end

  describe "vector scope" do
    test "a stored vector carries its document's tenant and workspace", ctx do
      id = document!(ctx.tenant, ctx.ws, "scoped-#{ctx.n}", "A scoped note")
      :ok = Vectors.store(id, [1.0, 0.0, 0.0])

      assert {:ok, [[tenant, workspace]]} =
               Store.raw_query(
                 "SELECT tenant_id, workspace_id FROM vectors WHERE context_id = ?1",
                 [
                   id
                 ]
               )

      assert {tenant, workspace} == {ctx.tenant, ctx.ws}
    end

    test "a vector stored before its document takes the workspace it is given", ctx do
      id = "early-#{ctx.n}"
      :ok = Vectors.store(id, [0.0, 1.0, 0.0], workspace_id: ctx.other)

      assert {:ok, [[tenant, workspace]]} =
               Store.raw_query(
                 "SELECT tenant_id, workspace_id FROM vectors WHERE context_id = ?1",
                 [
                   id
                 ]
               )

      assert {tenant, workspace} == {ctx.tenant, ctx.other}
    end

    test "migration 70 moves mis-scoped vectors, chunks and chunk embeddings to their document's scope",
         ctx do
      id = document!(ctx.tenant, ctx.ws, "stale-#{ctx.n}", "Moved note")
      chunk = "chunk-#{ctx.n}"
      blob = {:blob, <<1.0::float-little-32, 0.0::float-little-32>>}

      {:ok, _} =
        Store.raw_query(
          "INSERT INTO vectors (context_id, embedding, dimensions, tenant_id, workspace_id) VALUES (?1, ?2, 2, 'default', 'default')",
          [id, blob]
        )

      {:ok, _} =
        Store.raw_query(
          "INSERT INTO chunks (id, tenant_id, signal_id, scale, workspace_id) VALUES (?1, 'default', ?2, 'document', ?3)",
          [chunk, id, ctx.other]
        )

      {:ok, _} =
        Store.raw_query(
          "INSERT INTO chunk_embeddings (chunk_id, tenant_id, model, modality, dim, vector, workspace_id) VALUES (?1, 'default', 'test', 'text', 2, ?2, ?3)",
          [chunk, blob, ctx.other]
        )

      {70, _description, statements} = List.keyfind(OptimalEngine.Store.Migrations.all(), 70, 0)
      for {_label, sql} <- statements, do: {:ok, _} = Store.raw_query(sql, [])

      expected = [ctx.tenant, ctx.ws]

      assert {:ok, [^expected]} =
               Store.raw_query(
                 "SELECT tenant_id, workspace_id FROM vectors WHERE context_id = ?1",
                 [
                   id
                 ]
               )

      assert {:ok, [^expected]} =
               Store.raw_query("SELECT tenant_id, workspace_id FROM chunks WHERE id = ?1", [chunk])

      assert {:ok, [^expected]} =
               Store.raw_query(
                 "SELECT tenant_id, workspace_id FROM chunk_embeddings WHERE chunk_id = ?1",
                 [chunk]
               )
    end
  end

  describe "run/1" do
    setup ctx do
      has = document!(ctx.tenant, ctx.ws, "has-#{ctx.n}", "Already embedded")
      :ok = Vectors.store(has, [1.0, 0.0, 0.0])

      missing = [
        document!(ctx.tenant, ctx.ws, "miss-a-#{ctx.n}", "Pricing call notes"),
        document!(ctx.tenant, ctx.other, "miss-b-#{ctx.n}", "Hiring plan")
      ]

      archived = document!(ctx.tenant, ctx.ws, "archived-#{ctx.n}", "Old draft")

      {:ok, _} =
        Store.raw_query("UPDATE contexts SET archived_at = datetime('now') WHERE id = ?1", [
          archived
        ])

      empty = document!(ctx.tenant, ctx.ws, "empty-#{ctx.n}", "", "")

      %{has: has, missing: missing, archived: archived, empty: empty}
    end

    test "documents without a vector are embedded once, in their own workspace", ctx do
      parent = self()

      embed = fn text ->
        send(parent, {:embedded, text})
        {:ok, [0.0, 0.0, 1.0]}
      end

      assert {:ok, %{embedded: 2, failed: 0, remaining: 0}} =
               Backfill.run(tenant_id: ctx.tenant, embed: embed)

      assert_received {:embedded, first}
      assert_received {:embedded, second}
      refute_received {:embedded, _}
      assert Enum.sort([first, second]) |> Enum.all?(&(&1 =~ ~r/Pricing call notes|Hiring plan/))

      {:ok, rows} =
        Store.raw_query(
          "SELECT context_id, workspace_id FROM vectors WHERE tenant_id = ?1 ORDER BY context_id",
          [ctx.tenant]
        )

      [miss_a, miss_b] = ctx.missing

      assert Enum.sort(rows) ==
               Enum.sort([[ctx.has, ctx.ws], [miss_a, ctx.ws], [miss_b, ctx.other]])

      assert {:ok, %{embedded: 0, remaining: 0}} =
               Backfill.run(tenant_id: ctx.tenant, embed: embed)
    end

    test "a limit embeds that many and reports what remains", ctx do
      embed = fn _ -> {:ok, [0.0, 0.0, 1.0]} end

      assert {:ok, %{embedded: 1, remaining: 1}} =
               Backfill.run(tenant_id: ctx.tenant, limit: 1, embed: embed)

      assert {:ok, %{embedded: 1, remaining: 0}} =
               Backfill.run(tenant_id: ctx.tenant, limit: 1, embed: embed)
    end

    test "one workspace can be backfilled alone", ctx do
      embed = fn _ -> {:ok, [0.0, 0.0, 1.0]} end

      assert {:ok, %{embedded: 1, remaining: 0}} =
               Backfill.run(workspace_id: ctx.other, embed: embed)

      assert {:ok, %{missing: 1}} = Backfill.status(workspace_id: ctx.ws)
      assert {:ok, %{missing: 0}} = Backfill.status(workspace_id: ctx.other)
    end

    test "a document the embedder rejects is counted and the run goes on", ctx do
      embed = fn text ->
        if text =~ "Pricing", do: {:error, :bad_input}, else: {:ok, [0.0, 0.0, 1.0]}
      end

      assert {:ok, %{embedded: 1, failed: 1}} = Backfill.run(tenant_id: ctx.tenant, embed: embed)
    end

    test "an unreachable embedder stops the run", ctx do
      embed = fn _ -> {:error, :ollama_unavailable} end

      assert {:error, {:embedder_unavailable, :ollama_unavailable}} =
               Backfill.run(tenant_id: ctx.tenant, embed: embed)

      assert {:ok, %{missing: 2}} = Backfill.status(tenant_id: ctx.tenant)
    end
  end

  describe "routes" do
    test "need admin, stay in the caller's tenant, and report what is missing", ctx do
      document!(ctx.tenant, ctx.ws, "route-#{ctx.n}", "Route note")

      {:ok, %{key: admin}} =
        OptimalEngine.Auth.ApiKey.mint(%{
          tenant_id: ctx.tenant,
          name: "admin",
          scopes: ["*"],
          workspace_scope: ["*"]
        })

      {:ok, %{key: reader}} =
        OptimalEngine.Auth.ApiKey.mint(%{
          tenant_id: ctx.tenant,
          name: "reader",
          scopes: ["read"],
          workspace_scope: ["*"]
        })

      call = fn method, path, key, body ->
        conn =
          if body,
            do:
              Plug.Test.conn(method, path, Jason.encode!(body))
              |> Plug.Conn.put_req_header("content-type", "application/json"),
            else: Plug.Test.conn(method, path)

        conn
        |> Plug.Conn.put_req_header("authorization", "Bearer " <> key)
        |> OptimalEngine.API.Router.call(OptimalEngine.API.Router.init([]))
      end

      assert call.(:get, "/api/maintenance/embeddings", reader, nil).status == 403

      status = call.(:get, "/api/maintenance/embeddings?workspace=#{ctx.ws}", admin, nil)
      assert status.status == 200
      assert Jason.decode!(status.resp_body)["missing"] == 1

      tenant_wide = call.(:get, "/api/maintenance/embeddings", admin, nil)
      assert Jason.decode!(tenant_wide.resp_body)["scope"] == %{"tenant_id" => ctx.tenant}

      assert call.(:get, "/api/maintenance/embeddings?workspace=default", admin, nil).status ==
               404

      assert call.(:post, "/api/maintenance/embeddings", admin, %{"workspace" => "default"}).status ==
               404

      # Nothing is missing in this workspace, so no embedder is called.
      done = call.(:post, "/api/maintenance/embeddings", admin, %{"workspace" => ctx.other})
      assert done.status == 200
      assert %{"embedded" => 0, "remaining" => 0} = Jason.decode!(done.resp_body)
    end
  end

  defp document!(tenant, workspace, id, title, content \\ nil) do
    {:ok, _} =
      Store.raw_query(
        "INSERT INTO contexts (id, tenant_id, workspace_id, type, title, content, created_at) VALUES (?1, ?2, ?3, 'signal', ?4, ?5, datetime('now'))",
        [id, tenant, workspace, title, content || "Body of #{title}."]
      )

    id
  end
end
