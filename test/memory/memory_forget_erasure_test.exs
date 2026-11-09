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

  test "forgetting any version erases the whole version chain", ctx do
    first = text(ctx, "first")
    second = text(ctx, "second")
    third = text(ctx, "third")

    {:ok, v1} = Memory.create(%{content: first, workspace_id: ctx.workspace})
    {:ok, v2} = Memory.update(v1.id, %{content: second})
    {:ok, v3} = Memory.update(v2.id, %{content: third})

    # The middle version: the one before it and the one after it go too.
    assert :ok = Memory.forget(v2.id, reason: "asked to")

    for doomed <- [first, second, third],
        do: assert(outside_ledger(StoreGrep.find_all(doomed)) == [])

    for version <- [v1, v2, v3] do
      {:ok, forgotten} = Memory.get(version.id)
      assert forgotten.is_forgotten
      assert forgotten.forget_reason == "asked to"
      assert forgotten.content == ""
    end
  end

  test "a memory that extends the forgotten one is its own, and stays", ctx do
    source = text(ctx, "source")
    extension = text(ctx, "extension")

    {:ok, memory} = Memory.create(%{content: source, workspace_id: ctx.workspace})
    {:ok, child} = Memory.extend(memory.id, %{content: extension})

    assert :ok = Memory.forget(memory.id)
    assert outside_ledger(StoreGrep.find_all(source)) == []
    refute StoreGrep.find_all(extension) == []
    {:ok, kept} = Memory.get(child.id)
    refute kept.is_forgotten
  end

  test "the hash, the citation and the metadata that carry the text go too", ctx do
    doomed = text(ctx, "fields")

    {:ok, memory} =
      Memory.create(%{
        content: doomed,
        workspace_id: ctx.workspace,
        citation_uri: "optimal://#{ctx.workspace}/notes/#{ctx.n}",
        metadata: %{"note" => doomed, "summary" => "about " <> doomed}
      })

    assert is_binary(memory.content_hash)
    assert :ok = Memory.forget(memory.id)

    assert outside_ledger(StoreGrep.find_all(doomed)) == []
    # The hash would let a guess of the text be checked against it.
    assert outside_ledger(StoreGrep.find(memory.content_hash)) == []

    {:ok, forgotten} = Memory.get(memory.id)
    assert forgotten.content_hash == nil
    assert forgotten.citation_uri == nil
    assert forgotten.source_chunk_id == nil
  end

  describe "the source chunk" do
    defp chunk!(ctx, id, signal_id, body) do
      {:ok, _} =
        Store.raw_query(
          "INSERT INTO chunks (id, tenant_id, workspace_id, signal_id, scale, text) VALUES (?1, ?2, ?3, ?4, 'document', ?5)",
          [id, ctx.tenant, ctx.workspace, signal_id, body]
        )

      id
    end

    defp chunk?(id) do
      {:ok, rows} = Store.raw_query("SELECT 1 FROM chunks WHERE id = ?1", [id])
      rows != []
    end

    test "is erased when nothing else holds it", ctx do
      doomed = text(ctx, "chunk")
      chunk = chunk!(ctx, "chunk-gone-#{ctx.n}", "signal-gone-#{ctx.n}", doomed)

      {:ok, memory} =
        Memory.create(%{content: doomed, workspace_id: ctx.workspace, source_chunk_id: chunk})

      assert :ok = Memory.forget(memory.id)
      refute chunk?(chunk)
      assert outside_ledger(StoreGrep.find_all(doomed)) == []
    end

    test "stays while its context or another live memory holds it", ctx do
      body = text(ctx, "shared")
      signal = "signal-kept-#{ctx.n}"

      {:ok, _} =
        Store.raw_query(
          "INSERT INTO contexts (id, tenant_id, workspace_id, title, content, created_at) VALUES (?1, ?2, ?3, 't', ?4, '2026-01-01')",
          [signal, ctx.tenant, ctx.workspace, body]
        )

      of_context = chunk!(ctx, "chunk-ctx-#{ctx.n}", signal, body)
      of_memory = chunk!(ctx, "chunk-mem-#{ctx.n}", "signal-gone2-#{ctx.n}", body)

      {:ok, a} =
        Memory.create(%{
          content: text(ctx, "a"),
          workspace_id: ctx.workspace,
          source_chunk_id: of_context
        })

      {:ok, b} =
        Memory.create(%{
          content: text(ctx, "b"),
          workspace_id: ctx.workspace,
          source_chunk_id: of_memory
        })

      {:ok, _other} =
        Memory.create(%{
          content: text(ctx, "c"),
          workspace_id: ctx.workspace,
          source_chunk_id: of_memory
        })

      assert :ok = Memory.forget(a.id)
      assert :ok = Memory.forget(b.id)
      assert chunk?(of_context)
      assert chunk?(of_memory)
    end
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

  # On PostgreSQL the posting lists are rewritten after the commit. The row
  # trigger queued the memory's key in the forget's own transaction
  # (`optimal_fts_queue`), so a refresh that fails leaves it queued, and the
  # store's background refresh, or the next search, removes the postings.
  @tag :postgres_engine
  test "a full-text refresh that fails is the forget's error, and the queued refresh removes the text",
       ctx do
    doomed = text(ctx, "refresh")
    {:ok, memory} = Memory.create(%{content: doomed, workspace_id: ctx.workspace})
    :ok = OptimalEngine.Store.FullText.refresh(["memories_fts"])
    refute StoreGrep.find_all(doomed) == []

    previous = Application.get_env(:optimal_engine, :store_call_timeout_ms)
    Application.put_env(:optimal_engine, :store_call_timeout_ms, 300)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:optimal_engine, :store_call_timeout_ms, previous),
        else: Application.delete_env(:optimal_engine, :store_call_timeout_ms)
    end)

    # The posting lists held by another session: the refresh cannot run.
    held =
      OptimalEngine.Test.StoreStall.hold_tables(~w(optimal_fts_postings optimal_fts_docs), 2_000)

    assert {:error, {:memory_erasure_failed, :fts_refresh, _}} = Memory.forget(memory.id)

    # Committed: the row is flagged and emptied, and its key is queued.
    {:ok, [[flag, content]]} =
      Store.raw_query("SELECT is_forgotten, content FROM memories WHERE id = ?1", [memory.id])

    assert {flag, content} == {1, ""}

    {:ok, [[queued]]} =
      Store.raw_query("SELECT count(*) FROM optimal_fts_queue WHERE index_name = ?1", [
        "memories_fts"
      ])

    assert queued > 0

    assert {:ok, :released} = Task.await(held, 10_000)
    Application.put_env(:optimal_engine, :store_call_timeout_ms, previous || 15_000)

    # The store's background refresh (its timer), not the test, takes the queue.
    send(Process.whereis(OptimalEngine.Store.Postgres), :full_text)
    assert eventually(fn -> outside_ledger(StoreGrep.find_all(doomed)) == [] end)

    word = doomed |> String.split() |> hd()

    assert Memory.list(workspace_id: ctx.workspace, q: word, include_forgotten: true) == []
  end

  defp eventually(check, tries \\ 50) do
    cond do
      check.() -> true
      tries == 0 -> false
      true -> Process.sleep(100) && eventually(check, tries - 1)
    end
  end
end
