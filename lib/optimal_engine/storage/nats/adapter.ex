defmodule OptimalEngine.Storage.NATS.Adapter do
  @moduledoc """
  Storage provider adapter for NATS JetStream.

  Implements the `OptimalEngine.Storage.Provider` contract so the inventory
  reports `nats_jetstream` as implemented, configured and healthy instead of
  `adapter_missing`. Health is claimed only on evidence: a `PONG` and a
  JetStream account answer. Nothing here returns, logs or embeds the URL or
  its credential.
  """

  @behaviour OptimalEngine.Storage.Provider

  alias OptimalEngine.Storage.NATS

  @capabilities ~w(event_stream jobs replication coordination)a

  @impl OptimalEngine.Storage.Provider
  def id, do: "nats_jetstream"

  @impl OptimalEngine.Storage.Provider
  def capabilities, do: @capabilities

  @impl OptimalEngine.Storage.Provider
  def describe do
    %{
      id: id(),
      name: "NATS JetStream",
      kind: "service",
      role: "transport",
      capabilities: Enum.map(@capabilities, &Atom.to_string/1),
      operations: ~w(publish stream_create stream_msg_get stream_delete),
      protocol: "NATS text protocol over TCP, TLS with tls://; JetStream through $JS.API",
      durability: "replayable transport; canonical state stays in the governed ledgers"
    }
  end

  @impl OptimalEngine.Storage.Provider
  def status(opts \\ []) do
    configured = NATS.configured?()

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

  @doc "Provider health from a PING and a JetStream account answer. Never raises."
  @spec health(keyword()) :: OptimalEngine.Storage.Provider.health()
  def health(opts \\ []) do
    case NATS.health(opts) do
      :healthy -> :healthy
      :not_configured -> :not_configured
      _ -> :unreachable
    end
  end

  @doc "The full proof: a stream created, a message published, read back by sequence, the stream deleted."
  @spec probe(keyword()) :: {:ok, map()} | {:error, term()}
  def probe(opts \\ []) do
    if NATS.configured?() do
      with {:ok, evidence} <- NATS.round_trip(opts) do
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
    case NATS.safe_config() do
      {:ok, %{ssl: ssl}} -> ssl
      _ -> false
    end
  end
end
