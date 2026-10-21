defmodule OptimalEngine.Memory.VersionedCacheForgetTest do
  @moduledoc """
  A memory that is deleted or forgotten takes the embedding cached from its text with it,
  while the row is still there to say what the text was.
  """

  use ExUnit.Case, async: false

  alias OptimalEngine.Embed.Text
  alias OptimalEngine.Memory.Versioned
  alias OptimalEngine.Memory.Versioned.Embeddings
  alias OptimalEngine.TestSupport.EmbedStub
  alias OptimalEngine.Workspace

  setup do
    n = System.unique_integer([:positive])
    dir = Path.join(System.tmp_dir!(), "memory-forget-#{n}")

    saved =
      Map.new(
        [:cache_path, :text_embedding, :memory_embeddings],
        &{&1, Application.get_env(:optimal_engine, &1)}
      )

    Application.put_env(:optimal_engine, :cache_path, dir)
    {url, stop} = EmbedStub.start()
    Application.put_env(:optimal_engine, :text_embedding, url: url, dimensions: 4)
    # The embedding is cached here by hand, so nothing indexes behind the test's back.
    Application.put_env(:optimal_engine, :memory_embeddings, auto_index: false)

    on_exit(fn ->
      stop.()

      Enum.each(saved, fn
        {name, nil} -> Application.delete_env(:optimal_engine, name)
        {name, value} -> Application.put_env(:optimal_engine, name, value)
      end)

      File.rm_rf(dir)
    end)

    {:ok, workspace} = Workspace.create(%{slug: "memory-forget-#{n}", name: "Memory forget"})
    %{n: n, dir: dir, workspace: workspace.id}
  end

  test "deleting a memory removes the embedding cached from its content", ctx do
    memory = memory!(ctx, "deleted memory #{ctx.n}")
    bystander = memory!(ctx, "bystander memory #{ctx.n}")
    cache_embedding!(memory)
    cache_embedding!(bystander)
    assert length(cache_files(ctx.dir)) == 2

    assert :ok = Versioned.delete(memory.id)

    assert length(cache_files(ctx.dir)) == 1
    assert {:error, :not_found} = Versioned.get(memory.id)
  end

  test "forgetting a memory removes it too", ctx do
    memory = memory!(ctx, "forgotten memory #{ctx.n}")
    cache_embedding!(memory)
    assert length(cache_files(ctx.dir)) == 1

    assert :ok = Versioned.forget(memory.id, reason: "asked to")

    assert cache_files(ctx.dir) == []
  end

  test "an entry made under a prefix the row cannot reproduce is left to the sweep", ctx do
    memory = memory!(ctx, "prefixed memory #{ctx.n}")

    {:ok, _} =
      Text.embed("search_document: " <> memory.content,
        model: Embeddings.model(),
        tenant_id: memory.tenant_id,
        workspace_id: memory.workspace_id
      )

    assert :ok = Versioned.delete(memory.id)

    assert length(cache_files(ctx.dir)) == 1
  end

  defp memory!(ctx, content) do
    {:ok, memory} = Versioned.create(%{content: content, workspace_id: ctx.workspace})
    memory
  end

  defp cache_embedding!(memory) do
    {:ok, _} =
      Text.embed(memory.content,
        model: Embeddings.model(),
        tenant_id: memory.tenant_id,
        workspace_id: memory.workspace_id
      )
  end

  defp cache_files(dir) do
    dir |> Path.join("**/*") |> Path.wildcard(match_dot: true) |> Enum.filter(&File.regular?/1)
  end
end
