defmodule OptimalEngine.Compliance.ArtifactsTest do
  @moduledoc """
  The files a delete removes are of the shape this Engine writes, in the places it writes
  them, and nothing else: a recorded path is data, and a bundle import writes it too. The
  Engine's root, a tenant's directory of copies and another workspace's files are never
  removed, whatever a row says.
  """

  use ExUnit.Case, async: false

  alias OptimalEngine.Compliance.Artifacts
  alias OptimalEngine.Store

  @workspace "default:acme-sales"

  setup do
    n = System.unique_integer([:positive])
    root = Path.join(System.tmp_dir!(), "artifacts-#{n}")
    cache = Path.join(root, "cache")
    outside = Path.join(Path.dirname(root), "artifacts-outside-#{n}")
    File.mkdir_p!(cache)
    File.mkdir_p!(outside)

    saved = Map.new([:root_path, :cache_path], &{&1, Application.get_env(:optimal_engine, &1)})
    Application.put_env(:optimal_engine, :root_path, root)
    Application.put_env(:optimal_engine, :cache_path, cache)

    on_exit(fn ->
      Enum.each(saved, fn
        {name, nil} -> Application.delete_env(:optimal_engine, name)
        {name, value} -> Application.put_env(:optimal_engine, name, value)
      end)

      File.rm_rf(root)
      File.rm_rf(outside)
    end)

    %{n: n, root: root, cache: cache, outside: outside}
  end

  describe "a local asset" do
    test "is removed from the assets directory of its own workspace", ctx do
      default = file!(ctx.root, "assets/ab/default.bin")
      named = file!(ctx.root, "acme-sales/assets/cd/named.bin")
      tenanted = file!(ctx.root, "tenants/acme/sales/assets/ef/tenanted.bin")

      assert {:ok, %{files: 3}} =
               Artifacts.remove([
                 {:asset_file, default, "default"},
                 {:asset_file, named, @workspace},
                 {:asset_file, tenanted, "acme:sales"}
               ])

      for path <- [default, named, tenanted], do: refute(File.exists?(path))
    end

    test "is not removed when it is any other file of the root, or outside it", ctx do
      note = file!(ctx.root, "tenants/acme/sales/nodes/deal.md")
      state = file!(ctx.root, "index.db")
      hidden = file!(ctx.root, ".optimal/assets/ab/secret.bin")
      outside = file!(ctx.outside, "outside.bin")
      deep = file!(ctx.root, "a/b/c/assets/ab/too-deep.bin")

      paths = [note, state, hidden, outside, deep, ctx.root, Path.join(ctx.root, "assets")]

      for workspace <- ["default", @workspace, "acme:sales"] do
        assert {:ok, %{files: 0}} =
                 Artifacts.remove(Enum.map(paths, &{:asset_file, &1, workspace}))
      end

      for path <- [note, state, hidden, outside, deep], do: assert(File.exists?(path))
      assert File.dir?(ctx.root)
    end

    test "is not removed when a row names another workspace's file", ctx do
      theirs = file!(ctx.root, "other-team/assets/ab/theirs.bin")
      sales = file!(ctx.root, "acme-sales/assets/ab/sales.bin")
      tenanted = file!(ctx.root, "tenants/acme/sales/assets/ab/tenanted.bin")
      default = file!(ctx.root, "assets/ab/default.bin")

      # Each row is in a workspace whose directory is not the one the file is in.
      assert {:ok, %{files: 0}} =
               Artifacts.remove([
                 {:asset_file, theirs, @workspace},
                 {:asset_file, theirs, "default"},
                 {:asset_file, sales, "default"},
                 {:asset_file, tenanted, @workspace},
                 {:asset_file, default, @workspace}
               ])

      for path <- [theirs, sales, tenanted, default], do: assert(File.exists?(path))
    end

    test "a path that climbs out of the root is not followed", ctx do
      outside = file!(ctx.outside, "climbed.bin")
      climbing = Path.join(ctx.root, "assets/ab/../../../#{Path.basename(ctx.outside)}/climbed.bin")

      assert {:ok, %{files: 0}} = Artifacts.remove([{:asset_file, climbing, "default"}])
      assert File.exists?(outside)
    end

    test "a link is not followed", ctx do
      target = file!(ctx.outside, "linked.bin")
      link = Path.join(ctx.root, "assets/ab/link.bin")
      File.mkdir_p!(Path.dirname(link))
      File.ln_s!(target, link)

      assert {:ok, %{files: 0}} = Artifacts.remove([{:asset_file, link, "default"}])
      assert File.exists?(target)
    end

    test "a link in a directory above it is not followed", ctx do
      target = file!(ctx.outside, "assets/ab/kept.bin")
      File.mkdir_p!(Path.join(ctx.root, "acme-sales"))
      File.ln_s!(Path.join(ctx.outside, "assets"), Path.join(ctx.root, "acme-sales/assets"))

      assert {:ok, %{files: 0}} =
               Artifacts.remove([
                 {:asset_file, Path.join(ctx.root, "acme-sales/assets/ab/kept.bin"), @workspace}
               ])

      assert File.exists?(target)
    end

    test "a link in place of the workspace's directory is not followed", ctx do
      target = file!(ctx.outside, "assets/ab/kept.bin")
      File.ln_s!(ctx.outside, Path.join(ctx.root, "acme-sales"))

      assert {:ok, %{files: 0}} =
               Artifacts.remove([
                 {:asset_file, Path.join(ctx.root, "acme-sales/assets/ab/kept.bin"), @workspace}
               ])

      assert File.exists?(target)
    end
  end

  describe "a checkpoint" do
    test "is removed when it is the file this Engine names for the run and workspace", ctx do
      path = checkpoint!(ctx, "run-1", @workspace)

      assert {:ok, %{files: 1}} = Artifacts.remove([{:checkpoint, "run-1", path, @workspace}])
      refute File.exists?(path)
    end

    test "is not removed from anywhere but the checkpoint directory of the cache", ctx do
      # A forged row can name any run id and any path; only `<cache>/decomposition/<id>.json`
      # is a checkpoint.
      authority =
        file!(ctx.root, "agent-authority.json", checkpoint_body("agent-authority", @workspace))

      rooted = file!(ctx.root, "checkpoints/run-2.json", checkpoint_body("run-2", @workspace))
      cached = file!(ctx.cache, "elsewhere/run-3.json", checkpoint_body("run-3", @workspace))
      outside = file!(ctx.outside, "run-4.json", checkpoint_body("run-4", @workspace))

      assert {:ok, %{files: 0}} =
               Artifacts.remove([
                 {:checkpoint, "agent-authority", authority, @workspace},
                 {:checkpoint, "run-2", rooted, @workspace},
                 {:checkpoint, "run-3", cached, @workspace},
                 {:checkpoint, "run-4", outside, @workspace}
               ])

      for path <- [authority, rooted, cached, outside], do: assert(File.exists?(path))
    end

    test "is not removed under another run's name", ctx do
      other = checkpoint!(ctx, "run-other", @workspace)

      assert {:ok, %{files: 0}} = Artifacts.remove([{:checkpoint, "run-1", other, @workspace}])
      assert File.exists?(other)
    end

    test "is not removed for a run id that is not a plain id", ctx do
      spaced = checkpoint!(ctx, "run 5", @workspace)
      dotted = checkpoint!(ctx, "run.6", @workspace)

      assert {:ok, %{files: 0}} =
               Artifacts.remove([
                 {:checkpoint, "run 5", spaced, @workspace},
                 {:checkpoint, "run.6", dotted, @workspace}
               ])

      assert File.exists?(spaced)
      assert File.exists?(dotted)
    end

    test "is not removed when the file says it belongs to another run or workspace", ctx do
      other_workspace = checkpoint!(ctx, "run-7", "default:someone-else")
      other_run = checkpoint!(ctx, "run-8", @workspace, run_id: "run-9")
      not_json = file!(ctx.cache, "decomposition/run-10.json", "not json at all")
      no_identity = file!(ctx.cache, "decomposition/run-11.json", ~s({"output": {}}))

      assert {:ok, %{files: 0}} =
               Artifacts.remove([
                 {:checkpoint, "run-7", other_workspace, @workspace},
                 {:checkpoint, "run-8", other_run, @workspace},
                 {:checkpoint, "run-10", not_json, @workspace},
                 {:checkpoint, "run-11", no_identity, @workspace}
               ])

      for path <- [other_workspace, other_run, not_json, no_identity],
          do: assert(File.exists?(path))
    end

    test "is not removed when it is behind a link", ctx do
      File.rm_rf!(Path.join(ctx.cache, "decomposition"))
      target = file!(ctx.outside, "run-12.json", checkpoint_body("run-12", @workspace))
      File.ln_s!(ctx.outside, Path.join(ctx.cache, "decomposition"))

      assert {:ok, %{files: 0}} =
               Artifacts.remove([
                 {:checkpoint, "run-12", Path.join(ctx.cache, "decomposition/run-12.json"),
                  @workspace}
               ])

      assert File.exists?(target)
    end

    test "is not removed when the file itself is a link", ctx do
      target = file!(ctx.outside, "run-13.json", checkpoint_body("run-13", @workspace))
      link = Path.join(ctx.cache, "decomposition/run-13.json")
      File.mkdir_p!(Path.dirname(link))
      File.ln_s!(target, link)

      assert {:ok, %{files: 0}} = Artifacts.remove([{:checkpoint, "run-13", link, @workspace}])
      assert File.exists?(target)
    end
  end

  describe "the copy of an object-store asset" do
    test "is removed from the copy directory of its own workspace only", ctx do
      ours = file!(ctx.cache, "assets/default/#{@workspace}/assets/ab/ours.bin")
      theirs = file!(ctx.cache, "assets/default/default:someone-else/assets/ab/theirs.bin")
      tenants = file!(ctx.cache, "assets/other/#{@workspace}/assets/ab/other-tenant.bin")

      assert {:ok, %{files: 1}} =
               Artifacts.remove([
                 {:asset_copy, "s3://bucket/default/#{@workspace}/assets/ab/ours.bin", "default",
                  @workspace},
                 {:asset_copy, "s3://bucket/default/default:someone-else/assets/ab/theirs.bin",
                  "default", @workspace},
                 {:asset_copy, "s3://bucket/other/#{@workspace}/assets/ab/other-tenant.bin",
                  "default", @workspace}
               ])

      refute File.exists?(ours)
      assert File.exists?(theirs)
      assert File.exists?(tenants)
    end

    test "is not removed when its key climbs out of the workspace's directory", ctx do
      theirs = file!(ctx.cache, "assets/default/default:someone-else/assets/ab/theirs.bin")

      key = "default/#{@workspace}/../default:someone-else/assets/ab/theirs.bin"

      assert {:ok, %{files: 0}} =
               Artifacts.remove([{:asset_copy, "s3://bucket/#{key}", "default", @workspace}])

      assert File.exists?(theirs)
    end

    test "is not removed when a directory above it is a link", ctx do
      target = file!(ctx.outside, "assets/ab/kept.bin")
      File.mkdir_p!(Path.join(ctx.cache, "assets/default"))
      File.ln_s!(ctx.outside, Path.join(ctx.cache, "assets/default/#{@workspace}"))

      assert {:ok, %{files: 0}} =
               Artifacts.remove([
                 {:asset_copy, "s3://bucket/default/#{@workspace}/assets/ab/kept.bin", "default",
                  @workspace}
               ])

      assert File.exists?(target)
    end
  end

  describe "the copies of a workspace's object-store assets" do
    setup ctx do
      tenant = "default"

      workspaces =
        for id <- ["default:copies-#{ctx.n}", ".", ".."] do
          {:ok, _} =
            Store.raw_query(
              "INSERT OR IGNORE INTO workspaces (id, tenant_id, slug, name, status) VALUES (?1, ?2, ?3, ?3, 'active')",
              [id, tenant, "slug-#{String.replace(id, ~r/[^a-z0-9]/, "-")}-#{ctx.n}"]
            )

          id
        end

      on_exit(fn ->
        for id <- workspaces, do: Store.raw_query("DELETE FROM workspaces WHERE id = ?1", [id])
      end)

      %{tenant: tenant, workspace: hd(workspaces)}
    end

    test "go with the workspace, and no other workspace's", ctx do
      ours = file!(ctx.cache, "assets/#{ctx.tenant}/#{ctx.workspace}/assets/ab/ours.bin")
      theirs = file!(ctx.cache, "assets/#{ctx.tenant}/default:someone-else/assets/ab/theirs.bin")

      assert {:ok, %{files: 1}} = Artifacts.purge_workspace(ctx.workspace)

      refute File.exists?(ours)
      refute File.exists?(Path.dirname(Path.dirname(Path.dirname(ours))))
      assert File.exists?(theirs)
    end

    test "never take the tenant's directory, the copies directory or the root with them", ctx do
      theirs = file!(ctx.cache, "assets/#{ctx.tenant}/default:someone-else/assets/ab/theirs.bin")
      kept = file!(ctx.root, "engine-state")

      # A workspace id that names a directory above its own.
      for id <- [".", ".."] do
        assert {:ok, %{files: 0}} = Artifacts.purge_workspace(id)
      end

      assert File.exists?(theirs)
      assert File.exists?(kept)
      assert File.dir?(Path.join(ctx.cache, "assets"))
      assert File.dir?(ctx.root)
    end

    test "a directory of copies behind a link is not followed", ctx do
      target = file!(ctx.outside, "assets/ab/kept.bin")
      File.mkdir_p!(Path.join(ctx.cache, "assets/#{ctx.tenant}"))
      File.ln_s!(ctx.outside, Path.join(ctx.cache, "assets/#{ctx.tenant}/#{ctx.workspace}"))

      assert {:ok, _} = Artifacts.purge_workspace(ctx.workspace)

      assert File.exists?(target)
    end

    test "an empty workspace id is refused" do
      assert {:error, :invalid_workspace} = Artifacts.purge_workspace("")
    end
  end

  defp checkpoint!(ctx, run_id, workspace, opts \\ []) do
    file!(
      ctx.cache,
      "decomposition/#{run_id}.json",
      checkpoint_body(Keyword.get(opts, :run_id, run_id), workspace)
    )
  end

  defp checkpoint_body(run_id, workspace) do
    Jason.encode!(%{
      run_id: run_id,
      workspace_id: workspace,
      output: %{chunks: [%{text: "chunk text of #{run_id}"}]}
    })
  end

  defp file!(dir, relative, body \\ nil) do
    path = Path.join(dir, relative)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, body || "contents of #{relative}")
    path
  end
end
