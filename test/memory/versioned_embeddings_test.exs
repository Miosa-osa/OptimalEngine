defmodule OptimalEngine.Memory.Versioned.EmbeddingsTest do
  use ExUnit.Case, async: false

  alias OptimalEngine.Memory.Versioned
  alias OptimalEngine.Memory.Versioned.Embeddings
  alias OptimalEngine.Store

  setup do
    Store.raw_query("DELETE FROM memory_embeddings", [])
    Store.raw_query("DELETE FROM memories", [])
    :ok
  end

  test "semantic search is workspace scoped and ranks cosine similarity" do
    {:ok, target} =
      Versioned.create(%{content: "Alice uses watercolor painting", workspace_id: "default"})

    {:ok, distractor} =
      Versioned.create(%{content: "Bob reviews invoices", workspace_id: "default"})

    {:ok, isolated} =
      Versioned.create(%{content: "Private painting note", workspace_id: "other"})

    :ok = Embeddings.put(target, [1.0, 0.0])
    :ok = Embeddings.put(distractor, [0.0, 1.0])
    :ok = Embeddings.put(isolated, [1.0, 0.0])

    assert {:ok, [{result, score}]} =
             Embeddings.search([1.0, 0.0], workspace_id: "default", limit: 1)

    assert result.id == target.id
    assert score == 1.0
  end

  test "rebuild indexes current memories through an injectable embedder" do
    {:ok, _memory} =
      Versioned.create(%{content: "semantic projection", workspace_id: "rebuild-ws"})

    assert {:ok, %{indexed: 1, failed: 0, total: 1}} =
             Embeddings.rebuild("rebuild-ws", embedder: fn _content -> {:ok, [0.5, 0.5]} end)

    assert {:ok, [{memory, _score}]} =
             Embeddings.search([0.5, 0.5], workspace_id: "rebuild-ws", limit: 1)

    assert memory.content == "semantic projection"
  end

  test "rebuild never indexes another tenant sharing the workspace id" do
    {:ok, allowed} =
      Versioned.create(%{
        content: "allowed tenant memory",
        workspace_id: "shared-rebuild",
        tenant_id: "tenant-a"
      })

    {:ok, denied} =
      Versioned.create(%{
        content: "denied tenant memory",
        workspace_id: "shared-rebuild",
        tenant_id: "tenant-b"
      })

    assert {:ok, %{indexed: 1, total: 1}} =
             Embeddings.rebuild("shared-rebuild",
               tenant_id: "tenant-a",
               embedder: fn _content -> {:ok, [1.0, 0.0]} end
             )

    assert {:ok, [[1]]} =
             Store.raw_query(
               "SELECT COUNT(*) FROM memory_embeddings WHERE memory_id = ?1",
               [allowed.id]
             )

    assert {:ok, [[0]]} =
             Store.raw_query(
               "SELECT COUNT(*) FROM memory_embeddings WHERE memory_id = ?1",
               [denied.id]
             )
  end

  test "index embeds and stores one memory" do
    {:ok, memory} =
      Versioned.create(%{content: "index this memory", workspace_id: "index-ws"})

    assert :ok = Embeddings.index(memory, embedder: fn _content -> {:ok, [0.2, 0.8]} end)

    assert {:ok, [{result, score}]} =
             Embeddings.search([0.2, 0.8], workspace_id: "index-ws", limit: 1)

    assert result.id == memory.id
    assert_in_delta score, 1.0, 1.0e-9
  end

  test "rebuildable task profiles prefix documents without changing canonical content" do
    {:ok, memory} =
      Versioned.create(%{content: "canonical content", workspace_id: "task-prefix-ws"})

    parent = self()

    assert :ok =
             Embeddings.index(memory,
               model: "nomic-search-v1",
               provider_model: "nomic-embed-text",
               document_prefix: "search_document: ",
               embedder: fn content ->
                 send(parent, {:embedded, content})
                 {:ok, [1.0, 0.0]}
               end
             )

    assert_received {:embedded, "search_document: canonical content"}
    assert {:ok, persisted} = Versioned.get(memory.id)
    assert persisted.content == "canonical content"
  end

  test "public search retrieves a semantic durable-memory paraphrase" do
    {:ok, target} =
      Versioned.create(%{
        content: "The quarterly planning ritual happens beside the cedar desk",
        workspace_id: "semantic-search"
      })

    :ok = Embeddings.put(target, [1.0, 0.0])

    assert {:ok, [result]} =
             OptimalEngine.search("where does the recurring strategy session take place?",
               workspace_id: "semantic-search",
               tenant_id: "default",
               vector_enabled: false,
               query_embedding: [1.0, 0.0],
               limit: 1
             )

    assert result.id == target.id
    assert result.type == :memory
  end

  test "semantic-only memory search does not require lexical overlap" do
    {:ok, target} =
      Versioned.create(%{
        content: "The quarterly planning ritual happens beside the cedar desk",
        workspace_id: "semantic-only-search"
      })

    :ok = Embeddings.put(target, [1.0, 0.0])

    assert {:ok, [result]} =
             OptimalEngine.search("unrelated lexical vocabulary",
               workspace_id: "semantic-only-search",
               tenant_id: "default",
               vector_enabled: false,
               query_embedding: [1.0, 0.0],
               memory_search_mode: :semantic,
               limit: 1
             )

    assert result.id == target.id
  end

  test "lexical and semantic search both enforce tenant scope" do
    {:ok, allowed} =
      Versioned.create(%{
        content: "shared tenant phrase",
        workspace_id: "tenant-scope",
        tenant_id: "tenant-a"
      })

    {:ok, denied} =
      Versioned.create(%{
        content: "shared tenant phrase secret",
        workspace_id: "tenant-scope",
        tenant_id: "tenant-b"
      })

    :ok = Embeddings.put(allowed, [1.0, 0.0])
    :ok = Embeddings.put(denied, [1.0, 0.0])

    assert {:ok, results} =
             OptimalEngine.search("shared tenant phrase",
               workspace_id: "tenant-scope",
               tenant_id: "tenant-a",
               vector_enabled: false,
               query_embedding: [1.0, 0.0],
               limit: 10
             )

    assert Enum.any?(results, &(&1.id == allowed.id))
    refute Enum.any?(results, &(&1.id == denied.id))
  end
end
