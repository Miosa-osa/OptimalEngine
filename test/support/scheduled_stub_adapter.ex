defmodule OptimalEngine.Test.ScheduledStubAdapter do
  @moduledoc """
  A connector adapter for scheduler tests.

  Every sync reports itself to the listening test process as
  `{:stub_sync, marker, pid}` and emits one Signal titled after the row's
  `"marker"`. A row with `"block" => true` waits for `:release` (sent to the
  pid it reported) before it answers, which is how a test holds one
  connector mid-run. A row with `"fail" => true` answers `{:error, :boom}`.
  """

  @behaviour OptimalEngine.Connectors.Behaviour

  alias OptimalEngine.Signal

  @listener {__MODULE__, :listener}

  @doc "Routes every sync report to `pid`."
  def listen(pid), do: :persistent_term.put(@listener, pid)

  @doc "Stops reporting syncs."
  def stop_listening, do: :persistent_term.erase(@listener)

  @impl true
  def kind, do: :sources_folder

  @impl true
  def display_name, do: "Scheduled stub"

  @impl true
  def auth_scheme, do: :token

  @impl true
  def required_config_keys, do: []

  @impl true
  def init(config), do: {:ok, config}

  @impl true
  def sync(state, cursor) do
    marker = Map.get(state, "marker", "stub")

    case :persistent_term.get(@listener, nil) do
      nil -> :ok
      pid -> send(pid, {:stub_sync, marker, self()})
    end

    if Map.get(state, "block") do
      receive do
        :release -> :ok
      after
        15_000 -> :ok
      end
    end

    if Map.get(state, "fail") do
      {:error, :boom}
    else
      step = String.to_integer(cursor || "0") + 1

      signal = %Signal{
        id: "stub-#{marker}-#{step}",
        title: "Stub #{marker} #{step}",
        content: "Stub content for #{marker}, pull #{step}.",
        node: "inbox",
        sn_ratio: 0.5,
        entities: [],
        l0_summary: "stub",
        l1_description: "stub",
        routed_to: []
      }

      {:ok, [signal], Integer.to_string(step)}
    end
  end
end
