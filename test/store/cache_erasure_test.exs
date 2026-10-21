defmodule OptimalEngine.Store.CacheErasureTest do
  @moduledoc """
  Deleting, archiving, moving or erasing leaves nothing of a workspace in the
  embedder's filesystem cache, and takes the vectors and chunks derived from an
  erased context with it.

  Each test embeds text under a workspace through the real embedder (against a stub
  endpoint), runs one removal path, and then reads the raw bytes of every file under
  the cache path for the text it embedded.
  """

  use ExUnit.Case, async: false

  import Plug.Test

  alias OptimalEngine.API.Router
  alias OptimalEngine.Compliance.{Erasure, Retention}
  alias OptimalEngine.DataSteward
  alias OptimalEngine.Embed.Text
  alias OptimalEngine.Identity.Principal
  alias OptimalEngine.Pipeline.Decomposer.Chunk
  alias OptimalEngine.Portability.WorkspaceBundle
  alias OptimalEngine.Store
  alias OptimalEngine.Tenancy.Tenant
  alias OptimalEngine.TestSupport.EmbedStub
  alias OptimalEngine.Workspace

  @saved [:cache_path, :text_embedding]

  setup do
    saved = Map.new(@saved, &{&1, Application.get_env(:optimal_engine, &1)})
    dir = Path.join(System.tmp_dir!(), "cache-erasure-#{System.unique_integer([:positive])}")
    Application.put_env(:optimal_engine, :cache_path, dir)

    {url, stop} = EmbedStub.start()
    Application.put_env(:optimal_engine, :text_embedding, url: url, dimensions: 4)

    on_exit(fn ->
      stop.()

      Enum.each(saved, fn
        {name, nil} -> Application.delete_env(:optimal_engine, name)
        {name, value} -> Application.put_env(:optimal_engine, name, value)
      end)

      File.rm_rf(dir)
    end)

    n = System.unique_integer([:positive])
    %{dir: dir, n: n, doomed: "doomed-marker-#{n}", kept: "kept-marker-#{n}"}
  end

  describe "archiving a workspace" do
    test "removes its cache entries and no other workspace's", ctx do
      {:ok, doomed} = Workspace.create(%{slug: "cache-doomed-#{ctx.n}", name: "Doomed"})
      {:ok, kept} = Workspace.create(%{slug: "cache-kept-#{ctx.n}", name: "Kept"})
      embed!("default", doomed.id, "#{ctx.doomed} first")
      embed!("default", doomed.id, "#{ctx.doomed} second")
      embed!("default", kept.id, "#{ctx.kept} only")
      assert length(cache_files(ctx.dir)) == 3

      assert :ok = Workspace.archive(doomed.id)

      assert length(cache_files(ctx.dir)) == 1
      refute marker_in_cache?(ctx.dir, ctx.doomed)

      # The other workspace still answers from its own entry.
      drain_requests()
      assert {:ok, _} = embed!("default", kept.id, "#{ctx.kept} only")
      refute_received {:embed_request, _, _}
    end
  end

  describe "archiving a workspace whose cache cannot be purged" do
    test "answers with the failure, and archiving again retries the purge", ctx do
      # File permissions do not bind the superuser, so the failure cannot be made as one.
      {uid, 0} = System.cmd("id", ["-u"])

      unless String.trim(uid) == "0" do
        {:ok, workspace} = Workspace.create(%{slug: "cache-stuck-#{ctx.n}", name: "Stuck"})
        embed!("default", workspace.id, "#{ctx.doomed} stuck")
        [entry] = cache_files(ctx.dir)
        shard = Path.dirname(entry)
        File.chmod!(shard, 0o500)
        on_exit(fn -> File.chmod(shard, 0o700) end)

        # The workspace is archived all the same, and the failure is not swallowed.
        assert {:error, {:cache_purge_failed, :eacces}} = Workspace.archive(workspace.id)
        assert {:ok, %{status: :archived}} = Workspace.get(workspace.id)

        # Over HTTP: a 500 that names the failure and no path.
        conn = conn(:post, "/api/workspaces/#{workspace.id}/archive")
        conn = Router.call(conn, Router.init([]))
        assert conn.status == 500
        assert conn.resp_body =~ "cache_purge_failed"
        refute conn.resp_body =~ ctx.dir

        File.chmod!(shard, 0o700)
        assert :ok = Workspace.archive(workspace.id)
        assert cache_files(ctx.dir) == []
      end
    end
  end

  describe "archiving a workspace also removes what stands in for its data" do
    test "decomposition checkpoints and asset copies, and no other workspace's", ctx do
      {:ok, doomed} = Workspace.create(%{slug: "files-doomed-#{ctx.n}", name: "Doomed"})
      {:ok, kept} = Workspace.create(%{slug: "files-kept-#{ctx.n}", name: "Kept"})
      doomed_run = checkpoint!(ctx, doomed.id, "run-doomed-#{ctx.n}", ctx.doomed)
      kept_run = checkpoint!(ctx, kept.id, "run-kept-#{ctx.n}", ctx.kept)
      doomed_copy = asset_copy!(ctx, doomed.id, "doomed-#{ctx.n}", ctx.doomed)
      kept_copy = asset_copy!(ctx, kept.id, "kept-#{ctx.n}", ctx.kept)

      assert :ok = Workspace.archive(doomed.id)

      refute File.exists?(doomed_run)
      refute File.exists?(doomed_copy)
      refute marker_in_cache?(ctx.dir, ctx.doomed)
      assert File.exists?(kept_run)
      assert File.exists?(kept_copy)

      # The pointer to a file that is gone is cleared; the other workspace's stays.
      assert pointer("run-doomed-#{ctx.n}") == nil
      assert pointer("run-kept-#{ctx.n}") == kept_run
    end

    test "a failure to remove one is the archive's failure, and archiving again retries", ctx do
      {:ok, workspace} = Workspace.create(%{slug: "files-stuck-#{ctx.n}", name: "Stuck"})
      run = checkpoint!(ctx, workspace.id, "run-stuck-#{ctx.n}", ctx.doomed)

      unless root?() do
        File.chmod!(Path.dirname(run), 0o500)
        on_exit(fn -> File.chmod(Path.dirname(run), 0o700) end)

        assert {:error, {:cache_purge_failed, {:checkpoint, :eacces}}} =
                 Workspace.archive(workspace.id)

        assert File.exists?(run)

        File.chmod!(Path.dirname(run), 0o700)
        assert :ok = Workspace.archive(workspace.id)
        refute File.exists?(run)
      end
    end
  end

  describe "erasing a principal" do
    test "removes the cache of the workspaces holding their contexts, and what is derived", ctx do
      {:ok, home} = Workspace.create(%{slug: "cache-erase-#{ctx.n}", name: "Erase"})
      {:ok, other} = Workspace.create(%{slug: "cache-bystander-#{ctx.n}", name: "Bystander"})
      principal = "user:cache-erase-#{ctx.n}@test"
      {:ok, _} = Principal.upsert(%{id: principal, kind: :user, display_name: "Subject"})

      text = "#{ctx.doomed} the subject's record"
      context!("erase-ctx-#{ctx.n}", "default", home.id, principal, text)
      derive!("erase-ctx-#{ctx.n}", "default", home.id, text)
      embed!("default", home.id, text)
      embed!("default", other.id, "#{ctx.kept} bystander")

      assert {:ok, report} = Erasure.erase(principal)

      # Nothing ties a context's vectors and chunks to it, so erasure deletes them by name.
      assert %{vectors: 1, chunks: 1, chunk_embeddings: 1} = report.deleted
      assert report.deleted.contexts >= 1
      assert count("vectors", "context_id", "erase-ctx-#{ctx.n}") == 0
      assert count("chunks", "signal_id", "erase-ctx-#{ctx.n}") == 0
      assert count("chunk_embeddings", "chunk_id", "erase-ctx-#{ctx.n}:chk-0") == 0

      assert %{workspaces: [workspace_id], files: 1, bytes: bytes} = report.cache_purged
      assert workspace_id == home.id
      assert bytes > 0
      assert length(cache_files(ctx.dir)) == 1
      refute marker_in_cache?(ctx.dir, ctx.doomed)

      drain_requests()
      embed!("default", other.id, "#{ctx.kept} bystander")
      refute_received {:embed_request, _, _}
    end

    test "erases a principal with more contexts than one batch holds", ctx do
      {:ok, home} = Workspace.create(%{slug: "cache-many-#{ctx.n}", name: "Many"})
      principal = "user:cache-many-#{ctx.n}@test"
      {:ok, _} = Principal.upsert(%{id: principal, kind: :user, display_name: "Subject"})

      count = OptimalEngine.Compliance.DerivedData.batch_size() * 2 + 5

      for i <- 1..count,
          do: context!("many-#{ctx.n}-#{i}", "default", home.id, principal, "text #{i}")

      assert {:ok, report} = Erasure.erase(principal)

      assert report.deleted.contexts == count
      assert count("contexts", "created_by", principal) == 0
      assert count("principals", "id", principal) == 0
    end

    test "removes the checkpoints of the contexts it erases and no other run's", ctx do
      {:ok, home} = Workspace.create(%{slug: "cache-runs-#{ctx.n}", name: "Runs"})
      principal = "user:cache-runs-#{ctx.n}@test"
      bystander = "user:cache-runs-other-#{ctx.n}@test"
      {:ok, _} = Principal.upsert(%{id: principal, kind: :user, display_name: "Subject"})
      {:ok, _} = Principal.upsert(%{id: bystander, kind: :user, display_name: "Other"})

      context!("runs-gone-#{ctx.n}", "default", home.id, principal, "the subject's text")
      context!("runs-kept-#{ctx.n}", "default", home.id, bystander, "another person's text")
      gone_run = checkpoint!(ctx, home.id, "run-gone-#{ctx.n}", ctx.doomed)
      kept_run = checkpoint!(ctx, home.id, "run-kept-#{ctx.n}", ctx.kept)
      link_package!("runs-gone-#{ctx.n}", "pkg-run-gone-#{ctx.n}")
      link_package!("runs-kept-#{ctx.n}", "pkg-run-kept-#{ctx.n}")

      assert {:ok, _report} = Erasure.erase(principal)

      refute File.exists?(gone_run)
      # A decomposition in flight, or one of a context that stays, keeps its checkpoint.
      assert File.exists?(kept_run)
      assert pointer("run-kept-#{ctx.n}") == kept_run
    end

    test "purges the cache of the principal's workspaces when a batch fails", ctx do
      {:ok, home} = Workspace.create(%{slug: "cache-failing-#{ctx.n}", name: "Failing"})
      principal = "user:cache-failing-#{ctx.n}@test"
      {:ok, _} = Principal.upsert(%{id: principal, kind: :user, display_name: "Subject"})

      count = OptimalEngine.Compliance.DerivedData.batch_size() + 5

      for i <- 1..count,
          do: context!("failing-#{ctx.n}-#{i}", "default", home.id, principal, "text #{i}")

      embed!("default", home.id, "#{ctx.doomed} embedded before the erasure")
      assert marker_in_cache?(ctx.dir, ctx.doomed)

      {:ok, _} =
        Store.raw_query(
          """
          CREATE TRIGGER IF NOT EXISTS cache_erasure_test_poison BEFORE DELETE ON contexts
          WHEN old.id = 'failing-#{ctx.n}-#{count}'
          BEGIN SELECT RAISE(ABORT, 'refused'); END
          """,
          []
        )

      on_exit(fn -> Store.raw_query("DROP TRIGGER IF EXISTS cache_erasure_test_poison", []) end)

      assert {:error, _} = Erasure.erase(principal)

      # Some contexts went before the batch that failed; what the cache holds for the
      # workspace must not outlive them.
      refute marker_in_cache?(ctx.dir, ctx.doomed)
    end

    test "the dry run also counts the claims, packages and pages it would delete", ctx do
      {:ok, home} = Workspace.create(%{slug: "cache-dry-#{ctx.n}", name: "Dry"})
      principal = "user:cache-dry-#{ctx.n}@test"
      {:ok, _} = Principal.upsert(%{id: principal, kind: :user, display_name: "Subject"})
      id = "dry-ctx-#{ctx.n}"
      context!(id, "default", home.id, principal, "dry body")

      {:ok, _} =
        Store.raw_query(
          "INSERT INTO source_packages (id, workspace_id, content_hash, raw_text) VALUES (?1, ?2, ?3, 'raw')",
          ["dry-pkg-#{ctx.n}", home.id, "dry-hash-#{ctx.n}"]
        )

      {:ok, _} =
        Store.raw_query(
          "INSERT INTO claims (id, workspace_id, source_package_id, signal_id, claim_text) VALUES (?1, ?2, ?3, ?4, 'a claim')",
          ["dry-claim-#{ctx.n}", home.id, "dry-pkg-#{ctx.n}", id]
        )

      {:ok, _} =
        Store.raw_query(
          "UPDATE contexts SET metadata = json_object('source_package_id', ?1) WHERE id = ?2",
          ["dry-pkg-#{ctx.n}", id]
        )

      assert {:ok, %{counts: %{claims: 1, source_packages: 1}}} = Erasure.preview(principal)
      assert count("claims", "id", "dry-claim-#{ctx.n}") == 1
      assert count("source_packages", "id", "dry-pkg-#{ctx.n}") == 1
    end

    test "the dry run counts the derived rows it would delete", ctx do
      {:ok, home} = Workspace.create(%{slug: "cache-preview-#{ctx.n}", name: "Preview"})
      principal = "user:cache-preview-#{ctx.n}@test"
      {:ok, _} = Principal.upsert(%{id: principal, kind: :user, display_name: "Subject"})
      context!("preview-ctx-#{ctx.n}", "default", home.id, principal, "preview body")
      derive!("preview-ctx-#{ctx.n}", "default", home.id, "preview body")

      assert {:ok, %{counts: %{contexts: 1, vectors: 1, chunks: 1}}} = Erasure.preview(principal)
      assert count("vectors", "context_id", "preview-ctx-#{ctx.n}") == 1
    end
  end

  describe "a retention sweep" do
    setup ctx do
      tenant = "cache-ret-#{ctx.n}"
      workspace = "#{tenant}:docs"
      %{tenant: tenant, workspace: workspace}
    end

    test "that deletes removes the derived rows and the workspace's cache", ctx do
      {:ok, _} =
        Retention.add_policy(
          tenant_id: ctx.tenant,
          scope_type: "tenant",
          ttl_days: 1,
          action: "delete"
        )

      text = "#{ctx.doomed} expired record"
      old_context!("ret-ctx-#{ctx.n}", ctx.tenant, ctx.workspace, text)
      derive!("ret-ctx-#{ctx.n}", ctx.tenant, ctx.workspace, text)
      embed!(ctx.tenant, ctx.workspace, text)
      embed!(ctx.tenant, "#{ctx.tenant}:elsewhere", "#{ctx.kept} elsewhere")

      assert {:ok, result} = Retention.sweep(tenant_id: ctx.tenant)

      assert %{policies_evaluated: 1, actions_taken: 1, errors: 0} = result
      refute Map.has_key?(result, :deleted_in)
      assert count("contexts", "id", "ret-ctx-#{ctx.n}") == 0
      assert count("vectors", "context_id", "ret-ctx-#{ctx.n}") == 0
      assert count("chunks", "signal_id", "ret-ctx-#{ctx.n}") == 0
      assert count("chunk_embeddings", "chunk_id", "ret-ctx-#{ctx.n}:chk-0") == 0

      assert length(cache_files(ctx.dir)) == 1
      refute marker_in_cache?(ctx.dir, ctx.doomed)
    end

    test "that deletes removes the deleted context's checkpoint and no other run's", ctx do
      {:ok, _} =
        Retention.add_policy(
          tenant_id: ctx.tenant,
          scope_type: "tenant",
          ttl_days: 1,
          action: "delete"
        )

      old_context!("ret-run-old-#{ctx.n}", ctx.tenant, ctx.workspace, "an expired record")
      context!("ret-run-new-#{ctx.n}", ctx.tenant, ctx.workspace, "user:test", "a current record")
      gone_run = checkpoint!(ctx, ctx.workspace, "run-ret-gone-#{ctx.n}", ctx.doomed)
      kept_run = checkpoint!(ctx, ctx.workspace, "run-ret-kept-#{ctx.n}", ctx.kept)
      link_package!("ret-run-old-#{ctx.n}", "pkg-run-ret-gone-#{ctx.n}")
      link_package!("ret-run-new-#{ctx.n}", "pkg-run-ret-kept-#{ctx.n}")

      assert {:ok, %{actions_taken: 1, errors: 0}} = Retention.sweep(tenant_id: ctx.tenant)

      assert count("contexts", "id", "ret-run-old-#{ctx.n}") == 0
      assert count("contexts", "id", "ret-run-new-#{ctx.n}") == 1
      refute File.exists?(gone_run)
      assert File.exists?(kept_run)
    end

    test "that only archives leaves the cache alone", ctx do
      {:ok, _} =
        Retention.add_policy(
          tenant_id: ctx.tenant,
          scope_type: "tenant",
          ttl_days: 1,
          action: "archive"
        )

      text = "#{ctx.kept} archived record"
      old_context!("ret-arch-#{ctx.n}", ctx.tenant, ctx.workspace, text)
      embed!(ctx.tenant, ctx.workspace, text)

      assert {:ok, %{actions_taken: 1, errors: 0}} = Retention.sweep(tenant_id: ctx.tenant)

      assert length(cache_files(ctx.dir)) == 1
    end

    test "a dry run purges nothing", ctx do
      {:ok, _} =
        Retention.add_policy(
          tenant_id: ctx.tenant,
          scope_type: "tenant",
          ttl_days: 1,
          action: "delete"
        )

      text = "#{ctx.kept} dry run record"
      old_context!("ret-dry-#{ctx.n}", ctx.tenant, ctx.workspace, text)
      embed!(ctx.tenant, ctx.workspace, text)

      assert {:ok, %{actions_taken: 0}} = Retention.sweep(tenant_id: ctx.tenant, dry_run: true)

      assert count("contexts", "id", "ret-dry-#{ctx.n}") == 1
      assert length(cache_files(ctx.dir)) == 1
    end
  end

  describe "moving a workspace to another Engine" do
    test "finalizing the move removes the cache with the rows and files", ctx do
      tenant = "cache-move-#{ctx.n}"
      {:ok, _} = Tenant.create(%{id: tenant, name: "Move #{ctx.n}"})

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
          slug: "moving",
          name: "Moving"
        })

      embed!(tenant, workspace.id, "#{ctx.doomed} about to move")
      assert length(cache_files(ctx.dir)) == 1

      path = Path.join(System.tmp_dir!(), "cache-move-#{ctx.n}.tar.gz")
      on_exit(fn -> File.rm(path) end)
      {:ok, manifest} = WorkspaceBundle.export(tenant, workspace.id, path)
      :ok = WorkspaceBundle.prepare_move(tenant, workspace.id, manifest["bundle_sha256"])

      assert {:ok, result} =
               WorkspaceBundle.finalize_move(tenant, workspace.id, manifest["bundle_sha256"], %{
                 "target_url" => "https://other.example"
               })

      assert %{files: 1} = result.cache_purged
      assert cache_files(ctx.dir) == []
      refute marker_in_cache?(ctx.dir, ctx.doomed)
    end
  end

  describe "moving a workspace also removes the files its rows point at" do
    test "decomposition checkpoints, though the rows go first", ctx do
      tenant = "files-move-#{ctx.n}"
      {:ok, _} = Tenant.create(%{id: tenant, name: "Move #{ctx.n}"})

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
          slug: "moving",
          name: "Moving"
        })

      run = checkpoint!(ctx, workspace.id, "run-move-#{ctx.n}", ctx.doomed)
      copy = asset_copy!(ctx, workspace.id, "move-#{ctx.n}", ctx.doomed, tenant)

      path = Path.join(System.tmp_dir!(), "files-move-#{ctx.n}.tar.gz")
      on_exit(fn -> File.rm(path) end)
      {:ok, manifest} = WorkspaceBundle.export(tenant, workspace.id, path)
      :ok = WorkspaceBundle.prepare_move(tenant, workspace.id, manifest["bundle_sha256"])

      assert {:ok, result} =
               WorkspaceBundle.finalize_move(tenant, workspace.id, manifest["bundle_sha256"], %{
                 "target_url" => "https://other.example"
               })

      assert result.cache_purged.files >= 2
      refute File.exists?(run)
      refute File.exists?(copy)
      refute marker_in_cache?(ctx.dir, ctx.doomed)
    end
  end

  describe "the data steward" do
    test "renaming a workspace's id removes what the cache held under the old one", ctx do
      {:ok, workspace} = Workspace.create(%{slug: "steward-old-#{ctx.n}", name: "Steward"})
      {:ok, _} = Workspace.update(workspace.id, %{slug: "steward-new-#{ctx.n}"})
      embed!("default", workspace.id, "#{ctx.doomed} under the old id")
      assert length(cache_files(ctx.dir)) == 1

      assert {:ok, result} =
               DataSteward.rename_workspace(workspace.id, "default:steward-new-#{ctx.n}",
                 actor_id: "user:test",
                 tenant_id: "default"
               )

      assert %{files: 1} = result.cache_purged
      assert cache_files(ctx.dir) == []
      refute marker_in_cache?(ctx.dir, ctx.doomed)
    end

    test "re-homing an orphaned scope removes what the cache held under it", ctx do
      {:ok, target} = Workspace.create(%{slug: "steward-home-#{ctx.n}", name: "Home"})
      orphan = "default:orphan-#{ctx.n}"
      context!("orphan-ctx-#{ctx.n}", "default", orphan, "user:test", "orphaned body")
      embed!("default", orphan, "#{ctx.doomed} orphaned")
      embed!("default", target.id, "#{ctx.kept} at home")

      assert {:ok, result} =
               DataSteward.repair_orphan_scope(orphan, target.id,
                 actor_id: "user:test",
                 tenant_id: "default"
               )

      assert %{files: 1} = result.cache_purged
      assert length(cache_files(ctx.dir)) == 1
      refute marker_in_cache?(ctx.dir, ctx.doomed)
    end
  end

  # A decomposition run of a workspace and the checkpoint file it points at, which
  # carries chunk text.
  defp checkpoint!(ctx, workspace_id, run_id, text) do
    path = Path.join([ctx.dir, "decomposition", "#{run_id}.json"])
    File.mkdir_p!(Path.dirname(path))

    File.write!(
      path,
      Jason.encode!(%{
        run_id: run_id,
        workspace_id: workspace_id,
        output: %{chunks: [%{text: text}]}
      })
    )

    {:ok, _} =
      Store.raw_query(
        """
        INSERT INTO decomposition_runs (id, organization_id, workspace_id, source_package_id, strategy, checkpoint_uri)
        VALUES (?1, 'org', ?2, ?3, 'deterministic', ?4)
        """,
        [run_id, workspace_id, "pkg-#{run_id}", path]
      )

    path
  end

  # An asset stored in an object store, and the local copy made for a parser.
  defp asset_copy!(ctx, workspace_id, name, text, tenant \\ "default") do
    key = "#{tenant}/#{workspace_id}/assets/ab/#{name}.bin"
    copy = Path.join([ctx.dir, "assets", key])
    File.mkdir_p!(Path.dirname(copy))
    File.write!(copy, text)

    {:ok, _} =
      Store.raw_query(
        """
        INSERT INTO assets (id, tenant_id, content_type, size_bytes, storage_path, workspace_id)
        VALUES (?1, ?5, 'text/plain', ?2, ?3, ?4)
        """,
        ["asset-#{name}", byte_size(text), "s3://bucket/#{key}", workspace_id, tenant]
      )

    copy
  end

  # The context was made from this source package, which is how the rows of a package
  # (its decomposition runs among them) are found when the context is deleted.
  defp link_package!(context_id, package_id) do
    {:ok, _} =
      Store.raw_query(
        "UPDATE contexts SET metadata = json_object('source_package_id', ?1) WHERE id = ?2",
        [package_id, context_id]
      )
  end

  defp pointer(run_id) do
    {:ok, [[uri]]} =
      Store.raw_query("SELECT checkpoint_uri FROM decomposition_runs WHERE id = ?1", [run_id])

    uri
  end

  defp root?, do: match?({"0\n", 0}, System.cmd("id", ["-u"]))

  defp embed!(tenant_id, workspace_id, text) do
    {:ok, _vector} = result = Text.embed(text, tenant_id: tenant_id, workspace_id: workspace_id)
    result
  end

  defp context!(id, tenant, workspace, created_by, text) do
    {:ok, _} =
      Store.raw_query(
        """
        INSERT INTO contexts (id, tenant_id, workspace_id, uri, title, content, created_by, genre, node)
        VALUES (?1, ?2, ?3, ?4, 't', ?5, ?6, 'note', 'person-operator')
        """,
        [id, tenant, workspace, "optimal://cache-erasure/#{id}", text, created_by]
      )
  end

  defp old_context!(id, tenant, workspace, text) do
    {:ok, _} =
      Store.raw_query(
        """
        INSERT INTO contexts (id, tenant_id, workspace_id, uri, title, content, genre, node, created_at)
        VALUES (?1, ?2, ?3, ?4, 't', ?5, 'note', 'person-operator', '2020-01-01T00:00:00Z')
        """,
        [id, tenant, workspace, "optimal://cache-erasure/#{id}", text]
      )
  end

  # A document vector, a chunk and its vector: what ingest derives from a context.
  defp derive!(context_id, tenant, workspace, text) do
    vector = [1.0, 0.0, 0.0, 0.0]

    chunk =
      Chunk.new(
        id: "#{context_id}:chk-0",
        signal_id: context_id,
        tenant_id: tenant,
        workspace_id: workspace,
        text: text
      )

    :ok = Store.insert_chunks([chunk])

    :ok =
      Store.insert_embeddings([
        %{
          chunk_id: chunk.id,
          tenant_id: tenant,
          model: "test",
          modality: :text,
          dim: 4,
          vector: vector,
          workspace_id: workspace
        }
      ])

    :ok = Store.Vectors.store(context_id, vector, workspace_id: workspace)
  end

  defp count(table, column, value) do
    {:ok, [[n]]} = Store.raw_query("SELECT COUNT(*) FROM #{table} WHERE #{column} = ?1", [value])
    n
  end

  defp drain_requests do
    receive do
      {:embed_request, _, _} -> drain_requests()
    after
      0 -> :ok
    end
  end

  defp cache_files(dir) do
    dir |> Path.join("**/*") |> Path.wildcard(match_dot: true) |> Enum.filter(&File.regular?/1)
  end

  # The raw bytes of every file under the cache path, read for the text that was embedded.
  defp marker_in_cache?(dir, marker) do
    dir |> cache_files() |> Enum.any?(&(:binary.match(File.read!(&1), marker) != :nomatch))
  end
end
