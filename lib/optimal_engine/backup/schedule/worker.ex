defmodule OptimalEngine.Backup.Schedule.Worker do
  @moduledoc """
  Schedules and drains offsite backup jobs (`OptimalEngine.Backup.Schedule`).

  Off unless `OPTIMAL_OFFSITE_BACKUP_INTERVAL_MS` (`config :optimal_engine,
  :offsite_backup_interval_ms`) is above zero. When on, it checks every
  minute, or every interval when that is shorter: the current slot's job is
  enqueued once, and due jobs, including retries, are run. The backup and its
  upload run in this process, never in the Store.
  """

  use GenServer
  require Logger

  alias OptimalEngine.Backup.Schedule

  @check_interval 60_000
  @boot_delay 30_000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Runs one pass now."
  def tick, do: GenServer.call(__MODULE__, :tick, :infinity)

  @impl true
  def init(_opts) do
    interval = Schedule.interval_ms()

    if interval > 0 do
      report_misconfiguration()
      Process.send_after(self(), :tick, min(@boot_delay, interval))
    end

    {:ok, %{interval: interval}}
  end

  @impl true
  def handle_info(:tick, state) do
    run()

    if state.interval > 0,
      do: Process.send_after(self(), :tick, min(state.interval, @check_interval))

    {:noreply, state}
  end

  @impl true
  def handle_call(:tick, _from, state), do: {:reply, run(), state}

  defp run do
    %{scheduled: Schedule.schedule(), ran: Schedule.drain()}
  rescue
    error ->
      Logger.error("[Backup.Schedule] pass failed: #{Exception.message(error)}")
      {:error, Exception.message(error)}
  end

  # A schedule that can never ship is reported at boot, not first at the dead
  # letter three attempts later.
  defp report_misconfiguration do
    status = Schedule.status()

    for {name, %{problem: problem}} when is_binary(problem) <- [
          {"backup key", status.encryption},
          {"object store", status.object_store}
        ] do
      Logger.error(
        "[Backup.Schedule] offsite backups are scheduled but the #{name} is not ready: #{problem}"
      )
    end

    :ok
  rescue
    error ->
      Logger.warning("[Backup.Schedule] status unavailable at boot: #{Exception.message(error)}")
  end
end
