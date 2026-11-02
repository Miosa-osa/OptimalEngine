defmodule OptimalEngine.Storage.Valkey.Adapter do
  @moduledoc """
  Storage provider adapter for Valkey.

  Implements the `OptimalEngine.Storage.Provider` contract so the inventory
  reports `valkey` as implemented, configured and healthy instead of
  `adapter_missing`. Health is claimed only on evidence: a `PING` the server
  answered. Nothing here returns, logs or embeds the URL or its credential.
  """

  @behaviour OptimalEngine.Storage.Provider

  alias OptimalEngine.Storage.Valkey

  @capabilities ~w(cache coordination rate_limits)a

  @impl OptimalEngine.Storage.Provider
  def id, do: "valkey"

  @impl OptimalEngine.Storage.Provider
  def capabilities, do: @capabilities

  @impl OptimalEngine.Storage.Provider
  def describe do
    %{
      id: id(),
      name: "Valkey",
      kind: "service",
      role: "ephemeral",
      capabilities: Enum.map(@capabilities, &Atom.to_string/1),
      operations: ~w(ping set get del),
      protocol: "RESP2 over TCP, TLS with rediss://",
      durability: "none: a cache and coordination store, rebuilt from the canonical stores"
    }
  end

  @impl OptimalEngine.Storage.Provider
  def status(opts \\ []) do
    configured = Valkey.configured?()

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
      tls: tls_configured?()
    }
  end

  @doc "Provider health from one `PING`. Never raises."
  @spec health(keyword()) :: OptimalEngine.Storage.Provider.health()
  def health(opts \\ []) do
    case Valkey.health(opts) do
      :healthy -> :healthy
      :not_configured -> :not_configured
      _ -> :unreachable
    end
  end

  @doc "The full proof: write a key, read it back, delete it."
  @spec probe(keyword()) :: {:ok, map()} | {:error, term()}
  def probe(opts \\ []) do
    if Valkey.configured?() do
      with {:ok, evidence} <- Valkey.round_trip(opts) do
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

  defp tls_configured? do
    case Valkey.safe_config() do
      {:ok, %{ssl: ssl}} -> ssl
      _ -> false
    end
  end
end
