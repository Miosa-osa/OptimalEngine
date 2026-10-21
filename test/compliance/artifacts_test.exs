defmodule OptimalEngine.Compliance.ArtifactsTest do
  @moduledoc """
  The files a delete removes are of the shape this Engine writes, in the places it writes
  them, and nothing else: a recorded path is data, and a bundle import writes it too. The
  Engine's root, a tenant's directory of copies and another workspace's files are never
  removed.
  """

  use ExUnit.Case, async: false

  alias OptimalEngine.Compliance.Artifacts
  alias OptimalEngine.Store

  setup do
    n = System.unique_integer([:positive])
    root = Path.join(System.tmp_dir!(), "artifacts-#{n}")
    cache = Path.join(root, "cache")
    File.mkdir_p!(cache)

    saved = Map.new([:root_path, :cache_path], &{&1, Application.get_env(:optimal_engine, &1)})
    Application.put_env(:optimal_engine, :root_path, root)
    Application.put_env(:optimal_engine, :cache_path, cache)

    on_exit(fn ->
      Enum.each(saved, fn
        {name, nil} -> Application.delete_env(:optimal_engine, name)
        {name, value} -> Application.put_env(:optimal_engine, name, value)
      end)

      File.rm_rf(root)
    end)

    %{n: n, root: root, cache: cache}
  end

  describe "a local asset" do
    test "is removed from an assets directory of a workspace under the root", ctx do
      default = file!(ctx.root, "assets/ab/default.bin")
      named = file!(ctx.root, "acme-sales/assets/cd/named.bin")
      tenanted = file!(ctx.root, "tenants/acme/sales/assets/ef/tenanted.bin")

      assert {:ok, %{files: 3}} =
               Artifacts.remove(Enum.map([default, named, tenanted], &{:asset_file, &1}))

      for path <- [default, named, tenanted], do: refute(File.exists?(path))
    end

    test "is not removed when it is any other file of the root, or outside it", ctx do
      note = file!(ctx.root, "tenants/acme/sales/nodes/deal.md")
      state = file!(ctx.root, "index.db")
      hidden = file!(ctx.root, ".optimal/assets/ab/secret.bin")
      outside = file!(Path.dirname(ctx.root), "outside-#{ctx.n}.bin")
      on_exit(fn -> File.rm(outside) end)
      deep = file!(ctx.root, "a/b/c/assets/ab/too-deep.bin")

      paths = [note, state, hidden, outside, deep, ctx.root, Path.join(ctx.root, "assets")]

      assert {:ok, %{files: 0}} = Artifacts.remove(Enum.map(paths, &{:asset_file, &1}))

      for path <- [note, state, hidden, outside, deep], do: assert(File.exists?(path))
      assert File.dir?(ctx.root)
    end

    test "a path that climbs out of the root is not followed", ctx do
      outside = file!(Path.dirname(ctx.root), "climbed-#{ctx.n}.bin")
      on_exit(fn -> File.rm(outside) end)
      climbing = Path.join(ctx.root, "assets/ab/../../../climbed-#{ctx.n}.bin")

      assert {:ok, %{files: 0}} = Artifacts.remove([{:asset_file, climbing}])
      assert File.exists?(outside)
    end

    test "a link is not followed", ctx do
      target = file!(Path.dirname(ctx.root), "linked-#{ctx.n}.bin")
      on_exit(fn -> File.rm(target) end)
      link = Path.join(ctx.root, "assets/ab/link.bin")
      File.mkdir_p!(Path.dirname(link))
      File.ln_s!(target, link)

      assert {:ok, %{files: 0}} = Artifacts.remove([{:asset_file, link}])
      assert File.exists?(target)
    end
  end

  describe "a checkpoint" do
    test "is removed when it is named for its run and is under the cache or the root", ctx do
      cached = file!(ctx.cache, "decomposition/run-1.json")
      rooted = file!(ctx.root, "checkpoints/run-2.json")

      assert {:ok, %{files: 2}} =
               Artifacts.remove([
                 {:checkpoint, "run-1", cached},
                 {:checkpoint, "run-2", rooted}
               ])

      refute File.exists?(cached)
      refute File.exists?(rooted)
    end

    test "is not removed under another name or outside the Engine's directories", ctx do
      misnamed = file!(ctx.cache, "decomposition/other.json")
      outside = file!(Path.dirname(ctx.root), "run-3-#{ctx.n}.json")
      on_exit(fn -> File.rm(outside) end)

      assert {:ok, %{files: 0}} =
               Artifacts.remove([
                 {:checkpoint, "run-1", misnamed},
                 {:checkpoint, "run-3-#{ctx.n}", outside}
               ])

      assert File.exists?(misnamed)
      assert File.exists?(outside)
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

    test "an empty workspace id is refused" do
      assert {:error, :invalid_workspace} = Artifacts.purge_workspace("")
    end
  end

  defp file!(dir, relative) do
    path = Path.join(dir, relative)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "contents of #{relative}")
    path
  end
end
