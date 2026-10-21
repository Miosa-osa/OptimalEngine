defmodule OptimalEngine.Storage.S3AdapterTest do
  @moduledoc """
  The S3 provider must report itself honestly: implemented, configured, and
  healthy only when a signed request against the bucket actually succeeds.
  """

  use ExUnit.Case, async: false

  alias OptimalEngine.Storage.{Providers, S3}
  alias OptimalEngine.Storage.S3.Adapter
  alias OptimalEngine.TestSupport.S3Stub

  @s3_env ~w(OPTIMAL_S3_ENDPOINT OPTIMAL_S3_BUCKET OPTIMAL_S3_REGION OPTIMAL_S3_ACCESS_KEY_ID
             OPTIMAL_S3_SECRET_ACCESS_KEY OPTIMAL_S3_PREFIX OPTIMAL_S3_PATH_STYLE)

  setup do
    previous = Map.new(@s3_env, &{&1, System.get_env(&1)})
    Enum.each(@s3_env, &System.delete_env/1)

    ref = S3Stub.ref()
    on_exit(fn -> S3Stub.stop(ref) end)
    {:ok, stub} = S3Stub.start(ref: ref, bucket: "engine-test")

    on_exit(fn ->
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    %{stub: stub}
  end

  defp point_at(stub) do
    System.put_env("OPTIMAL_S3_ENDPOINT", stub.endpoint)
    System.put_env("OPTIMAL_S3_BUCKET", stub.bucket)
    System.put_env("OPTIMAL_S3_ACCESS_KEY_ID", stub.access_key_id)
    System.put_env("OPTIMAL_S3_SECRET_ACCESS_KEY", stub.secret_access_key)
    System.put_env("OPTIMAL_S3_REGION", stub.region)
  end

  test "s3 is an implemented provider, not adapter_missing" do
    assert {:ok, provider} = Providers.get("s3")
    assert provider.adapter_implemented
    assert provider.adapter_module == "OptimalEngine.Storage.S3.Adapter"
    refute provider.lifecycle_state == "adapter_missing"
    assert Enum.sort(provider.capabilities) == ~w(assets backups objects)a
  end

  test "unconfigured s3 is not_configured and never healthy", %{stub: stub} do
    assert {:ok, provider} = Providers.get("s3", probe: true)
    refute provider.configured
    assert provider.health == "not_configured"
    assert provider.lifecycle_state == "not_configured"
    assert "OPTIMAL_S3_ENDPOINT" in provider.missing_environment
    assert stub.agent |> S3Stub.requests() |> Enum.empty?()

    assert %{configured: false, lifecycle_state: "not_configured"} = Adapter.status()
  end

  test "a configured, reachable bucket reports available with a passing probe", %{stub: stub} do
    point_at(stub)

    assert {:ok, provider} = Providers.get("s3", probe: true)
    assert provider.configured
    assert provider.health == "healthy"
    assert provider.lifecycle_state == "available"
    assert provider.missing_environment == []
    assert [request] = S3Stub.requests(stub.agent)
    assert request.accepted
    assert request.method == "GET"
  end

  test "configured without a probe is only configured_unverified", %{stub: stub} do
    point_at(stub)

    assert {:ok, provider} = Providers.get("s3")
    assert provider.configured
    assert provider.health == "configured"
    assert provider.lifecycle_state == "configured_unverified"
  end

  test "an unreachable endpoint reports unavailable, never healthy", %{stub: stub} do
    point_at(stub)
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)

    System.put_env("OPTIMAL_S3_ENDPOINT", "http://127.0.0.1:#{port}")
    System.put_env("OPTIMAL_S3_MAX_RETRIES", "0")

    assert {:ok, provider} = Providers.get("s3", probe: true)
    assert provider.configured
    assert provider.health == "unreachable"
    assert provider.lifecycle_state == "unavailable"
    refute provider.lifecycle_state in ["active", "available"]
  end

  test "wrong credentials report unavailable rather than a healthy endpoint", %{stub: stub} do
    point_at(stub)
    System.put_env("OPTIMAL_S3_SECRET_ACCESS_KEY", "wrong-secret")
    System.put_env("OPTIMAL_S3_MAX_RETRIES", "0")

    assert {:ok, provider} = Providers.get("s3", probe: true)
    assert provider.health == "unreachable"
    assert provider.lifecycle_state == "unavailable"
  end

  test "an unimplemented provider stays adapter_missing even when its probe would pass" do
    assert {:ok, qdrant} = Providers.get("qdrant")
    refute qdrant.adapter_implemented
    assert qdrant.lifecycle_state == "adapter_missing"
  end

  test "adapter status and probe describe the endpoint without secret material", %{stub: stub} do
    point_at(stub)

    status = Adapter.status(probe: true)
    described = Adapter.describe()

    assert status.id == "s3"
    assert status.lifecycle_state == "available"
    assert described.capabilities == ~w(objects assets backups)
    assert described.operations == ~w(put get head list delete multipart)

    encoded = Jason.encode!(%{status: status, described: described})
    refute encoded =~ stub.secret_access_key
    refute encoded =~ stub.access_key_id
    refute encoded =~ "secret_access_key"

    assert {:ok, location} = Adapter.location()
    assert location.bucket == stub.bucket
  end

  test "the provider proof round trips an object and leaves the bucket clean", %{stub: stub} do
    point_at(stub)

    assert {:ok, evidence} = Adapter.probe()
    assert evidence.provider == "s3"
    assert evidence.deleted
    assert S3Stub.object_keys(stub.agent) == []

    assert {:ok, _} = S3.put_object("keep/me.txt", "bytes")
    assert S3Stub.object_keys(stub.agent) == ["keep/me.txt"]
  end

  test "the proof refuses to run without configuration" do
    assert {:error, :not_configured} = Adapter.probe()
    assert Adapter.health() == :not_configured
    assert {:error, :not_configured} = Adapter.location()
  end
end
