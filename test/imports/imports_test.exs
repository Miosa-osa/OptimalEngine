defmodule OptimalEngine.ImportsTest do
  @moduledoc """
  `OptimalEngine.Imports` job bookkeeping: the outstanding cap holds for
  requests that race, and the sweep removes what old imports leave behind,
  including a job dead-lettered when its last lease ran out, without touching
  an import that is still queued or a folder that is not an import's.
  """

  use ExUnit.Case, async: false

  alias OptimalEngine.Imports
  alias OptimalEngine.Jobs
  alias OptimalEngine.Store
  alias OptimalEngine.Tenancy.Tenant
  alias OptimalEngine.TestSupport.NotionExportFixture, as: Fixture

  setup do
    n = System.unique_integer([:positive])
    tenant = "imports-#{n}"
    {:ok, _} = Tenant.create(%{id: tenant, name: "Imports #{n}"})
    workspace = "#{tenant}:docs"

    {:ok, _} =
      Store.raw_query(
        "INSERT INTO workspaces (id, tenant_id, slug, name, status, metadata) VALUES (?1, ?2, 'docs', 'docs', 'active', '{}')",
        [workspace, tenant]
      )

    %{workspace: workspace}
  end

  defp enqueue(workspace) do
    staged = Imports.stage()
    File.write!(staged.source, Fixture.export())
    source = %{"kind" => "upload", "bytes" => byte_size(Fixture.export())}
    {staged, Imports.enqueue_notion(workspace, staged, source)}
  end

  defp age!(path), do: File.touch!(path, System.os_time(:second) - 2 * 86_400)

  defp import_dir_name,
    do: "imp_" <> (:crypto.strong_rand_bytes(12) |> Base.encode16(case: :lower))

  test "requests that race cannot take more than the outstanding places", ctx do
    results =
      1..6
      |> Enum.map(fn _ -> Task.async(fn -> enqueue(ctx.workspace) end) end)
      |> Task.await_many(30_000)

    queued = for {_staged, {:ok, _job, :queued}} <- results, do: :queued
    refused = for {staged, {:error, :too_many_imports}} <- results, do: staged

    assert length(queued) == Imports.max_outstanding()
    assert length(refused) == 6 - Imports.max_outstanding()
    assert {:ok, 2} = Jobs.count_active(ctx.workspace, Imports.notion_kind())

    # A refused request leaves nothing staged.
    for staged <- refused, do: refute(File.exists?(staged.dir))
  end

  test "the sweep cleans old leftovers and leaves live imports alone", ctx do
    # A job whose last lease ran out is dead-lettered by the next claim; its
    # source stays behind until the sweep.
    {dead_staged, {:ok, dead, :queued}} = enqueue(ctx.workspace)

    {:ok, _} =
      Store.raw_query(
        "UPDATE jobs SET status = 'running', attempts = max_attempts, lease_owner = 'gone', lease_expires_at = datetime('now', '-1 hour') WHERE id = ?1",
        [dead.id]
      )

    assert {:ok, :idle} = Imports.drain(workspace_id: ctx.workspace)
    assert {:ok, %{status: "dead"}} = Jobs.get(dead.id, ctx.workspace)
    File.write!(Path.join(dead_staged.dir, "report.json"), "{}")
    age!(dead_staged.dir)

    {queued_staged, {:ok, _queued, :queued}} = enqueue(ctx.workspace)
    age!(queued_staged.dir)

    orphan = Path.join(Imports.dir(), import_dir_name())
    File.mkdir_p!(orphan)
    File.write!(Path.join(orphan, "source.zip"), "left behind")
    age!(orphan)

    young = Path.join(Imports.dir(), import_dir_name())
    File.mkdir_p!(young)

    stranger = Path.join(Imports.dir(), "not-an-import-#{System.unique_integer([:positive])}")
    File.mkdir_p!(stranger)
    age!(stranger)

    on_exit(fn ->
      File.rm_rf(young)
      File.rm_rf(stranger)
    end)

    assert Imports.sweep() >= 2

    # The dead job keeps its report; the orphan is gone.
    assert File.ls!(dead_staged.dir) == ["report.json"]
    refute File.exists?(orphan)

    # A queued import, a young folder and a folder that is not an import's stay.
    assert File.exists?(queued_staged.source)
    assert File.dir?(young)
    assert File.dir?(stranger)
  end
end
