defmodule OptimalEngine.Memory.Versioned.EmbeddingsTest do
  use ExUnit.Case, async: false

  alias OptimalEngine.Memory.Versioned
  alias OptimalEngine.Memory.Versioned.Embeddings
  alias OptimalEngine.Memory.Versioned.RetrievalDocument
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

  test "one memory retains multiple named projection embeddings" do
    {:ok, memory} =
      Versioned.create(%{content: "multiple projections", workspace_id: "multi-profile-ws"})

    :ok = Embeddings.put(memory, [1.0, 0.0], model: "profile-a")
    :ok = Embeddings.put(memory, [0.0, 1.0], model: "profile-b")

    assert {:ok, [[2]]} =
             Store.raw_query(
               "SELECT COUNT(*) FROM memory_embeddings WHERE memory_id = ?1",
               [memory.id]
             )

    assert {:ok, [{profile_a_memory, 1.0}]} =
             Embeddings.search([1.0, 0.0],
               workspace_id: "multi-profile-ws",
               model: "profile-a"
             )

    assert profile_a_memory.id == memory.id

    assert {:ok, [{profile_b_memory, 1.0}]} =
             Embeddings.search([0.0, 1.0],
               workspace_id: "multi-profile-ws",
               model: "profile-b"
             )

    assert profile_b_memory.id == memory.id
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

  test "contextual profiles embed and hash the searchable representation" do
    {:ok, memory} =
      Versioned.create(%{
        content: "[D9:7] [2024-01-12] John to Tim: Barcelona is a must-visit",
        workspace_id: "contextual-profile-ws",
        metadata: %{"session" => "January trip", "evidence_tag" => "D9:7"}
      })

    parent = self()

    assert :ok =
             Embeddings.index(memory,
               model: "nomic-context-v1",
               document_profile: RetrievalDocument.profile(),
               document_prefix: "search_document: ",
               embedder: fn content ->
                 send(parent, {:embedded, content})
                 {:ok, [1.0, 0.0]}
               end
             )

    expected = "search_document: " <> RetrievalDocument.serialize(memory)
    assert_received {:embedded, ^expected}
    refute expected =~ "D9:7"

    assert {:ok, [[hash]]} =
             Store.raw_query(
               "SELECT content_hash FROM memory_embeddings WHERE memory_id = ?1 AND model = ?2",
               [memory.id, "nomic-context-v1"]
             )

    assert hash == :crypto.hash(:sha256, expected) |> Base.encode16(case: :lower)
    assert {:ok, persisted} = Versioned.get(memory.id)
    assert persisted.content == memory.content
  end

  test "unknown document profiles fail closed" do
    {:ok, memory} =
      Versioned.create(%{content: "do not index", workspace_id: "unknown-profile-ws"})

    assert {:error, {:unsupported_document_profile, "made-up-v9"}} =
             Embeddings.index(memory,
               document_profile: "made-up-v9",
               embedder: fn _content -> flunk("embedder must not run") end
             )

    assert {:error, {:unsupported_document_profile, "made-up-v9"}} =
             Embeddings.rebuild("unknown-profile-ws", document_profile: "made-up-v9")
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

  test "semantic-only search fuses complementary named projections" do
    {:ok, first} =
      Versioned.create(%{content: "first projection winner", workspace_id: "ensemble-search"})

    {:ok, second} =
      Versioned.create(%{content: "second projection winner", workspace_id: "ensemble-search"})

    :ok = Embeddings.put(first, [1.0, 0.0], model: "projection-a")
    :ok = Embeddings.put(second, [1.0, 0.0], model: "projection-b")

    assert {:ok, results} =
             OptimalEngine.search("no lexical overlap",
               workspace_id: "ensemble-search",
               tenant_id: "default",
               vector_enabled: false,
               query_embedding: [1.0, 0.0],
               memory_search_mode: :semantic,
               memory_embedding_model: "projection-a,projection-b",
               limit: 2
             )

    assert Enum.map(results, & &1.id) == Enum.sort([first.id, second.id])
  end

  test "candidate portfolio preserves lexical and projection-specific evidence" do
    {:ok, lexical} =
      Versioned.create(%{
        content: "cedar phrase found only by lexical search",
        workspace_id: "portfolio-search"
      })

    {:ok, first} =
      Versioned.create(%{content: "first semantic evidence", workspace_id: "portfolio-search"})

    {:ok, second} =
      Versioned.create(%{content: "second semantic evidence", workspace_id: "portfolio-search"})

    :ok = Embeddings.put(first, [1.0, 0.0], model: "projection-a")
    :ok = Embeddings.put(second, [1.0, 0.0], model: "projection-b")

    assert {:ok, results} =
             OptimalEngine.search("cedar",
               workspace_id: "portfolio-search",
               tenant_id: "default",
               vector_enabled: false,
               query_embedding: [1.0, 0.0],
               memory_search_mode: :portfolio,
               memory_embedding_model: "projection-a,projection-b",
               limit: 3
             )

    assert MapSet.new(Enum.map(results, & &1.id)) == MapSet.new([lexical.id, first.id, second.id])
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
