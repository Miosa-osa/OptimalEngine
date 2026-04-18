defmodule OptimalEngine.Telemetry do
  @moduledoc """
  Runtime metrics aggregator.

  The engine's pipeline emits `:telemetry.execute/3` events at each
  stage (`[:optimal_engine, :intake, :ingested]`, `[:search, :query]`,
  `[:retrieval, :rag, :ask]`, …). This module attaches handlers that
  fold those events into an in-memory counter/histogram table, so
  `Telemetry.snapshot/0` returns a machine-readable picture of engine
  health without pulling a StatsD / Prometheus dependency.

  ## Events

  Counters:
    * `[:optimal_engine, :intake, :ingested]`
    * `[:optimal_engine, :intake, :rejected]`
    * `[:optimal_engine, :search, :query]`
    * `[:optimal_engine, :retrieval, :rag]`
    * `[:optimal_engine, :connector, :run]`

  Histograms (p50/p95/p99):
    * `[:optimal_engine, :search, :latency_ms]`
    * `[:optimal_engine, :retrieval, :latency_ms]`
    * `[:optimal_engine, :connector, :latency_ms]`

  ## Using it

      OptimalEngine.Telemetry.start_link()  # idempotent; called by Application
      OptimalEngine.Telemetry.snapshot()    # returns a map of current values
      OptimalEngine.Telemetry.reset()       # test-only

  Prometheus/StatsD bridges live in Phase 11 — this module is the
  portable core they plug into.
  """

  use GenServer

  @counters ~w(
    optimal_engine.intake.ingested
    optimal_engine.intake.rejected
    optimal_engine.search.query
    optimal_engine.retrieval.rag
    optimal_engine.connector.run
  )a

  @histograms ~w(
    optimal_engine.search.latency_ms
    optimal_engine.retrieval.latency_ms
    optimal_engine.connector.latency_ms
  )a

  @histogram_window 1_000

  @type snapshot :: %{
          counters: %{atom() => non_neg_integer()},
          histograms: %{
            atom() => %{p50: number(), p95: number(), p99: number(), count: non_neg_integer()}
          },
          uptime_ms: non_neg_integer()
        }

  # ─── public api ──────────────────────────────────────────────────────────

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns the current metric snapshot."
  @spec snapshot() :: snapshot()
  def snapshot do
    GenServer.call(__MODULE__, :snapshot)
  end

  @doc "Clears every counter/histogram. Test-only."
  @spec reset() :: :ok
  def reset, do: GenServer.call(__MODULE__, :reset)

  @doc "Manually increment a counter — useful for code paths without telemetry events yet."
  @spec incr(atom(), non_neg_integer()) :: :ok
  def incr(metric, by \\ 1), do: GenServer.cast(__MODULE__, {:incr, metric, by})

  @doc "Manually record a histogram observation."
  @spec observe(atom(), number()) :: :ok
  def observe(metric, value) when is_number(value),
    do: GenServer.cast(__MODULE__, {:observe, metric, value})

  @doc "Declared counter metric names."
  @spec counter_names() :: [atom()]
  def counter_names, do: @counters

  @doc "Declared histogram metric names."
  @spec histogram_names() :: [atom()]
  def histogram_names, do: @histograms

  # ─── server ──────────────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    attach_handlers()

    {:ok,
     %{
       started_at: System.monotonic_time(:millisecond),
       counters: Map.new(@counters, &{&1, 0}),
       histograms: Map.new(@histograms, &{&1, []})
     }}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    snap = %{
      counters: state.counters,
      histograms: Map.new(state.histograms, fn {k, samples} -> {k, summarize(samples)} end),
      uptime_ms: System.monotonic_time(:millisecond) - state.started_at
    }

    {:reply, snap, state}
  end

  def handle_call(:reset, _from, state) do
    {:reply, :ok,
     %{state | counters: Map.new(@counters, &{&1, 0}), histograms: Map.new(@histograms, &{&1, []})}}
  end

  @impl true
  def handle_cast({:incr, metric, by}, state) do
    {:noreply, update_in(state.counters[metric], fn v -> (v || 0) + by end)}
  end

  def handle_cast({:observe, metric, value}, state) do
    {:noreply, bump_histogram(state, metric, value)}
  end

  @impl true
  def handle_info({:telemetry_event, metric, measurements}, state) do
    state =
      cond do
        metric in @counters ->
          update_in(state.counters[metric], fn v -> (v || 0) + (measurements[:count] || 1) end)

        metric in @histograms ->
          bump_histogram(state, metric, measurements[:value] || 0)

        true ->
          state
      end

    {:noreply, state}
  end

  # ─── private ─────────────────────────────────────────────────────────────

  defp bump_histogram(state, metric, value) do
    update_in(state.histograms[metric], fn samples ->
      [value | List.wrap(samples)] |> Enum.take(@histogram_window)
    end)
  end

  defp summarize([]), do: %{p50: 0, p95: 0, p99: 0, count: 0}

  defp summarize(samples) do
    sorted = Enum.sort(samples)
    n = length(sorted)
    %{p50: at(sorted, n, 0.50), p95: at(sorted, n, 0.95), p99: at(sorted, n, 0.99), count: n}
  end

  defp at(sorted, n, pct) do
    idx = max(0, min(n - 1, round(pct * (n - 1))))
    Enum.at(sorted, idx)
  end

  # Forward :telemetry events to the GenServer as messages. We don't
  # call from inside the handler to avoid blocking emitters.
  defp attach_handlers do
    events =
      Enum.map(@counters ++ @histograms, fn name ->
        name |> Atom.to_string() |> String.split(".") |> Enum.map(&String.to_atom/1)
      end)

    :telemetry.attach_many(
      "optimal-engine-telemetry",
      events,
      &__MODULE__.handle_event/4,
      nil
    )
  rescue
    _ -> :ok
  end

  @doc false
  def handle_event(event, measurements, _metadata, _config) do
    metric = event |> Enum.map_join(".", &Atom.to_string/1) |> String.to_atom()
    send(__MODULE__, {:telemetry_event, metric, measurements})
  end
end
