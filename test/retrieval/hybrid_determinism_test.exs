defmodule OptimalEngine.Retrieval.HybridDeterminismTest do
  @moduledoc """
  The hybrid path (full text plus the vector hop) ranks the same way on two
  Engines that hold the same data.

  A local endpoint answers every embedding with the same vector, so no model is
  loaded. Every context that has a stored vector is then exactly as similar to
  the query as every other, and only the ordering rule separates them. Context
  ids run opposite to their URIs, so an order by id cannot pass for an order by
  URI.
  """

  use ExUnit.Case, async: false

  import OptimalEngine.TestSupport.RetrievalFixtures

  alias OptimalEngine.Retrieval.Search
  alias OptimalEngine.Store.Vectors

  @vector [1.0, 0.0, 0.0, 0.0]

  setup do
    token = token()
    workspaces = ["#{token}-a", "#{token}-b"]
    on_exit(fn -> delete_workspaces(workspaces) end)
    use_embedder(fn _text -> @vector end)
    {:ok, token: token, ws_a: Enum.at(workspaces, 0), ws_b: Enum.at(workspaces, 1)}
  end

  # `count` contexts with the query's vector, whose ids run opposite to their
  # URIs: in `ws_a` stored in uri order, in `ws_b` in the reverse.
  defp store_twice(token, ws_a, ws_b, count, opts \\ []) do
    uris = uris(token, count)
    numbered = Enum.with_index(uris, 1)

    store = fn workspace, label, pairs ->
      for {uri, n} <- pairs do
        id = "#{token}-#{label}-#{String.pad_leading(Integer.to_string(count + 1 - n), 2, "0")}"
        insert_context(workspace, id, uri, token, opts)
        :ok = Vectors.store(id, @vector, workspace_id: workspace)
      end
    end

    store.(ws_a, "a", numbered)
    store.(ws_b, "b", Enum.reverse(numbered))
    uris
  end

  defp uris_of(results), do: Enum.map(results, & &1.uri)

  defp insert_chunk_embedding(workspace, chunk_id, context_id, vector) do
    blob = for value <- vector, into: <<>>, do: <<value::float-little-32>>

    {:ok, _} =
      OptimalEngine.Store.raw_query(
        "INSERT INTO chunks (id, tenant_id, signal_id, scale, text, workspace_id) VALUES (?1, 'default', ?2, 'chunk', ?3, ?4)",
        [chunk_id, context_id, context_id, workspace]
      )

    {:ok, _} =
      OptimalEngine.Store.raw_query(
        "INSERT INTO chunk_embeddings (chunk_id, tenant_id, model, modality, dim, vector, workspace_id) VALUES (?1, 'default', 'test', 'text', ?2, ?3, ?4)",
        [chunk_id, length(vector), {:blob, blob}, workspace]
      )
  end

  test "the hybrid path runs against the local embedder", ctx do
    store_twice(ctx.token, ctx.ws_a, ctx.ws_b, 3)
    assert {:ok, [_ | _]} = Search.search(ctx.token, workspace_id: ctx.ws_a, mode: :hybrid)
  end

  test "contexts that tie on text and on vector rank in uri order", ctx do
    uris = store_twice(ctx.token, ctx.ws_a, ctx.ws_b, 12)

    for workspace <- [ctx.ws_a, ctx.ws_b], mode <- [:hybrid, :auto] do
      assert {:ok, results} =
               Search.search(ctx.token, workspace_id: workspace, mode: mode, limit: 20)

      assert uris_of(results) == uris
    end
  end

  test "a cut inside a tie keeps the first contexts by uri, not by id", ctx do
    uris = store_twice(ctx.token, ctx.ws_a, ctx.ws_b, 12)

    for workspace <- [ctx.ws_a, ctx.ws_b] do
      assert {:ok, results} =
               Search.search(ctx.token, workspace_id: workspace, mode: :hybrid, limit: 4)

      assert uris_of(results) == Enum.take(uris, 4)
    end
  end

  test "a cut inside a tie of contexts only the vector found keeps the first by uri", ctx do
    # Three contexts match the text and the vector. Six more match the vector
    # alone: they tie each other below the first three, and the cut at five
    # falls inside that tie. They are loaded from the database to be ranked.
    matching = store_twice(ctx.token, ctx.ws_a, ctx.ws_b, 3)
    only_vector = for n <- 4..9, do: "optimal://nodes/ranking/#{ctx.token}/doc-0#{n}"
    numbered = Enum.with_index(only_vector, 4)

    # Ids run opposite to the URIs here too.
    for {workspace, label, order} <- [
          {ctx.ws_a, "a", numbered},
          {ctx.ws_b, "b", Enum.reverse(numbered)}
        ],
        {uri, n} <- order do
      id = "#{ctx.token}-#{label}-vec-#{20 - n}"

      insert_context(workspace, id, uri, ctx.token,
        title: "Unrelated #{id}",
        content: "nothing in common with the query"
      )

      :ok = Vectors.store(id, @vector, workspace_id: workspace)
    end

    for workspace <- [ctx.ws_a, ctx.ws_b] do
      assert {:ok, results} =
               Search.search(ctx.token, workspace_id: workspace, mode: :hybrid, limit: 5)

      assert uris_of(results) == matching ++ Enum.take(only_vector, 2)
    end
  end

  test "lexical mode ignores the vectors", ctx do
    store_twice(ctx.token, ctx.ws_a, ctx.ws_b, 3)

    uri = "optimal://nodes/ranking/#{ctx.token}/zz"

    insert_context(ctx.ws_a, "#{ctx.token}-vec-only", uri, ctx.token,
      title: "Unrelated",
      content: "nothing in common with the query"
    )

    :ok = Vectors.store("#{ctx.token}-vec-only", @vector, workspace_id: ctx.ws_a)

    assert {:ok, lexical} = Search.search(ctx.token, workspace_id: ctx.ws_a, mode: :lexical)
    assert {:ok, hybrid} = Search.search(ctx.token, workspace_id: ctx.ws_a, mode: :hybrid)

    refute Enum.any?(lexical, &String.ends_with?(&1.uri, "/zz"))
    assert Enum.any?(hybrid, &String.ends_with?(&1.uri, "/zz"))
  end

  describe "Store.Vectors" do
    test "search orders equal similarities by context id, whatever order they were stored in",
         ctx do
      ids = for n <- 1..8, do: "#{ctx.token}-v-#{n}"

      for {id, n} <- ids |> Enum.with_index(1) |> Enum.shuffle() do
        insert_context(ctx.ws_a, id, "optimal://nodes/ranking/#{ctx.token}/v-#{n}", ctx.token)
        :ok = Vectors.store(id, @vector, workspace_id: ctx.ws_a)
      end

      for _ <- 1..3 do
        assert {:ok, pairs} = Vectors.search(@vector, workspace_id: ctx.ws_a, limit: 20)
        assert Enum.map(pairs, &elem(&1, 0)) == ids
        assert pairs |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> length() == 1
      end

      assert {:ok, pairs} = Vectors.search(@vector, workspace_id: ctx.ws_a, limit: 3)
      assert Enum.map(pairs, &elem(&1, 0)) == Enum.take(ids, 3)
    end

    test "search orders by similarity first", ctx do
      vectors = [
        {"#{ctx.token}-a-first", [0.0, 1.0, 0.0, 0.0]},
        {"#{ctx.token}-far", [0.5, 0.5, 0.5, 0.5]},
        {"#{ctx.token}-near", [0.9, 0.1, 0.0, 0.0]}
      ]

      for {{id, vector}, n} <- Enum.with_index(vectors, 1) do
        insert_context(ctx.ws_a, id, "optimal://nodes/ranking/#{ctx.token}/s-#{n}", ctx.token)
        :ok = Vectors.store(id, vector, workspace_id: ctx.ws_a)
      end

      assert {:ok, pairs} =
               Vectors.search(@vector, workspace_id: ctx.ws_a, limit: 10, min_similarity: 0.1)

      assert Enum.map(pairs, &elem(&1, 0)) == ["#{ctx.token}-near", "#{ctx.token}-far"]
    end

    test "rerank_contexts orders equal chunk similarities by context id", ctx do
      ids = for n <- 1..6, do: "#{ctx.token}-r-#{n}"

      for {id, n} <- ids |> Enum.with_index(1) |> Enum.shuffle() do
        insert_context(ctx.ws_a, id, "optimal://nodes/ranking/#{ctx.token}/r-#{n}", ctx.token)
        insert_chunk_embedding(ctx.ws_a, "#{id}-chunk", id, @vector)
      end

      for _ <- 1..3 do
        assert {:ok, pairs} =
                 Vectors.rerank_contexts(@vector, Enum.shuffle(ids), workspace_id: ctx.ws_a)

        assert Enum.map(pairs, &elem(&1, 0)) == ids
      end

      assert {:ok, pairs} =
               Vectors.rerank_contexts(@vector, ids, workspace_id: ctx.ws_a, limit: 2)

      assert Enum.map(pairs, &elem(&1, 0)) == Enum.take(ids, 2)
    end
  end
end
