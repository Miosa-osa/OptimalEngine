defmodule OptimalEngine.Analyses.ScheduleCostTest do
  @moduledoc """
  `Analyses.schedule/2` enqueues the day's analyses of every active workspace.
  It used to make a few store calls per workspace (the workspace's tenant, the
  insert, the read back, its meeting connectors), so on an Engine with many
  workspaces the daily schedule ran for minutes. It now makes a bounded number
  per tenant: the workspaces, the tenant's meeting connectors, and the jobs
  inserted in batches. Counted in store calls, not in time.
  """
  use ExUnit.Case, async: false

  alias OptimalEngine.{Analyses, Store}
  alias OptimalEngine.Tenancy.Tenant

  @workspaces 300

  setup do
    n = System.unique_integer([:positive])
    tenant = "sched-cost-#{n}"
    {:ok, _} = Tenant.create(%{id: tenant, name: "Schedule cost #{n}"})

    for chunk <- Enum.chunk_every(1..@workspaces, 100) do
      values =
        Enum.map_join(chunk, ", ", fn i -> "('#{tenant}:w#{i}', '#{tenant}', 'w#{i}', 'W #{i}')" end)

      {:ok, _} =
        Store.raw_query("INSERT INTO workspaces (id, tenant_id, slug, name) VALUES #{values}", [])
    end

    %{tenant: tenant}
  end

  @counted [
    {Store, :raw_query, 2},
    {Store, :raw_execute, 2},
    {Store, :transaction, 1},
    {Store, :transaction, 2}
  ]

  defp store_calls(fun) do
    for mfa <- @counted, do: :erlang.trace_pattern(mfa, true, [:call_count])

    try do
      result = fun.()

      calls =
        Enum.sum(
          for mfa <- @counted do
            case :erlang.trace_info(mfa, :call_count) do
              {:call_count, count} when is_integer(count) -> count
              _ -> 0
            end
          end
        )

      {result, calls}
    after
      for mfa <- @counted, do: :erlang.trace_pattern(mfa, false, [:call_count])
    end
  end

  test "the store calls of a tenant's schedule do not grow with its workspaces", ctx do
    today = Date.utc_today()
    {scheduled, calls} = store_calls(fn -> Analyses.schedule(today, tenant_id: ctx.tenant) end)

    assert scheduled >= @workspaces

    {:ok, [[jobs]]} =
      Store.raw_query("SELECT count(*) FROM jobs WHERE tenant_id = ?1", [ctx.tenant])

    assert jobs == scheduled
    # The workspaces, the meeting connectors, the corpus source and the inserts
    # (in batches): far fewer than one call per workspace.
    assert calls < 40, "#{calls} store calls for #{@workspaces} workspaces"

    # Again on the same day: the same jobs, nothing new.
    assert Analyses.schedule(today, tenant_id: ctx.tenant) == scheduled

    {:ok, [[again]]} =
      Store.raw_query("SELECT count(*) FROM jobs WHERE tenant_id = ?1", [ctx.tenant])

    assert again == jobs
  end
end
