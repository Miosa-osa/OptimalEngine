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
  alias OptimalEngine.Storage.NATS.{Connection, LedgerPublisher}

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
      operations:
        ~w(publish stream_create stream_update stream_info stream_msg_get stream_delete consumer_create consumer_pull ack nak term),
      protocol:
        "NATS text protocol over TCP, TLS with tls://; JetStream through $JS.API; one supervised connection that reconnects with backoff",
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
      tls: tls_configured?(),
      client: Connection.status()
    }
  end

  @doc """
  The Engine's own long-lived client as it is now
  (`OptimalEngine.Storage.NATS.Connection.status/1`): its state, how often the
  connection was lost, the last error and the server's version; and each flow
  that runs on it (`flows.ledger`: `off`, `buffering` with each workspace's
  backlog, `publishing`, `caught_up`). Never the URL or its credential.
  """
  @spec runtime() :: map()
  def runtime do
    %{
      client: Connection.status(),
      flows: %{ledger: LedgerPublisher.status()}
    }
  end

  @doc """
  What the Engine routes through NATS when it is configured: the flows named
  in `OPTIMAL_NATS_FLOWS`. None by default, and the adapter then only checks
  and proves the server.
  """
  @spec serves() :: [String.t()]
  def serves do
    Enum.flat_map(NATS.flows(), fn
      "ledger" -> ["change_ledger_stream"]
      _other -> []
    end)
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
