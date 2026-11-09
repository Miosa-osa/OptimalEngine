defmodule OptimalEngine.Secrets.OpenBaoSecretsTest do
  @moduledoc """
  The Engine's own secrets are read from the environment or, when a variable
  is an `openbao:<path>#<field>` reference, from OpenBao. A reference never
  falls back: OpenBao absent, sealed, unreachable or refusing fails the caller
  with a reason that names the variable and never the secret.
  """
  use ExUnit.Case, async: false

  @moduletag capture_log: true

  import ExUnit.CaptureLog

  alias OptimalEngine.Authority.Keys
  alias OptimalEngine.Backup
  alias OptimalEngine.Backup.Envelope
  alias OptimalEngine.Connectors.Credential
  alias OptimalEngine.Secrets
  alias OptimalEngine.Storage.{OpenBao, S3}
  alias OptimalEngine.TestSupport.OpenBaoStub

  @env ~w(OPTIMAL_OPENBAO_ADDR OPTIMAL_OPENBAO_TOKEN OPTIMAL_OPENBAO_KV_MOUNT
          OPTIMAL_BACKUP_KEY OPTIMAL_AUTHORITY_KEY CONNECTOR_KEY
          OPTIMAL_S3_ENDPOINT OPTIMAL_S3_BUCKET OPTIMAL_S3_ACCESS_KEY_ID
          OPTIMAL_S3_SECRET_ACCESS_KEY OPTIMAL_S3_CREDENTIALS_FILE
          OPTIMAL_CONNECTOR_CREDENTIAL_STORE OPTIMAL_OPENBAO_TRANSIT_KEY)

  setup do
    previous = Map.new(@env, &{&1, System.get_env(&1)})
    Enum.each(@env, &System.delete_env/1)
    Secrets.flush_cache()

    on_exit(fn ->
      Secrets.flush_cache()

      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    {:ok, stub} = OpenBaoStub.start()
    on_exit(fn -> OpenBaoStub.stop(stub) end)
    %{stub: stub, hex: Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)}
  end

  defp point_at(stub, token \\ nil) do
    System.put_env("OPTIMAL_OPENBAO_ADDR", stub.endpoint)
    System.put_env("OPTIMAL_OPENBAO_TOKEN", token || stub.token)
  end

  defp kv_reads(stub, path) do
    Enum.count(OpenBaoStub.requests(stub), &(&1 == {"GET", "/v1/secret/data/" <> path}))
  end

  describe "fetch/1" do
    test "a plain value is the secret, unset or blank is not set, and nothing asks OpenBao", %{
      stub: stub
    } do
      point_at(stub)
      System.put_env("OPTIMAL_BACKUP_KEY", "  plain-value  ")
      assert Secrets.fetch("OPTIMAL_BACKUP_KEY") == {:ok, "plain-value"}
      assert Secrets.source("OPTIMAL_BACKUP_KEY") == "env"

      System.put_env("OPTIMAL_BACKUP_KEY", "   ")
      assert Secrets.fetch("OPTIMAL_BACKUP_KEY") == {:error, :not_set}
      System.delete_env("OPTIMAL_BACKUP_KEY")
      assert Secrets.fetch("OPTIMAL_BACKUP_KEY") == {:error, :not_set}
      assert Secrets.source("OPTIMAL_BACKUP_KEY") == "unset"

      assert OpenBaoStub.requests(stub) == []
    end

    test "a reference reads the field of a KV version 2 secret, once a minute per path", %{
      stub: stub,
      hex: hex
    } do
      point_at(stub)
      OpenBaoStub.put_secret(stub, "optimal/engine", %{"backup_key" => hex, "other" => "x"})
      System.put_env("OPTIMAL_BACKUP_KEY", "openbao:optimal/engine#backup_key")
      System.put_env("CONNECTOR_KEY", "openbao:optimal/engine#other")

      assert Secrets.source("OPTIMAL_BACKUP_KEY") == "openbao"
      assert Secrets.fetch("OPTIMAL_BACKUP_KEY") == {:ok, hex}
      assert Secrets.fetch("CONNECTOR_KEY") == {:ok, "x"}
      assert Secrets.fetch("OPTIMAL_BACKUP_KEY") == {:ok, hex}
      assert kv_reads(stub, "optimal/engine") == 1

      # A rotated secret is read again once the kept copy is dropped.
      rotated = String.duplicate("a", 64)
      OpenBaoStub.put_secret(stub, "optimal/engine", %{"backup_key" => rotated})
      Secrets.flush_cache()
      assert Secrets.fetch("OPTIMAL_BACKUP_KEY") == {:ok, rotated}
      assert kv_reads(stub, "optimal/engine") == 2
    end

    test "a reference fails clearly, naming the variable and never the secret or token", %{
      stub: stub,
      hex: hex
    } do
      System.put_env("OPTIMAL_BACKUP_KEY", "openbao:optimal/engine#backup_key")

      # OpenBao is not configured at all: no fall back to anything.
      assert Secrets.fetch("OPTIMAL_BACKUP_KEY") ==
               {:error, {:secret_unavailable, "OPTIMAL_BACKUP_KEY", :openbao_not_configured}}

      point_at(stub)

      assert {:error, {:secret_unavailable, _, :secret_not_found}} =
               Secrets.fetch("OPTIMAL_BACKUP_KEY")

      OpenBaoStub.put_secret(stub, "optimal/engine", %{"other" => hex})

      assert {:error, {:secret_unavailable, _, :field_not_found}} =
               Secrets.fetch("OPTIMAL_BACKUP_KEY")

      OpenBaoStub.put_secret(stub, "optimal/engine", %{"backup_key" => hex})
      point_at(stub, "wrong-token")

      log =
        capture_log(fn ->
          assert {:error, {:secret_unavailable, "OPTIMAL_BACKUP_KEY", :openbao_forbidden}} =
                   Secrets.fetch("OPTIMAL_BACKUP_KEY")
        end)

      assert log =~ "OPTIMAL_BACKUP_KEY"
      assert log =~ "refused the token"
      refute log =~ "wrong-token"

      point_at(stub)
      OpenBaoStub.seal(stub)

      log =
        capture_log(fn ->
          assert {:error, {:secret_unavailable, "OPTIMAL_BACKUP_KEY", :openbao_sealed}} =
                   Secrets.fetch("OPTIMAL_BACKUP_KEY")
        end)

      assert log =~ "sealed"
      refute log =~ hex
      refute log =~ stub.token

      # A failure is never kept: unsealing makes the next fetch succeed.
      OpenBaoStub.unseal(stub)
      assert Secrets.fetch("OPTIMAL_BACKUP_KEY") == {:ok, hex}

      OpenBaoStub.stop(stub)
      Secrets.flush_cache()

      assert {:error, {:secret_unavailable, _, :openbao_unreachable}} =
               Secrets.fetch("OPTIMAL_BACKUP_KEY")
    end

    test "a malformed reference is refused and the OpenBao token is never a reference", %{
      stub: stub
    } do
      point_at(stub)

      for bad <- ["openbao:", "openbao:path", "openbao:#field", "openbao:path#", "openbao:../x#f"] do
        System.put_env("OPTIMAL_BACKUP_KEY", bad)
        assert {:error, {:secret_unavailable, _, reason}} = Secrets.fetch("OPTIMAL_BACKUP_KEY")
        assert reason in [:invalid_reference, :invalid_secret_path]
      end

      System.put_env("OPTIMAL_OPENBAO_TOKEN", "openbao:optimal/engine#token")
      assert Secrets.fetch("OPTIMAL_OPENBAO_TOKEN") == {:ok, "openbao:optimal/engine#token"}
      assert Secrets.source("OPTIMAL_OPENBAO_TOKEN") == "env"
    end
  end

  describe "the backup key" do
    test "comes from a reference, and a sealed OpenBao is a reason an operator can act on", %{
      stub: stub,
      hex: hex
    } do
      point_at(stub)
      OpenBaoStub.put_secret(stub, "optimal/engine", %{"backup_key" => hex})
      System.put_env("OPTIMAL_BACKUP_KEY", "openbao:optimal/engine#backup_key")

      assert Envelope.backup_key() == {:ok, Base.decode16!(hex, case: :lower)}

      Secrets.flush_cache()
      OpenBaoStub.seal(stub)

      capture_log(fn ->
        assert {:error, {:backup_key_unavailable, :openbao_sealed} = reason} =
                 Envelope.backup_key()

        assert Backup.explain(reason) =~ "sealed"
        refute Backup.explain(reason) =~ hex
      end)
    end
  end

  describe "authority keys" do
    test "are wrapped under a referenced key, and never stored unwrapped while OpenBao is sealed",
         %{stub: stub, hex: hex} do
      point_at(stub)
      OpenBaoStub.put_secret(stub, "optimal/engine", %{"authority" => hex})
      System.put_env("OPTIMAL_AUTHORITY_KEY", "openbao:optimal/engine#authority")

      tenant = "bao-tenant-#{System.unique_integer([:positive])}"
      assert {:ok, key} = Keys.active(tenant, "grant")
      assert is_binary(key.private_key)

      {:ok, [[wrapped]]} =
        OptimalEngine.Store.raw_query(
          "SELECT wrapped FROM authority_keys WHERE kid = ?1",
          [key.kid]
        )

      assert wrapped == 1

      Secrets.flush_cache()
      OpenBaoStub.seal(stub)
      other = tenant <> "-sealed"

      capture_log(fn ->
        assert Keys.active(other, "grant") ==
                 {:error, {:authority_key_unavailable, :openbao_sealed}}

        # The key wrapped before the seal cannot be opened either.
        assert {:error, {:authority_key_unavailable, :openbao_sealed}} =
                 Keys.active(tenant, "grant")
      end)

      {:ok, [[count]]} =
        OptimalEngine.Store.raw_query(
          "SELECT COUNT(*) FROM authority_keys WHERE tenant_id = ?1",
          [other]
        )

      assert count == 0
    end
  end

  describe "the connector key" do
    test "opens envelopes from a reference and refuses every envelope while OpenBao is sealed",
         %{stub: stub, hex: hex} do
      point_at(stub)
      OpenBaoStub.put_secret(stub, "optimal/engine", %{"connector_key" => hex})
      System.put_env("CONNECTOR_KEY", "openbao:optimal/engine#connector_key")

      assert {:ok, envelope} = Credential.encrypt(%{"api_key" => "k"})
      assert Credential.decrypt(envelope) == {:ok, %{"api_key" => "k"}}

      Secrets.flush_cache()
      OpenBaoStub.seal(stub)

      log =
        capture_log(fn ->
          assert Credential.decrypt(envelope) == {:error, :key_missing}
          assert Credential.encrypt(%{"api_key" => "k"}) == {:error, :key_missing}
        end)

      assert log =~ "CONNECTOR_KEY"
      assert log =~ "sealed"
    end
  end

  describe "S3 credentials" do
    test "are read from references, and an unreadable one is an error, not a missing value", %{
      stub: stub
    } do
      point_at(stub)
      OpenBaoStub.put_secret(stub, "optimal/s3", %{"id" => "AKIDBAO", "secret" => "s3-secret"})
      System.put_env("OPTIMAL_S3_ENDPOINT", "http://127.0.0.1:9")
      System.put_env("OPTIMAL_S3_BUCKET", "bucket")
      System.put_env("OPTIMAL_S3_ACCESS_KEY_ID", "openbao:optimal/s3#id")
      System.put_env("OPTIMAL_S3_SECRET_ACCESS_KEY", "openbao:optimal/s3#secret")

      assert {:ok, %{access_key_id: "AKIDBAO", secret_access_key: "s3-secret"}} = S3.config()

      Secrets.flush_cache()
      OpenBaoStub.seal(stub)

      capture_log(fn ->
        assert S3.config() == {:error, :credentials_unavailable}
        refute S3.configured?()
      end)
    end
  end

  test "the provider status names what OpenBao serves without reading any secret", %{stub: stub} do
    point_at(stub)
    System.put_env("OPTIMAL_BACKUP_KEY", "openbao:optimal/engine#backup_key")
    System.put_env("CONNECTOR_KEY", "plain")

    status = OpenBao.Adapter.status()
    assert status.secret_references == ["OPTIMAL_BACKUP_KEY"]
    # Configuring OpenBao does not move connector credentials into it.
    assert status.connector_credentials == "engine"
    assert status.backup_transit_key == nil
    assert OpenBao.Adapter.serves() == ["secret_references"]

    System.put_env("OPTIMAL_CONNECTOR_CREDENTIAL_STORE", "openbao")
    assert OpenBao.Adapter.status().connector_credentials == "openbao"
    assert OpenBao.Adapter.serves() == ["secret_references", "connector_credentials"]

    System.delete_env("OPTIMAL_BACKUP_KEY")
    System.delete_env("OPTIMAL_CONNECTOR_CREDENTIAL_STORE")
    assert OpenBao.Adapter.serves() == []
    assert OpenBaoStub.requests(stub) == []
  end
end
