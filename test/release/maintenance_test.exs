defmodule OptimalEngine.Release.MaintenanceTest do
  @moduledoc """
  `bin/optimal maintenance <task> [args]` dispatches to the Mix tasks' code,
  passes the arguments through, refuses a task when the Engine is in the wrong
  state, and reports failures with an exit code. The Engine in these tests is
  the one the test run already started, so `:start` and `:stop` are no-ops.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias OptimalEngine.Release.Maintenance
  alias OptimalEngine.Store

  # The Engine is stopped, and starting and stopping it here is a no-op.
  defp stopped, do: [engine: fn -> :stopped end, start: fn -> :ok end, stop: fn -> :ok end]

  setup do
    n = System.unique_integer([:positive])
    %{n: n, ws: "maint-release-#{n}"}
  end

  test "the tasks are the ones a managed Engine runs, each with a Mix-free entry point" do
    assert Maintenance.tasks() ==
             ~w(migrate health embed_backfill graph_backfill facts claims conformance)

    for module <- [
          Mix.Tasks.Optimal.Migrate,
          Mix.Tasks.Optimal.Health,
          Mix.Tasks.Optimal.EmbedBackfill,
          Mix.Tasks.Optimal.GraphBackfill,
          Mix.Tasks.Optimal.Facts,
          Mix.Tasks.Optimal.Claims,
          Mix.Tasks.Optimal.Conformance
        ] do
      assert Code.ensure_loaded?(module)
      assert function_exported?(module, :main, 1), "#{inspect(module)} has no main/1"
    end
  end

  test "an unknown task exits 64 and lists the tasks" do
    err = capture_io(:stderr, fn -> assert Maintenance.run(["vacuum"], stopped()) == 64 end)
    assert err =~ "unknown maintenance task 'vacuum'"
    for task <- Maintenance.tasks(), do: assert(err =~ task)
  end

  test "no task prints the usage and exits 64; help prints it and exits 0" do
    err = capture_io(:stderr, fn -> assert Maintenance.run([], stopped()) == 64 end)
    assert err =~ "Usage: bin/optimal maintenance <task> [args]"

    out = capture_io(fn -> assert Maintenance.run(["help"], stopped()) == 0 end)
    assert out =~ "With the Engine stopped"
    assert out =~ "With the Engine running"
    for task <- Maintenance.tasks(), do: assert(out =~ task)
  end

  test "a known task runs with its arguments", ctx do
    chunk!(ctx.ws, "maint-release-chunk-#{ctx.n}")

    out =
      capture_io(fn ->
        assert Maintenance.run(
                 ["embed_backfill", "--workspace", ctx.ws, "--batch", "7", "--dry-run"],
                 stopped()
               ) == 0
      end)

    assert out =~ "Chunks missing embeddings: 1"
    assert out =~ "Backfilling: 1 (batch=7, dry-run)"
    assert {:ok, [[0]]} = embeddings_in(ctx.ws)
  end

  test "graph_backfill writes the workspace's edges", ctx do
    entity = "maint-release-entity-#{ctx.n}"

    {:ok, _} =
      Store.raw_query(
        "INSERT INTO contexts (id, workspace_id, type, title, content, node, entities, created_at) VALUES (?1, ?2, 'signal', 'Release', 'Body', 'inbox', ?3, datetime('now'))",
        ["maint-release-ctx-#{ctx.n}", ctx.ws, Jason.encode!([entity])]
      )

    out =
      capture_io(fn ->
        args = ["graph_backfill", "--workspace", ctx.ws, "--no-claims"]
        assert Maintenance.run(args, stopped()) == 0
      end)

    assert out =~ "Contexts: 1  Claims: 0"

    assert {:ok, [[1]]} =
             Store.raw_query(
               "SELECT COUNT(*) FROM graph_edges WHERE source_id = ?1 AND workspace_id = ?2",
               [entity, ctx.ws]
             )
  end

  test "migrate --status reports the schema" do
    out = capture_io(fn -> assert Maintenance.run(["migrate", "--status"], stopped()) == 0 end)
    assert out =~ "Migration status"
  end

  test "a task that opens the store refuses while an Engine is up, and starts nothing", ctx do
    chunk!(ctx.ws, "maint-release-busy-#{ctx.n}")
    parent = self()

    opts = [
      engine: fn -> {:running, "something is listening on 127.0.0.1:4200"} end,
      start: fn ->
        send(parent, :started)
        :ok
      end,
      stop: fn -> :ok end
    ]

    err =
      capture_io(:stderr, fn ->
        assert Maintenance.run(["embed_backfill", "--workspace", ctx.ws], opts) == 78
      end)

    assert err =~ "'embed_backfill' opens the store"
    assert err =~ "something is listening on 127.0.0.1:4200"
    assert err =~ "nothing was changed"
    refute_received :started
  end

  test "a task that talks to a running Engine refuses when nothing answers at its target" do
    parent = self()

    answers? = fn url ->
      send(parent, {:probed, url})
      false
    end

    err =
      capture_io(:stderr, fn ->
        assert Maintenance.run(
                 ["conformance", "--url", "http://127.0.0.1:9", "--key", "k"],
                 answers?: answers?
               ) == 78
      end)

    assert_received {:probed, "http://127.0.0.1:9"}
    assert err =~ "'conformance' checks a running Engine over HTTP"
    assert err =~ "nothing answers at http://127.0.0.1:9"
  end

  test "a task that fails exits 1 with its message", ctx do
    err =
      capture_io(:stderr, fn ->
        assert Maintenance.run(["facts", "get", "no-such-fact-#{ctx.n}"], stopped()) == 1
      end)

    assert err =~ "facts: Fact not found: no-such-fact-#{ctx.n}"

    # The test Engine's embedder is a closed port, so the backfill stops.
    chunk!(ctx.ws, "maint-release-unembedded-#{ctx.n}")

    err =
      capture_io(:stderr, fn ->
        capture_io(fn ->
          assert Maintenance.run(["embed_backfill", "--workspace", ctx.ws], stopped()) == 1
        end)
      end)

    assert err =~ "embed_backfill: stopped: the embedder is unavailable"
  end

  test "a maintenance VM starts with the HTTP API and the background loops off" do
    env =
      Maintenance.quiet(
        api: [enabled: true, port: 4200],
        analyses_interval_ms: 300_000,
        pull_scheduler: [enabled: true, tick_ms: 60_000],
        db_path: "/data/.optimal/engine.db"
      )

    assert env[:api][:enabled] == false
    assert env[:api][:port] == 4200
    assert env[:analyses_interval_ms] == 0
    assert env[:maintenance_interval_ms] == 0
    assert env[:embedding_sweep_interval_ms] == 0
    assert env[:offsite_backup_interval_ms] == 0
    assert env[:pull_scheduler][:enabled] == false
    assert env[:pull_scheduler][:tick_ms] == 60_000
    assert env[:promotion_scheduler] == [enabled: false]
    assert env[:data_quality_scheduler_enabled] == false
    assert env[:db_path] == "/data/.optimal/engine.db"
  end

  test "an Engine is up when its API port answers or its node is registered", ctx do
    previous =
      Map.new(~w(OPTIMAL_API_PORT OPTIMAL_API_INTERFACE RELEASE_NODE), &{&1, System.get_env(&1)})

    on_exit(fn ->
      for {name, value} <- previous,
          do: if(value, do: System.put_env(name, value), else: System.delete_env(name))
    end)

    {:ok, listener} = :gen_tcp.listen(0, ip: {127, 0, 0, 1}, active: false)
    {:ok, port} = :inet.port(listener)
    System.delete_env("OPTIMAL_API_INTERFACE")
    System.put_env("OPTIMAL_API_PORT", Integer.to_string(port))
    System.put_env("RELEASE_NODE", "maint-release-#{ctx.n}")

    assert Maintenance.engine() == {:running, "something is listening on 127.0.0.1:#{port}"}

    :ok = :gen_tcp.close(listener)
    assert Maintenance.engine() == :stopped
  end

  defp chunk!(workspace, id) do
    {:ok, _} =
      Store.raw_query(
        "INSERT INTO chunks (id, tenant_id, signal_id, scale, text, modality, workspace_id) VALUES (?1, 'default', ?2, 'chunk', 'Maintenance chunk', 'text', ?3)",
        [id, "signal-" <> id, workspace]
      )

    id
  end

  defp embeddings_in(workspace),
    do:
      Store.raw_query("SELECT COUNT(*) FROM chunk_embeddings WHERE workspace_id = ?1", [workspace])
end
