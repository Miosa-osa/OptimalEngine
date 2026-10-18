defmodule OptimalEngine.BackupTest do
  use ExUnit.Case, async: false

  alias OptimalEngine.Backup

  @moduletag :tmp_dir

  test "create/1 produces a readable SQLite file and counts rows", %{tmp_dir: tmp} do
    target = Path.join(tmp, "snap.db")

    assert {:ok, info} = Backup.create(target)
    assert info.target == target
    assert info.size_bytes > 0
    assert info.rows_backed_up >= 0
    assert info.duration_ms >= 0
    assert String.starts_with?(info.id, "backup_")
    assert String.length(info.checksum_sha256) == 64
    assert info.integrity_status == "verified"

    assert File.exists?(target)

    assert {:ok, [["completed", "verified", checksum]]} =
             OptimalEngine.Store.raw_query(
               "SELECT status, integrity_status, checksum_sha256 FROM backup_records WHERE id = ?1",
               [info.id]
             )

    assert checksum == info.checksum_sha256
  end

  test "create/1 refuses to overwrite an existing target", %{tmp_dir: tmp} do
    target = Path.join(tmp, "existing.db")
    File.write!(target, "")
    assert {:error, {:target_exists, ^target}} = Backup.create(target)
  end

  test "create/1 rejects a non-existent parent directory", %{tmp_dir: tmp} do
    target = Path.join([tmp, "nope", "snap.db"])
    assert {:error, {:parent_missing, _}} = Backup.create(target)
  end

  test "verify/1 returns :ok on a clean backup", %{tmp_dir: tmp} do
    target = Path.join(tmp, "verify.db")
    {:ok, _} = Backup.create(target)
    assert {:ok, :ok} = Backup.verify(target)
  end

  test "restore/1 refuses while the supervisor is up", %{tmp_dir: tmp} do
    target = Path.join(tmp, "snap.db")
    {:ok, _} = Backup.create(target)
    assert {:error, :supervisor_still_running} = Backup.restore(target)
  end

  describe "restore/2 into a target path" do
    test "restores a cataloged backup and proves the bytes match", %{tmp_dir: tmp} do
      source = Path.join(tmp, "source.db")
      target = Path.join(tmp, "restored.db")
      {:ok, info} = Backup.create(source)

      assert {:ok, result} = Backup.restore(source, target: target)
      assert result.target == target
      assert result.checksum_sha256 == info.checksum_sha256
      assert result.archived == nil
      assert {:ok, :ok} = Backup.verify(target)
      assert sha256(target) == info.checksum_sha256
    end

    test "rejects a backup whose bytes no longer match the catalog", %{tmp_dir: tmp} do
      source = Path.join(tmp, "tampered.db")
      target = Path.join(tmp, "never.db")
      {:ok, info} = Backup.create(source)
      File.write!(source, "tamper", [:append])

      assert {:error, {:checksum_mismatch, expected, actual}} =
               Backup.restore(source, target: target)

      assert expected == info.checksum_sha256
      refute actual == expected
      refute File.exists?(target)
    end

    test "refuses an uncataloged file unless a checksum is supplied", %{tmp_dir: tmp} do
      source = Path.join(tmp, "cataloged.db")
      copy = Path.join(tmp, "copied.db")
      target = Path.join(tmp, "from-copy.db")
      {:ok, info} = Backup.create(source)
      File.cp!(source, copy)

      assert {:error, :backup_not_cataloged} = Backup.restore(copy, target: target)
      refute File.exists?(target)

      assert {:error, {:checksum_mismatch, _, _}} =
               Backup.restore(copy, target: target, checksum_sha256: String.duplicate("0", 64))

      assert {:ok, _} = Backup.restore(copy, target: target, checksum_sha256: info.checksum_sha256)
      assert sha256(target) == info.checksum_sha256
    end

    test "archives the current target with its sidecars and clears stale -wal/-shm",
         %{tmp_dir: tmp} do
      source = Path.join(tmp, "fresh.db")
      target = Path.join(tmp, "live.db")
      {:ok, info} = Backup.create(source)

      File.write!(target, "old main")
      File.write!(target <> "-wal", "stale wal")
      File.write!(target <> "-shm", "stale shm")

      assert {:ok, %{archived: archived}} = Backup.restore(source, target: target)
      assert File.read!(archived) == "old main"
      assert File.read!(archived <> "-wal") == "stale wal"
      assert File.read!(archived <> "-shm") == "stale shm"

      refute File.exists?(target <> "-wal")
      refute File.exists?(target <> "-shm")
      assert sha256(target) == info.checksum_sha256
      assert {:ok, :ok} = Backup.verify(target)
    end

    test "refuses a source with an uncheckpointed -wal sidecar", %{tmp_dir: tmp} do
      source = Path.join(tmp, "walled.db")
      target = Path.join(tmp, "walled-target.db")
      {:ok, _info} = Backup.create(source)
      File.write!(source <> "-wal", "pending frames")

      assert {:error, {:source_has_wal, _}} = Backup.restore(source, target: target)
      refute File.exists?(target)
    end

    test "refuses to replace the live database while the engine runs", %{tmp_dir: tmp} do
      source = Path.join(tmp, "live-attempt.db")
      {:ok, _} = Backup.create(source)
      live = Application.fetch_env!(:optimal_engine, :db_path)

      assert {:error, :supervisor_still_running} = Backup.restore(source, target: live)
    end
  end

  defp sha256(path) do
    :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)
  end
end
