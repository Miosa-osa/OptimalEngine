defmodule OptimalEngine.Storage.AssetReconcile.Worker do
  @moduledoc """
  Runs `OptimalEngine.Storage.AssetReconcile` every ten minutes
  (`OPTIMAL_ASSET_RECONCILE_INTERVAL_MS`, `config :optimal_engine,
  :asset_reconcile_interval_ms`; 0 turns it off) while S3 is configured and
  assets are pending. A pass places at most 100 assets; when it placed a full
  batch the next one follows at once.
  """

  use GenServer
  require Logger

  alias OptimalEngine.Storage.{AssetReconcile, S3}

  @default_interval_ms :timer.minutes(10)

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    case Application.get_env(:optimal_engine, :asset_reconcile_interval_ms, @default_interval_ms) do
      interval when is_integer(interval) and interval > 0 ->
        schedule(interval)
        {:ok, %{interval: interval}}

      _ ->
        :ignore
    end
  end

  @impl true
  def handle_info(:reconcile, state) do
    next =
      try do
        pass(state.interval)
      rescue
        error ->
          Logger.error("[AssetReconcile] the pass failed: #{Exception.message(error)}")
          state.interval
      end

    schedule(next)
    {:noreply, state}
  end

  defp pass(interval) do
    # Counted on every tick, S3 configured or not, so the metrics' cached count
    # is never older than a tick.
    counts = AssetReconcile.refresh_counts()

    if S3.configured?() and match?({:ok, %{pending: pending}} when pending > 0, counts) do
      case AssetReconcile.run() do
        {:ok, %{placed: placed, failed: 0, pending: pending}} when placed > 0 and pending > 0 -> 0
        _ -> interval
      end
    else
      interval
    end
  end

  defp schedule(ms), do: Process.send_after(self(), :reconcile, ms)
end
