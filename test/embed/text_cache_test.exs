defmodule OptimalEngine.Embed.TextCacheTest do
  @moduledoc """
  The embedder's filesystem cache holds no text, keeps each workspace's entries
  apart, and serves a search from its own workspace's entries.

  An embedding endpoint is stubbed, so a request that reaches it is a cache miss.
  """

  use ExUnit.Case, async: false

  alias OptimalEngine.Embed.Text
  alias OptimalEngine.Retrieval.Search
  alias OptimalEngine.TestSupport.EmbedStub

  @saved [:cache_path, :text_embedding, :hybrid_search]

  setup do
    saved = Map.new(@saved, &{&1, Application.get_env(:optimal_engine, &1)})
    dir = Path.join(System.tmp_dir!(), "text-cache-#{System.unique_integer([:positive])}")
    Application.put_env(:optimal_engine, :cache_path, dir)

    {url, stop} = EmbedStub.start()
    Application.put_env(:optimal_engine, :text_embedding, url: url, dimensions: 4)

    on_exit(fn ->
      stop.()

      Enum.each(saved, fn
        {name, nil} -> Application.delete_env(:optimal_engine, name)
        {name, value} -> Application.put_env(:optimal_engine, name, value)
      end)

      File.rm_rf(dir)
    end)

    tag = Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
    %{dir: dir, tag: tag, one: scope("one-#{tag}"), two: scope("two-#{tag}")}
  end

  test "an entry holds neither the text nor the endpoint it came from", ctx do
    text = "marker-#{ctx.tag} the patient's diagnosis"

    assert {:ok, [1.0, +0.0, +0.0, +0.0]} = Text.embed(text, ctx.one)
    assert_received {:embed_request, "/v1/embeddings", ^text}

    assert [_entry] = cache_files(ctx.dir)
    bytes = cache_bytes(ctx.dir)
    refute contains?(bytes, "marker-#{ctx.tag}")
    refute contains?(bytes, "127.0.0.1")
    refute contains?(bytes, "nomic-embed-text")
  end

  test "an identical text is served from the cache within its workspace", ctx do
    text = "again-#{ctx.tag}"

    assert {:ok, vector} = Text.embed(text, ctx.one)
    assert {:ok, ^vector} = Text.embed(text, ctx.one)
    assert [{:ok, ^vector}] = Text.embed_many([text], ctx.one)

    assert_received {:embed_request, _, ^text}
    refute_received {:embed_request, _, _}
  end

  test "two workspaces with identical text get separate entries", ctx do
    text = "shared-#{ctx.tag}"

    assert {:ok, vector} = Text.embed(text, ctx.one)
    assert_received {:embed_request, _, ^text}

    # The second workspace is not answered from the first one's entry.
    assert {:ok, ^vector} = Text.embed(text, ctx.two)
    assert_received {:embed_request, _, ^text}

    assert length(cache_files(ctx.dir)) == 2

    assert {:ok, ^vector} = Text.embed(text, ctx.one)
    assert {:ok, ^vector} = Text.embed(text, ctx.two)
    refute_received {:embed_request, _, _}
  end

  test "the same workspace id under another tenant is a separate partition", ctx do
    text = "tenants-#{ctx.tag}"
    other_tenant = Keyword.put(ctx.one, :tenant_id, "other-#{ctx.tag}")

    assert {:ok, _} = Text.embed(text, ctx.one)
    assert {:ok, _} = Text.embed(text, other_tenant)
    assert_received {:embed_request, _, ^text}
    assert_received {:embed_request, _, ^text}
  end

  test "an embedding with no workspace to keep it in is never cached", ctx do
    text = "unscoped-#{ctx.tag}"

    assert {:ok, _} = Text.embed(text)
    assert {:ok, _} = Text.embed(text)
    assert [{:ok, _}] = Text.embed_many([text])
    assert_received {:embed_request, _, ^text}
    assert_received {:embed_request, _, ^text}
    assert_received {:embed_request, _, [^text]}

    assert cache_files(ctx.dir) == []
  end

  test "cache: false bypasses the cache even with a workspace", ctx do
    text = "bypass-#{ctx.tag}"

    assert {:ok, _} = Text.embed(text, [{:cache, false} | ctx.one])
    assert {:ok, _} = Text.embed(text, [{:cache, false} | ctx.one])
    assert cache_files(ctx.dir) == []
  end

  test "a search still hits the cache within its workspace", ctx do
    hybrid = Application.get_env(:optimal_engine, :hybrid_search, [])
    Application.put_env(:optimal_engine, :hybrid_search, Keyword.put(hybrid, :vector_enabled, true))

    query = "who are we recruiting #{ctx.tag}"
    workspace = ctx.one[:workspace_id]
    other = ctx.two[:workspace_id]

    assert {:ok, _} = Search.search(query, workspace_id: workspace)
    assert_received {:embed_request, "/v1/embeddings", ^query}
    flush_requests(query)

    assert {:ok, _} = Search.search(query, workspace_id: workspace)
    refute_received {:embed_request, _, ^query}

    # The same words searched in another workspace are embedded again.
    assert {:ok, _} = Search.search(query, workspace_id: other)
    assert_received {:embed_request, "/v1/embeddings", ^query}
  end

  defp flush_requests(text) do
    receive do
      {:embed_request, _, ^text} -> flush_requests(text)
    after
      0 -> :ok
    end
  end

  defp scope(name), do: [tenant_id: "default", workspace_id: "default:cache-#{name}"]

  defp cache_files(dir) do
    dir |> Path.join("**/*") |> Path.wildcard(match_dot: true) |> Enum.filter(&File.regular?/1)
  end

  defp cache_bytes(dir), do: dir |> cache_files() |> Enum.map_join(&File.read!/1)

  defp contains?(bytes, needle), do: :binary.match(bytes, needle) != :nomatch
end
