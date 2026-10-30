defmodule OptimalEngine.TelemetryTest do
  use ExUnit.Case, async: false

  alias OptimalEngine.Telemetry

  setup do
    Telemetry.reset()
    :ok
  end

  test "snapshot/0 returns zero counters + empty histograms on a fresh reset" do
    snap = Telemetry.snapshot()
    assert snap.uptime_ms >= 0
    assert is_map(snap.counters)
    assert Enum.all?(Map.values(snap.counters), &(&1 == 0))

    assert Enum.all?(snap.histograms, fn {_k, v} ->
             v.p50 == 0 and v.count == 0
           end)
  end

  test "incr/2 increments a counter" do
    Telemetry.incr(:"optimal_engine.intake.ingested", 3)
    # Cast is async — use a sync snapshot call to flush the mailbox.
    snap = Telemetry.snapshot()
    assert snap.counters[:"optimal_engine.intake.ingested"] == 3
  end

  test "observe/2 feeds the histogram buffer" do
    for v <- [10, 20, 30, 40, 50, 60, 70, 80, 90, 100] do
      Telemetry.observe(:"optimal_engine.search.latency_ms", v)
    end

    snap = Telemetry.snapshot()
    h = snap.histograms[:"optimal_engine.search.latency_ms"]
    assert h.count == 10
    assert h.p50 >= 40 and h.p50 <= 60
    assert h.p95 >= 90
  end

  test "counter_names/0 + histogram_names/0 declare the known metrics" do
    assert :"optimal_engine.intake.ingested" in Telemetry.counter_names()
    assert :"optimal_engine.search.failed" in Telemetry.counter_names()
    assert :"optimal_engine.search.latency_ms" in Telemetry.histogram_names()
  end

  test "telemetry.execute events route to the aggregator" do
    :telemetry.execute([:optimal_engine, :search, :query], %{count: 1}, %{})

    # Give the cast a tick to arrive.
    Process.sleep(50)

    snap = Telemetry.snapshot()
    assert snap.counters[:"optimal_engine.search.query"] >= 1
  end

  test "a counter event with duration_ms also feeds its latency histogram" do
    :telemetry.execute([:optimal_engine, :search, :query], %{duration_ms: 12}, %{})
    :telemetry.execute([:optimal_engine, :retrieval, :rag], %{count: 1, duration_ms: 30}, %{})
    :telemetry.execute([:optimal_engine, :connector, :run], %{count: 1, duration_ms: 50}, %{})

    snap = Telemetry.snapshot()

    for name <- [:search, :retrieval, :connector] do
      assert snap.histograms[:"optimal_engine.#{name}.latency_ms"].count == 1
    end

    assert snap.counters[:"optimal_engine.retrieval.rag"] == 1
    assert snap.counters[:"optimal_engine.connector.run"] == 1
    assert snap.histograms[:"optimal_engine.retrieval.latency_ms"].p50 == 30
  end

  describe "emitters" do
    setup do
      id = "telemetry-test-#{System.unique_integer([:positive])}"
      test = self()

      :telemetry.attach_many(
        id,
        [
          [:optimal_engine, :retrieval, :rag],
          [:optimal_engine, :connector, :run],
          [:optimal_engine, :intake, :ingested],
          [:optimal_engine, :intake, :rejected]
        ],
        fn event, measurements, _meta, _ -> send(test, {:event, event, measurements}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(id) end)
    end

    test "RAG.ask emits a rag event with its duration" do
      OptimalEngine.Retrieval.RAG.ask("telemetry probe", skip_wiki: true)

      assert_receive {:event, [:optimal_engine, :retrieval, :rag], %{duration_ms: ms}}
      assert is_integer(ms)
      assert Telemetry.snapshot().counters[:"optimal_engine.retrieval.rag"] >= 1
    end

    test "a connector run emits a run event, even for one that fails" do
      assert {:error, _} = OptimalEngine.Connectors.Runner.run("no-such-connector")

      assert_receive {:event, [:optimal_engine, :connector, :run], %{duration_ms: ms}}
      assert is_integer(ms)
      assert Telemetry.snapshot().counters[:"optimal_engine.connector.run"] >= 1
    end

    test "intake emits an ingested or rejected event" do
      OptimalEngine.Pipeline.Intake.process("telemetry intake probe #{System.unique_integer()}")

      assert_receive {:event, [:optimal_engine, :intake, kind], _}
      assert kind in [:ingested, :rejected]
    end
  end
end
