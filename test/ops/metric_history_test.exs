defmodule OptimalEngine.Telemetry.HistoryTest do
  use ExUnit.Case, async: false

  alias OptimalEngine.Store
  alias OptimalEngine.Telemetry.{History, HistorySampler}

  setup do
    %{scope: "metrics-#{System.unique_integer([:positive])}"}
  end

  test "records and reads a labelled sample", %{scope: scope} do
    assert {:ok, sample} =
             History.record(scope, "queue.depth", 7, kind: "gauge", labels: %{"queue" => "ingest"})

    assert sample.workspace_id == scope
    assert sample.value == 7.0
    assert sample.metric_kind == "gauge"
    assert sample.labels == %{"queue" => "ingest"}

    assert {:ok, [listed]} = History.list(scope, metric_name: "queue.depth")
    assert listed.id == sample.id
    assert {:ok, %{id: id}} = History.latest(scope, "queue.depth")
    assert id == sample.id
  end

  test "lists newest first and filters by name and time", %{scope: scope} do
    {:ok, a} = History.record(scope, "a.metric", 1)
    {:ok, b} = History.record(scope, "a.metric", 2)
    {:ok, _} = History.record(scope, "b.metric", 3)

    assert {:ok, [first, second]} = History.list(scope, metric_name: "a.metric")
    assert [first.id, second.id] == [b.id, a.id]

    future = DateTime.add(DateTime.utc_now(), 3_600, :second)
    assert {:ok, []} = History.list(scope, since: future)
    assert {:ok, []} = History.list("another-#{scope}")
  end

  test "persists the live Telemetry snapshot", %{scope: scope} do
    OptimalEngine.Telemetry.incr(:"optimal_engine.search.query", 3)
    OptimalEngine.Telemetry.observe(:"optimal_engine.search.latency_ms", 12)
    _ = OptimalEngine.Telemetry.snapshot()

    assert {:ok, written} = History.snapshot_telemetry(scope)
    assert written > 0

    assert {:ok, %{metric_kind: "counter", value: queries}} =
             History.latest(scope, "optimal_engine.search.query")

    assert queries >= 3

    assert {:ok, quantiles} = History.list(scope, metric_name: "optimal_engine.search.latency_ms")
    assert quantiles |> Enum.map(& &1.labels["quantile"]) |> Enum.sort() == ["0.5", "0.95", "0.99"]
  end

  test "rejects malformed samples without writing", %{scope: scope} do
    assert {:error, :workspace_required} = History.record("", "x", 1)
    assert {:error, {:invalid_metric_name, "bad name"}} = History.record(scope, "bad name", 1)
    assert {:error, {:invalid_value, "1"}} = History.record(scope, "x", "1")
    assert {:error, {:invalid_kind, "summary"}} = History.record(scope, "x", 1, kind: "summary")
    assert {:error, :invalid_labels} = History.record(scope, "x", 1, labels: %{"a" => %{}})
    assert {:ok, []} = History.list(scope)
  end

  test "prune enforces retention", %{scope: scope} do
    {:ok, old} = History.record(scope, "old.metric", 1)

    :ok =
      Store.raw_execute(
        "UPDATE metric_samples SET recorded_at = datetime('now', '-40 days') WHERE id = ?1",
        [old.id]
      )

    {:ok, fresh} = History.record(scope, "fresh.metric", 1)

    assert {:ok, pruned} = History.prune(30 * 86_400)
    assert pruned >= 1
    assert {:ok, [remaining]} = History.list(scope)
    assert remaining.id == fresh.id
  end

  test "the supervised sampler writes engine-scoped samples on demand" do
    assert {:ok, %{written: written}} = HistorySampler.sample_now()
    assert written > 0

    assert {:ok, [_ | _]} =
             History.list(History.engine_scope(), metric_name: "optimal_engine.uptime_ms")
  end
end
