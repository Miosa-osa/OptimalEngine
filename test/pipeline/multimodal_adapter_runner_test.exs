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

    assert {:ok, [extraction]} =
             MemoryCore.list_asset_extractions(asset.id, workspace_id: "runner-workspace")

    assert extraction.adapter_run_id == run.id
    assert extraction.extraction_type == "ocr_span"
    assert extraction.content_text == "Docling extracted text"
    assert extraction.metadata["auto_projected"] == true

    assert {:ok, [[1]]} =
             Store.raw_query(
               """
               SELECT COUNT(*) FROM asset_ocr_spans
               WHERE workspace_id = ?1
                 AND asset_id = ?2
                 AND adapter_run_id = ?3
               """,
               ["runner-workspace", asset.id, run.id]
             )
  end

  test "can disable automatic extraction projection", %{tmp_dir: tmp_dir} do
    asset = store_test_asset!(tmp_dir, "manual.pdf", "%PDF-1.7\nmanual-projection-test")

    assert {:ok, run} =
             MemoryCore.run_asset_adapter(asset.id, :docling,
               workspace_id: "runner-workspace",
               actor_id: "user:runner",
               command: "printf",
               args: ["Manual extraction only"],
               auto_extract: false
             )

    assert run.status == "completed"

    assert {:ok, []} =
             MemoryCore.list_asset_extractions(asset.id, workspace_id: "runner-workspace")
  end

  test "projects transcript JSON into segment-level transcript rows", %{tmp_dir: tmp_dir} do
    asset = store_test_asset!(tmp_dir, "segments.wav", "RIFF....WAVEsegments")

    transcript_json =
      Jason.encode!(%{
        language: "en",
        segments: [
          %{id: 1, start: 0.0, end: 1.25, speaker: "speaker-a", text: "First segment"},
          %{id: 2, start: 1.25, end: 2.0, speaker: "speaker-b", text: "Second segment"}
        ]
      })

    assert {:ok, run} =
             MemoryCore.run_asset_adapter(asset.id, :openai_whisper,
               workspace_id: "runner-workspace",
               actor_id: "user:runner",
               command: "printf",
               args: [transcript_json],
               adapter_role: :audio_transcription,
               confidence: 0.88,
               precision: 0.77
             )

    assert run.status == "completed"

    assert {:ok, extractions} =
             MemoryCore.list_asset_extractions(asset.id, workspace_id: "runner-workspace")

    assert Enum.count(extractions, &(&1.extraction_type == "transcript")) == 2
    assert Enum.any?(extractions, &(&1.content_text == "First segment"))
    assert Enum.any?(extractions, &(&1.content_text == "Second segment"))

    assert {:ok, rows} =
             Store.raw_query(
               """
               SELECT transcript_text, language, speaker, start_ms, end_ms
               FROM asset_transcripts
               WHERE workspace_id = ?1 AND asset_id = ?2
               ORDER BY start_ms ASC
               """,
               ["runner-workspace", asset.id]
             )

    assert [
             ["First segment", "en", "speaker-a", 0, 1250],
             ["Second segment", "en", "speaker-b", 1250, 2000]
           ] = rows
  end

  test "projects document JSON into page-level OCR spans", %{tmp_dir: tmp_dir} do
    asset = store_test_asset!(tmp_dir, "pages.pdf", "%PDF-1.7\npage-json-test")

    page_json =
      Jason.encode!(%{
        pages: [
          %{page_number: 1, text: "Page one extracted text", bbox: %{x: 1, y: 2}},
          %{page_number: 2, text: "Page two extracted text", bbox: %{x: 3, y: 4}}
        ]
      })

    assert {:ok, run} =
             MemoryCore.run_asset_adapter(asset.id, :docling,
               workspace_id: "runner-workspace",
               actor_id: "user:runner",
               command: "printf",
               args: [page_json],
               adapter_role: :document_intelligence
             )

    assert run.status == "completed"

    assert {:ok, extractions} =
             MemoryCore.list_asset_extractions(asset.id, workspace_id: "runner-workspace")

    assert Enum.count(extractions, &(&1.extraction_type == "ocr_span")) == 2

    assert {:ok, rows} =
             Store.raw_query(
               """
               SELECT page_number, span_text, bbox
               FROM asset_ocr_spans
               WHERE workspace_id = ?1 AND asset_id = ?2
               ORDER BY page_number ASC
               """,
               ["runner-workspace", asset.id]
             )

    assert [[1, "Page one extracted text", bbox_1], [2, "Page two extracted text", bbox_2]] = rows
    assert Jason.decode!(bbox_1) == %{"x" => 1, "y" => 2}
    assert Jason.decode!(bbox_2) == %{"x" => 3, "y" => 4}
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
