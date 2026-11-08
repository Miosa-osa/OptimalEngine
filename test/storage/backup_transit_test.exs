defmodule OptimalEngine.Storage.BackupTransitTest do
  @moduledoc """
  With `OPTIMAL_OPENBAO_TRANSIT_KEY` set, a backup's data key is made and
  wrapped by OpenBao transit, so the key that protects every copy never leaves
  OpenBao. A copy sealed that way opens only through the same transit key, and
  a sealed or unreachable OpenBao fails the seal or the open with that reason.
  """
  use ExUnit.Case, async: false

  @moduletag capture_log: true

  import ExUnit.CaptureLog

  alias OptimalEngine.Backup
  alias OptimalEngine.Backup.{Envelope, Schedule}
  alias OptimalEngine.Secrets
  alias OptimalEngine.TestSupport.OpenBaoStub

  @moduletag :tmp_dir

  @env ~w(OPTIMAL_OPENBAO_ADDR OPTIMAL_OPENBAO_TOKEN OPTIMAL_OPENBAO_TRANSIT_KEY
          OPTIMAL_OPENBAO_TRANSIT_MOUNT OPTIMAL_BACKUP_KEY)

  setup %{tmp_dir: tmp} do
    previous = Map.new(@env, &{&1, System.get_env(&1)})
    Enum.each(@env, &System.delete_env/1)
    Secrets.flush_cache()

    on_exit(fn ->
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    {:ok, stub} = OpenBaoStub.start(transit_keys: ["optimal-backup"])
    on_exit(fn -> OpenBaoStub.stop(stub) end)
    System.put_env("OPTIMAL_OPENBAO_ADDR", stub.endpoint)
    System.put_env("OPTIMAL_OPENBAO_TOKEN", stub.token)
    System.put_env("OPTIMAL_OPENBAO_TRANSIT_KEY", "optimal-backup")

    source = Path.join(tmp, "plain.db")
    plaintext = :crypto.strong_rand_bytes(9_000) <> "SQLite format 3\0"
    File.write!(source, plaintext)
    %{stub: stub, tmp: tmp, source: source, plaintext: plaintext}
  end

  defp path(ctx, name), do: Path.join(ctx.tmp, "#{name}-#{System.unique_integer([:positive])}")

  test "a copy is sealed under the transit key and opens through it alone", ctx do
    assert {:ok, %{transit: %{mount: "transit", name: "optimal-backup"}} = key} =
             Envelope.sealing_key()

    sealed = path(ctx, "sealed")
    assert {:ok, info} = Envelope.seal_file(ctx.source, sealed, key, chunk_bytes: 4_096)
    assert info.key_id == "transit:transit/optimal-backup"

    assert {:ok, header} = Envelope.read_header(sealed)
    assert header["key_wrap"] == "openbao-transit"
    assert "vault:v1:" <> _ = header["wrapped_key"]
    refute File.read!(sealed) =~ "SQLite format 3"

    assert {"POST", "/v1/transit/datakey/plaintext/optimal-backup"} in OpenBaoStub.requests(
             ctx.stub
           )

    # Opened with the configured key the header names, and with no backup key set.
    opened = path(ctx, "opened")
    assert {:ok, result} = Envelope.open_file(sealed, opened)
    assert File.read!(opened) == ctx.plaintext
    assert result.key_id == "transit:transit/optimal-backup"
    assert {"POST", "/v1/transit/decrypt/optimal-backup"} in OpenBaoStub.requests(ctx.stub)
  end

  test "a sealed OpenBao fails the seal and the open, and leaves no file behind", ctx do
    {:ok, key} = Envelope.sealing_key()
    sealed = path(ctx, "sealed")
    {:ok, _info} = Envelope.seal_file(ctx.source, sealed, key)

    OpenBaoStub.seal(ctx.stub)

    second = path(ctx, "second")

    assert Envelope.seal_file(ctx.source, second, key) ==
             {:error, {:backup_key_unavailable, :openbao_sealed}}

    refute File.exists?(second)

    opened = path(ctx, "opened")

    assert Envelope.open_file(sealed, opened) ==
             {:error, {:backup_key_unavailable, :openbao_sealed}}

    refute File.exists?(opened)
    assert Backup.explain({:backup_key_unavailable, :openbao_sealed}) =~ "unseal"
  end

  test "a transit key that does not exist, or no OpenBao at all, is refused clearly", ctx do
    System.put_env("OPTIMAL_OPENBAO_TRANSIT_KEY", "no-such-key")
    {:ok, key} = Envelope.sealing_key()

    assert Envelope.seal_file(ctx.source, path(ctx, "sealed"), key) ==
             {:error, {:backup_key_unavailable, :openbao_transit_key_missing}}

    System.delete_env("OPTIMAL_OPENBAO_TOKEN")

    assert Envelope.sealing_key() ==
             {:error, {:backup_key_unavailable, :openbao_not_configured}}

    # The local backup key is not a silent stand-in for a named transit key.
    System.put_env("OPTIMAL_BACKUP_KEY", String.duplicate("ab", 32))
    assert {:error, {:backup_key_unavailable, :openbao_not_configured}} = Envelope.sealing_key()
  end

  test "a copy sealed with the local key still opens after the switch to transit", ctx do
    local = :crypto.strong_rand_bytes(32)
    System.put_env("OPTIMAL_BACKUP_KEY", Base.encode16(local))
    System.delete_env("OPTIMAL_OPENBAO_TRANSIT_KEY")

    {:ok, ^local} = Envelope.sealing_key()
    sealed = path(ctx, "local")
    {:ok, _info} = Envelope.seal_file(ctx.source, sealed, local)

    System.put_env("OPTIMAL_OPENBAO_TRANSIT_KEY", "optimal-backup")
    assert {:ok, %{transit: _}} = Envelope.sealing_key()
    assert {:ok, ^local} = Envelope.key_for(Envelope.key_id(local))

    opened = path(ctx, "opened")
    assert {:ok, _result} = Envelope.open_file(sealed, opened)
    assert File.read!(opened) == ctx.plaintext

    # Without the local key it names the key it needs.
    System.delete_env("OPTIMAL_BACKUP_KEY")
    assert {:error, :backup_key_missing} = Envelope.open_file(sealed, path(ctx, "again"))
  end

  test "a transit copy names its transit key when another key is configured", ctx do
    {:ok, key} = Envelope.sealing_key()
    sealed = path(ctx, "sealed")
    {:ok, _info} = Envelope.seal_file(ctx.source, sealed, key)

    System.put_env("OPTIMAL_OPENBAO_TRANSIT_KEY", "a-newer-key")

    assert {:error, {:backup_key_mismatch, "transit:transit/optimal-backup"} = reason} =
             Envelope.open_file(sealed, path(ctx, "opened"))

    assert Backup.explain(reason) =~ "OPTIMAL_OPENBAO_TRANSIT_KEY"
  end

  test "the schedule status says the key lives in OpenBao transit, never the key itself" do
    capture_log(fn ->
      status = Schedule.status()
      assert status.encryption.key_configured
      assert status.encryption.key_id == "transit:transit/optimal-backup"
      assert status.encryption.key_source == "openbao_transit"
    end)
  end
end
