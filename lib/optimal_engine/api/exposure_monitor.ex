defmodule OptimalEngine.API.ExposureMonitor do
  @moduledoc """
  Repeats the open-API error line (`OptimalEngine.API.Exposure.message/1`) every
  10 minutes while the Engine runs with authentication off on a network
  interface, so the warning is never only at the top of an old log.
  `OptimalEngine.API.Endpoint` starts it only for such an Engine.
  """

  use GenServer
  require Logger

  alias OptimalEngine.API.Exposure

  @interval_ms :timer.minutes(10)

  @doc "Options: `:interface` (required), `:interval_ms`, `:name` (nil for none)."
  def start_link(opts) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @impl true
  def init(opts) do
    state = %{
      interface: Keyword.fetch!(opts, :interface),
      interval_ms: Keyword.get(opts, :interval_ms, @interval_ms)
    }

    schedule(state)
    {:ok, state}
  end

  @impl true
  def handle_info(:report, state) do
    Logger.error(Exposure.message(state.interface))
    schedule(state)
    {:noreply, state}
  end

  defp schedule(state), do: Process.send_after(self(), :report, state.interval_ms)
end
