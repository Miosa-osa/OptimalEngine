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
end
