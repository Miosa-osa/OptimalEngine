defmodule Mix.Tasks.OptimalImportNotionTest do
  @moduledoc "`mix optimal.import_notion` runs the import job to the end and prints the counts."

  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias OptimalEngine.Imports.Notion
  alias OptimalEngine.Store
  alias OptimalEngine.Tenancy.Tenant
  alias OptimalEngine.TestSupport.NotionExportFixture, as: Fixture

  @moduletag :tmp_dir

  setup do
    n = System.unique_integer([:positive])
    tenant = "mix-notion-#{n}"
    {:ok, _} = Tenant.create(%{id: tenant, name: "Mix Notion #{n}"})
    workspace = "#{tenant}:docs"

    {:ok, _} =
      Store.raw_query(
        "INSERT INTO workspaces (id, tenant_id, slug, name, status, metadata) VALUES (?1, ?2, 'docs', 'docs', 'active', '{}')",
        [workspace, tenant]
      )

    %{workspace: workspace}
  end

  defp run_task(args) do
    Mix.Task.reenable("optimal.import_notion")
    capture_io(fn -> Mix.Tasks.Optimal.ImportNotion.run(args) end)
  end

  test "imports an export and reports the counts; the same key reports the first import", ctx do
    path = Fixture.write!(ctx.tmp_dir, Fixture.export())

    output = run_task([path, "--workspace", ctx.workspace, "--key", "first"])
    assert output =~ "completed: 5 pages, 1 databases, 2 rows"
    assert output =~ "contexts written 7, unchanged 0"
    assert output =~ "edges child_of 5, links_to 3, unresolved links 1"

    {:ok, [[count]]} =
      Store.raw_query("SELECT COUNT(*) FROM contexts WHERE workspace_id = ?1", [ctx.workspace])

    assert count == 7

    json = run_task([path, "--workspace", ctx.workspace, "--key", "first", "--json"])
    report = json |> String.split("\n", parts: 2) |> List.last() |> Jason.decode!()
    assert report["status"] == "completed"
    assert report["counts"]["contexts"] == 7
    assert Notion.uri(ctx.workspace, Fixture.ids().handbook) in report["root_uris"]
  end

  test "refuses a missing file and a missing workspace", ctx do
    assert_raise Mix.Error, ~r/--workspace is required/, fn ->
      run_task([Fixture.write!(ctx.tmp_dir, Fixture.export())])
    end

    assert_raise Mix.Error, ~r/Not a file/, fn ->
      run_task([Path.join(ctx.tmp_dir, "absent.zip"), "--workspace", ctx.workspace])
    end

    assert_raise Mix.Error, ~r/No active workspace/, fn ->
      run_task([Fixture.write!(ctx.tmp_dir, Fixture.export()), "--workspace", "nowhere"])
    end
  end
end
