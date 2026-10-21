defmodule OptimalEngine.Retrieval.MemoryRankingTest do
  @moduledoc """
  Durable memories rank the same way on two Engines that hold the same data:
  the lexical SQL, the semantic search over their embeddings, the fusion of the
  two, the merge with contexts, and the versioned store's own listing.

  Memories of one workspace share a text, a creation time and an update time,
  and are stored in an order that is not their id order, so only the ordering
  rule can put them right.
  """

  use ExUnit.Case, async: false

  import OptimalEngine.TestSupport.RetrievalFixtures

  alias OptimalEngine.Memory
  alias OptimalEngine.Memory.Versioned
  alias OptimalEngine.Memory.Versioned.Embeddings
  alias OptimalEngine.Retrieval.Search
  alias OptimalEngine.Store

  @at "2026-10-10 12:00:00"
  @vector [1.0, 0.0]

  setup do
    token = token()
    workspace = "#{token}-w"
    on_exit(fn -> delete_workspaces([workspace]) end)
    {:ok, token: token, workspace: workspace}
  end

  defp memory_ids(token, count) do
    for n <- 1..count, do: "mem-#{token}-#{String.pad_leading(Integer.to_string(n), 2, "0")}"
  end

  defp insert_memory(workspace, id, content) do
    {:ok, _} =
      Store.raw_query(
        "INSERT INTO memories (id, workspace_id, content, root_memory_id, created_at, updated_at) VALUES (?1, ?2, ?3, ?1, ?4, ?4)",
        [id, workspace, content, @at]
      )

    id
  end

  # `count` memories of one text, stored in the reverse of their id order.
  defp store_identical(ctx, count) do
    ids = memory_ids(ctx.token, count)
    for id <- Enum.reverse(ids), do: insert_memory(ctx.workspace, id, "#{ctx.token} ties")
    ids
  end

  defp index(ids, models) do
    for id <- Enum.shuffle(ids), model <- models do
      {:ok, memory} = Versioned.get(id)
      :ok = Embeddings.put(memory, @vector, model: model)
    end
  end

  defp search(ctx, opts) do
    Search.search(
      ctx.token,
      Keyword.merge([type: :memory, workspace_id: ctx.workspace, limit: 50], opts)
    )
  end

  defp ids_of({:ok, results}), do: Enum.map(results, & &1.id)

  describe "lexical search" do
    test "orders memories equal in score and time by id, whatever order they were stored in",
         ctx do
      ids = store_identical(ctx, 8)

      for _ <- 1..3 do
        assert ids_of(search(ctx, memory_search_mode: :lexical)) == ids
      end

      assert ids_of(search(ctx, memory_search_mode: :lexical, limit: 3)) == Enum.take(ids, 3)
    end

    test "orders by the score with the exact-phrase bonus, not by the order of the SQL", ctx do
      query = "#{ctx.token} alpha"

      # The same words and the same length, so the same BM25 whatever else the
      # database holds; only the one that has the query verbatim earns the
      # bonus. The SQL breaks the tie by id and so lists `plain` first.
      plain = insert_memory(ctx.workspace, "mem-#{ctx.token}-a-plain", "alpha #{ctx.token}")
      phrase = insert_memory(ctx.workspace, "mem-#{ctx.token}-b-phrase", query)

      assert {:ok, results} =
               Search.search(query,
                 type: :memory,
                 workspace_id: ctx.workspace,
                 memory_search_mode: :lexical
               )

      assert Enum.map(results, & &1.id) == [phrase, plain]
      scores = Enum.map(results, &Map.get(&1, :rank_score, &1.score))
      assert scores == Enum.sort(scores, :desc)
    end
  end

  describe "semantic search" do
    test "orders equal similarities by id, whatever order they were embedded in", ctx do
      ids = store_identical(ctx, 8)
      index(ids, ["stubmodel"])

      opts = [
        memory_search_mode: :semantic,
        query_embedding: @vector,
        memory_embedding_model: "stubmodel"
      ]

      for _ <- 1..3, do: assert(ids_of(search(ctx, opts)) == ids)
      assert ids_of(search(ctx, opts ++ [limit: 3])) == Enum.take(ids, 3)
    end

    test "fuses rankings from several models by their best similarity, ties by id", ctx do
      ids = store_identical(ctx, 6)
      index(ids, ["stubmodel", "stubmodel2"])

      opts = [
        memory_search_mode: :semantic,
        query_embedding: @vector,
        memory_embedding_model: "stubmodel,stubmodel2"
      ]

      assert ids_of(search(ctx, opts)) == ids
    end
  end

  describe "hybrid search" do
    test "fuses the lexical and the semantic ranking by reciprocal rank, ties by id", ctx do
      ids = store_identical(ctx, 8)
      index(ids, ["stubmodel"])

      opts = [
        memory_search_mode: :hybrid,
        query_embedding: @vector,
        memory_embedding_model: "stubmodel"
      ]

      for _ <- 1..3, do: assert(ids_of(search(ctx, opts)) == ids)
      assert ids_of(search(ctx, opts ++ [limit: 3])) == Enum.take(ids, 3)
    end

    test "the portfolio of rankings is the same every time", ctx do
      ids = store_identical(ctx, 8)
      index(ids, ["stubmodel"])

      opts = [
        memory_search_mode: :portfolio,
        query_embedding: @vector,
        memory_embedding_model: "stubmodel"
      ]

      first = ids_of(search(ctx, opts))
      assert Enum.sort(first) == ids
      assert first == ids

      for _ <- 1..3, do: assert(ids_of(search(ctx, opts)) == first)
    end
  end

  describe "memories and contexts together" do
    test "are merged on the exact score, and equal scores by uri", ctx do
      ids = store_identical(ctx, 3)
      uris = uris(ctx.token, 3)

      for {uri, n} <- Enum.with_index(Enum.reverse(uris), 1) do
        insert_context(ctx.workspace, "ctx-#{ctx.token}-#{n}", uri, ctx.token)
      end

      assert {:ok, results} =
               Search.search(ctx.token,
                 workspace_id: ctx.workspace,
                 memory_search_mode: :lexical,
                 limit: 10
               )

      # One list, best first by the exact score. Memories and contexts are
      # scored on different scales (a memory's is its BM25 plus the bonus for
      # holding the query verbatim), so how the two kinds interleave depends on
      # the size of the database; within each kind the order is the rule's.
      scores = Enum.map(results, &Map.get(&1, :rank_score, &1.score))
      assert scores == Enum.sort(scores, :desc)

      {memories, contexts} = Enum.split_with(results, &(&1.type == :memory))
      assert Enum.map(memories, & &1.id) == ids
      assert Enum.map(contexts, & &1.id) == for(n <- 3..1//-1, do: "ctx-#{ctx.token}-#{n}")
    end
  end

  describe "the versioned store" do
    test "lists memories equal in creation time by id", ctx do
      ids = store_identical(ctx, 8)

      for _ <- 1..3 do
        assert {:ok, memories} = Versioned.list(workspace_id: ctx.workspace, limit: 50)
        assert Enum.map(memories, & &1.id) == ids
      end

      assert {:ok, memories} = Versioned.list(workspace_id: ctx.workspace, limit: 3)
      assert Enum.map(memories, & &1.id) == Enum.take(ids, 3)
    end

    test "lists a full text match equal in rank by id", ctx do
      ids = store_identical(ctx, 8)

      memories = Memory.list(workspace_id: ctx.workspace, q: ctx.token, limit: 50)
      assert Enum.map(memories, & &1.id) == ids

      memories = Memory.list(workspace_id: ctx.workspace, q: ctx.token, limit: 3)
      assert Enum.map(memories, & &1.id) == Enum.take(ids, 3)
    end
  end

  describe "Embeddings.search" do
    test "orders equal similarities by id, whatever order they were embedded in", ctx do
      ids = store_identical(ctx, 8)
      index(ids, ["stubmodel"])

      for _ <- 1..3 do
        assert {:ok, pairs} =
                 Embeddings.search(@vector,
                   workspace_id: ctx.workspace,
                   model: "stubmodel",
                   limit: 50
                 )

        assert Enum.map(pairs, fn {memory, _score} -> memory.id end) == ids
      end
    end
  end
end
