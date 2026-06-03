defmodule OptimalEngine.MemoryCore.AssetStoreTest do
  use ExUnit.Case, async: false

  alias OptimalEngine.{MemoryCore, Store}

  setup do
    original_root = Application.get_env(:optimal_engine, :root_path)
    tmp_dir = Path.join(System.tmp_dir!(), "asset-store-#{System.unique_integer([:positive])}")
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

  test "stores a raw file as governed asset evidence", %{tmp_dir: tmp_dir} do
    source_path = Path.join(tmp_dir, "input.png")
    File.mkdir_p!(tmp_dir)
    File.write!(source_path, "\x89PNG\r\n\x1a\nasset-store-test")

    assert {:ok, %{asset: asset, source_package: source_package}} =
             MemoryCore.store_asset_file(source_path,
               workspace_id: "default",
               actor_id: "user:asset-reviewer",
               trust_label: "unreviewed",
               security_labels: ["internal"],
               partition_ids: ["media"],
               metadata: %{purpose: "asset-store-test"}
             )

    assert asset.id =~ "asset_"
    assert asset.workspace_id == "default"
    assert asset.modality == "image"
    assert asset.content_hash =~ "sha256:"
    assert asset.source_package_id == source_package.id
    assert asset.trust_label == "unreviewed"
    assert asset.security_labels == ["internal"]
    assert asset.partition_ids == ["media"]
    assert asset.metadata["purpose"] == "asset-store-test"
    assert File.exists?(asset.storage_path)
    assert asset.storage_path != source_path

    assert source_package.source_class == "image"
    assert source_package.verbatim_archive_uri == asset.storage_path
    assert source_package.metadata.asset_id == asset.id
    assert source_package.metadata.content_hash == asset.content_hash

    assert {:ok, fetched} = MemoryCore.get_asset(asset.id, workspace_id: "default")
    assert fetched.id == asset.id
    assert fetched.source_package_id == source_package.id

    assert {:ok, [[1]]} =
             Store.raw_query(
               "SELECT COUNT(*) FROM source_packages WHERE id = ?1 AND workspace_id = ?2",
               [source_package.id, "default"]
             )

    assert {:ok, [[ledger_count]]} =
             Store.raw_query(
               """
               SELECT COUNT(*) FROM derivation_ledger
               WHERE workspace_id = ?1
                 AND activity_type = 'asset_store.preserve_file'
                 AND output_object_links LIKE ?2
               """,
               ["default", "%#{asset.id}%"]
             )

    assert ledger_count >= 1
  end

  test "same bytes in different workspaces keep separate asset identities", %{tmp_dir: tmp_dir} do
    source_path = Path.join(tmp_dir, "shared.wav")
    File.mkdir_p!(tmp_dir)
    File.write!(source_path, "RIFF....WAVEasset-store-test")

    assert {:ok, %{asset: default_asset}} =
             MemoryCore.store_asset_file(source_path, workspace_id: "default")

    assert {:ok, %{asset: other_asset}} =
             MemoryCore.store_asset_file(source_path, workspace_id: "second-workspace")

    assert default_asset.content_hash == other_asset.content_hash
    assert default_asset.id != other_asset.id
    assert default_asset.workspace_id == "default"
    assert other_asset.workspace_id == "second-workspace"
  end

  test "records multimodal adapter runs as derived asset artifacts", %{tmp_dir: tmp_dir} do
    source_path = Path.join(tmp_dir, "document.pdf")
    File.mkdir_p!(tmp_dir)
    File.write!(source_path, "%PDF-1.7\nasset-adapter-run-test")

    assert {:ok, %{asset: asset}} =
             MemoryCore.store_asset_file(source_path,
               workspace_id: "adapter-workspace",
               actor_id: "user:adapter",
               security_labels: ["internal"],
               partition_ids: ["documents"]
             )

    assert {:ok, run} =
             MemoryCore.record_asset_adapter_run(asset.id,
               workspace_id: "adapter-workspace",
               actor_id: "user:adapter",
               adapter_id: :docling,
               adapter_role: :document_intelligence,
               status: "completed",
               output_text: "Extracted document text",
               model_id: "docling",
               model_version: "local",
               confidence: 0.82,
               precision: 0.77,
               metadata: %{pages: 1}
             )

    assert run.id =~ "aar_"
    assert run.asset_id == asset.id
    assert run.adapter_id == "docling"
    assert run.adapter_role == "document_intelligence"
    assert run.status == "completed"
    assert run.output_hash =~ "sha256:"

    assert {:ok, [stored_run]} =
             MemoryCore.list_asset_adapter_runs(asset.id, workspace_id: "adapter-workspace")

    assert stored_run.id == run.id
    assert stored_run.derivation_ledger_id =~ "dl_"
    assert stored_run.metadata["pages"] == 1
    assert stored_run.security_labels == ["internal"]
    assert stored_run.partition_ids == ["documents"]

    assert {:ok, [[1]]} =
             Store.raw_query(
               """
               SELECT COUNT(*) FROM derivation_ledger
               WHERE workspace_id = ?1
                 AND activity_type = 'asset_adapter.docling'
                 AND output_object_links LIKE ?2
               """,
               ["adapter-workspace", "%#{run.id}%"]
             )
  end

  test "turns a completed adapter run into a pending claim", %{tmp_dir: tmp_dir} do
    source_path = Path.join(tmp_dir, "claimable.pdf")
    File.mkdir_p!(tmp_dir)
    File.write!(source_path, "%PDF-1.7\nasset-adapter-claim-test")

    assert {:ok, %{asset: asset}} =
             MemoryCore.store_asset_file(source_path,
               workspace_id: "adapter-claim-workspace",
               actor_id: "user:adapter",
               security_labels: ["internal"],
               partition_ids: ["documents"]
             )

    assert {:ok, run} =
             MemoryCore.record_asset_adapter_run(asset.id,
               workspace_id: "adapter-claim-workspace",
               actor_id: "user:adapter",
               adapter_id: :docling,
               adapter_role: :document_intelligence,
               status: "completed",
               output_text: "Adapter found an approved renewal date.",
               model_id: "docling",
               confidence: 0.72,
               precision: 0.68
             )

    assert {:ok, %{source_package: source_package, pending_claim: claim}} =
             MemoryCore.claim_from_asset_adapter_run(run.id,
               workspace_id: "adapter-claim-workspace",
               actor_id: "user:reviewer",
               subject_anchor: "renewal",
               action_class: "found_date"
             )

    assert source_package.source_type == "adapter_output"
    assert source_package.source_system == "docling"
    assert source_package.metadata.adapter_run_id == run.id

    assert claim.claim_type == "adapter_output"
    assert claim.claim_text == "Adapter found an approved renewal date."
    assert claim.review_status == "unreviewed"
    assert claim.lifecycle_state == "pending"
    assert claim.source_package_id == source_package.id
    assert claim.aggregate_confidence == 0.72
    assert claim.aggregate_precision == 0.68

    assert {:ok, [[1]]} =
             Store.raw_query(
               """
               SELECT COUNT(*) FROM claims
               WHERE workspace_id = ?1
                 AND extraction_run_id = ?2
                 AND review_status = 'unreviewed'
               """,
               ["adapter-claim-workspace", run.id]
             )
  end

  test "does not create a claim from unavailable adapter output", %{tmp_dir: tmp_dir} do
    source_path = Path.join(tmp_dir, "unavailable.pdf")
    File.mkdir_p!(tmp_dir)
    File.write!(source_path, "%PDF-1.7\nasset-adapter-unavailable-test")

    assert {:ok, %{asset: asset}} =
             MemoryCore.store_asset_file(source_path,
               workspace_id: "adapter-claim-workspace",
               actor_id: "user:adapter"
             )

    assert {:ok, run} =
             MemoryCore.record_asset_adapter_run(asset.id,
               workspace_id: "adapter-claim-workspace",
               actor_id: "user:adapter",
               adapter_id: :docling,
               status: "unavailable",
               error_reason: "command not found"
             )

    assert {:error, {:adapter_run_not_completed, "unavailable"}} =
             MemoryCore.claim_from_asset_adapter_run(run.id,
               workspace_id: "adapter-claim-workspace"
             )
  end
end
