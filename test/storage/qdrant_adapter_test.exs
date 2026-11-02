defmodule OptimalEngine.Storage.QdrantAdapterTest do
  @moduledoc """
  The Qdrant provider must report itself honestly: implemented, configured and
  healthy only when the collections endpoint answered with the key, and proved
  only by a vector indexed and retrieved.
  """
  use ExUnit.Case, async: false

  alias OptimalEngine.Storage.{Providers, Qdrant}
  alias OptimalEngine.Storage.Qdrant.Adapter
  alias OptimalEngine.TestSupport.QdrantStub

  @env ~w(OPTIMAL_QDRANT_URL OPTIMAL_QDRANT_API_KEY)

  setup do
    previous = Map.new(@env, &{&1, System.get_env(&1)})
    Enum.each(@env, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    :ok
  end

  test "qdrant is an implemented provider, not adapter_missing" do
    assert {:ok, provider} = Providers.get("qdrant")
    assert provider.adapter_implemented
    assert provider.adapter_module == "OptimalEngine.Storage.Qdrant.Adapter"
    assert provider.lifecycle_state == "not_configured"
  end

  test "unconfigured is not_configured, a non-http URL invalid, and the key never shown" do
    assert Qdrant.health() == :not_configured
    assert {:error, :not_configured} = Adapter.probe()

    System.put_env("OPTIMAL_QDRANT_URL", "qdrant.example.com:6333")
    assert Qdrant.health() == :invalid_config

    System.put_env("OPTIMAL_QDRANT_URL", "https://qdrant.example.com:6333/")
    System.put_env("OPTIMAL_QDRANT_API_KEY", "k3y-s3cret")

    assert {:ok, %{base_url: "https://qdrant.example.com:6333", tls: true, key: true}} =
             Qdrant.config()

    refute inspect(Adapter.status()) =~ "k3y"
    assert %{api_key_configured: true, lifecycle_state: "configured_unverified"} = Adapter.status()
  end

  test "a server that lists collections is healthy and available; a closed port is unreachable" do
    {:ok, stub} = QdrantStub.start()
    on_exit(fn -> QdrantStub.stop(stub) end)
    System.put_env("OPTIMAL_QDRANT_URL", stub.endpoint)

    assert Qdrant.health() == :healthy
    assert {:ok, provider} = Providers.get("qdrant", probe: true)
    assert provider.lifecycle_state == "available"
    assert [{"GET", "/collections"} | _] = QdrantStub.requests(stub)

    QdrantStub.stop(stub)
    assert Qdrant.health(timeout: 500) == :unreachable
  end

  test "the proof creates a collection, upserts a point, finds it by vector and deletes the collection" do
    {:ok, stub} = QdrantStub.start()
    on_exit(fn -> QdrantStub.stop(stub) end)
    System.put_env("OPTIMAL_QDRANT_URL", stub.endpoint)

    assert {:ok,
            %{
              provider: "qdrant",
              collection_created: true,
              points: 1,
              searched: true,
              read_back: true
            }} =
             Adapter.probe()

    assert QdrantStub.collections(stub) == %{}

    assert [{"PUT", "/collections/" <> name}, {"PUT", _points}, {"POST", _search}, {"DELETE", _}] =
             QdrantStub.requests(stub)

    assert String.starts_with?(name, "optimal_proof_")

    assert [%{provider: "qdrant", status: "pass"}] =
             Providers.proofs() |> Enum.filter(&(&1.provider == "qdrant"))
  end

  test "the key is sent as api-key, and a wrong one is unreachable, not healthy" do
    {:ok, stub} = QdrantStub.start(api_key: "right")
    on_exit(fn -> QdrantStub.stop(stub) end)
    System.put_env("OPTIMAL_QDRANT_URL", stub.endpoint)

    System.put_env("OPTIMAL_QDRANT_API_KEY", "right")
    assert Qdrant.health() == :healthy

    System.put_env("OPTIMAL_QDRANT_API_KEY", "wrong")
    assert Qdrant.health() == :unreachable
    assert {:error, {:round_trip_mismatch, 401, _}} = Qdrant.round_trip()
  end
end
