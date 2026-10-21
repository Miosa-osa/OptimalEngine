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

  defp with_auth(fun) do
    original = Application.get_env(:optimal_engine, :auth, [])

    Application.put_env(
      :optimal_engine,
      :auth,
      Keyword.merge(original, auth_required: true, bcrypt_cost: 4)
    )

    try do
      fun.()
    after
      Application.put_env(:optimal_engine, :auth, original)
    end
  end

  defp admin_key(tenant) do
    {:ok, %{key: key}} =
      ApiKey.mint(%{tenant_id: tenant, name: "admin", scopes: ["*"], workspace_scope: ["*"]})

    key
  end

  defp json_call(method, path, token, body) do
    conn(method, path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer " <> token)
    |> Router.call(Router.init([]))
  end

  defp upload(token, bytes, headers \\ []) do
    headers
    |> Enum.reduce(conn(:post, "/api/bundles/import", bytes), fn {name, value}, conn ->
      put_req_header(conn, name, value)
    end)
    |> put_req_header("content-type", "application/gzip")
    |> put_req_header("authorization", "Bearer " <> token)
    |> Router.call(Router.init([]))
  end

  defp uploads_left(tenant),
    do: Path.wildcard(Path.join(WorkspaceBundle.bundle_dir(tenant), ".upload-*"), match_dot: true)

  # Upload limits for one test, and the size of every chunk read while it runs.
  defp with_upload_limits(limits, fun) do
    keys = [
      chunk_bytes: :bundle_upload_chunk_bytes,
      max_bytes: :bundle_max_bytes,
      deadline_ms: :bundle_upload_deadline_ms
    ]

    previous = Map.new(keys, fn {_, key} -> {key, Application.get_env(:optimal_engine, key)} end)

    Enum.each(limits, fn {name, value} ->
      Application.put_env(:optimal_engine, keys[name], value)
    end)

    handler = "bundle-upload-chunks-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:optimal_engine, :bundle, :upload_chunk],
      &__MODULE__.report_chunk/4,
      self()
    )

    try do
      fun.()
    after
      :telemetry.detach(handler)

      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:optimal_engine, key)
        {key, value} -> Application.put_env(:optimal_engine, key, value)
      end)
    end
  end

  @doc false
  def report_chunk(_event, %{bytes: bytes}, _meta, test), do: send(test, {:upload_chunk, bytes})

  defp chunks(acc \\ []) do
    receive do
      {:upload_chunk, bytes} -> chunks([bytes | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # Incompressible bytes in the workspace folder, so its bundle spans many chunks.
  defp noise(ctx) do
    dir = Filesystem.path(Application.get_env(:optimal_engine, :root_path), ctx.open)
    File.mkdir_p!(Path.join(dir, "nodes/notes"))
    File.write!(Path.join(dir, "nodes/notes/noise.bin"), :crypto.strong_rand_bytes(24_000))
  end

  # The source gives the workspace up, as a move does, so one test database can
  # stand in for the Engine the bundle goes to.
  defp give_up(ctx, manifest) do
    :ok = WorkspaceBundle.prepare_move(ctx.tenant, ctx.open, manifest["bundle_sha256"])

    {:ok, _} =
      WorkspaceBundle.finalize_move(ctx.tenant, ctx.open, manifest["bundle_sha256"], %{
        "target_url" => "https://other.example"
      })
  end

  # Exports the open workspace, has the source give it up (one database stands in
  # for two Engines), and makes the tenant that will import it.
  defp moved_target(ctx, label) do
    {:ok, manifest} = WorkspaceBundle.export(ctx.tenant, ctx.open, ctx.path)
    give_up(ctx, manifest)

    target = "#{label}-#{ctx.n}"
    {:ok, _} = Tenant.create(%{id: target, name: "Target"})
    target
  end

  # Adds a table to an exported bundle and signs the manifest again, as anyone
  # who can write a bundle can.
  defp craft_bundle(ctx, table, rows) do
    dir = Path.join(System.tmp_dir!(), "craft-#{ctx.n}-#{table}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    :ok =
      :erl_tar.extract(String.to_charlist(ctx.path), [:compressed, {:cwd, String.to_charlist(dir)}])

    {:ok, info} = Store.raw_query("PRAGMA table_info(#{table})", [])
    content = Enum.map_join(rows, "", &(Jason.encode!(&1) <> "\n"))
    File.write!(Path.join([dir, "tables", table <> ".jsonl"]), content)

    entry = %{
      "name" => table,
      "rows" => length(rows),
      "columns" => Enum.map(info, fn [_cid, name | _rest] -> name end),
      "sha256" => :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
    }

    manifest =
      dir
      |> Path.join("manifest.json")
      |> File.read!()
      |> Jason.decode!()
      |> Map.delete("bundle_sha256")
      |> Map.update!("tables", &(&1 ++ [entry]))

    manifest =
      Map.put(manifest, "bundle_sha256", OptimalEngine.Authority.CanonicalJSON.hash(manifest))

    File.write!(Path.join(dir, "manifest.json"), Jason.encode!(manifest, pretty: true))

    files =
      for f <- Path.wildcard(Path.join(dir, "**"), match_dot: true),
          File.regular?(f),
          do: {String.to_charlist(Path.relative_to(f, dir)), String.to_charlist(f)}

    :ok = :erl_tar.create(String.to_charlist(ctx.path), files, [:compressed])
  end

  defp call(method, path, token) do
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

  # Rewrites the bundle at `path` the way a release before mentions recorded a
  # tenant wrote it: no `tenant_id` on the mentions, in the rows, the column
  # list and the checksums.
  defp without_mention_tenant(path, n) do
    dir = Path.join(System.tmp_dir!(), "old-shape-#{n}")
    File.mkdir_p!(dir)
    :ok = :erl_tar.extract(String.to_charlist(path), [:compressed, {:cwd, String.to_charlist(dir)}])

    table_file = Path.join(dir, "tables/entity_mentions.jsonl")

    content =
      table_file
      |> File.stream!()
      |> Enum.map_join(fn line ->
        line |> Jason.decode!() |> Map.delete("tenant_id") |> Jason.encode!() |> Kernel.<>("\n")
      end)

    File.write!(table_file, content)
    sha = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

    manifest =
      Path.join(dir, "manifest.json")
      |> File.read!()
      |> Jason.decode!()
      |> Map.delete("bundle_sha256")
      |> Map.update!("tables", fn tables ->
        Enum.map(tables, fn
          %{"name" => "entity_mentions"} = table ->
            %{table | "sha256" => sha, "columns" => table["columns"] -- ["tenant_id"]}

          table ->
            table
        end)
      end)

    manifest =
      Map.put(manifest, "bundle_sha256", OptimalEngine.Authority.CanonicalJSON.hash(manifest))

    File.write!(Path.join(dir, "manifest.json"), Jason.encode!(manifest))

    files =
      for f <- Path.wildcard(Path.join(dir, "**"), match_dot: true),
          File.regular?(f),
          do: {String.to_charlist(Path.relative_to(f, dir)), String.to_charlist(f)}

    :ok = :erl_tar.create(String.to_charlist(path), files, [:compressed])
    File.rm_rf!(dir)
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
      {:ok, summary} = WorkspaceBundle.import(ctx.path, target, cross_tenant: true)
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

      assert {:error, :workspace_exists} =
               WorkspaceBundle.import(ctx.path, target, cross_tenant: true)

      assert {:ok, merged} =
               WorkspaceBundle.import(ctx.path, target, cross_tenant: true, mode: :merge)

      assert Enum.all?(
               Map.drop(merged.rows, ["decisions", "events", "observations"]),
               fn {_table, n} -> n == 0 end
             )
    end

    test "a move takes the workspace's mentions along, including one that records no tenant",
         ctx do
      {:ok, %{id: carried}} =
        OptimalEngine.EntityResolution.resolve(
          %{workspace_id: ctx.open, surface_text: "Carried #{ctx.n}"},
          tenant_id: ctx.tenant
        )

      # Written before mentions recorded a tenant, naming nothing.
      older = "mention-older-#{ctx.n}"

      {:ok, _} =
        Store.raw_query(
          "INSERT INTO entity_mentions (id, workspace_id, surface_text, normalized_text) VALUES (?1, ?2, 'Older', 'older')",
          [older, ctx.open]
        )

      {:ok, manifest} = WorkspaceBundle.export(ctx.tenant, ctx.open, ctx.path)
      :ok = WorkspaceBundle.prepare_move(ctx.tenant, ctx.open, manifest["bundle_sha256"])

      {:ok, _} =
        WorkspaceBundle.finalize_move(ctx.tenant, ctx.open, manifest["bundle_sha256"], %{
          "target_url" => "https://other.example"
        })

      assert {:ok, [[0]]} =
               Store.raw_query("SELECT COUNT(*) FROM entity_mentions WHERE workspace_id = ?1", [
                 ctx.open
               ])

      target = "target-#{ctx.n}"
      {:ok, _} = Tenant.create(%{id: target, name: "Target"})
      {:ok, summary} = WorkspaceBundle.import(ctx.path, target, cross_tenant: true)

      assert {:ok, rows} =
               Store.raw_query(
                 "SELECT id, tenant_id FROM entity_mentions WHERE workspace_id = ?1 ORDER BY id",
                 [summary.workspace_id]
               )

      assert Enum.sort(rows) == Enum.sort([[carried, target], [older, target]])
    end

    test "a move leaves another tenant's mention under the same id where it is", ctx do
      other = "other-#{ctx.n}"
      {:ok, _} = Tenant.create(%{id: other, name: "Other"})

      {:ok, %{id: mine}} =
        OptimalEngine.EntityResolution.resolve(
          %{workspace_id: ctx.open, surface_text: "Mine #{ctx.n}"},
          tenant_id: ctx.tenant
        )

      # Written under the registered id by another tenant (an earlier version
      # did not stop it): not this workspace's, so a move does not take it.
      {:ok, %{id: theirs}} =
        OptimalEngine.EntityResolution.resolve(
          %{workspace_id: ctx.open, surface_text: "Theirs #{ctx.n}"},
          tenant_id: other
        )

      {:ok, manifest} = WorkspaceBundle.export(ctx.tenant, ctx.open, ctx.path)

      assert %{"rows" => 1} =
               Enum.find(manifest["tables"], &(&1["name"] == "entity_mentions"))

      :ok = WorkspaceBundle.prepare_move(ctx.tenant, ctx.open, manifest["bundle_sha256"])

      {:ok, _} =
        WorkspaceBundle.finalize_move(ctx.tenant, ctx.open, manifest["bundle_sha256"], %{
          "target_url" => "https://other.example"
        })

      assert {:ok, [[ctx.open, other]]} ==
               Store.raw_query(
                 "SELECT workspace_id, tenant_id FROM entity_mentions WHERE id = ?1",
                 [theirs]
               )

      assert {:ok, [[0]]} =
               Store.raw_query("SELECT COUNT(*) FROM entity_mentions WHERE id = ?1", [mine])
    end

    test "a bundle exported before mentions recorded a tenant imports them under the target's",
         ctx do
      {:ok, %{id: carried}} =
        OptimalEngine.EntityResolution.resolve(
          %{workspace_id: ctx.open, surface_text: "Carried #{ctx.n}"},
          tenant_id: ctx.tenant
        )

      {:ok, manifest} = WorkspaceBundle.export(ctx.tenant, ctx.open, ctx.path)
      :ok = WorkspaceBundle.prepare_move(ctx.tenant, ctx.open, manifest["bundle_sha256"])

      {:ok, _} =
        WorkspaceBundle.finalize_move(ctx.tenant, ctx.open, manifest["bundle_sha256"], %{
          "target_url" => "https://other.example"
        })

      without_mention_tenant(ctx.path, ctx.n)

      target = "target-#{ctx.n}"
      {:ok, _} = Tenant.create(%{id: target, name: "Target"})
      assert {:ok, summary} = WorkspaceBundle.import(ctx.path, target, cross_tenant: true)

      assert {:ok, [[^target]]} =
               Store.raw_query(
                 "SELECT tenant_id FROM entity_mentions WHERE id = ?1 AND workspace_id = ?2",
                 [carried, summary.workspace_id]
               )
    end

    test "a renamed workspace keeps its id when moved into its own tenant, not its old slugs",
         ctx do
      {:ok, _} = Workspace.update(ctx.open, %{slug: "open-renamed"})
      {:ok, manifest} = WorkspaceBundle.export(ctx.tenant, ctx.open, ctx.path)

      # The source gives the workspace up, then the record goes too: the
      # target Engine has never seen this id.
      :ok = WorkspaceBundle.prepare_move(ctx.tenant, ctx.open, manifest["bundle_sha256"])

      {:ok, _} =
        WorkspaceBundle.finalize_move(ctx.tenant, ctx.open, manifest["bundle_sha256"], %{
          "target_url" => "https://other.example"
        })

      {:ok, _} = Store.raw_query("DELETE FROM uri_redirects WHERE workspace_id = ?1", [ctx.open])
      {:ok, _} = Store.raw_query("DELETE FROM workspaces WHERE id = ?1", [ctx.open])

      assert {:ok, summary} = WorkspaceBundle.import(ctx.path, ctx.tenant)
      assert summary.workspace_id == ctx.open

      {:ok, moved} = Workspace.get(ctx.open)
      assert moved.slug == "open-renamed"
      refute Map.has_key?(moved.metadata, "previous_slugs")
      assert Workspace.handles(ctx.open) == ["open-renamed"]
    end

    test "a bundle carries the external id into another tenant", ctx do
      external = "bundle-ext-#{ctx.n}"
      {:ok, _} = Workspace.update(ctx.open, %{external_id: external, slug: "opened"})
      {:ok, manifest} = WorkspaceBundle.export(ctx.tenant, ctx.open, ctx.path)
      assert manifest["workspace"]["external_id"] == external

      :ok = WorkspaceBundle.prepare_move(ctx.tenant, ctx.open, manifest["bundle_sha256"])

      {:ok, _} =
        WorkspaceBundle.finalize_move(ctx.tenant, ctx.open, manifest["bundle_sha256"], %{
          "target_url" => "https://other.example"
        })

      # The archived source keeps its external id value and its slugs.
      assert {:ok, %{status: :archived, external_id: ^external}} = Workspace.get(ctx.open)

      target = "bundle-ext-target-#{ctx.n}"
      {:ok, _} = Tenant.create(%{id: target, name: "Target"})
      assert {:ok, summary} = WorkspaceBundle.import(ctx.path, target, cross_tenant: true)
      assert summary.workspace_id == "#{target}:opened"
      assert summary.external_id == external
      assert summary.imported_external_id == nil

      assert {:ok, %{id: id}} = Workspace.get_by_external_id(external, target)
      assert id == summary.workspace_id

      # The slugs it held before stay reserved on the Engine it came from only.
      assert Workspace.handles(id) == ["opened"]
    end

    test "an import into the tenant of an archived holder keeps the external id", ctx do
      external = "bundle-archived-#{ctx.n}"
      {:ok, _} = Workspace.update(ctx.open, %{external_id: external})
      {:ok, manifest} = WorkspaceBundle.export(ctx.tenant, ctx.open, ctx.path)
      :ok = WorkspaceBundle.prepare_move(ctx.tenant, ctx.open, manifest["bundle_sha256"])

      {:ok, _} =
        WorkspaceBundle.finalize_move(ctx.tenant, ctx.open, manifest["bundle_sha256"], %{
          "target_url" => "https://same.example"
        })

      copy = "#{ctx.tenant}:copy"

      assert {:ok, summary} =
               WorkspaceBundle.import(ctx.path, ctx.tenant,
                 workspace_id: copy,
                 organization_id: "#{ctx.tenant}:org"
               )

      assert summary.external_id == external
      assert summary.imported_external_id == nil

      assert {:ok, %{id: ^copy}} = Workspace.get_by_external_id(external, ctx.tenant)
      assert {:ok, %{status: :archived, external_id: ^external}} = Workspace.get(ctx.open)
    end

    test "an import into a tenant where an active workspace holds the external id keeps it aside",
         ctx do
      external = "bundle-held-#{ctx.n}"
      {:ok, _} = Workspace.update(ctx.open, %{external_id: external})
      {:ok, manifest} = WorkspaceBundle.export(ctx.tenant, ctx.open, ctx.path)
      :ok = WorkspaceBundle.prepare_move(ctx.tenant, ctx.open, manifest["bundle_sha256"])

      {:ok, _} =
        WorkspaceBundle.finalize_move(ctx.tenant, ctx.open, manifest["bundle_sha256"], %{
          "target_url" => "https://same.example"
        })

      # Another workspace of the tenant was bound to the id after the move.
      {:ok, _} = Workspace.update(ctx.private, %{external_id: external})
      copy = "#{ctx.tenant}:copy"

      assert {:ok, summary} =
               WorkspaceBundle.import(ctx.path, ctx.tenant,
                 workspace_id: copy,
                 organization_id: "#{ctx.tenant}:org"
               )

      assert summary.workspace_id == copy
      assert summary.external_id == nil
      assert summary.imported_external_id == external

      assert {:ok, imported} = Workspace.get(copy)
      assert imported.external_id == nil
      assert imported.metadata["imported_external_id"] == external
      refute Map.has_key?(imported.metadata, "external_id")

      assert {:ok, %{id: holder}} = Workspace.get_by_external_id(external, ctx.tenant)
      assert holder == ctx.private
    end

    test "metadata writes that set one key keep the workspace's identity", ctx do
      external = "keys-#{ctx.n}"
      {:ok, _} = Workspace.update(ctx.open, %{external_id: external, slug: "open-renamed"})
      {:ok, _} = Scope.set_share_up(ctx.tenant, ctx.open, "none", "user:owner")

      {:ok, manifest} = WorkspaceBundle.export(ctx.tenant, ctx.open, ctx.path)
      :ok = WorkspaceBundle.prepare_move(ctx.tenant, ctx.open, manifest["bundle_sha256"])

      {:ok, _} =
        WorkspaceBundle.finalize_move(ctx.tenant, ctx.open, manifest["bundle_sha256"], %{
          "target_url" => "https://keys.example"
        })

      assert {:ok, [[^external, previous, "none", "https://keys.example"]]} =
               Store.raw_query(
                 """
                 SELECT json_extract(metadata, '$.external_id'), json_extract(metadata, '$.previous_slugs'),
                        json_extract(metadata, '$.share_up'), json_extract(metadata, '$.moved_to')
                 FROM workspaces WHERE id = ?1
                 """,
                 [ctx.open]
               )

      assert Jason.decode!(previous) == ["open"]
    end

    test "an export lands in its tenant's folder, out of another tenant's reach", ctx do
      other = "other-#{ctx.n}"
      {:ok, _} = Tenant.create(%{id: other, name: "Other"})

      with_auth(fn ->
        conn =
          json_call(
            :post,
            "/api/workspaces/#{URI.encode_www_form(ctx.open)}/bundle",
            admin_key(ctx.tenant),
            %{}
          )

        assert conn.status == 201
        name = Jason.decode!(conn.resp_body)["bundle"]
        exported = Path.join(WorkspaceBundle.bundle_dir(ctx.tenant), name)
        assert File.regular?(exported)
        assert {:ok, tenant} = WorkspaceBundle.source_tenant(exported)
        assert tenant == ctx.tenant

        intruder = admin_key(other)
        assert call(:get, "/api/bundles/#{name}", intruder).status == 404
        assert json_call(:post, "/api/bundles/import", intruder, %{"bundle" => name}).status == 404

        # Copied into the other tenant's folder, it still names its own tenant.
        File.cp!(exported, Path.join(WorkspaceBundle.bundle_dir(other), name))
        assert call(:get, "/api/bundles/#{name}", intruder).status == 404
        assert json_call(:post, "/api/bundles/import", intruder, %{"bundle" => name}).status == 404

        refused =
          json_call(:post, "/api/bundles/import", intruder, %{
            "bundle" => name,
            "cross_tenant" => true
          })

        assert refused.status == 403
        assert Jason.decode!(refused.resp_body)["error"] =~ "operator_only"

        upload = upload(intruder, File.read!(exported))
        assert upload.status == 403
        assert Jason.decode!(upload.resp_body)["error"] =~ "bundle_from_another_tenant"
        assert uploads_left(other) == []
        assert {:error, :not_found} = Workspace.get("#{other}:open")

        # Its own tenant downloads it.
        assert call(:get, "/api/bundles/#{name}", admin_key(ctx.tenant)).status == 200
      end)
    end

    test "a bundle from another tenant is imported only when the move is meant", ctx do
      {:ok, manifest} = WorkspaceBundle.export(ctx.tenant, ctx.open, ctx.path)
      give_up(ctx, manifest)

      target = "refused-#{ctx.n}"
      {:ok, _} = Tenant.create(%{id: target, name: "Refused"})
      assert {:error, :bundle_from_another_tenant} = WorkspaceBundle.import(ctx.path, target)
      assert {:error, :not_found} = Workspace.get("#{target}:open")

      # The Engine operator seeds the default tenant from it by name, and says so.
      name = "seed-#{ctx.n}.tar.gz"
      File.cp!(ctx.path, Path.join(WorkspaceBundle.bundle_dir("default"), name))
      seeded = "default:seeded-#{ctx.n}"
      operator = admin_key("default")

      with_auth(fn ->
        body = %{"bundle" => name, "workspace_id" => seeded}
        assert json_call(:post, "/api/bundles/import", operator, body).status == 404

        conn =
          json_call(:post, "/api/bundles/import", operator, Map.put(body, "cross_tenant", true))

        assert conn.status == 201
        assert Jason.decode!(conn.resp_body)["workspace_id"] == seeded
      end)
    end

    test "a raw upload streams in chunks, checks its sha256, and leaves no file behind", ctx do
      noise(ctx)
      {:ok, manifest} = WorkspaceBundle.export(ctx.tenant, ctx.open, ctx.path)
      give_up(ctx, manifest)
      {:ok, _} = Store.raw_query("DELETE FROM uri_redirects WHERE workspace_id = ?1", [ctx.open])
      {:ok, _} = Store.raw_query("DELETE FROM workspaces WHERE id = ?1", [ctx.open])

      bytes = File.read!(ctx.path)
      digest = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
      chunk = 1_024
      assert byte_size(bytes) > 8 * chunk

      with_upload_limits([chunk_bytes: chunk], fn ->
        with_auth(fn ->
          admin = admin_key(ctx.tenant)

          wrong = upload(admin, bytes, [{"x-bundle-sha256", String.duplicate("0", 64)}])
          assert wrong.status == 422
          assert Jason.decode!(wrong.resp_body)["received_sha256"] == digest
          assert uploads_left(ctx.tenant) == []
          assert {:error, :not_found} = Workspace.get(ctx.open)
          _ = chunks()

          conn = upload(admin, bytes, [{"x-bundle-sha256", digest}])
          assert conn.status == 201
          assert Jason.decode!(conn.resp_body)["workspace_id"] == ctx.open

          # Read a chunk at a time, never more than one chunk in hand.
          sizes = chunks()
          assert Enum.sum(sizes) == byte_size(bytes)
          assert Enum.all?(sizes, &(&1 <= chunk))
          assert length(sizes) == div(byte_size(bytes) + chunk - 1, chunk)
          assert uploads_left(ctx.tenant) == []
        end)
      end)
    end

    test "a raw upload past the size limit is refused with 413", ctx do
      noise(ctx)
      {:ok, _} = WorkspaceBundle.export(ctx.tenant, ctx.open, ctx.path)
      bytes = File.read!(ctx.path)
      assert byte_size(bytes) > 8_192

      with_upload_limits([chunk_bytes: 1_024, max_bytes: 2_048], fn ->
        with_auth(fn ->
          admin = admin_key(ctx.tenant)

          # A declared length past the limit is refused before a byte is read.
          declared = upload(admin, bytes, [{"content-length", Integer.to_string(byte_size(bytes))}])
          assert declared.status == 413
          assert chunks() == []

          # Without one, reading stops at the first chunk past the limit.
          streamed = upload(admin, bytes)
          assert streamed.status == 413
          assert Enum.sum(chunks()) == 3_072
          assert uploads_left(ctx.tenant) == []
        end)
      end)
    end

    test "a raw upload that outlasts its deadline is refused with 408 and leaves no file", ctx do
      noise(ctx)
      {:ok, _} = WorkspaceBundle.export(ctx.tenant, ctx.open, ctx.path)
      bytes = File.read!(ctx.path)

      with_upload_limits([chunk_bytes: 1_024, deadline_ms: 0], fn ->
        with_auth(fn ->
          late = upload(admin_key(ctx.tenant), bytes)
          assert late.status == 408
          assert late.resp_body =~ "upload_timeout"
          assert Enum.sum(chunks()) == 1_024
          assert uploads_left(ctx.tenant) == []
        end)
      end)
    end

    test "unfinished uploads and stale staging folders are swept, and nothing else", ctx do
      dir = WorkspaceBundle.bundle_dir(ctx.tenant)
      kept = Path.join(dir, "kept-#{ctx.n}.tar.gz")
      left = for suffix <- [".part", ".tar.gz"], do: Path.join(dir, ".upload-#{ctx.n}#{suffix}")
      Enum.each([kept | left], &File.write!(&1, "x"))

      staging = Path.join([Path.dirname(dir), "..", "staging"]) |> Path.expand()
      stale = Path.join(staging, "bundle-#{ctx.n}-stale")
      fresh = Path.join(staging, "bundle-#{ctx.n}-fresh")
      other = Path.join(staging, "other-#{ctx.n}")
      three_hours_ago = System.os_time(:second) - 3 * 3_600

      for folder <- [stale, fresh, other] do
        File.mkdir_p!(folder)
        File.write!(Path.join(folder, "manifest.json"), "{}")
      end

      File.touch!(stale, three_hours_ago)
      File.touch!(other, three_hours_ago)

      assert WorkspaceBundle.sweep_leftovers() >= 3
      refute Enum.any?(left, &File.exists?/1)
      refute File.exists?(stale)

      # An export, a staging folder still in use, and anything not a bundle's
      # stay where they are.
      assert File.exists?(kept)
      assert File.exists?(fresh)
      assert File.exists?(other)
      File.rm(kept)
      Enum.each([fresh, other], &File.rm_rf/1)
    end

    test "a retained export of a tenant whose id starts with upload- survives the sweep", ctx do
      tenant = "upload-x-#{ctx.n}"
      {:ok, _} = Tenant.create(%{id: tenant, name: "Upload X"})

      {:ok, _} =
        OptimalEngine.Organization.create(%{
          id: "#{tenant}:org",
          tenant_id: tenant,
          slug: "org",
          name: "Org"
        })

      {:ok, workspace} =
        Workspace.create(%{
          tenant_id: tenant,
          organization_id: "#{tenant}:org",
          slug: "open",
          name: "Open"
        })

      context(tenant, workspace.id, "upload-x-#{ctx.n}", "Kept", "a retained export")

      name = "#{tenant}-open-#{System.os_time(:second)}.tar.gz"
      path = Path.join(WorkspaceBundle.bundle_dir(tenant), name)
      {:ok, _} = WorkspaceBundle.export(tenant, workspace.id, path)
      assert {:ok, ^path} = WorkspaceBundle.bundle_path(tenant, name)

      WorkspaceBundle.sweep_leftovers()
      assert File.exists?(path)
      File.rm(path)
    end

    test "a table larger than one export page travels whole", ctx do
      {:ok, :inserted} =
        Store.transaction(fn txn ->
          for i <- 1..2_500 do
            {:ok, 1} =
              Store.txn_execute(
                txn,
                "INSERT INTO contexts (id, tenant_id, workspace_id, title, content, created_at, uri) VALUES (?1, ?2, ?3, ?4, 'paged', '2026-10-14T10:00:00Z', ?5)",
                [
                  "paged-#{ctx.n}-#{i}",
                  ctx.tenant,
                  ctx.open,
                  "Paged #{i}",
                  "optimal://#{ctx.open}/contexts/paged-#{i}"
                ]
              )
          end

          {:ok, :inserted}
        end)

      {:ok, manifest} = WorkspaceBundle.export(ctx.tenant, ctx.open, ctx.path)
      exported = Enum.find(manifest["tables"], &(&1["name"] == "contexts"))
      assert exported["rows"] >= 2_501

      :ok = WorkspaceBundle.prepare_move(ctx.tenant, ctx.open, manifest["bundle_sha256"])

      {:ok, _} =
        WorkspaceBundle.finalize_move(ctx.tenant, ctx.open, manifest["bundle_sha256"], %{
          "target_url" => "https://other.example"
        })

      target = "paged-#{ctx.n}"
      {:ok, _} = Tenant.create(%{id: target, name: "Paged"})
      {:ok, summary} = WorkspaceBundle.import(ctx.path, target, cross_tenant: true)
      assert summary.rows["contexts"] == exported["rows"]

      assert {:ok, [[count]]} =
               Store.raw_query("SELECT COUNT(DISTINCT id) FROM contexts WHERE workspace_id = ?1", [
                 summary.workspace_id
               ])

      assert count == exported["rows"]
    end

    test "an import told to consume its bundle deletes the file once it is unpacked", ctx do
      {:ok, manifest} = WorkspaceBundle.export(ctx.tenant, ctx.open, ctx.path)
      :ok = WorkspaceBundle.prepare_move(ctx.tenant, ctx.open, manifest["bundle_sha256"])

      {:ok, _} =
        WorkspaceBundle.finalize_move(ctx.tenant, ctx.open, manifest["bundle_sha256"], %{
          "target_url" => "https://other.example"
        })

      target = "consume-#{ctx.n}"
      {:ok, _} = Tenant.create(%{id: target, name: "Consume"})

      assert {:ok, %{bundle_sha256: sha256}} =
               WorkspaceBundle.import(ctx.path, target, cross_tenant: true, consume: true)

      assert sha256 == manifest["bundle_sha256"]
      refute File.exists?(ctx.path)
    end

    test "a bundle imports in small batches, parents before children", ctx do
      # The older memory points at the newer one, so in export order the child
      # row comes before its parent.
      {:ok, parent} =
        OptimalEngine.Memory.create(%{
          content: "Parent memory for the batch import",
          workspace_id: ctx.open,
          tenant_id: ctx.tenant
        })

      {:ok, _} =
        Store.raw_query("UPDATE memories SET parent_memory_id = ?1 WHERE id = ?2", [
          parent.id,
          ctx.memory_id
        ])

      {:ok, manifest} = WorkspaceBundle.export(ctx.tenant, ctx.open, ctx.path)
      :ok = WorkspaceBundle.prepare_move(ctx.tenant, ctx.open, manifest["bundle_sha256"])

      {:ok, _} =
        WorkspaceBundle.finalize_move(ctx.tenant, ctx.open, manifest["bundle_sha256"], %{
          "target_url" => "https://other.example"
        })

      target = "batch-#{ctx.n}"
      {:ok, _} = Tenant.create(%{id: target, name: "Batch target"})

      assert {:ok, summary} =
               WorkspaceBundle.import(ctx.path, target, cross_tenant: true, batch_rows: 1)

      assert {:ok, [[parent_id]]} =
               Store.raw_query(
                 "SELECT parent_memory_id FROM memories WHERE id = ?1 AND workspace_id = ?2",
                 [ctx.memory_id, summary.workspace_id]
               )

      assert parent_id == parent.id
      assert summary.rows["memories"] == 2
    end

    test "connectors, their run log, queued jobs and dead letters stay with the Engine that runs them",
         ctx do
      {:ok, _} =
        Store.raw_query(
          "INSERT INTO connectors (id, tenant_id, workspace_id, kind, config, enabled) VALUES (?1, ?2, ?3, 'gmail', '{}', 1)",
          ["bundle-conn-#{ctx.n}", ctx.tenant, ctx.open]
        )

      {:ok, _} =
        Store.raw_query(
          "INSERT INTO dead_letter_jobs (id, original_job_id, tenant_id, workspace_id, kind, attempts, final_error) VALUES (?1, 'job', ?2, ?3, 'noop', 5, 'boom')",
          ["bundle-dlj-#{ctx.n}", ctx.tenant, ctx.open]
        )

      {:ok, manifest} = WorkspaceBundle.export(ctx.tenant, ctx.open, ctx.path)
      names = Enum.map(manifest["tables"], & &1["name"])

      for operational <- ~w(connectors connector_runs jobs dead_letter_jobs processor_runs) do
        refute operational in names, "#{operational} travelled in the bundle"
      end

      assert "contexts" in names
    end

    test "a failed import leaves no workspace and no rows behind", ctx do
      {:ok, _manifest} = WorkspaceBundle.export(ctx.tenant, ctx.open, ctx.path)

      # The source still holds its rows, and row ids are unique per database,
      # so writing the contexts collides part way through the import.
      target = "failed-#{ctx.n}"
      {:ok, _} = Tenant.create(%{id: target, name: "Failed target"})

      assert {:error, {:import_failed, _table, _reason}} =
               WorkspaceBundle.import(ctx.path, target, cross_tenant: true, batch_rows: 1)

      assert {:error, :not_found} = OptimalEngine.Workspace.get("#{target}:open")

      for table <- ~w(contexts memories memory_embeddings open_loops) do
        assert {:ok, [[0]]} =
                 Store.raw_query(
                   "SELECT COUNT(*) FROM #{table} WHERE workspace_id = ?1",
                   ["#{target}:open"]
                 )
      end

      # The source is untouched.
      assert {:ok, [[n]]} =
               Store.raw_query("SELECT COUNT(*) FROM contexts WHERE workspace_id = ?1", [ctx.open])

      assert n >= 1
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

    test "a workspace is moved off only when its directory holds it alone" do
      for id <- ~w(default default:default default:tenants default:Tenants default:.optimal
                   default:.wiki default:nodes default:cache default:assets default:. t:..) do
        assert {:error, :workspace_directory_shared} = WorkspaceBundle.movable(id), id
      end

      for id <- ~w(default:notes t:notes other:projects) do
        assert :ok = WorkspaceBundle.movable(id), id
      end
    end

    test "a workspace whose directory is the Engine root is never moved off, and the root stays" do
      root = Application.get_env(:optimal_engine, :root_path)
      marker = Path.join(root, "move-root-marker-#{System.unique_integer([:positive])}.md")
      File.write!(marker, "keep")
      on_exit(fn -> File.rm(marker) end)

      assert Filesystem.path(root, "default") == root
      assert {:error, :workspace_directory_shared} = WorkspaceBundle.movable("default")
      assert {:error, :workspace_directory_shared} = WorkspaceBundle.movable("default:default")

      assert {:error, :workspace_directory_shared} =
               WorkspaceBundle.prepare_move("default", "default", "any-hash")

      assert {:error, :workspace_directory_shared} =
               WorkspaceBundle.finalize_move("default", "default", "any-hash", %{
                 "target_url" => "https://own-engine.example",
                 "target_workspace_id" => "own:default"
               })

      assert File.exists?(marker)

      assert {:ok, []} =
               Store.raw_query(
                 "SELECT 1 FROM uri_redirects WHERE tenant_id = 'default' AND workspace_id = 'default'",
                 []
               )
    end

    test "a workspace with a member and an operating document exports and imports", ctx do
      principal = "bundle-member-#{ctx.n}"

      {:ok, _} =
        OptimalEngine.Identity.Principal.upsert(%{
          id: principal,
          kind: :user,
          display_name: "Bundle Member",
          tenant_id: ctx.tenant
        })

      {:ok, _} = Workspace.add_member(ctx.open, principal, tenant_id: ctx.tenant)

      {:ok, _} =
        OptimalEngine.Operating.Protocol.put(
          ctx.tenant,
          "workspace",
          ctx.open,
          "protocol",
          "Bundle protocol #{ctx.n}",
          "u"
        )

      {:ok, manifest} = WorkspaceBundle.export(ctx.tenant, ctx.open, ctx.path)
      names = Enum.map(manifest["tables"], & &1["name"])
      assert "principals" in names and "operating_documents" in names

      # Everything an export writes, an import accepts.
      assert Enum.all?(names, &(&1 in WorkspaceBundle.exportable_tables()))
      assert "memory_reconstruction_steps" in WorkspaceBundle.exportable_tables()

      :ok = WorkspaceBundle.prepare_move(ctx.tenant, ctx.open, manifest["bundle_sha256"])

      {:ok, _} =
        WorkspaceBundle.finalize_move(ctx.tenant, ctx.open, manifest["bundle_sha256"], %{
          "target_url" => "https://other.example"
        })

      # One database stands in for two Engines: the target Engine has never seen
      # the member, so the source's principal row is not in the way.
      {:ok, _} = Store.raw_query("DELETE FROM principals WHERE id = ?1", [principal])

      target = "member-target-#{ctx.n}"
      {:ok, _} = Tenant.create(%{id: target, name: "Target"})

      assert {:ok, summary} = WorkspaceBundle.import(ctx.path, target, cross_tenant: true)

      assert {:ok, [[1]]} =
               Store.raw_query(
                 "SELECT COUNT(*) FROM workspace_members WHERE workspace_id = ?1 AND principal_id = ?2",
                 [summary.workspace_id, principal]
               )

      assert {:ok, [[content]]} =
               Store.raw_query(
                 "SELECT content FROM operating_documents WHERE tenant_id = ?1 AND scope_id = ?2 AND kind = 'protocol'",
                 [target, summary.workspace_id]
               )

      assert content == "Bundle protocol #{ctx.n}"
    end

    test "a row key that only looks like a column is refused, whatever its case", ctx do
      target = moved_target(ctx, "case-target")

      craft_bundle(ctx, "routing_rules", [
        %{
          "id" => "rule-case-#{ctx.n}",
          "tenant_id" => "ignored",
          "Workspace_ID" => "some-other-tenant:review",
          "field" => "sender",
          "pattern" => "a@example.com"
        }
      ])

      assert {:error, {:import_failed, "routing_rules", :unknown_column}} =
               WorkspaceBundle.import(ctx.path, target, cross_tenant: true)

      assert {:ok, [[0]]} =
               Store.raw_query("SELECT COUNT(*) FROM routing_rules WHERE id = ?1", [
                 "rule-case-#{ctx.n}"
               ])

      assert {:error, :not_found} = Workspace.get("#{target}:open")
    end

    test "a second spelling of tenant_id cannot take the first one's place in a principals row",
         ctx do
      target = moved_target(ctx, "twin-target")
      forged = "twin-principal-#{ctx.n}"

      craft_bundle(ctx, "principals", [
        %{
          "id" => forged,
          "tenant_id" => target,
          "TENANT_ID" => ctx.tenant,
          "kind" => "user",
          "display_name" => "Twin"
        }
      ])

      assert {:error, {:import_failed, "principals", :unknown_column}} =
               WorkspaceBundle.import(ctx.path, target, cross_tenant: true)

      assert {:ok, []} = Store.raw_query("SELECT tenant_id FROM principals WHERE id = ?1", [forged])
    end

    test "a row that leaves out its tenant lands in the importing tenant, not the column's default",
         ctx do
      target = moved_target(ctx, "default-target")
      id = "dq-omitted-#{ctx.n}"

      craft_bundle(ctx, "data_quality_snapshots", [
        %{
          "id" => id,
          "workspace_id" => "ignored",
          "health_score" => 1,
          "health_status" => "ok",
          "dashboard" => "{}"
        }
      ])

      assert {:ok, summary} = WorkspaceBundle.import(ctx.path, target, cross_tenant: true)

      assert {:ok, [[^target, workspace_id]]} =
               Store.raw_query(
                 "SELECT tenant_id, workspace_id FROM data_quality_snapshots WHERE id = ?1",
                 [id]
               )

      assert workspace_id == summary.workspace_id
    end

    test "an operating document is the workspace's, whatever scope it names", ctx do
      target = moved_target(ctx, "scope-target")

      craft_bundle(ctx, "operating_documents", [
        %{
          "tenant_id" => ctx.tenant,
          "scope_type" => "tenant",
          "scope_id" => ctx.tenant,
          "kind" => "protocol",
          "content" => "A tenant-wide protocol",
          "hash" => "h"
        }
      ])

      assert {:ok, summary} = WorkspaceBundle.import(ctx.path, target, cross_tenant: true)

      assert {:ok, [[scope_type, scope_id, tenant]]} =
               Store.raw_query(
                 "SELECT scope_type, scope_id, tenant_id FROM operating_documents WHERE content = 'A tenant-wide protocol'",
                 []
               )

      assert {scope_type, scope_id, tenant} == {"workspace", summary.workspace_id, target}
    end

    test "a member who is another tenant's principal is refused", ctx do
      target = moved_target(ctx, "member-guard-target")
      other = "other-tenant-#{ctx.n}"
      {:ok, _} = Tenant.create(%{id: other, name: "Other"})
      foreign = "foreign-principal-#{ctx.n}"

      {:ok, _} =
        OptimalEngine.Identity.Principal.upsert(%{
          id: foreign,
          kind: :user,
          display_name: "Foreign",
          tenant_id: other
        })

      craft_bundle(ctx, "workspace_members", [
        %{
          "tenant_id" => ctx.tenant,
          "workspace_id" => ctx.open,
          "principal_id" => foreign,
          "role" => "admin"
        }
      ])

      assert {:error, {:import_failed, "workspace_members", :foreign_principal}} =
               WorkspaceBundle.import(ctx.path, target, cross_tenant: true)

      assert {:ok, [[0]]} =
               Store.raw_query("SELECT COUNT(*) FROM workspace_members WHERE principal_id = ?1", [
                 foreign
               ])

      assert {:error, :not_found} = Workspace.get("#{target}:open")
    end

    test "a create import may name only a workspace of the importing tenant", ctx do
      target = moved_target(ctx, "name-target")

      assert {:error, :workspace_id_not_in_tenant} =
               WorkspaceBundle.import(ctx.path, target,
                 cross_tenant: true,
                 workspace_id: "beta-#{ctx.n}:review"
               )

      assert {:error, :invalid_workspace_id} =
               WorkspaceBundle.import(ctx.path, target, cross_tenant: true, workspace_id: "")

      assert {:error, :not_found} = Workspace.get("beta-#{ctx.n}:review")

      assert {:ok, %{workspace_id: workspace_id}} =
               WorkspaceBundle.import(ctx.path, target, cross_tenant: true, workspace_id: "review")

      assert workspace_id == "#{target}:review"
    end

    test "a crafted principals row is written into the importing tenant, whatever tenant it names",
         ctx do
      {:ok, manifest} = WorkspaceBundle.export(ctx.tenant, ctx.open, ctx.path)
      :ok = WorkspaceBundle.prepare_move(ctx.tenant, ctx.open, manifest["bundle_sha256"])

      {:ok, _} =
        WorkspaceBundle.finalize_move(ctx.tenant, ctx.open, manifest["bundle_sha256"], %{
          "target_url" => "https://other.example"
        })

      target = "principal-target-#{ctx.n}"
      {:ok, _} = Tenant.create(%{id: target, name: "Target"})
      forged = "crafted-principal-#{ctx.n}"

      craft_bundle(ctx, "principals", [
        %{
          "id" => forged,
          "tenant_id" => "some-other-tenant-#{ctx.n}",
          "kind" => "user",
          "display_name" => "Crafted"
        }
      ])

      # What a bundle may still do: add principals to the tenant that imports
      # it, under ids that tenant does not already have. It cannot name another
      # tenant's, and it cannot replace a principal that exists.
      assert {:ok, _summary} = WorkspaceBundle.import(ctx.path, target, cross_tenant: true)

      assert {:ok, [[^target]]} =
               Store.raw_query("SELECT tenant_id FROM principals WHERE id = ?1", [forged])
    end

    test "a crafted bundle cannot write a table the Engine keeps for itself", ctx do
      {:ok, _manifest} = WorkspaceBundle.export(ctx.tenant, ctx.open, ctx.path)

      target = "crafted-target-#{ctx.n}"
      {:ok, _} = Tenant.create(%{id: target, name: "T"})
      connector = "crafted-connector-#{ctx.n}"

      craft_bundle(ctx, "connectors", [
        %{
          "id" => connector,
          "tenant_id" => target,
          "workspace_id" => "#{target}:open",
          "kind" => "gmail",
          "config" =>
            ~s({"credential_source":"broker","broker_url":"https://api.miosa.ai/api/v1/connect/broker/credentials","broker_reference":"x"}),
          "enabled" => 1
        }
      ])

      assert {:error, {:table_not_allowed, ["connectors"]}} =
               WorkspaceBundle.import(ctx.path, target)

      assert {:ok, [[0]]} =
               Store.raw_query("SELECT COUNT(*) FROM connectors WHERE id = ?1", [connector])

      assert {:error, :not_found} = Workspace.get("#{target}:open")
    end

    test "nor a table that is not a workspace's data at all", ctx do
      {:ok, _manifest} = WorkspaceBundle.export(ctx.tenant, ctx.open, ctx.path)

      target = "crafted-tenants-#{ctx.n}"
      {:ok, _} = Tenant.create(%{id: target, name: "T"})

      craft_bundle(ctx, "tenants", [%{"id" => "crafted-tenant-#{ctx.n}", "name" => "Crafted"}])

      assert {:error, {:table_not_allowed, ["tenants"]}} = WorkspaceBundle.import(ctx.path, target)
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

    test "a link written with a renamed workspace's slug answers moved once it has moved", ctx do
      # The workspace is renamed, then moved: its id (the redirect's key) is
      # not the slug the link names.
      {:ok, _} = Workspace.update(ctx.open, %{slug: "open-renamed"})
      {:ok, manifest} = WorkspaceBundle.export(ctx.tenant, ctx.open, ctx.path)
      :ok = WorkspaceBundle.prepare_move(ctx.tenant, ctx.open, manifest["bundle_sha256"])

      target = %{"target_url" => "https://own-engine.example", "target_workspace_id" => "own:open"}

      assert {:ok, _} =
               WorkspaceBundle.finalize_move(
                 ctx.tenant,
                 ctx.open,
                 manifest["bundle_sha256"],
                 target
               )

      moved = %{
        "engine_url" => "https://own-engine.example",
        "workspace_id" => "own:open",
        "uri" => "optimal://own:open/contexts/x"
      }

      by_id = "optimal://#{ctx.open}/contexts/x"
      by_new_slug = "optimal://#{ctx.tenant}:open-renamed/contexts/x"

      assert {:moved, ^moved} = WorkspaceBundle.resolve(ctx.tenant, by_id)
      assert {:moved, ^moved} = WorkspaceBundle.resolve(ctx.tenant, by_new_slug)

      assert {:moved, %{"uri" => "optimal://own:open"}} =
               WorkspaceBundle.resolve(ctx.tenant, "optimal://#{ctx.tenant}:open-renamed")

      # A workspace that did not move still answers local by its id.
      {:ok, _} = Workspace.update(ctx.private, %{slug: "private-renamed"})

      assert {:local, "optimal://#{ctx.private}/contexts/y"} ==
               WorkspaceBundle.resolve(
                 ctx.tenant,
                 "optimal://#{ctx.tenant}:private-renamed/contexts/y"
               )
    end

    test "the export route names the ledger mark a seeded replica pulls from", ctx do
      {:ok, _} = OptimalEngine.Sync.enable(ctx.tenant, ctx.open, "user:owner")

      {:ok, %{key: admin}} =
        ApiKey.mint(%{tenant_id: ctx.tenant, name: "admin", scopes: ["*"], workspace_scope: ["*"]})

      original = Application.get_env(:optimal_engine, :auth, [])

      Application.put_env(
        :optimal_engine,
        :auth,
        Keyword.merge(original, auth_required: true, bcrypt_cost: 4)
      )

      try do
        conn = call(:post, "/api/workspaces/#{URI.encode_www_form(ctx.open)}/bundle", admin)
        assert conn.status == 201
        body = Jason.decode!(conn.resp_body)
        assert is_integer(body["ledger_sequence"])
        assert is_binary(body["bundle_sha256"])
      after
        Application.put_env(:optimal_engine, :auth, original)
      end
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
