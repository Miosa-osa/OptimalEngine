defmodule OptimalEngine.Pipeline.IndexerTenantPathsTest do
  @moduledoc """
  A full crawl files a file under the workspace and the tenant its path names.
  A workspace of another tenant lives at `tenants/<tenant>/<slug>`
  (`Workspace.Filesystem.path/2`), so its files are that tenant's rows in
  `<tenant>:<slug>`; read as a top-level folder they were `default:tenants`
  rows of the default tenant.
  """

  use ExUnit.Case, async: false

  alias OptimalEngine.Pipeline.Indexer
  alias OptimalEngine.Store
  alias OptimalEngine.Tenancy.Tenant
  alias OptimalEngine.Workspace.Filesystem

  setup do
    n = System.unique_integer([:positive])
    root = Path.join(System.tmp_dir!(), "optimal-indexer-tenants-#{n}")
    File.mkdir_p!(root)
    original_state = :sys.get_state(Indexer)

    :sys.replace_state(Indexer, fn state ->
      %{state | topology: Map.put(state.topology, :root_path, root)}
    end)

    on_exit(fn ->
      :sys.replace_state(Indexer, fn _ -> original_state end)
      File.rm_rf(root)
    end)

    tenant = "idx-tenant-#{n}"
    {:ok, _} = Tenant.create(%{id: tenant, name: "Indexer #{n}"})
    %{n: n, root: root, tenant: tenant}
  end

  defp write!(root, relative) do
    path = Path.join(root, relative)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "# Fixture\nVerified scope boundary for #{relative}.")
    path
  end

  defp scope_of(path) do
    {:ok, rows} =
      Store.raw_query("SELECT workspace_id, tenant_id FROM contexts WHERE path = ?1", [path])

    rows
  end

  defp await_index(0), do: flunk("full index did not finish")

  defp await_index(attempts) do
    if Indexer.status().status == :running do
      Process.sleep(10)
      await_index(attempts - 1)
    else
      assert Indexer.status().status == :idle
    end
  end

  test "files a tenant's workspace under that tenant", %{root: root, tenant: tenant} do
    other = write!(root, "tenants/#{tenant}/ops/notes/one.md")
    nested = write!(root, "tenants/#{tenant}/ops/deep/er/two.md")
    shared = write!(root, "project-a/three.md")
    top = write!(root, "README.md")
    own = write!(root, "nodes/team/four.md")

    assert {:ok, :started} = Indexer.full_index()
    await_index(300)

    assert scope_of(other) == [["#{tenant}:ops", tenant]]
    assert scope_of(nested) == [["#{tenant}:ops", tenant]]
    # What was a top-level folder stays one.
    assert scope_of(shared) == [["default:project-a", "default"]]
    assert scope_of(top) == [["default", "default"]]
    # The root's own directories are the default workspace's tree.
    assert scope_of(own) == [["default", "default"]]
  end

  test "reads a path back to the workspace and tenant that Filesystem.path built it for", ctx do
    %{root: root, tenant: tenant, n: n} = ctx

    # {the id a file is written for, the workspace and tenant it is read back as}
    cases = [
      {"default", {"default", "default"}},
      {"default:rt-#{n}", {"default:rt-#{n}", "default"}},
      # A bare id and `default:<id>` are one directory; the crawl reads both as the latter.
      {"bare-rt-#{n}", {"default:bare-rt-#{n}", "default"}},
      {"#{tenant}:rt-#{n}", {"#{tenant}:rt-#{n}", tenant}}
    ]

    files =
      for {id, expected} <- cases do
        dir = Filesystem.path(root, id)
        subdirectory = if id == "default", do: "nodes/team", else: "nodes"
        {write!(dir, "#{subdirectory}/round-trip.md"), expected}
      end

    assert {:ok, :started} = Indexer.full_index()
    await_index(300)

    for {path, {workspace, expected_tenant}} <- files do
      assert scope_of(path) == [[workspace, expected_tenant]], path
    end
  end
end
