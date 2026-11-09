defmodule OptimalEngine.Memory.ForgetErasureTest do
  @moduledoc """
  Forgetting a memory erases its text from everywhere the Engine derived it
  from or put it: the memory row and its full-text index, the source package
  and the pending claim the create bridge staged, the claim review queue and
  its derivation ledger entries. The row stays, flagged forgotten with its
  reason, so the forget is still on record; its text does not. Another
  memory's text is untouched.
  """

  use ExUnit.Case, async: false

  alias OptimalEngine.Memory
  alias OptimalEngine.Test.StoreGrep
  alias OptimalEngine.Workspace

  setup do
    # Random, not unique_integer: a store kept between runs keeps the slugs.
    n = :crypto.strong_rand_bytes(5) |> Base.encode16(case: :lower)
    {:ok, workspace} = Workspace.create(%{slug: "forget-erasure-#{n}", name: "Forget erasure"})
    %{n: n, workspace: workspace.id}
  end

  # A token no other test writes: the grep finds it in any copy of the text,
  # a full-text posting list included.
  defp text(ctx, tag), do: "zq#{tag}#{ctx.n}xv unique memory text to forget"
  defp token(text), do: text |> String.split(" ") |> hd()

  test "after forget the text is nowhere in the store", ctx do
    doomed = text(ctx, "doomed")
    kept = text(ctx, "kept")

    {:ok, memory} = Memory.create(%{content: doomed, workspace_id: ctx.workspace})
    {:ok, _other} = Memory.create(%{content: kept, workspace_id: ctx.workspace})

    # The create bridge staged the text in a source package and a pending claim.
    refute StoreGrep.find(token(doomed)) == []
    assert :ok = Memory.forget(memory.id, reason: "asked to")

    assert StoreGrep.find(token(doomed)) == []
    refute StoreGrep.find(token(kept)) == []

    {:ok, forgotten} = Memory.get(memory.id)
    assert forgotten.is_forgotten
    assert forgotten.forget_reason == "asked to"
    refute forgotten.content =~ doomed
  end

  test "a remembered memory's staged copies go too", ctx do
    doomed = text(ctx, "remembered")

    assert {:ok, %{memory: memory}} =
             Memory.remember(%{content: doomed, workspace_id: ctx.workspace},
               force: true,
               versioned_projection: true
             )

    refute StoreGrep.find(token(doomed)) == []
    assert :ok = Memory.forget(memory.id)
    assert StoreGrep.find(token(doomed)) == []
  end

  test "an updated memory's forgotten version is erased, its other versions kept", ctx do
    first = text(ctx, "first")
    second = text(ctx, "second")

    {:ok, v1} = Memory.create(%{content: first, workspace_id: ctx.workspace})
    {:ok, v2} = Memory.update(v1.id, %{content: second})

    assert :ok = Memory.forget(v2.id)
    assert StoreGrep.find(token(second)) == []
    refute StoreGrep.find(token(first)) == []
  end
end
