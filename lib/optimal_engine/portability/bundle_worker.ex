defmodule OptimalEngine.Portability.BundleWorker do
  @moduledoc """
  Runs the bundle jobs (`OptimalEngine.Portability.BundleJobs`) one at a time.

  When it starts it first releases the jobs an Engine that stopped left
  running, so they run again from the start. Then every five seconds
  (`config :optimal_engine, :bundle_jobs_interval_ms`; 0 turns the worker off,
  as in tests) it runs the next due job in a process linked to it, and once an
  hour it removes expired bundles and old job records. The link means a job
  never outlives the worker: a restarted worker can release every job still
  marked running without one of them still being at work.
  """

  use GenServer
  require Logger

  alias OptimalEngine.Portability.BundleJobs

  @sweep_every_ms :timer.hours(1)

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    case Application.get_env(:optimal_engine, :bundle_jobs_interval_ms, 5_000) do
      interval when is_integer(interval) and interval > 0 ->
        Process.flag(:trap_exit, true)
        send(self(), :recover)
        {:ok, %{interval: interval, job: nil, swept_at: nil}}

      _ ->
        :ignore
    end
  end

  @impl true
  def handle_info(:recover, state) do
    # A job that cannot be recovered is released again at every boot, so a
    # raise here would crash this worker at every boot and take the supervisor
    # down with it: recovery logs what it cannot do and goes on.
    try do
      case BundleJobs.recover() do
        0 ->
          :ok

        n ->
          Logger.warning(
            "[BundleWorker] #{n} bundle jobs were cut off when the Engine stopped; they run again from the start"
          )
      end
    rescue
      error -> Logger.error("[BundleWorker] recovery failed: #{Exception.message(error)}")
    catch
      kind, reason -> Logger.error("[BundleWorker] recovery failed: #{kind} #{inspect(reason)}")
    end

    schedule(state.interval)
    {:noreply, state}
  end

  def handle_info(:tick, %{job: nil} = state) do
    state = sweep(state)
    worker = self()

    pid =
      spawn_link(fn ->
        result =
          try do
            BundleJobs.drain()
          rescue
            error -> {:error, Exception.message(error)}
          end

        send(worker, {:drained, result})
      end)

    {:noreply, %{state | job: pid}}
  end

  def handle_info(:tick, state) do
    schedule(state.interval)
    {:noreply, state}
  end

  # A job that ran is followed at once by the next one; an idle queue waits.
  def handle_info({:drained, result}, state) do
    case result do
      {:ok, :idle} -> schedule(state.interval)
      {:ok, _view} -> schedule(0)
      {:error, reason} -> log_and_schedule(reason, state.interval)
    end

    {:noreply, %{state | job: nil}}
  end

  # A run that died before it reported.
  def handle_info({:EXIT, pid, reason}, %{job: pid} = state) when reason != :normal do
    log_and_schedule(reason, state.interval)
    {:noreply, %{state | job: nil}}
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  defp log_and_schedule(reason, interval) do
    Logger.error("[BundleWorker] a bundle job run failed: #{inspect(reason)}")
    schedule(interval)
  end

  defp sweep(%{swept_at: at} = state) do
    now = System.monotonic_time(:millisecond)

    if is_nil(at) or now - at >= @sweep_every_ms do
      try do
        BundleJobs.sweep()
      rescue
        error -> Logger.error("[BundleWorker] the sweep failed: #{Exception.message(error)}")
      end

      %{state | swept_at: now}
    else
      state
    end
  end

  defp schedule(ms), do: Process.send_after(self(), :tick, ms)
end
