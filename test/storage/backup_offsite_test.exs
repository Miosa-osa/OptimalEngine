defmodule OptimalEngine.Storage.BackupOffsiteTest do
  @moduledoc """
  The offsite drill: take a backup, ship it to the object store, delete the
  local copy, and restore from the object into a fresh data directory. The
  restored database must pass integrity_check and hold the same rows.

  Offsite copies are sealed with `OPTIMAL_BACKUP_KEY` before they leave the
  machine, so the object store only ever holds ciphertext.
  """

  use ExUnit.Case, async: false

  alias OptimalEngine.{Backup, Store}
  alias OptimalEngine.Backup.Envelope
  alias OptimalEngine.Storage.S3
  alias OptimalEngine.TestSupport.S3Stub

  @s3_env ~w(OPTIMAL_S3_ENDPOINT OPTIMAL_S3_BUCKET OPTIMAL_S3_REGION OPTIMAL_S3_ACCESS_KEY_ID
             OPTIMAL_S3_SECRET_ACCESS_KEY OPTIMAL_S3_PREFIX OPTIMAL_S3_MAX_RETRIES
             OPTIMAL_BACKUP_KEY)

  setup do
    previous_env = Map.new(@s3_env, &{&1, System.get_env(&1)})
    previous_dir = Application.get_env(:optimal_engine, :backup_dir)

    tmp = Path.join(System.tmp_dir!(), "backup-offsite-#{System.unique_integer([:positive])}")
    backing = Path.join(tmp, "backups")
    File.mkdir_p!(backing)
    Application.put_env(:optimal_engine, :backup_dir, backing)

    ref = S3Stub.ref()
    on_exit(fn -> S3Stub.stop(ref) end)
    {:ok, stub} = S3Stub.start(ref: ref, bucket: "engine-test")

    System.put_env("OPTIMAL_S3_ENDPOINT", stub.endpoint)
    System.put_env("OPTIMAL_S3_BUCKET", stub.bucket)
    System.put_env("OPTIMAL_S3_ACCESS_KEY_ID", stub.access_key_id)
    System.put_env("OPTIMAL_S3_SECRET_ACCESS_KEY", stub.secret_access_key)
    System.put_env("OPTIMAL_S3_REGION", stub.region)
    System.put_env("OPTIMAL_BACKUP_KEY", Base.encode16(:crypto.strong_rand_bytes(32)))

    on_exit(fn ->
      Enum.each(previous_env, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)

      case previous_dir do
        nil -> Application.delete_env(:optimal_engine, :backup_dir)
        value -> Application.put_env(:optimal_engine, :backup_dir, value)
      end

      File.rm_rf(tmp)
    end)

    %{stub: stub, tmp: tmp, backing: backing}
  end

  defp take_backup(_backing, name, opts \\ []) do
    assert {:ok, target} = Backup.resolve_target(name)
    assert {:ok, info} = Backup.create(target, opts)
    info
  end

  test "a backup is shipped offsite sealed, and its catalog row records the copy", %{
    stub: stub,
    backing: backing
  } do
    info = take_backup(backing, "offsite-drill.db", offsite: true)

    assert info.integrity_status == "verified"
    assert info.offsite.status == "shipped"
    assert info.offsite.uri =~ "s3://#{stub.bucket}/"
    assert info.offsite.checksum_sha256 == info.checksum_sha256
    assert info.offsite.encrypted == true
    assert info.offsite.cipher == "AES-256-GCM"

    # The object store holds ciphertext only: not the local bytes, not a SQLite
    # file, and nothing of the database's header.
    object = S3Stub.object_body(stub.agent, info.offsite.key)
    local = File.read!(info.target)
    refute object == local
    refute String.starts_with?(object, "SQLite format 3")
    assert :binary.match(object, binary_part(local, 0, 100)) == :nomatch
    assert info.offsite.ciphertext_sha256 == sha256(object)
    assert info.offsite.ciphertext_bytes == byte_size(object)

    {:ok, key} = Envelope.backup_key()
    assert info.offsite.key_id == Envelope.key_id(key)

    assert {:ok, listed_all} = Backup.list_offsite()
    listed = Enum.find(listed_all, &(&1.id == info.id))
    refute is_nil(listed)
    assert listed.offsite_uri == info.offsite.uri
    assert listed.offsite_key == info.offsite.key
    assert listed.checksum_sha256 == info.checksum_sha256
    assert listed.local_path == Path.expand(info.target)
    assert listed.encrypted == true
    assert listed.ciphertext_sha256 == sha256(object)
    assert listed.key_id == info.offsite.key_id

    assert {:ok, [[1, 1, metadata]]} =
             Store.raw_query(
               "SELECT offsite, encrypted, metadata FROM backup_records WHERE id = ?1",
               [info.id]
             )

    metadata = Jason.decode!(metadata)
    assert metadata["offsite_ciphertext_sha256"] == sha256(object)
    assert metadata["offsite_cipher"] == "AES-256-GCM"

    # The sealed temporary file never outlives the upload.
    assert Path.wildcard(Path.join(backing, "*.enc*")) == []
  end

  test "without OPTIMAL_BACKUP_KEY nothing is uploaded, and the refusal says why", %{
    stub: stub,
    backing: backing
  } do
    System.delete_env("OPTIMAL_BACKUP_KEY")
    info = take_backup(backing, "no-key.db", offsite: true)

    assert info.offsite.status == "failed"
    assert info.offsite.reason == ":backup_key_missing"
    assert info.offsite.message =~ "OPTIMAL_BACKUP_KEY"
    assert File.regular?(info.target)
    assert S3Stub.object_keys(stub.agent) == []

    assert {:ok, [[0, 0]]} =
             Store.raw_query("SELECT offsite, encrypted FROM backup_records WHERE id = ?1", [
               info.id
             ])

    System.put_env("OPTIMAL_BACKUP_KEY", "too-short")
    assert {:error, :backup_key_invalid} = Backup.ship_offsite(info.id)
    assert S3Stub.object_keys(stub.agent) == []
  end

  test "an offsite restore into a fresh data directory reproduces the backup", %{
    stub: stub,
    backing: backing,
    tmp: tmp
  } do
    info = take_backup(backing, "restore-drill.db", offsite: true)

    before = row_counts(info.target)
    assert before["workspaces"] > 0

    # The drill removes the local copy: the object is the only source left.
    File.rm!(info.target)
    refute File.exists?(info.target)

    data_dir = Path.join(tmp, "restored-engine")

    assert {:ok, restored} = Backup.restore_offsite(info.id, data_dir: data_dir)
    assert restored.target == Path.join(data_dir, "index.db")
    assert restored.source_uri == info.offsite.uri
    assert restored.checksum_sha256 == info.checksum_sha256
    assert restored.encrypted
    assert restored.source_bytes == info.offsite.ciphertext_bytes
    assert restored.archived == nil
    assert restored.download_path == nil

    assert {:ok, :ok} = Backup.verify(restored.target)
    assert row_counts(restored.target) == before

    # The temporary download is gone and the object is untouched, so the drill
    # can be run again with the same backup.
    assert Path.wildcard(Path.join(System.tmp_dir!(), "optimal-offsite-restore/*")) == []
    assert S3Stub.object_body(stub.agent, info.offsite.key) != nil

    assert {:ok, again} = Backup.restore_offsite(info.id, data_dir: data_dir)
    assert row_counts(again.target) == before
  end

  test "a restore refuses a target it was not given", %{backing: backing} do
    info = take_backup(backing, "no-target.db", offsite: true)
    assert {:error, :restore_target_required} = Backup.restore_offsite(info.id, [])
  end

  test "a backup that was never shipped cannot be restored offsite", %{backing: backing} do
    info = take_backup(backing, "local-only.db")

    assert {:error, {:backup_not_offsite, _}} =
             Backup.restore_offsite(info.id, data_dir: System.tmp_dir!())

    assert {:error, {:backup_not_cataloged, "backup_missing"}} =
             Backup.restore_offsite("backup_missing", data_dir: System.tmp_dir!())
  end

  test "an offsite copy that does not match the catalog checksum is refused", %{
    backing: backing,
    tmp: tmp
  } do
    info = take_backup(backing, "tampered-offsite.db", offsite: true)

    # Replace the object with different bytes, as a corrupted or substituted
    # upload would.
    :ok = OptimalEngine.Storage.S3.delete_object(info.offsite.key)
    assert {:ok, _} = OptimalEngine.Storage.S3.put_object(info.offsite.key, "not the backup")

    assert {:error, {:offsite_download_mismatch, _, _}} =
             Backup.restore_offsite(info.id, data_dir: Path.join(tmp, "never"))

    refute File.exists?(Path.join([tmp, "never", "index.db"]))
  end

  test "a restore with the wrong key or no key fails cleanly and writes nothing", %{
    backing: backing,
    tmp: tmp
  } do
    info = take_backup(backing, "wrong-key.db", offsite: true)
    target_dir = Path.join(tmp, "wrong-key-restore")

    System.put_env("OPTIMAL_BACKUP_KEY", Base.encode16(:crypto.strong_rand_bytes(32)))

    assert {:error, {:backup_key_mismatch, key_id}} =
             Backup.restore_offsite(info.id, data_dir: target_dir)

    assert key_id == info.offsite.key_id
    refute File.exists?(Path.join(target_dir, "index.db"))

    System.delete_env("OPTIMAL_BACKUP_KEY")

    assert {:error, :backup_key_missing} =
             Backup.restore_offsite(info.id, data_dir: target_dir)

    refute File.exists?(Path.join(target_dir, "index.db"))
    assert Path.wildcard(Path.join(System.tmp_dir!(), "optimal-offsite-restore/*")) == []
  end

  test "a sealed object restores without its catalog row, as after losing the machine", %{
    stub: stub,
    backing: backing,
    tmp: tmp
  } do
    info = take_backup(backing, "disaster.db", offsite: true)
    before = row_counts(info.target)
    File.rm!(info.target)

    assert {:ok, listing} = Backup.list_offsite_objects()
    assert info.offsite.key in listing.keys

    # A changed byte anywhere in the object fails authentication.
    object = S3Stub.object_body(stub.agent, info.offsite.key)
    position = byte_size(object) - 40
    <<head::binary-size(position), byte, rest::binary>> = object
    tampered_key = info.offsite.key <> ".tampered"
    assert {:ok, _} = S3.put_object(tampered_key, head <> <<Bitwise.bxor(byte, 1)>> <> rest)

    assert {:error, {:backup_decrypt_failed, {:chunk, _}}} =
             Backup.restore_offsite_object(tampered_key, data_dir: Path.join(tmp, "tampered"))

    refute File.exists?(Path.join([tmp, "tampered", "index.db"]))

    data_dir = Path.join(tmp, "recovered")

    assert {:ok, restored} = Backup.restore_offsite_object(info.offsite.key, data_dir: data_dir)
    assert restored.backup_id == info.id
    assert restored.checksum_sha256 == info.checksum_sha256
    assert {:ok, :ok} = Backup.verify(restored.target)
    assert row_counts(restored.target) == before
    assert Path.wildcard(Path.join(System.tmp_dir!(), "optimal-offsite-restore/*")) == []
  end

  test "a plaintext copy shipped before encryption existed still restores", %{
    stub: stub,
    backing: backing,
    tmp: tmp
  } do
    info = take_backup(backing, "legacy-plain.db")
    before = row_counts(info.target)
    key = S3.object_key(["backups", "default", Path.basename(info.target)])
    assert {:ok, _} = S3.put_file(key, info.target)

    metadata = Jason.encode!(%{"offsite_key" => key, "offsite_uri" => S3.uri(key)})

    :ok =
      Store.raw_execute(
        "UPDATE backup_records SET offsite = 1, encrypted = 0, metadata = ?1 WHERE id = ?2",
        [metadata, info.id]
      )

    File.rm!(info.target)
    System.delete_env("OPTIMAL_BACKUP_KEY")

    assert {:ok, restored} =
             Backup.restore_offsite(info.id, data_dir: Path.join(tmp, "legacy-restore"))

    assert row_counts(restored.target) == before
    assert S3Stub.object_body(stub.agent, key) != nil
  end

  test "a backup that is not in the catalog is never shipped" do
    assert {:error, {:backup_not_cataloged, _}} =
             Backup.ship_offsite("backup_not_a_real_id")
  end

  test "a failed ship is reported without discarding the local backup", %{
    stub: stub,
    backing: backing
  } do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)

    System.put_env("OPTIMAL_S3_ENDPOINT", "http://127.0.0.1:#{port}")
    System.put_env("OPTIMAL_S3_MAX_RETRIES", "0")

    info = take_backup(backing, "failed-ship.db", offsite: true)

    assert info.offsite.status == "failed"
    assert File.regular?(info.target)
    assert {:ok, :ok} = Backup.verify(info.target)

    assert {:ok, [[0]]} =
             Store.raw_query("SELECT offsite FROM backup_records WHERE id = ?1", [info.id])

    assert S3Stub.object_keys(stub.agent) == []
  end

  test "the storage audit counts an offsite-only backup as present, and reports a lost object", %{
    stub: stub,
    backing: backing
  } do
    info = take_backup(backing, "audit-offsite.db", offsite: true)

    assert %{copies: ["local"]} = audit_check("verified_backup")

    # The local copy goes away; the offsite object is now the only one, and the
    # audit confirms it rather than calling the backup missing.
    File.rm!(info.target)
    assert %{copies: ["offsite"], offsite_uri: uri} = audit_check("verified_backup")
    assert uri == info.offsite.uri

    # If the object is gone too, that is a real failure.
    :ok = OptimalEngine.Storage.S3.delete_object(info.offsite.key)
    assert audit_check("verified_backup") == ":verified_backup_unreachable"

    assert S3Stub.object_keys(stub.agent) == []
  end

  defp audit_check(name) do
    OptimalEngine.StorageAudit.run().checks
    |> Enum.find(&(&1.name == name))
    |> Map.get(:detail)
  end

  defp sha256(data), do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)

  defp row_counts(db_path) do
    for table <- ~w(workspaces contexts memories backup_records), into: %{} do
      {table, scalar(db_path, "SELECT COUNT(*) FROM #{table}")}
    end
  end

  defp scalar(db_path, sql) do
    {:ok, db} = Exqlite.Sqlite3.open(db_path, mode: :readonly)

    try do
      {:ok, stmt} = Exqlite.Sqlite3.prepare(db, sql)
      {:ok, rows} = Exqlite.Sqlite3.fetch_all(db, stmt)
      Exqlite.Sqlite3.release(db, stmt)
      rows |> List.first() |> List.first()
    after
      Exqlite.Sqlite3.close(db)
    end
  end
end
