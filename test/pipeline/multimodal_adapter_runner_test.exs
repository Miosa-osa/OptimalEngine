defmodule OptimalEngine.Pipeline.MultimodalAdapterRunnerTest do
  use ExUnit.Case, async: false

  alias OptimalEngine.{MemoryCore, Store}

  setup do
    original_root = Application.get_env(:optimal_engine, :root_path)

    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "multimodal-adapter-runner-#{System.unique_integer([:positive])}"
      )

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

  test "executes a configured adapter command and records a completed run", %{tmp_dir: tmp_dir} do
    asset = store_test_asset!(tmp_dir, "doc.pdf", "%PDF-1.7\nrunner-test")

    assert {:ok, run} =
             MemoryCore.run_asset_adapter(asset.id, :docling,
               workspace_id: "runner-workspace",
               actor_id: "user:runner",
               command: "printf",
               args: ["Docling extracted text"],
               model_version: "test",
               metadata: %{test_case: "completed"}
             )

    assert run.status == "completed"
    assert run.adapter_id == "docling"
    assert run.output_text == "Docling extracted text"
    assert run.output_hash =~ "sha256:"
    assert run.metadata["command"] == "printf"
    assert run.metadata["args"] == ["Docling extracted text"]
    assert run.metadata["test_case"] == "completed"

    assert {:ok, [[1]]} =
             Store.raw_query(
               """
               SELECT COUNT(*) FROM asset_adapter_runs
               WHERE workspace_id = ?1
                 AND asset_id = ?2
                 AND status = 'completed'
               """,
               ["runner-workspace", asset.id]
             )
  end

  test "records unavailable run when adapter command is not configured or missing", %{
    tmp_dir: tmp_dir
  } do
    asset = store_test_asset!(tmp_dir, "image.png", "\x89PNG\r\n\x1a\nrunner-test")

    assert {:ok, run} =
             MemoryCore.run_asset_adapter(asset.id, :qwen_vl,
               workspace_id: "runner-workspace",
               actor_id: "user:runner"
             )

    assert run.status == "unavailable"
    assert run.adapter_id == "qwen_vl"
    assert run.error_reason == "adapter has no local command configured"

    assert {:ok, [stored_run]} =
             MemoryCore.list_asset_adapter_runs(asset.id, workspace_id: "runner-workspace")

    assert stored_run.id == run.id
    assert stored_run.derivation_ledger_id =~ "dl_"
  end

  test "unknown adapter is rejected before an adapter run is written", %{tmp_dir: tmp_dir} do
    asset = store_test_asset!(tmp_dir, "unknown.bin", "runner-test")

    assert {:error, {:unknown_adapter, :not_a_real_adapter}} =
             MemoryCore.run_asset_adapter(asset.id, :not_a_real_adapter,
               workspace_id: "runner-workspace"
             )

    assert {:ok, []} =
             MemoryCore.list_asset_adapter_runs(asset.id, workspace_id: "runner-workspace")
  end

  defp store_test_asset!(tmp_dir, filename, bytes) do
    path = Path.join(tmp_dir, filename)
    File.mkdir_p!(tmp_dir)
    File.write!(path, bytes)

    {:ok, %{asset: asset}} =
      MemoryCore.store_asset_file(path,
        workspace_id: "runner-workspace",
        actor_id: "user:runner",
        security_labels: ["internal"],
        partition_ids: ["runner-assets"]
      )

    asset
  end
end
