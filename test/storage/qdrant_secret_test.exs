defmodule OptimalEngine.Storage.QdrantSecretTest do
  @moduledoc """
  `OPTIMAL_QDRANT_API_KEY` is read through `OptimalEngine.Secrets`, so it can
  be an `openbao:<path>#<field>` reference: the key sent is the secret OpenBao
  holds, never the reference text, and a reference OpenBao cannot answer
  fails the request with a reason that says so instead of sending no key.
  """
  use ExUnit.Case, async: false

  @moduletag capture_log: true

  alias OptimalEngine.Secrets
  alias OptimalEngine.Storage.Qdrant
  alias OptimalEngine.TestSupport.{OpenBaoStub, QdrantStub}

  @env ~w(OPTIMAL_QDRANT_URL OPTIMAL_QDRANT_API_KEY OPTIMAL_OPENBAO_ADDR OPTIMAL_OPENBAO_TOKEN)

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

    {:ok, bao} = OpenBaoStub.start()
    {:ok, qdrant} = QdrantStub.start(api_key: "qdrant-k3y-from-bao")
    on_exit(fn -> OpenBaoStub.stop(bao) end)
    on_exit(fn -> QdrantStub.stop(qdrant) end)

    System.put_env("OPTIMAL_QDRANT_URL", qdrant.endpoint)
    %{bao: bao, qdrant: qdrant}
  end

  test "the API key is the secret an openbao: reference names", %{bao: bao} do
    System.put_env("OPTIMAL_OPENBAO_ADDR", bao.endpoint)
    System.put_env("OPTIMAL_OPENBAO_TOKEN", bao.token)
    OpenBaoStub.put_secret(bao, "optimal/qdrant", %{"api_key" => "qdrant-k3y-from-bao"})
    System.put_env("OPTIMAL_QDRANT_API_KEY", "openbao:optimal/qdrant#api_key")

    assert Qdrant.health() == :healthy
    assert {:ok, %{read_back: true, collection_deleted: true}} = Qdrant.round_trip()
    assert Secrets.source("OPTIMAL_QDRANT_API_KEY") == "openbao"
    assert "OPTIMAL_QDRANT_API_KEY" in Secrets.references()
  end

  test "a plain key still works and asks OpenBao nothing", %{bao: bao} do
    System.put_env("OPTIMAL_OPENBAO_ADDR", bao.endpoint)
    System.put_env("OPTIMAL_OPENBAO_TOKEN", bao.token)
    System.put_env("OPTIMAL_QDRANT_API_KEY", "qdrant-k3y-from-bao")

    assert Qdrant.health() == :healthy
    assert OpenBaoStub.requests(bao) == []
  end

  test "a reference OpenBao cannot answer fails with the reason, and sends nothing", %{
    bao: bao,
    qdrant: qdrant
  } do
    System.put_env("OPTIMAL_OPENBAO_ADDR", bao.endpoint)
    System.put_env("OPTIMAL_OPENBAO_TOKEN", bao.token)
    OpenBaoStub.seal(bao)
    System.put_env("OPTIMAL_QDRANT_API_KEY", "openbao:optimal/qdrant#api_key")

    assert {:error, {:api_key_unavailable, :openbao_sealed}} = Qdrant.round_trip()
    assert Qdrant.health() == :unreachable
    assert QdrantStub.requests(qdrant) == []
  end
end
