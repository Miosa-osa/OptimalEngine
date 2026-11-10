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

  # Both wait at a barrier, then go at once. Whichever runs first, the update
  # is refused (the forget ran first) or its version is forgotten with the
  # rest of the chain (the update ran first): never a live version with text.
  test "an update racing a forget never leaves a live version with text", ctx do
    for i <- 1..15 do
      {:ok, v1} = Memory.create(%{content: text(ctx, "race#{i}a"), workspace_id: ctx.workspace})
      newer = text(ctx, "race#{i}b")
      test = self()

      racer = fn fun ->
        Task.async(fn ->
          send(test, {:ready, self()})

          receive do
            :go -> fun.()
          end
        end)
      end

      update = racer.(fn -> Memory.update(v1.id, %{content: newer}) end)
      forget = racer.(fn -> Memory.forget(v1.id) end)
      for task <- [update, forget], do: assert_receive({:ready, pid} when pid == task.pid, 5_000)
      for task <- [update, forget], do: send(task.pid, :go)

      updated = Task.await(update, 30_000)
      assert :ok = Task.await(forget, 30_000)
      assert_update_lost(updated, "iteration #{i}")
      assert live_with(ctx, newer) == [], "iteration #{i}"
    end
  end

  # The update ran first and its version was forgotten with the chain, or it
  # ran second and was refused.
  defp assert_update_lost({:error, :forgotten}, _label), do: :ok

  defp assert_update_lost({:ok, %{id: id}}, label) do
    {:ok, rows} =
      Store.raw_query("SELECT is_forgotten, content FROM memories WHERE id = ?1", [id])

    assert rows == [[1, ""]], label
  end

  defp assert_update_lost(other, label),
    do: flunk("#{label}: the update returned #{inspect(other)}")

  # A transaction holding the chain's root makes the update and the forget
  # both wait inside their own transactions, so they overlap for certain; on
  # release they take the root's row one after the other.
  @tag :postgres_engine
  test "an update and a forget both waiting on the root serialize: the update is refused or forgotten",
       ctx do
    {:ok, v1} = Memory.create(%{content: text(ctx, "overlap"), workspace_id: ctx.workspace})
    newer = text(ctx, "overlapnewer")
    test = self()

    holder =
      Task.async(fn ->
        Store.transaction(fn txn ->
          :ok = Store.txn_lock_row(txn, "memories", "id", v1.id)
          send(test, :held)

          receive do
            :release -> {:ok, :released}
          after
            10_000 -> {:ok, :timed_out}
          end
        end)
      end)

    assert_receive :held, 5_000
    update = Task.async(fn -> Memory.update(v1.id, %{content: newer}) end)
    forget = Task.async(fn -> Memory.forget(v1.id) end)

    # Both are waiting on the root's row while the holder has it.
    assert Task.yield(update, 300) == nil
    assert Task.yield(forget, 300) == nil
    send(holder.pid, :release)
    assert {:ok, :released} = Task.await(holder, 10_000)

    assert :ok = Task.await(forget, 10_000)
    assert_update_lost(Task.await(update, 10_000), "after the release")
    assert live_with(ctx, newer) == []
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

  defp insert_raw!(ctx, id, parent, content, version, opts \\ []) do
    {:ok, _} =
      Store.raw_query(
        "INSERT INTO memories (id, tenant_id, workspace_id, content, version, parent_memory_id, root_memory_id) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
        [
          id,
          Keyword.get(opts, :tenant, ctx.tenant),
          Keyword.get(opts, :workspace, ctx.workspace),
          content,
          version,
          parent,
          Keyword.get(opts, :root)
        ]
      )
  end

  test "a parent_memory_id cycle without a root is an error, and erases nothing", ctx do
    doomed = text(ctx, "cycle")
    [a, b] = ["cycle-a-#{ctx.n}", "cycle-b-#{ctx.n}"]
    insert_raw!(ctx, a, nil, doomed, 1)
    insert_raw!(ctx, b, a, text(ctx, "cycleb"), 2)
    {:ok, _} = Store.raw_query("UPDATE memories SET parent_memory_id = ?1 WHERE id = ?2", [b, a])

    assert {:error, :memory_chain_broken} = Versioned.forget(a)
    {:ok, rows} = Store.raw_query("SELECT is_forgotten, content FROM memories WHERE id = ?1", [a])
    assert rows == [[0, doomed]]
  end

  test "the chain is the memory's workspace's: a link into another workspace is not followed",
       ctx do
    {:ok, other} = Workspace.create(%{slug: "forget-chain-other-#{ctx.n}", name: "Other"})
    theirs = text(ctx, "theirs")
    mine = text(ctx, "mine")
    their_root = "foreign-root-#{ctx.n}"
    insert_raw!(ctx, their_root, nil, theirs, 1, workspace: other.id, tenant: other.tenant_id)
    # A row of this workspace that names the other workspace's memory.
    insert_raw!(ctx, "mine-#{ctx.n}", their_root, mine, 2)

    assert :ok = Versioned.forget("mine-#{ctx.n}")
    assert outside_ledger(StoreGrep.find_all(mine)) == []
    refute StoreGrep.find_all(theirs) == []

    {:ok, [[flag]]} =
      Store.raw_query("SELECT is_forgotten FROM memories WHERE id = ?1", [their_root])

    assert flag == 0
  end

  # `POST /api/memory` takes `source_chunk_id` as given, so a memory can name
  # a chunk of another tenant: forgetting it must not remove that chunk.
  test "a forget never removes another tenant's chunk the memory names", ctx do
    chunk = "foreign-chunk-#{ctx.n}"
    theirs = text(ctx, "theirchunk")

    {:ok, _} =
      Store.raw_query(
        "INSERT INTO chunks (id, tenant_id, signal_id, scale, text) VALUES (?1, ?2, ?3, 'paragraph', ?4)",
        [chunk, "other-tenant-#{ctx.n}", "gone-signal-#{ctx.n}", theirs]
      )

    {:ok, mine} =
      Memory.create(%{
        content: text(ctx, "namesforeign"),
        workspace_id: ctx.workspace,
        source_chunk_id: chunk
      })

    assert :ok = Memory.forget(mine.id)
    assert {:ok, [[^theirs]]} = Store.raw_query("SELECT text FROM chunks WHERE id = ?1", [chunk])

    {:ok, again} =
      Memory.create(%{
        content: text(ctx, "namesforeign2"),
        workspace_id: ctx.workspace,
        source_chunk_id: chunk
      })

    assert :ok = Memory.delete(again.id)
    assert {:ok, [[^theirs]]} = Store.raw_query("SELECT text FROM chunks WHERE id = ?1", [chunk])
  end

  # The update waits for the forget holding the chain's root, and so lands
  # after it: refused, with no new version.
  @tag :postgres_engine
  test "an update waits for a forget that holds the chain's root, and is then refused", ctx do
    {:ok, v1} = Memory.create(%{content: text(ctx, "held"), workspace_id: ctx.workspace})
    newer = text(ctx, "heldnewer")
    test = self()

    holder =
      Task.async(fn ->
        Store.transaction(fn txn ->
          :ok = Store.txn_lock_row(txn, "memories", "id", v1.id)
          send(test, :held)

          receive do
            :release -> :ok
          after
            10_000 -> :ok
          end

          {:ok, _} =
            Store.txn_execute(txn, "UPDATE memories SET is_forgotten = 1 WHERE id = ?1", [v1.id])

          {:ok, :done}
        end)
      end)

    assert_receive :held, 5_000
    update = Task.async(fn -> Memory.update(v1.id, %{content: newer}) end)

    # Still waiting on the root's row while the holder has it.
    assert Task.yield(update, 500) == nil
    send(holder.pid, :release)
    assert {:ok, :done} = Task.await(holder, 10_000)
    assert {:error, :forgotten} = Task.await(update, 10_000)
    assert live_with(ctx, newer) == []
  end
end
