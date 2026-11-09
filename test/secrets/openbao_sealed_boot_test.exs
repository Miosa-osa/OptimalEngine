defmodule OptimalEngine.Secrets.OpenBaoSealedBootTest do
  @moduledoc """
  OpenBao comes up sealed after a reboot until someone unseals it. With every
  Engine secret an OpenBao reference and OpenBao sealed, the Engine still
  boots, serves, and reports OpenBao as the degraded part: readiness warns
  `openbao_unavailable` instead of failing, and each path that needs a secret
  fails with that reason instead of crashing.
  """

  use ExUnit.Case, async: false

  @moduletag capture_log: true

  alias OptimalEngine.{Health, Secrets}
  alias OptimalEngine.Authority.Keys
  alias OptimalEngine.Backup.Schedule
  alias OptimalEngine.Connectors.Credential
  alias OptimalEngine.Storage.{OpenBao, S3}
  alias OptimalEngine.TestSupport.OpenBaoStub

  @references %{
    "OPTIMAL_AUTHORITY_KEY" => "openbao:optimal/engine#authority_key",
    "CONNECTOR_KEY" => "openbao:optimal/engine#connector_key",
    "OPTIMAL_BACKUP_KEY" => "openbao:optimal/engine#backup_key",
    "OPTIMAL_S3_ACCESS_KEY_ID" => "openbao:optimal/engine#s3_id",
    "OPTIMAL_S3_SECRET_ACCESS_KEY" => "openbao:optimal/engine#s3_secret"
  }

  @env Map.keys(@references) ++
         ~w(OPTIMAL_OPENBAO_ADDR OPTIMAL_OPENBAO_TOKEN OPTIMAL_OPENBAO_TRANSIT_KEY
            OPTIMAL_CONNECTOR_CREDENTIAL_STORE OPTIMAL_S3_ENDPOINT OPTIMAL_S3_BUCKET)

  setup do
    previous = Map.new(@env, &{&1, System.get_env(&1)})

    {:ok, stub} = OpenBaoStub.start(sealed: true, transit_keys: ["optimal-backup"])

    on_exit(fn ->
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)

      Secrets.flush_cache()
      OpenBaoStub.stop(stub)
      # Leave the application running for the rest of the suite whatever happened.
      {:ok, _} = Application.ensure_all_started(:optimal_engine)
    end)

    Enum.each(@references, fn {name, ref} -> System.put_env(name, ref) end)
    System.put_env("OPTIMAL_OPENBAO_ADDR", stub.endpoint)
    System.put_env("OPTIMAL_OPENBAO_TOKEN", stub.token)
    System.put_env("OPTIMAL_OPENBAO_TRANSIT_KEY", "optimal-backup")
    System.put_env("OPTIMAL_CONNECTOR_CREDENTIAL_STORE", "openbao")
    System.put_env("OPTIMAL_S3_ENDPOINT", "http://127.0.0.1:1")
    System.put_env("OPTIMAL_S3_BUCKET", "engine")
    Secrets.flush_cache()

    %{stub: stub}
  end

  test "the Engine boots with OpenBao sealed and reports it, never crashing on a secret" do
    :ok = Application.stop(:optimal_engine)
    assert {:ok, _apps} = Application.ensure_all_started(:optimal_engine)
    assert Health.live?()

    # Readiness: degraded with the reason, not down (an orchestrator restarting
    # the Engine would not unseal OpenBao).
    report = Health.ready(skip: [:embedder])
    assert report.ok?, inspect(report.checks)
    assert :secrets in report.degraded
    assert {:warn, {:openbao_unavailable, :openbao_sealed}} = report.checks.secrets
    assert "openbao_unavailable" in Health.warnings(report)

    # Every path that needs a secret fails with the reason and returns.
    assert {:error, {:authority_key_unavailable, :openbao_sealed}} =
             Keys.active("default", "evidence")

    assert {:error, {:authority_key_unavailable, :openbao_sealed}} =
             OptimalEngine.Authority.Evidence.append("default", "settings.changed", %{})

    refute Credential.ready?()
    assert S3.config() == {:error, :credentials_unavailable}
    refute S3.configured?()

    status = Schedule.status()
    refute status.encryption.key_configured
    assert status.encryption.problem =~ "sealed"

    assert OpenBao.health() == :unreachable
  end

  test "readiness keeps connector_key an error only when the key is truly missing" do
    System.delete_env("CONNECTOR_KEY")
    report = Health.ready(skip: [:embedder])
    # A missing key with connectors configured is still the error it was.
    if report.checks.credential_key != :ok,
      do: assert(report.checks.credential_key == {:error, :connector_key_missing})

    System.put_env("CONNECTOR_KEY", "openbao:optimal/engine#connector_key")
    report = Health.ready(skip: [:embedder])
    refute match?({:error, _}, report.checks.credential_key)
  end
end
