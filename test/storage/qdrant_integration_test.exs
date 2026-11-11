defmodule OptimalEngine.Storage.QdrantIntegrationTest do
  @moduledoc """
  The Qdrant projection against a real Qdrant server, at
  `OPTIMAL_TEST_QDRANT_URL` (for example `docker run -p 6333:6333
  qdrant/qdrant`). Skipped without it (`test/test_helper.exs`). The
  collections it makes carry a prefix of their own and are deleted after.
  """
  use ExUnit.Case, async: false

  @moduletag :qdrant_integration

  alias OptimalEngine.Context
  alias OptimalEngine.Memory.Versioned
  alias OptimalEngine.Memory.Versioned.Embeddings, as: MemoryEmbeddings
  alias OptimalEngine.Storage.Qdrant
  alias OptimalEngine.Storage.Qdrant.{Projection, Sync}
  alias OptimalEngine.Store
  alias OptimalEngine.Store.Vectors

  @env ~w(OPTIMAL_QDRANT_URL OPTIMAL_QDRANT_API_KEY OPTIMAL_QDRANT_SERVING OPTIMAL_QDRANT_COLLECTION_PREFIX)

  setup do
    previous = Map.new(@env, &{&1, System.get_env(&1)})
    Enum.each(@env, &System.delete_env/1)
    n = System.unique_integer([:positive])
    prefix = "oetest#{n}"

    System.put_env("OPTIMAL_QDRANT_URL", System.fetch_env!("OPTIMAL_TEST_QDRANT_URL"))
    System.put_env("OPTIMAL_QDRANT_COLLECTION_PREFIX", prefix)

    if key = System.get_env("OPTIMAL_TEST_QDRANT_API_KEY"),
      do: System.put_env("OPTIMAL_QDRANT_API_KEY", key)

    Projection.reset()

    on_exit(fn ->
      for kind <- Projection.kinds(),
          {:ok, names} = Projection.collections(kind),
          name <- names,
          do: Qdrant.request(:delete, "/collections/#{name}")

      Projection.reset()

      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    %{n: n, ws: "qdrant-it-#{n}", other: "qdrant-it-other-#{n}", prefix: prefix}
  end

  test "mirrored vectors serve search with the embedded answer, scoped by workspace", ctx do
    vectors =
      for i <- 1..40 do
        angle = i / 40 * :math.pi()
        {"qit#{ctx.n}x#{i}", [:math.cos(angle), :math.sin(angle), 0.1 * rem(i, 3), 0.05]}
      end

    for {id, vector} <- vectors do
      context!(id, ctx.ws)
      :ok = Vectors.store(id, vector)
    end

    intruder = context!("qit#{ctx.n}other", ctx.other)
    :ok = Vectors.store(intruder.id, [1.0, 0.0, 0.0, 0.05])

    :ok = Projection.flush()
    query = [0.95, 0.2, 0.0, 0.05]
    opts = [workspace_id: ctx.ws, limit: 7, min_similarity: 0.1]

    System.put_env("OPTIMAL_QDRANT_SERVING", "off")
    {:ok, embedded} = Vectors.search(query, opts)
    System.delete_env("OPTIMAL_QDRANT_SERVING")

    assert {:ok, served} = Vectors.search(query, opts)
    assert Projection.status().counters.searches_served == 1
    assert Enum.map(served, &elem(&1, 0)) == Enum.map(embedded, &elem(&1, 0))

    for {{_, a}, {_, b}} <- Enum.zip(served, embedded), do: assert(a == b)
    refute Enum.any?(served, fn {id, _} -> id == intruder.id end)
  end

  test "memory search, erasure of a deleted memory, and a sync that removes orphans", ctx do
    {:ok, a} = Versioned.create(%{content: "integration a #{ctx.n}", workspace_id: ctx.ws})
    {:ok, b} = Versioned.create(%{content: "integration b #{ctx.n}", workspace_id: ctx.ws})
    :ok = MemoryEmbeddings.put(a, [1.0, 0.0, 0.0], model: "it")
    :ok = MemoryEmbeddings.put(b, [0.0, 1.0, 0.0], model: "it")
    :ok = Projection.flush()

    assert {:ok, [{found, _}]} =
             MemoryEmbeddings.search([1.0, 0.1, 0.0], workspace_id: ctx.ws, model: "it", limit: 1)

    assert found.id == a.id
    assert Projection.status().counters.searches_served == 1

    :ok = Versioned.delete(a.id)
    :ok = Projection.flush()
    collection = Projection.collection(:memories, 3)
    assert {:ok, 1} = Projection.remote_count(collection, %{workspace_id: ctx.ws})

    # A row removed behind the Engine's back: the sync finds the orphan.
    {:ok, _} = Store.raw_query("DELETE FROM memory_embeddings WHERE memory_id = ?1", [b.id])
    assert {:ok, %{deleted: 1, next: nil}} = Sync.run(workspace_id: ctx.ws)
    assert {:ok, 0} = Projection.remote_count(collection, %{workspace_id: ctx.ws})
  end

  test "forget and hard delete remove a memory's points through the durable removal, Qdrant down or up",
       ctx do
    {:ok, _} = Store.raw_query("DELETE FROM qdrant_pending_removals", [])
    collection = Projection.collection(:memories, 3)
    count = fn -> Projection.remote_count(collection, %{workspace_id: ctx.ws}) end

    # Two chains of two versions; only each latest version is mirrored.
    [forgotten, deleted] =
      for tag <- ["forget", "delete"] do
        {:ok, v1} = Versioned.create(%{content: "it #{tag} #{ctx.n}", workspace_id: ctx.ws})
        :ok = MemoryEmbeddings.put(v1, [1.0, 0.0, 0.0], model: "it")
        {:ok, v2} = Versioned.update(v1.id, %{content: "it #{tag} two #{ctx.n}"})
        :ok = MemoryEmbeddings.put(v2, [0.0, 1.0, 0.0], model: "it")
        {v1, v2}
      end

    :ok = Projection.flush()
    assert {:ok, 2} = count.()

    # Qdrant unreachable: the forget and the hard delete commit, and each
    # records its removal.
    url = System.get_env("OPTIMAL_QDRANT_URL")
    System.put_env("OPTIMAL_QDRANT_URL", "http://127.0.0.1:1")
    assert :ok = Versioned.forget(elem(forgotten, 0).id)
    assert :ok = Versioned.delete(elem(deleted, 1).id)
    :ok = Projection.flush()
    System.put_env("OPTIMAL_QDRANT_URL", url)
    Projection.reset_health()

    assert {:ok, [[2]]} = Store.raw_query("SELECT COUNT(*) FROM qdrant_pending_removals", [])
    assert {:ok, 2} = count.()

    # Qdrant back: the records are applied and the points are gone.
    assert :ok = Projection.retry_pending()
    assert {:ok, [[0]]} = Store.raw_query("SELECT COUNT(*) FROM qdrant_pending_removals", [])
    assert {:ok, 0} = count.()

    # With Qdrant up the removal is applied in order, without a retry.
    {:ok, m} = Versioned.create(%{content: "it live #{ctx.n}", workspace_id: ctx.ws})
    :ok = MemoryEmbeddings.put(m, [0.0, 0.0, 1.0], model: "it")
    :ok = Projection.flush()
    assert {:ok, 1} = count.()
    assert :ok = Versioned.forget(m.id)
    :ok = Projection.flush()
    assert {:ok, 0} = count.()
  end

  defp context!(id, workspace_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    ctx = %Context{
      id: id,
      uri: "optimal://inbox/#{id}.md",
      type: :signal,
      path: "/tmp/#{id}.md",
      title: id,
      content: id,
      l0_abstract: "SIGNAL | note | #{id}",
      l1_overview: id,
      signal: nil,
      node: "inbox",
      sn_ratio: 0.7,
      entities: [],
      created_at: now,
      modified_at: now,
      routed_to: [],
      workspace_id: workspace_id,
      metadata: %{}
    }

    :ok = Store.insert_context(ctx)
    ctx
  end
end
