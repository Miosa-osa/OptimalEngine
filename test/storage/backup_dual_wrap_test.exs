defmodule OptimalEngine.Storage.BackupDualWrapTest do
  @moduledoc """
  With an OpenBao transit key named, every data key is wrapped twice: by
  transit and by `OPTIMAL_BACKUP_KEY`. The in-guest OpenBao goes with the
  machine, so an offsite copy must open with `OPTIMAL_BACKUP_KEY` alone. Without
  that key a transit-only seal is refused unless the operator opts into it with
  `OPTIMAL_BACKUP_TRANSIT_ONLY=true`.
  """

  use ExUnit.Case, async: false

  @moduletag capture_log: true

  alias OptimalEngine.Backup
  alias OptimalEngine.Backup.{Envelope, Schedule}
  alias OptimalEngine.Secrets
  alias OptimalEngine.Storage.OpenBao
  alias OptimalEngine.TestSupport.{OpenBaoStub, S3Stub}

  @env ~w(OPTIMAL_S3_ENDPOINT OPTIMAL_S3_BUCKET OPTIMAL_S3_REGION OPTIMAL_S3_ACCESS_KEY_ID
          OPTIMAL_S3_SECRET_ACCESS_KEY OPTIMAL_S3_PREFIX OPTIMAL_S3_MAX_RETRIES
          OPTIMAL_BACKUP_KEY OPTIMAL_BACKUP_TRANSIT_ONLY OPTIMAL_OPENBAO_ADDR
          OPTIMAL_OPENBAO_TOKEN OPTIMAL_OPENBAO_TRANSIT_KEY OPTIMAL_OPENBAO_TRANSIT_MOUNT)

  setup do
    previous_env = Map.new(@env, &{&1, System.get_env(&1)})
    previous_dir = Application.get_env(:optimal_engine, :backup_dir)
    Enum.each(@env, &System.delete_env/1)
    Secrets.flush_cache()

    tmp = Path.join(System.tmp_dir!(), "backup-dual-#{System.unique_integer([:positive])}")
    backing = Path.join(tmp, "backups")
    File.mkdir_p!(backing)
    Application.put_env(:optimal_engine, :backup_dir, backing)

    ref = S3Stub.ref()
    {:ok, s3} = S3Stub.start(ref: ref, bucket: "engine-dual")
    {:ok, bao} = OpenBaoStub.start(transit_keys: ["optimal-backup"])

    on_exit(fn ->
      S3Stub.stop(ref)
      OpenBaoStub.stop(bao)

      Enum.each(previous_env, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)

      case previous_dir do
        nil -> Application.delete_env(:optimal_engine, :backup_dir)
        value -> Application.put_env(:optimal_engine, :backup_dir, value)
      end

      Secrets.flush_cache()
      File.rm_rf(tmp)
    end)

    System.put_env("OPTIMAL_S3_ENDPOINT", s3.endpoint)
    System.put_env("OPTIMAL_S3_BUCKET", s3.bucket)
    System.put_env("OPTIMAL_S3_ACCESS_KEY_ID", s3.access_key_id)
    System.put_env("OPTIMAL_S3_SECRET_ACCESS_KEY", s3.secret_access_key)
    System.put_env("OPTIMAL_S3_REGION", s3.region)
    System.put_env("OPTIMAL_OPENBAO_ADDR", bao.endpoint)
    System.put_env("OPTIMAL_OPENBAO_TOKEN", bao.token)
    System.put_env("OPTIMAL_OPENBAO_TRANSIT_KEY", "optimal-backup")

    local = :crypto.strong_rand_bytes(32)
    System.put_env("OPTIMAL_BACKUP_KEY", Base.encode16(local))

    %{tmp: tmp, bao: bao, local: local}
  end

  defp row_count(path) do
    {:ok, conn} = Exqlite.Sqlite3.open(path)
    {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, "SELECT count(*) FROM sqlite_master")
    {:row, [count]} = Exqlite.Sqlite3.step(conn, stmt)
    :ok = Exqlite.Sqlite3.release(conn, stmt)
    :ok = Exqlite.Sqlite3.close(conn)
    count
  end

  test "a copy is wrapped by transit and by OPTIMAL_BACKUP_KEY", %{local: local} do
    assert {:ok, %{transit: %{name: "optimal-backup"}, local: ^local} = key} =
             Envelope.sealing_key()

    # The copy is named by the key that recovers it without OpenBao.
    assert Envelope.key_id(key) == Envelope.key_id(local)
  end

  test "an offsite copy restores with OPTIMAL_BACKUP_KEY alone once OpenBao is gone", ctx do
    assert {:ok, target} = Backup.resolve_target("dual-wrap.db")
    assert {:ok, info} = Backup.create(target, offsite: true)
    assert info.offsite.status == "shipped"

    object = info.offsite.key
    download = Path.join(ctx.tmp, "header.enc")
    {:ok, _} = OptimalEngine.Storage.S3.get_object_to_file(object, download)
    assert {:ok, header} = Envelope.read_header(download)
    assert header["key_id"] == Envelope.key_id(ctx.local)
    assert header["transit_key_id"] == "transit:transit/optimal-backup"
    assert "vault:v1:" <> _ = header["transit_wrapped_key"]

    # The machine is lost: its OpenBao is gone and the new machine has none.
    OpenBaoStub.stop(ctx.bao)
    Enum.each(~w(OPTIMAL_OPENBAO_ADDR OPTIMAL_OPENBAO_TOKEN), &System.delete_env/1)
    Secrets.flush_cache()

    data_dir = Path.join(ctx.tmp, "recovered")
    assert {:ok, restored} = Backup.restore_offsite_object(object, data_dir: data_dir)
    assert restored.checksum_sha256 == info.checksum_sha256
    assert {:ok, :ok} = Backup.verify(restored.target)
    assert row_count(restored.target) > 0

    # The catalog path too, still naming the transit key it can no longer reach.
    System.put_env("OPTIMAL_OPENBAO_ADDR", "http://127.0.0.1:1")
    System.put_env("OPTIMAL_OPENBAO_TOKEN", "gone")

    assert {:ok, again} =
             Backup.restore_offsite(info.id, data_dir: Path.join(ctx.tmp, "catalog"))

    assert again.checksum_sha256 == info.checksum_sha256
  end

  test "the transit wrap alone still opens a copy when OPTIMAL_BACKUP_KEY is not set", ctx do
    {:ok, key} = Envelope.sealing_key()
    source = Path.join(ctx.tmp, "plain.db")
    File.write!(source, :crypto.strong_rand_bytes(5_000))
    sealed = Path.join(ctx.tmp, "sealed.enc")
    {:ok, _} = Envelope.seal_file(source, sealed, key)

    System.delete_env("OPTIMAL_BACKUP_KEY")
    opened = Path.join(ctx.tmp, "opened.db")
    assert {:ok, _} = Envelope.open_file(sealed, opened)
    assert File.read!(opened) == File.read!(source)
  end

  test "without OPTIMAL_BACKUP_KEY a transit-only seal is refused unless opted into" do
    System.delete_env("OPTIMAL_BACKUP_KEY")

    assert {:error, :backup_recovery_key_missing = reason} = Envelope.sealing_key()
    assert Backup.explain(reason) =~ "OPTIMAL_BACKUP_TRANSIT_ONLY"
    assert Schedule.status().encryption.key_configured == false

    System.put_env("OPTIMAL_BACKUP_TRANSIT_ONLY", "true")
    assert {:ok, %{transit: _} = key} = Envelope.sealing_key()
    refute Map.has_key?(key, :local)
    assert Schedule.status().encryption.recoverable_without_openbao == false
  end

  test "a backup key that lives only in OpenBao is warned about, once, with no transit key too",
       ctx do
    System.delete_env("OPTIMAL_OPENBAO_TRANSIT_KEY")
    hex = Base.encode16(:crypto.strong_rand_bytes(32))

    OptimalEngine.TestSupport.OpenBaoStub.put_secret(ctx.bao, "optimal/engine", %{
      "backup_key" => hex
    })

    System.put_env("OPTIMAL_BACKUP_KEY", "openbao:optimal/engine#backup_key")
    Envelope.reset_warnings()

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, key} = Envelope.sealing_key()
        assert byte_size(key) == 32
        assert {:ok, _} = Envelope.sealing_key()
      end)

    assert length(String.split(log, "lost with that OpenBao")) == 2
    assert log =~ "OPTIMAL_BACKUP_KEY"
    refute log =~ hex
  end

  test "the schedule says a dual-wrapped copy recovers without OpenBao" do
    status = Schedule.status()
    assert status.encryption.key_configured
    assert status.encryption.recoverable_without_openbao == true
    assert status.encryption.key_source == "openbao_transit+env"
    assert OpenBao.transit_key() != nil
  end
end
