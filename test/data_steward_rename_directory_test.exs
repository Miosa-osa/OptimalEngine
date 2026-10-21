defmodule OptimalEngine.DataStewardRenameDirectoryTest do
  @moduledoc """
  A workspace's directory is keyed by its id, so renaming the id moves the directory with
  it: the files, the paths and addresses that name them, in the transaction that renames
  the rows. A directory that cannot be moved safely refuses the rename and changes nothing.
  """

  use ExUnit.Case, async: false

  alias OptimalEngine.DataSteward
  alias OptimalEngine.Store
  alias OptimalEngine.Tenancy.Tenant
  alias OptimalEngine.URI, as: OptimalURI
  alias OptimalEngine.Workspace

  setup do
    n = System.unique_integer([:positive])
    root = Path.join(System.tmp_dir!(), "steward-rename-#{n}")
    File.mkdir_p!(root)
    saved = Application.get_env(:optimal_engine, :root_path)
    Application.put_env(:optimal_engine, :root_path, root)

    on_exit(fn ->
      if saved,
        do: Application.put_env(:optimal_engine, :root_path, saved),
        else: Application.delete_env(:optimal_engine, :root_path)

      File.rm_rf(root)
    end)

    %{n: n, root: root, old: "rename-old-#{n}", new: "rename-new-#{n}"}
  end

  defp rename(workspace_id, target, tenant \\ "default") do
    DataSteward.rename_workspace(workspace_id, target,
      tenant_id: tenant,
      actor_id: "user:test"
    )
  end

  # A workspace whose slug was changed after it was created, which is what leaves its id
  # not matching its slug.
  defp mismatched!(ctx) do
    {:ok, workspace} = Workspace.create(%{slug: ctx.old, name: "Rename #{ctx.n}"})
    {:ok, _} = Workspace.update(workspace.id, %{slug: ctx.new})
    workspace
  end

  test "moves the directory, its files, and the paths and addresses that name them", ctx do
    workspace = mismatched!(ctx)
    old_dir = Path.join(ctx.root, ctx.old)
    new_dir = Path.join(ctx.root, ctx.new)

    signal = file!(old_dir, "nodes/sales/signals/deal.md")
    asset = file!(old_dir, "assets/ab/hash.bin")
    other = file!(ctx.root, "elsewhere/signals/keep.md")
    context!(ctx, "signal", workspace.id, signal)
    context!(ctx, "other", workspace.id, other)

    {:ok, _} =
      Store.raw_query(
        "INSERT INTO assets (id, tenant_id, content_type, size_bytes, storage_path, workspace_id) VALUES (?1, 'default', 'x', 1, ?2, ?3)",
        ["asset-#{ctx.n}", asset, workspace.id]
      )

    assert {:ok, %{directory_moved: true}} = rename(workspace.id, "default:" <> ctx.new)

    moved = Path.join(new_dir, "nodes/sales/signals/deal.md")
    assert File.exists?(moved)
    assert File.exists?(Path.join(new_dir, "assets/ab/hash.bin"))
    refute File.exists?(old_dir)

    assert {:ok, [[^moved, uri]]} =
             Store.raw_query("SELECT path, uri FROM contexts WHERE id = ?1", ["ctx-signal-#{ctx.n}"])

    assert uri == OptimalURI.from_path(moved)

    assert {:ok, [[storage]]} =
             Store.raw_query("SELECT storage_path FROM assets WHERE id = ?1", ["asset-#{ctx.n}"])

    assert storage == Path.join(new_dir, "assets/ab/hash.bin")

    # A path that was not under the directory is not touched.
    assert {:ok, [[^other]]} =
             Store.raw_query("SELECT path FROM contexts WHERE id = ?1", ["ctx-other-#{ctx.n}"])
  end

  test "a workspace of another tenant moves within its tenant's directory", ctx do
    tenant = "rename-t-#{ctx.n}"
    {:ok, _} = Tenant.create(%{id: tenant, name: "Rename #{ctx.n}"})

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
        slug: ctx.old,
        name: "Tenanted"
      })

    {:ok, _} = Workspace.update(workspace.id, %{slug: ctx.new})
    kept = file!(Path.join(ctx.root, "tenants/#{tenant}/#{ctx.old}"), "nodes/sales/signals/a.md")

    assert {:ok, %{directory_moved: true}} = rename(workspace.id, "#{tenant}:" <> ctx.new, tenant)

    refute File.exists?(kept)

    assert File.exists?(
             Path.join(ctx.root, "tenants/#{tenant}/#{ctx.new}/nodes/sales/signals/a.md")
           )
  end

  test "a target directory that holds only empty directories is replaced", ctx do
    workspace = mismatched!(ctx)
    file!(Path.join(ctx.root, ctx.old), "nodes/a.md")
    File.mkdir_p!(Path.join(ctx.root, "#{ctx.new}/nodes/empty"))

    assert {:ok, %{directory_moved: true}} = rename(workspace.id, "default:" <> ctx.new)

    assert File.exists?(Path.join(ctx.root, "#{ctx.new}/nodes/a.md"))
  end

  test "a workspace with no directory is renamed with nothing to move", ctx do
    workspace = mismatched!(ctx)
    File.rm_rf!(Path.join(ctx.root, ctx.old))

    assert {:ok, %{directory_moved: false}} = rename(workspace.id, "default:" <> ctx.new)

    refute File.exists?(Path.join(ctx.root, ctx.new))
    assert {:ok, %{id: id}} = Workspace.get_by_handle(ctx.new, "default")
    assert id == "default:" <> ctx.new
  end

  describe "a rename that cannot move the directory safely" do
    test "is refused when the target directory holds files, and changes nothing", ctx do
      workspace = mismatched!(ctx)
      mine = file!(Path.join(ctx.root, ctx.old), "nodes/a.md")
      theirs = file!(Path.join(ctx.root, ctx.new), "notes/keep.md")

      assert {:error, :workspace_directory_exists} = rename(workspace.id, "default:" <> ctx.new)

      assert File.exists?(mine)
      assert File.exists?(theirs)
      assert {:ok, %{id: id}} = Workspace.get(workspace.id)
      assert id == workspace.id
    end

    test "is refused when the directory holds more than the workspace, and changes nothing", ctx do
      id = "default:cache"
      kept = file!(ctx.root, "cache/embeddings/x.bin")

      {:ok, _} =
        Store.raw_query(
          "INSERT OR IGNORE INTO workspaces (id, tenant_id, slug, name, status) VALUES (?1, 'default', ?2, ?2, 'active')",
          [id, ctx.new]
        )

      on_exit(fn -> Store.raw_query("DELETE FROM workspaces WHERE id = ?1", [id]) end)

      assert {:error, :workspace_directory_shared} = rename(id, "default:" <> ctx.new)

      assert File.exists?(kept)
      assert {:ok, [[1]]} = Store.raw_query("SELECT COUNT(*) FROM workspaces WHERE id = ?1", [id])
    end

    test "is refused when the source is a link, and changes nothing", ctx do
      workspace = mismatched!(ctx)
      File.rm_rf!(Path.join(ctx.root, ctx.old))
      target = file!(Path.dirname(ctx.root), "linked-#{ctx.n}/keep.md")
      on_exit(fn -> File.rm_rf(Path.dirname(target)) end)
      File.ln_s!(Path.dirname(target), Path.join(ctx.root, ctx.old))

      assert {:error, :workspace_directory_unusual} = rename(workspace.id, "default:" <> ctx.new)

      assert File.exists?(target)
    end

    test "leaves the directory where it was when the rows cannot be renamed", ctx do
      workspace = mismatched!(ctx)
      mine = file!(Path.join(ctx.root, ctx.old), "nodes/a.md")
      # The target id already holds a row.
      context!(ctx, "squatter", "default:" <> ctx.new, file!(ctx.root, "squatter/signals/s.md"))

      assert {:error, :target_workspace_has_rows} = rename(workspace.id, "default:" <> ctx.new)

      assert File.exists?(mine)
      refute File.exists?(Path.join(ctx.root, ctx.new))
    end
  end

  defp file!(dir, relative) do
    path = Path.join(dir, relative)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "contents of #{relative}")
    path
  end

  defp context!(ctx, label, workspace_id, path) do
    id = "ctx-#{label}-#{ctx.n}"

    {:ok, _} =
      Store.raw_query(
        """
        INSERT INTO contexts (id, tenant_id, workspace_id, uri, title, content, path, genre, node)
        VALUES (?1, 'default', ?2, ?3, 't', 'text', ?4, 'note', 'person-operator')
        """,
        [id, workspace_id, OptimalURI.from_path(path), path]
      )

    id
  end
end
