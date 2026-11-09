defmodule OptimalEngine.DataStewardRenameContentionTest do
  # A rename rewrites every workspace table in one transaction. On PostgreSQL
  # at SERIALIZABLE, short transactions of other workspaces that read and then
  # write those tables kept aborting it, and its retries ran out under ordinary
  # load. The rename now holds the tables against writers for its duration, as
  # SQLite's single writer always did, so it is not retried at all.
  use ExUnit.Case, async: false

  alias OptimalEngine.DataSteward
  alias OptimalEngine.Store
  alias OptimalEngine.Workspace

  @moduletag timeout: 120_000
  @writers 4

  setup do
    # Random, not unique_integer: the directories of earlier runs stay under the root.
    n = Base.encode16(:crypto.strong_rand_bytes(5), case: :lower)
    {:ok, renamed} = Workspace.create(%{slug: "contend-old-#{n}", name: "Renamed #{n}"})
    {:ok, _} = Workspace.update(renamed.id, %{slug: "contend-new-#{n}"})
    {:ok, busy} = Workspace.create(%{slug: "contend-busy-#{n}", name: "Busy #{n}"})

    for i <- 1..20, do: context!("r-#{n}-#{i}", renamed.id)

    %{n: n, renamed: renamed, busy: busy}
  end

  test "writers of another workspace do not make the rename retry", ctx do
    result =
      while_writing(ctx, fn ->
        DataSteward.rename_workspace(ctx.renamed.id, "default:contend-new-#{ctx.n}",
          tenant_id: "default",
          actor_id: "user:test"
        )
      end)

    assert {:ok, _} = result
  end

  test "writers of another workspace do not make an orphan repair retry", ctx do
    orphan = "default:contend-orphan-#{ctx.n}"
    for i <- 1..20, do: context!("o-#{ctx.n}-#{i}", orphan)

    result =
      while_writing(ctx, fn ->
        DataSteward.repair_orphan_scope(orphan, ctx.renamed.id,
          tenant_id: "default",
          actor_id: "user:test"
        )
      end)

    assert {:ok, _} = result
  end

  # Runs `operation` while writers of the busy workspace run, and asserts that
  # the writers wrote and that the operation's transaction was never retried.
  defp while_writing(ctx, operation) do
    stop = :atomics.new(1, [])

    writers =
      for w <- 1..@writers do
        Task.async(fn -> write_until(stop, ctx.busy.id, "b-#{ctx.n}-#{w}", 0) end)
      end

    # The writers are running before the rename starts.
    Process.sleep(200)

    retries = :counters.new(1, [])
    handler = "rename-contention-#{ctx.n}"

    :telemetry.attach(
      handler,
      [:optimal_engine, :store, :retry],
      fn _event, _measurements, _metadata, rename_process ->
        if self() == rename_process, do: :counters.add(retries, 1, 1)
      end,
      self()
    )

    result =
      try do
        operation.()
      after
        :atomics.put(stop, 1, 1)
        :telemetry.detach(handler)
      end

    written = writers |> Enum.map(&Task.await(&1, 60_000)) |> Enum.sum()

    assert written > 0
    assert :counters.get(retries, 1) == 0
    result
  end

  defp write_until(stop, workspace_id, tag, count) do
    if :atomics.get(stop, 1) == 1 do
      count
    else
      # A read of the table and then a write to it, in one transaction: the
      # shape of most of the Engine's writes.
      {:ok, _} =
        Store.transaction(fn txn ->
          {:ok, _} =
            Store.txn_query(txn, "SELECT count(*) FROM contexts WHERE workspace_id = ?1", [
              workspace_id
            ])

          Store.txn_execute(txn, insert_sql(), ["#{tag}-#{count}", workspace_id])
        end)

      write_until(stop, workspace_id, tag, count + 1)
    end
  end

  defp context!(id, workspace_id) do
    {:ok, _} = Store.raw_query(insert_sql(), [id, workspace_id])
  end

  defp insert_sql do
    "INSERT INTO contexts (id, tenant_id, workspace_id, title, content, created_at) " <>
      "VALUES (?1, 'default', ?2, 't', 'c', '2026-01-01')"
  end
end
