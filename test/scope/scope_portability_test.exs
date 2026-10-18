defmodule OptimalEngine.ScopePortabilityTest do
  @moduledoc """
  Walls, share-up, federated search, and moving a workspace between Engines
  with a checksummed bundle and a redirect.
  """

  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias OptimalEngine.API.Router
  alias OptimalEngine.Auth.ApiKey
  alias OptimalEngine.{Federation, Scope, Store, Workspace}
  alias OptimalEngine.Portability.WorkspaceBundle
  alias OptimalEngine.Tenancy.Tenant
  alias OptimalEngine.Workspace.Filesystem

  setup do
    n = System.unique_integer([:positive])
    tenant = "scope-#{n}"
    {:ok, _} = Tenant.create(%{id: tenant, name: "Scope #{n}"})

    {:ok, _} =
      OptimalEngine.Organization.create(%{
        id: "#{tenant}:org",
        tenant_id: tenant,
        slug: "org",
        name: "Org"
      })

    {:ok, open} =
      Workspace.create(%{
        tenant_id: tenant,
        organization_id: "#{tenant}:org",
        slug: "open",
        name: "Open"
      })

    {:ok, private} =
      Workspace.create(%{
        tenant_id: tenant,
        organization_id: "#{tenant}:org",
        slug: "private",
        name: "Private",
        metadata: %{"visibility" => "private"}
      })

    %{tenant: tenant, n: n, open: open.id, private: private.id}
  end

  defp context(tenant, workspace, id, title, content) do
    {:ok, _} =
      Store.raw_query(
        "INSERT INTO contexts (id, tenant_id, workspace_id, title, content, created_at, uri) VALUES (?1, ?2, ?3, ?4, ?5, '2026-10-14T10:00:00Z', ?6)",
        [id, tenant, workspace, title, content, "optimal://#{workspace}/contexts/#{id}"]
      )
  end

  defp call(method, path, token \\ nil) do
    conn = conn(method, path)
    conn = if token, do: put_req_header(conn, "authorization", "Bearer " <> token), else: conn
    Router.call(conn, Router.init([]))
  end

  describe "walls" do
    test "two tenants' workspaces with the same slug never share a directory" do
      root = "/srv/engine"
      assert Filesystem.path(root, "default") == root
      assert Filesystem.path(root, "default:sales") == "/srv/engine/sales"
      assert Filesystem.path(root, "sales") == "/srv/engine/sales"
      assert Filesystem.path(root, "acme:sales") == "/srv/engine/tenants/acme/sales"
      refute Filesystem.path(root, "acme:sales") == Filesystem.path(root, "beta:sales")
      assert Filesystem.path(root, "acme:..") == "/srv/engine/tenants/acme/_"
    end

    test "a workspace-scoped Engine serves only its workspace", ctx do
      {:ok, %{key: key}} = ApiKey.mint(%{tenant_id: ctx.tenant, name: "k", scopes: ["read"]})

      Application.put_env(:optimal_engine, :engine_scope, %{
        mode: "workspace",
        workspace_id: ctx.open
      })

      try do
        assert Scope.serves?(ctx.open)
        refute Scope.serves?(ctx.private)
        assert call(:get, "/api/memory?workspace=#{ctx.private}", key).status == 404
        assert call(:get, "/api/memory?workspace=#{ctx.open}", key).status == 200
      after
        Application.delete_env(:optimal_engine, :engine_scope)
      end
    end
  end

  describe "share-up and federated search" do
    test "private and client workspaces default to none, changes are recorded", ctx do
      assert Scope.share_up(ctx.open) == "read"
      assert Scope.share_up(ctx.private) == "none"

      assert {:ok, %{share_up: "read", previous: "none"}} =
               Scope.set_share_up(ctx.tenant, ctx.private, "read", "user:owner")

      assert Scope.share_up(ctx.private) == "read"

      kinds = ctx.tenant |> OptimalEngine.Authority.Evidence.list() |> Enum.map(& &1["kind"])
      assert "settings.changed" in kinds
      assert {:error, :invalid_share_up} = Scope.set_share_up(ctx.tenant, ctx.open, "write", "u")
    end

    test "only sharing sections answer, each result names its source", ctx do
      context(
        ctx.tenant,
        ctx.open,
        "ctx-open-#{ctx.n}",
        "Quarterly zephyrplan",
        "The zephyrplan covers the open work."
      )

      context(
        ctx.tenant,
        ctx.private,
        "ctx-private-#{ctx.n}",
        "Secret zephyrplan",
        "The zephyrplan private details."
      )

      result = Federation.search(ctx.tenant, "zephyrplan")
      sources = Enum.map(result.results, & &1["source_workspace_id"]) |> Enum.uniq()
      assert sources == [ctx.open]
      assert Enum.any?(result.sources, &(&1.workspace_id == ctx.open and &1.status == "ok"))

      assert Federation.search(ctx.tenant, "zephyrplan", allowed: [ctx.private]).results == []
    end

    test "peers are queried with their own key and failures are reported", ctx do
      previous = System.get_env("CONNECTOR_KEY")
      System.put_env("CONNECTOR_KEY", Base.encode16(:crypto.strong_rand_bytes(32)))

      Application.put_env(:optimal_engine, :http_mock, fn url, opts ->
        cond do
          String.starts_with?(url, "https://down.example") ->
            {:error, :econnrefused}

          true ->
            assert {"authorization", "Bearer peer-key"} in Keyword.get(opts, :headers, [])

            {:ok,
             {{~c"HTTP/1.1", 200, ~c"OK"}, [{~c"content-type", ~c"application/json"}],
              Jason.encode!(%{
                "results" => [%{"id" => "remote-1", "title" => "Remote zephyrplan", "score" => 9.0}]
              })}}
        end
      end)

      try do
        {:ok, _} =
          Federation.add_peer(
            ctx.tenant,
            %{
              "workspace_id" => "remote:ws",
              "url" => "https://peer.example",
              "api_key" => "peer-key",
              "share_up" => "read"
            },
            "u"
          )

        {:ok, _} =
          Federation.add_peer(
            ctx.tenant,
            %{
              "workspace_id" => "remote:down",
              "url" => "https://down.example",
              "api_key" => "k",
              "share_up" => "read"
            },
            "u"
          )

        {:ok, _} =
          Federation.add_peer(
            ctx.tenant,
            %{"workspace_id" => "remote:hidden", "url" => "https://peer.example", "api_key" => "k"},
            "u"
          )

        result = Federation.search(ctx.tenant, "zephyrplan")

        assert [
                 %{
                   "id" => "remote-1",
                   "source_workspace_id" => "remote:ws",
                   "source_engine" => "https://peer.example"
                 }
                 | _
               ] = result.results

        assert Enum.any?(
                 result.sources,
                 &(&1.workspace_id == "remote:down" and &1.status == "unavailable")
               )

        refute Enum.any?(result.sources, &(&1.workspace_id == "remote:hidden"))
        refute Enum.any?(Federation.peers(ctx.tenant), &Map.has_key?(&1, :credential))
      after
        Application.delete_env(:optimal_engine, :http_mock)

        if previous,
          do: System.put_env("CONNECTOR_KEY", previous),
          else: System.delete_env("CONNECTOR_KEY")
      end
    end
  end

  describe "workspace bundles" do
    setup ctx do
      context(
        ctx.tenant,
        ctx.open,
        "ctx-a-#{ctx.n}",
        "Bundle quokkaterm",
        "The quokkaterm survives the move."
      )

      {:ok, memory} =
        OptimalEngine.Memory.create(%{
          content: "Remember the quokkaterm detail",
          workspace_id: ctx.open,
          tenant_id: ctx.tenant
        })

      embedding = :crypto.strong_rand_bytes(32)

      {:ok, _} =
        Store.raw_query(
          "INSERT INTO memory_embeddings (memory_id, tenant_id, workspace_id, model, dimensions, embedding, content_hash) VALUES (?1, ?2, ?3, 'test-model', 8, ?4, 'h')",
          [memory.id, ctx.tenant, ctx.open, {:blob, embedding}]
        )

      {:ok, _} =
        OptimalEngine.Operating.Loops.create(
          ctx.tenant,
          %{"workspace_id" => ctx.open, "title" => "Move the bundle"},
          "u"
        )

      dir = Filesystem.path(Application.get_env(:optimal_engine, :root_path), ctx.open)
      File.mkdir_p!(Path.join(dir, "nodes/notes"))
      File.write!(Path.join(dir, "nodes/notes/one.md"), "# One\nquokkaterm file")

      path = Path.join(System.tmp_dir!(), "bundle-#{ctx.n}.tar.gz")
      on_exit(fn -> File.rm(path) end)
      %{path: path, memory_id: memory.id, embedding: embedding}
    end

    test "export then import into another tenant copies rows, vectors, text index and files", ctx do
      {:ok, manifest} = WorkspaceBundle.export(ctx.tenant, ctx.open, ctx.path)
      names = Enum.map(manifest["tables"], & &1["name"])

      assert "contexts" in names and "memories" in names and "memory_embeddings" in names and
               "open_loops" in names

      assert [%{"path" => "nodes/notes/one.md"}] =
               Enum.filter(manifest["files"], &String.ends_with?(&1["path"], "one.md"))

      # One test database stands in for two Engines: the source gives the
      # workspace up first (text ids are unique per database).
      :ok = WorkspaceBundle.prepare_move(ctx.tenant, ctx.open, manifest["bundle_sha256"])

      {:ok, _} =
        WorkspaceBundle.finalize_move(ctx.tenant, ctx.open, manifest["bundle_sha256"], %{
          "target_url" => "https://other.example"
        })

      target = "target-#{ctx.n}"
      {:ok, _} = Tenant.create(%{id: target, name: "Target"})
      {:ok, summary} = WorkspaceBundle.import(ctx.path, target)
      assert summary.workspace_id == "#{target}:open"
      assert summary.bundle_sha256 == manifest["bundle_sha256"]

      {:ok, [[blob]]} =
        Store.raw_query(
          "SELECT embedding FROM memory_embeddings WHERE workspace_id = ?1 AND memory_id = ?2",
          [summary.workspace_id, ctx.memory_id]
        )

      assert blob == ctx.embedding

      {:ok, hits} =
        OptimalEngine.search("quokkaterm",
          workspace_id: summary.workspace_id,
          tenant_id: target,
          limit: 5
        )

      assert Enum.any?(hits, &(Map.get(&1, :workspace_id) == summary.workspace_id))

      target_file =
        Path.join(
          Filesystem.path(Application.get_env(:optimal_engine, :root_path), summary.workspace_id),
          "nodes/notes/one.md"
        )

      assert File.read!(target_file) == "# One\nquokkaterm file"

      assert {:error, :workspace_exists} = WorkspaceBundle.import(ctx.path, target)
      assert {:ok, merged} = WorkspaceBundle.import(ctx.path, target, mode: :merge)

      assert Enum.all?(
               Map.drop(merged.rows, ["decisions", "events", "edges", "observations"]),
               fn {_table, n} -> n == 0 end
             )
    end

    test "a tampered bundle is refused before anything is written", ctx do
      {:ok, _manifest} = WorkspaceBundle.export(ctx.tenant, ctx.open, ctx.path)
      dir = Path.join(System.tmp_dir!(), "tamper-#{ctx.n}")
      File.mkdir_p!(dir)

      :ok =
        :erl_tar.extract(String.to_charlist(ctx.path), [
          :compressed,
          {:cwd, String.to_charlist(dir)}
        ])

      File.write!(Path.join(dir, "tables/contexts.jsonl"), ~s({"id":"forged"}\n))

      files =
        for f <- Path.wildcard(Path.join(dir, "**"), match_dot: true),
            File.regular?(f),
            do: {String.to_charlist(Path.relative_to(f, dir)), String.to_charlist(f)}

      :ok = :erl_tar.create(String.to_charlist(ctx.path), files, [:compressed])
      File.rm_rf!(dir)

      target = "tamper-target-#{ctx.n}"
      {:ok, _} = Tenant.create(%{id: target, name: "T"})
      assert {:error, :table_checksum_mismatch} = WorkspaceBundle.import(ctx.path, target)
      assert {:error, :not_found} = Workspace.get("#{target}:open")
    end

    test "a move deletes the source only after the target's checksum matches, and links redirect",
         ctx do
      {:ok, manifest} = WorkspaceBundle.export(ctx.tenant, ctx.open, ctx.path)
      :ok = WorkspaceBundle.prepare_move(ctx.tenant, ctx.open, manifest["bundle_sha256"])

      target = %{"target_url" => "https://own-engine.example", "target_workspace_id" => "own:open"}

      assert {:error, :checksum_mismatch} =
               WorkspaceBundle.finalize_move(ctx.tenant, ctx.open, "0000", target)

      assert {:ok, [[1]]} =
               Store.raw_query("SELECT COUNT(*) FROM contexts WHERE workspace_id = ?1", [ctx.open])

      assert {:ok, %{deleted_rows: deleted}} =
               WorkspaceBundle.finalize_move(
                 ctx.tenant,
                 ctx.open,
                 manifest["bundle_sha256"],
                 target
               )

      assert deleted >= 3

      assert {:ok, [[0]]} =
               Store.raw_query("SELECT COUNT(*) FROM contexts WHERE workspace_id = ?1", [ctx.open])

      assert {:ok, %{status: :archived}} = Workspace.get(ctx.open)

      assert {:moved,
              %{
                "engine_url" => "https://own-engine.example",
                "uri" => "optimal://own:open/contexts/x"
              }} =
               WorkspaceBundle.resolve(ctx.tenant, "optimal://#{ctx.open}/contexts/x")

      assert {:local, _} =
               WorkspaceBundle.resolve(ctx.tenant, "optimal://#{ctx.private}/contexts/y")
    end

    test "bundle routes need admin and stay inside the bundles folder", ctx do
      {:ok, %{key: reader}} = ApiKey.mint(%{tenant_id: ctx.tenant, name: "r", scopes: ["read"]})
      original = Application.get_env(:optimal_engine, :auth, [])

      Application.put_env(
        :optimal_engine,
        :auth,
        Keyword.merge(original, auth_required: true, bcrypt_cost: 4)
      )

      try do
        assert call(:post, "/api/workspaces/#{URI.encode_www_form(ctx.open)}/bundle", reader).status ==
                 403

        assert call(:get, "/api/bundles/..%2F..%2Fetc%2Fpasswd", reader).status == 403
      after
        Application.put_env(:optimal_engine, :auth, original)
      end
    end
  end
end
