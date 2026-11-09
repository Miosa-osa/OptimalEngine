defmodule OptimalEngine.Memory.ForgetChainTest do
  @moduledoc """
  Follow-ups to forgetting a memory (`OptimalEngine.Memory.Versioned.Erasure`):

  * an update and a forget of one memory serialize on its root row, so an
    update never adds a live version to a chain a forget is erasing, and an
    update of a forgotten memory is refused;
  * a hard delete erases what a forget erases, then removes the chain's rows;
  * a chain an older build wrote without `root_memory_id` is found through
    `parent_memory_id`.
  """
  use ExUnit.Case, async: false

  alias OptimalEngine.{Memory, Store, Workspace}
  alias OptimalEngine.Memory.Versioned
  alias OptimalEngine.Test.StoreGrep

  @ledger ~w(sync_mutations sync_capture)

  setup do
    n = :crypto.strong_rand_bytes(5) |> Base.encode16(case: :lower)
    {:ok, workspace} = Workspace.create(%{slug: "forget-chain-#{n}", name: "Forget chain"})
    %{n: n, workspace: workspace.id, tenant: workspace.tenant_id}
  end

  defp text(ctx, tag), do: "zq#{tag}#{ctx.n}xv yk#{tag}#{ctx.n}wq"
  defp outside_ledger(hits), do: Enum.reject(hits, fn {table, _} -> table in @ledger end)

  defp live_with(ctx, doomed) do
    word = doomed |> String.split() |> hd()

    {:ok, rows} =
      Store.raw_query(
        "SELECT id FROM memories WHERE workspace_id = ?1 AND is_forgotten = 0 AND content LIKE ?2",
        [ctx.workspace, "%" <> word <> "%"]
      )

    rows
  end

  test "an update of a forgotten memory is refused", ctx do
    {:ok, v1} = Memory.create(%{content: text(ctx, "first"), workspace_id: ctx.workspace})
    assert :ok = Memory.forget(v1.id)

    later = text(ctx, "later")
    assert {:error, :forgotten} = Memory.update(v1.id, %{content: later})
    assert live_with(ctx, later) == []
  end

  test "an update racing a forget never leaves a live version with text", ctx do
    for i <- 1..15 do
      {:ok, v1} = Memory.create(%{content: text(ctx, "race#{i}a"), workspace_id: ctx.workspace})
      newer = text(ctx, "race#{i}b")

      update = Task.async(fn -> Memory.update(v1.id, %{content: newer}) end)
      forget = Task.async(fn -> Memory.forget(v1.id) end)
      _ = Task.await(update, 30_000)
      assert :ok = Task.await(forget, 30_000)

      assert live_with(ctx, newer) == [], "iteration #{i}"
    end
  end

  test "a hard delete erases what a forget erases, and the chain's rows", ctx do
    first = text(ctx, "delfirst")
    second = text(ctx, "delsecond")
    {:ok, v1} = Memory.create(%{content: first, workspace_id: ctx.workspace})
    {:ok, v2} = Memory.update(v1.id, %{content: second})
    refute StoreGrep.find_all(first) == []

    assert :ok = Memory.delete(v2.id)

    assert outside_ledger(StoreGrep.find_all(first)) == []
    assert outside_ledger(StoreGrep.find_all(second)) == []
    assert {:error, :not_found} = Memory.get(v1.id)
    assert {:error, :not_found} = Memory.get(v2.id)
  end

  test "a chain without root_memory_id is found through parent_memory_id", ctx do
    first = text(ctx, "legacya")
    second = text(ctx, "legacyb")
    third = text(ctx, "legacyc")
    [a, b, c] = for tag <- ~w(a b c), do: "legacy-#{tag}-#{ctx.n}"

    for {id, parent, content, version} <- [{a, nil, first, 1}, {b, a, second, 2}, {c, b, third, 3}] do
      {:ok, _} =
        Store.raw_query(
          "INSERT INTO memories (id, tenant_id, workspace_id, content, version, parent_memory_id, root_memory_id) VALUES (?1, ?2, ?3, ?4, ?5, ?6, NULL)",
          [id, ctx.tenant, ctx.workspace, content, version, parent]
        )
    end

    assert :ok = Versioned.forget(b)

    for doomed <- [first, second, third],
        do: assert(outside_ledger(StoreGrep.find_all(doomed)) == [], doomed)
  end
end
