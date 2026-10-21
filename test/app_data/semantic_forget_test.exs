defmodule OptimalEngine.AppData.SemanticForgetTest do
  @moduledoc """
  A record that is deleted, or whose indexed text is rewritten, takes the embedding cached
  from the old text with it. A collection dropped whole is left to the age sweep.
  """

  use ExUnit.Case, async: false

  alias OptimalEngine.AppData
  alias OptimalEngine.AppData.Scope
  alias OptimalEngine.TestSupport.EmbedStub

  setup do
    n = System.unique_integer([:positive])
    dir = Path.join(System.tmp_dir!(), "appdata-forget-#{n}")

    saved =
      Map.new(
        [:cache_path, :text_embedding, :app_data],
        &{&1, Application.get_env(:optimal_engine, &1)}
      )

    Application.put_env(:optimal_engine, :cache_path, dir)
    {url, stop} = EmbedStub.start()
    Application.put_env(:optimal_engine, :text_embedding, url: url, dimensions: 4)
    Application.put_env(:optimal_engine, :app_data, semantic_indexing: :sync)

    on_exit(fn ->
      stop.()

      Enum.each(saved, fn
        {name, nil} -> Application.delete_env(:optimal_engine, name)
        {name, value} -> Application.put_env(:optimal_engine, name, value)
      end)

      File.rm_rf(dir)
    end)

    scope =
      Scope.new(
        tenant_id: "default",
        workspace_id: "default:appdata-forget-#{n}",
        actor: "local:operator"
      )

    {:ok, _} =
      AppData.create_collection(scope, %{
        "name" => "notes",
        "fields" => [
          %{"name" => "title", "type" => "string", "required" => true},
          %{"name" => "owner", "type" => "string"}
        ],
        "search" => %{"semantic" => ["title"]}
      })

    %{scope: scope, dir: dir, n: n}
  end

  test "deleting a record removes the embedding cached from its text", ctx do
    {:ok, kept} = AppData.create(ctx.scope, "notes", %{"data" => %{"title" => "kept #{ctx.n}"}})
    {:ok, gone} = AppData.create(ctx.scope, "notes", %{"data" => %{"title" => "gone #{ctx.n}"}})
    assert length(cache_files(ctx.dir)) == 2

    assert {:ok, _} = AppData.delete(ctx.scope, "notes", gone["id"])

    assert length(cache_files(ctx.dir)) == 1
    assert {:ok, _} = AppData.get(ctx.scope, "notes", kept["id"])
  end

  test "rewriting the indexed text removes the embedding of the old text", ctx do
    {:ok, note} = AppData.create(ctx.scope, "notes", %{"data" => %{"title" => "first #{ctx.n}"}})
    assert length(cache_files(ctx.dir)) == 1

    assert {:ok, _} =
             AppData.update(ctx.scope, "notes", note["id"], %{
               "data" => %{"title" => "second #{ctx.n}"}
             })

    # The new text is cached, the old one is not: one entry, not two.
    assert length(cache_files(ctx.dir)) == 1
  end

  test "changing a field that is not indexed keeps the entry", ctx do
    {:ok, note} = AppData.create(ctx.scope, "notes", %{"data" => %{"title" => "steady #{ctx.n}"}})
    assert length(cache_files(ctx.dir)) == 1

    assert {:ok, _} =
             AppData.update(ctx.scope, "notes", note["id"], %{"data" => %{"owner" => "someone"}})

    assert length(cache_files(ctx.dir)) == 1
  end

  defp cache_files(dir) do
    dir |> Path.join("**/*") |> Path.wildcard(match_dot: true) |> Enum.filter(&File.regular?/1)
  end
end
