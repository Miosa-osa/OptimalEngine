defmodule OptimalEngine.Telemetry.HistorySampler do
  @moduledoc """
  Periodically persists the live Telemetry snapshot into `metric_samples`
  and prunes samples past retention.

  Configure with:

      config :optimal_engine, :metric_history,
        enabled: true,
        interval_ms: 300_000,
        retention_days: 30

  Sampling failures are logged and never crash the supervision tree.
  """

  use GenServer
  require Logger

  alias OptimalEngine.Telemetry.History

  @default_interval_ms 5 * 60 * 1_000
  @default_retention_days 30

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Sample immediately and return `{written, pruned}`."
  @spec sample_now(GenServer.server()) :: {:ok, map()} | {:error, term()}
  def sample_now(server \\ __MODULE__), do: GenServer.call(server, :sample_now, 30_000)

  @impl true
  def init(opts) do
    config = Keyword.merge(Application.get_env(:optimal_engine, :metric_history, []), opts)

    state = %{
      enabled: Keyword.get(config, :enabled, true),
      interval_ms: Keyword.get(config, :interval_ms, @default_interval_ms),
      retention_seconds: Keyword.get(config, :retention_days, @default_retention_days) * 86_400
    }

    if state.enabled, do: schedule(state)
    {:ok, state}
  end

  @impl true
  def handle_call(:sample_now, _from, state), do: {:reply, sample(state), state}

  @impl true
  def handle_info(:sample, state) do
    case sample(state) do
      {:ok, _} -> :ok
      {:error, reason} -> Logger.warning("[Telemetry.History] sampling failed: #{inspect(reason)}")
    end

    schedule(state)
    {:noreply, state}
  end

  defp sample(state) do
    with {:ok, written} <- History.snapshot_telemetry(),
         {:ok, pruned} <- History.prune(state.retention_seconds) do
      {:ok, %{written: written, pruned: pruned}}
    end
  rescue
    error -> {:error, Exception.message(error)}
  catch
    :exit, reason -> {:error, reason}
  end

  defp schedule(state), do: Process.send_after(self(), :sample, state.interval_ms)
end
