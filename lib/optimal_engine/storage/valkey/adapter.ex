defmodule OptimalEngine.Storage.Valkey.Adapter do
  @moduledoc """
  Storage provider adapter for Valkey.

  Implements the `OptimalEngine.Storage.Provider` contract so the inventory
  reports `valkey` as implemented, configured and healthy instead of
  `adapter_missing`. Health is claimed only on evidence: a `PING` the server
  answered. Nothing here returns, logs or embeds the URL or its credential.

  When configured, Valkey is in the data path: `serves/0` names what runs on
  it (`OptimalEngine.Storage.Shared`), and `status/1` reports how many of the
  pool's connections are up.
  """

  @behaviour OptimalEngine.Storage.Provider

  alias OptimalEngine.Storage.Valkey
  alias OptimalEngine.Storage.Valkey.Pool

  @capabilities ~w(cache coordination rate_limits)a

  # What the Engine runs on Valkey when it is configured and up.
  @serves ~w(api_rate_limits connector_rate_limits api_key_cache sync_gate_cache)

  @impl OptimalEngine.Storage.Provider
  def id, do: "valkey"

  @impl OptimalEngine.Storage.Provider
  def capabilities, do: @capabilities

  @doc "The data the Engine keeps on Valkey while it is configured and up."
  @spec serves() :: [String.t()]
  def serves, do: @serves

  @impl OptimalEngine.Storage.Provider
  def describe do
    %{
      id: id(),
      name: "Valkey",
      kind: "service",
      role: "ephemeral",
      capabilities: Enum.map(@capabilities, &Atom.to_string/1),
      operations: ~w(ping set get del evalsha incr),
      serves: @serves,
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
      tls: tls_configured?(),
      serves: @serves,
      serving: Pool.serving?(),
      pool: Pool.stats()
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
