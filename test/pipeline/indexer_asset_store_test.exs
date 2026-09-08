defmodule OptimalEngine.Pipeline.IndexerAssetStoreTest do
  use ExUnit.Case, async: false

  alias OptimalEngine.{Pipeline.Indexer, Store}

  setup do
    original_root = Application.get_env(:optimal_engine, :root_path)

    tmp_dir =
      Path.join(System.tmp_dir!(), "indexer-asset-store-#{System.unique_integer([:positive])}")

    Application.put_env(:optimal_engine, :root_path, tmp_dir)

    on_exit(fn ->
      if original_root do
        Application.put_env(:optimal_engine, :root_path, original_root)
      else
        Application.delete_env(:optimal_engine, :root_path)
      end

      File.rm_rf(tmp_dir)
    end)

    %{tmp_dir: tmp_dir}
  end

  test "binary indexing preserves assets in the requested workspace", %{tmp_dir: tmp_dir} do
    workspace = "indexed-assets-#{System.unique_integer([:positive])}"
    source_path = Path.join(tmp_dir, "indexed-image.png")
    File.mkdir_p!(tmp_dir)
    File.write!(source_path, "\x89PNG\r\n\x1a\nindexer-asset-store-test")

    assert {:ok, context} =
             Indexer.index_file(source_path,
               workspace_id: workspace,
               actor_id: "user:indexer",
               security_labels: ["internal"],
               partition_ids: ["indexed-media"],
               skip_vlm: true
             )

    assert context.type == :resource
    assert context.path == source_path

    assert {:ok, [[1]]} =
             Store.raw_query(
               """
               SELECT COUNT(*) FROM assets
               WHERE workspace_id = ?1
                 AND original_path = ?2
                 AND modality = 'image'
               """,
               [workspace, source_path]
             )

    assert {:ok, [[1]]} =
             Store.raw_query(
               """
               SELECT COUNT(*) FROM source_packages
               WHERE workspace_id = ?1
                 AND source_uri = ?2
                 AND source_class = 'image'
               """,
               [workspace, source_path]
             )
  end

  test "full crawl assigns nested workspaces and keeps root documents in default", %{tmp_dir: root} do
    original_state = :sys.get_state(Indexer)
    File.mkdir_p!(Path.join(root, "project-a/notes"))
    File.mkdir_p!(Path.join(root, "project-b"))

    paths = [
      {"README.md", "default"},
      {"project-a/notes/one.md", "default:project-a"},
      {"project-b/two.md", "default:project-b"}
    ]

    for {path, _} <- paths,
        do: File.write!(Path.join(root, path), "# Workspace fixture\nVerified scope boundary.")

    :sys.replace_state(Indexer, fn state ->
      %{state | topology: Map.put(state.topology, :root_path, root)}
    end)

    on_exit(fn -> :sys.replace_state(Indexer, fn _ -> original_state end) end)
    assert {:ok, :started} = Indexer.full_index()
    await_index(200)

    for {path, workspace} <- paths do
      assert {:ok, [[^workspace]]} =
               Store.raw_query("SELECT workspace_id FROM contexts WHERE path = ?1", [
                 Path.join(root, path)
               ])
    end
  end

  defp await_index(0), do: flunk("full index did not finish")

  defp await_index(attempts) do
    if Indexer.status().status == :running do
      Process.sleep(10)
      await_index(attempts - 1)
    else
      assert Indexer.status().status == :idle
    end
  end
end
