defmodule OptimalEngine.Memory.ForgetErasureTest do
  @moduledoc """
  Forgetting a memory erases its text from everywhere the Engine derived it
  from or put it: the memory row and its full-text index, the source package
  and the pending claim the create bridge staged, the claim review queue and
  its derivation ledger entries. The row stays, flagged forgotten with its
  reason, so the forget is still on record; its text does not. Another
  memory's text is untouched.

  Every distinctive token of the text is looked for in every table and
  column, the FTS5 index itself included (`OptimalEngine.Test.StoreGrep`).
  The replication ledger (`sync_mutations`) still holds the text until the
  ledger redaction lands: that assertion is tagged `:ledger_redaction` and
  excluded until then.
  """

  use ExUnit.Case, async: false

  alias OptimalEngine.{Memory, Store, Sync, Workspace}
  alias OptimalEngine.Sync.Capture
  alias OptimalEngine.Test.StoreGrep

  # The replication ledger keeps every change's row as it was written; it is
  # rewritten by the ledger redaction, not by this erasure.
  @ledger ~w(sync_mutations sync_capture)

  setup do
    # Random, not unique_integer: a store kept between runs keeps the slugs.
    n = :crypto.strong_rand_bytes(5) |> Base.encode16(case: :lower)
    {:ok, workspace} = Workspace.create(%{slug: "forget-erasure-#{n}", name: "Forget erasure"})
    # Replicated, so the ledger has the memory's changes to look at.
    {:ok, _} = Sync.enable(workspace.tenant_id, workspace.id, "user:test")
    %{n: n, workspace: workspace.id, tenant: workspace.tenant_id}
  end

  # Every word is a token no other test writes.
  defp text(ctx, tag), do: "zq#{tag}#{ctx.n}xv yk#{tag}#{ctx.n}wq jp#{tag}#{ctx.n}rz"

  defp outside_ledger(hits), do: Enum.reject(hits, fn {table, _} -> table in @ledger end)

  test "after forget no token of the text is anywhere outside the ledger", ctx do
    doomed = text(ctx, "doomed")
    kept = text(ctx, "kept")

    {:ok, memory} = Memory.create(%{content: doomed, workspace_id: ctx.workspace})
    {:ok, _other} = Memory.create(%{content: kept, workspace_id: ctx.workspace})

    # The create bridge staged the text in a source package and a pending claim.
    refute StoreGrep.find_all(doomed) == []
    assert :ok = Memory.forget(memory.id, reason: "asked to")

    assert outside_ledger(StoreGrep.find_all(doomed)) == []
    refute StoreGrep.find_all(kept) == []

    {:ok, forgotten} = Memory.get(memory.id)
    assert forgotten.is_forgotten
    assert forgotten.forget_reason == "asked to"
    assert forgotten.content == ""
  end

  @tag :ledger_redaction
  test "after forget no token of the text is in the replication ledger either", ctx do
    doomed = text(ctx, "ledger")
    {:ok, memory} = Memory.create(%{content: doomed, workspace_id: ctx.workspace})
    {:ok, _} = Capture.seal()
    assert :ok = Memory.forget(memory.id)
    {:ok, _} = Capture.seal()

    assert StoreGrep.find_all(doomed) == []
  end

  test "a remembered memory's staged copies go too", ctx do
    doomed = text(ctx, "remembered")

    assert {:ok, %{memory: memory}} =
             Memory.remember(%{content: doomed, workspace_id: ctx.workspace},
               force: true,
               versioned_projection: true
             )

    refute StoreGrep.find_all(doomed) == []
    assert :ok = Memory.forget(memory.id)
    assert outside_ledger(StoreGrep.find_all(doomed)) == []
  end

  test "an updated memory's forgotten version is erased, its other versions kept", ctx do
    first = text(ctx, "first")
    second = text(ctx, "second")

    {:ok, v1} = Memory.create(%{content: first, workspace_id: ctx.workspace})
    {:ok, v2} = Memory.update(v1.id, %{content: second})

    assert :ok = Memory.forget(v2.id)
    assert outside_ledger(StoreGrep.find_all(second)) == []
    refute StoreGrep.find_all(first) == []
  end

  # A forget that cannot erase is not done at all: the memory is not left
  # flagged forgotten with its text in place, where nothing would retry it.
  @tag :sqlite_store
  test "a forget whose erasure fails changes nothing, and succeeds once it can", ctx do
    doomed = text(ctx, "atomic")
    {:ok, memory} = Memory.create(%{content: doomed, workspace_id: ctx.workspace})

    {:ok, _} =
      Store.raw_query(
        "CREATE TRIGGER forget_erasure_blocker BEFORE DELETE ON source_packages BEGIN SELECT RAISE(ABORT, 'blocked'); END",
        []
      )

    on_exit(fn -> Store.raw_query("DROP TRIGGER IF EXISTS forget_erasure_blocker", []) end)

    assert {:error, _reason} = Memory.forget(memory.id, reason: "asked to")

    {:ok, unchanged} = Memory.get(memory.id)
    refute unchanged.is_forgotten
    assert unchanged.content == doomed

    {:ok, _} = Store.raw_query("DROP TRIGGER forget_erasure_blocker", [])
    assert :ok = Memory.forget(memory.id, reason: "asked to")
    assert outside_ledger(StoreGrep.find_all(doomed)) == []
  end

  test "a full-text refresh that fails is the forget's error, not silence", ctx do
    doomed = text(ctx, "refresh")
    {:ok, memory} = Memory.create(%{content: doomed, workspace_id: ctx.workspace})

    Application.put_env(:optimal_engine, :memory_erasure_refresh, fn _ -> {:error, :down} end)
    on_exit(fn -> Application.delete_env(:optimal_engine, :memory_erasure_refresh) end)

    assert {:error, {:memory_erasure_failed, :fts_refresh, :down}} = Memory.forget(memory.id)
  end
end
