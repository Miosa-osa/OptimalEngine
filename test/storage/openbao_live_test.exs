defmodule OptimalEngine.Storage.OpenBaoLiveTest do
  @moduledoc """
  The OpenBao data path against a real server: a secret reference resolved, a
  KV mount enabled on first write, connector credentials written, read and
  deleted, and a backup sealed and opened through transit.

  Skipped unless `OPTIMAL_TEST_OPENBAO_ADDR` and `OPTIMAL_TEST_OPENBAO_TOKEN`
  name a server and a token allowed to enable mounts (and, to also seal and
  unseal it, `OPTIMAL_TEST_OPENBAO_UNSEAL_KEY`), for example:

      docker run --rm -d --name oe-openbao-it -p 8210:8200 \\
        -e BAO_DEV_ROOT_TOKEN_ID=it-root openbao/openbao:2.3.1
      OPTIMAL_TEST_OPENBAO_ADDR=http://127.0.0.1:8210 \\
        OPTIMAL_TEST_OPENBAO_TOKEN=it-root mix test test/storage/openbao_live_test.exs

  Each run uses mounts of its own, so nothing it writes collides with another
  run; they are disabled again at the end.
  """
  use ExUnit.Case, async: false

  @moduletag capture_log: true
  @moduletag :tmp_dir
  @moduletag :openbao

  alias OptimalEngine.Backup.Envelope
  alias OptimalEngine.Connectors.{CredentialVault, HTTP}
  alias OptimalEngine.Secrets
  alias OptimalEngine.Storage.OpenBao

  @addr System.get_env("OPTIMAL_TEST_OPENBAO_ADDR")
  @token System.get_env("OPTIMAL_TEST_OPENBAO_TOKEN")
  @unseal_key System.get_env("OPTIMAL_TEST_OPENBAO_UNSEAL_KEY")

  if is_nil(@addr) or is_nil(@token) do
    @moduletag skip: "set OPTIMAL_TEST_OPENBAO_ADDR and OPTIMAL_TEST_OPENBAO_TOKEN to run"
  end

  @env ~w(OPTIMAL_OPENBAO_ADDR OPTIMAL_OPENBAO_TOKEN OPTIMAL_OPENBAO_KV_MOUNT
          OPTIMAL_OPENBAO_TRANSIT_KEY OPTIMAL_OPENBAO_TRANSIT_MOUNT OPTIMAL_BACKUP_KEY)

  setup do
    previous = Map.new(@env, &{&1, System.get_env(&1)})
    run = Integer.to_string(System.unique_integer([:positive]))
    kv = "optimal-it-kv-#{run}"
    transit = "optimal-it-transit-#{run}"

    System.put_env("OPTIMAL_OPENBAO_ADDR", @addr)
    System.put_env("OPTIMAL_OPENBAO_TOKEN", @token)
    System.put_env("OPTIMAL_OPENBAO_KV_MOUNT", kv)
    Secrets.flush_cache()

    on_exit(fn ->
      admin(:delete, "/v1/sys/mounts/#{kv}")
      admin(:delete, "/v1/sys/mounts/#{transit}")
      Secrets.flush_cache()

      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    %{kv: kv, transit: transit}
  end

  defp admin(method, path, body \\ nil) do
    opts = [
      method: method,
      headers: [{"X-Vault-Token", @token}, {"content-type", "application/json"}],
      single_attempt: true
    ]

    opts = if body, do: Keyword.put(opts, :body, body), else: opts
    {:ok, %{status: status}} = HTTP.request(@addr <> path, opts)
    status
  end

  test "a reference resolves from a mount the first write enabled", %{kv: kv} do
    assert OpenBao.health() == :healthy
    hex = Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)

    # The mount does not exist yet: the write enables it as KV version 2.
    assert :ok = OpenBao.kv_write("optimal/engine", %{"backup_key" => hex})
    assert {:ok, %{"backup_key" => ^hex}} = OpenBao.kv_read("optimal/engine")
    assert admin(:get, "/v1/sys/mounts/#{kv}") == 200

    System.put_env("OPTIMAL_BACKUP_KEY", "openbao:optimal/engine#backup_key")
    assert Envelope.backup_key() == {:ok, Base.decode16!(hex, case: :lower)}

    System.put_env("OPTIMAL_BACKUP_KEY", "openbao:optimal/engine#missing")

    assert {:error, {:backup_key_unavailable, :field_not_found}} = Envelope.backup_key()
    assert {:error, :not_found} = OpenBao.kv_read("optimal/nothing-here")
  end

  test "connector credentials are written, read back as written and deleted" do
    nested = %{"api_key" => "k-live", "oauth" => %{"refresh_token" => "r-live"}}

    assert {:ok, marked} = CredentialVault.put(%{"x" => 1}, "default", "live:conn-1", nested)
    assert marked == %{"x" => 1, "credentials_store" => "openbao"}
    assert {:ok, config} = CredentialVault.get(marked, "default", "live:conn-1")
    assert config == Map.merge(%{"x" => 1}, nested)

    assert :ok = CredentialVault.delete("default", "live:conn-1")

    assert {:error, :credentials_not_found} =
             CredentialVault.get(marked, "default", "live:conn-1")
  end

  test "a backup sealed under a transit key opens through it", %{transit: transit, tmp_dir: tmp} do
    assert admin(:post, "/v1/sys/mounts/#{transit}", %{type: "transit"}) in [200, 204]
    assert admin(:post, "/v1/#{transit}/keys/optimal-backup", %{}) in [200, 204]
    System.put_env("OPTIMAL_OPENBAO_TRANSIT_MOUNT", transit)
    System.put_env("OPTIMAL_OPENBAO_TRANSIT_KEY", "optimal-backup")

    source = Path.join(tmp, "plain.db")
    plaintext = :crypto.strong_rand_bytes(70_000)
    File.write!(source, plaintext)

    {:ok, key} = Envelope.sealing_key()
    sealed = Path.join(tmp, "sealed.enc")
    assert {:ok, info} = Envelope.seal_file(source, sealed, key, chunk_bytes: 16_384)
    assert info.key_id == "transit:#{transit}/optimal-backup"

    opened = Path.join(tmp, "opened.db")
    assert {:ok, _result} = Envelope.open_file(sealed, opened)
    assert File.read!(opened) == plaintext

    System.put_env("OPTIMAL_OPENBAO_TRANSIT_KEY", "no-such-key")
    {:ok, missing} = Envelope.sealing_key()

    assert {:error, {:backup_key_unavailable, :openbao_transit_key_missing}} =
             Envelope.seal_file(source, Path.join(tmp, "never.enc"), missing)
  end

  test "an unreachable server is a clear failure, not a default" do
    System.put_env("OPTIMAL_OPENBAO_ADDR", "http://127.0.0.1:9")
    System.put_env("OPTIMAL_BACKUP_KEY", "openbao:optimal/engine#backup_key")
    assert {:error, {:backup_key_unavailable, :openbao_unreachable}} = Envelope.backup_key()
  end

  if is_nil(@unseal_key) do
    @tag skip: "set OPTIMAL_TEST_OPENBAO_UNSEAL_KEY to seal and unseal the server"
  end

  test "a sealed server fails every read and write with :openbao_sealed", %{tmp_dir: tmp} do
    hex = Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
    :ok = OpenBao.kv_write("optimal/engine", %{"backup_key" => hex})
    System.put_env("OPTIMAL_BACKUP_KEY", "openbao:optimal/engine#backup_key")
    System.put_env("OPTIMAL_OPENBAO_TRANSIT_KEY", "optimal-backup")
    source = Path.join(tmp, "plain.db")
    File.write!(source, "data")

    assert admin(:post, "/v1/sys/seal") == 204

    try do
      Secrets.flush_cache()
      assert {:error, {:backup_key_unavailable, :openbao_sealed}} = Envelope.backup_key()
      assert {:error, :openbao_sealed} = CredentialVault.get(%{}, "default", "sealed-conn")
      assert {:error, :openbao_sealed} = OpenBao.kv_write("optimal/x", %{"a" => "b"})
      {:ok, transit} = Envelope.sealing_key()

      assert {:error, {:backup_key_unavailable, :openbao_sealed}} =
               Envelope.seal_file(source, Path.join(tmp, "never.enc"), transit)
    after
      admin(:post, "/v1/sys/unseal", %{key: @unseal_key})
    end
  end
end
