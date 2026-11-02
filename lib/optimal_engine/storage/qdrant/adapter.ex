defmodule OptimalEngine.Storage.Qdrant.Adapter do
  @moduledoc """
  Storage provider adapter for Qdrant.

  Implements the `OptimalEngine.Storage.Provider` contract so the inventory
  reports `qdrant` as implemented, configured and healthy instead of
  `adapter_missing`. Health is claimed only on evidence: the collections
  endpoint answered with the key. Nothing here returns, logs or embeds the key.
  """

  @behaviour OptimalEngine.Storage.Provider

  alias OptimalEngine.Storage.Qdrant

  @capabilities ~w(vector)a

  @impl OptimalEngine.Storage.Provider
  def id, do: "qdrant"

  @impl OptimalEngine.Storage.Provider
  def capabilities, do: @capabilities

  @impl OptimalEngine.Storage.Provider
  def describe do
    %{
      id: id(),
      name: "Qdrant",
      kind: "service",
      role: "projection",
      capabilities: Enum.map(@capabilities, &Atom.to_string/1),
      operations: ~w(collection_create upsert search collection_delete),
      protocol: "REST over HTTP(S); api-key header when OPTIMAL_QDRANT_API_KEY is set",
      durability: "a projection: every collection is rebuilt from the canonical stores"
    }
  end

  @impl OptimalEngine.Storage.Provider
  def status(opts \\ []) do
    configured = Qdrant.configured?()

    health =
      cond do
        not configured -> :not_configured
        Keyword.get(opts, :probe, false) -> health(opts)
        true -> :unknown
      end

    %{
      id: id(),
      configured: configured,
      health: Atom.to_string(health),
      lifecycle_state: lifecycle_state(configured, health),
      capabilities: Enum.map(@capabilities, &Atom.to_string/1),
      api_key_configured: key_configured?()
    }
  end

  @doc "Provider health from the collections endpoint. Never raises."
  @spec health(keyword()) :: OptimalEngine.Storage.Provider.health()
  def health(opts \\ []) do
    case Qdrant.health(opts) do
      :healthy -> :healthy
      :not_configured -> :not_configured
      _ -> :unreachable
    end
  end

  @doc "The full proof: a collection created, a point upserted, searched, read back, the collection deleted."
  @spec probe(keyword()) :: {:ok, map()} | {:error, term()}
  def probe(opts \\ []) do
    if Qdrant.configured?() do
      with {:ok, evidence} <- Qdrant.round_trip(opts) do
        {:ok, Map.put(evidence, :provider, id())}
      end
    else
      {:error, :not_configured}
    end
  end

  defp lifecycle_state(false, _health), do: "not_configured"
  defp lifecycle_state(true, :healthy), do: "available"
  defp lifecycle_state(true, :unknown), do: "configured_unverified"
  defp lifecycle_state(true, _health), do: "unavailable"

  defp key_configured? do
    case Qdrant.config() do
      {:ok, %{key: key}} -> key
      _ -> false
    end
  end
end
