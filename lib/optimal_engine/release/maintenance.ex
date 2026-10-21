defmodule OptimalEngine.Release.Maintenance do
  @moduledoc """
  `bin/optimal maintenance <task> [args]`: the Engine's maintenance tasks in a
  release, which has no Mix to run `mix optimal.<task>`.

  `rel/env.sh.eex` turns the command into
  `bin/optimal eval "OptimalEngine.Release.Maintenance.main()" <task> [args]`
  in a new VM with the HTTP API off. Each task runs the code of its Mix task
  (the `main/1` of `Mix.Tasks.Optimal.<Task>`), so a release and a checkout run
  the same work with the same flags and output.

  A task either needs the Engine stopped or needs it running, and the command
  checks that before doing anything:

    * a task that opens the store refuses while an Engine is up, because the
      Engine is the store's only writer: something listening on the API port
      (`OPTIMAL_API_PORT`, default 4200, on 127.0.0.1 or `OPTIMAL_API_INTERFACE`)
      or the release node (`RELEASE_NODE`) registered with epmd counts as up.
      It then starts the Engine in this VM with the HTTP API and the background
      loops (analyses, connector pulls, sync, backups, sweeps) off, runs the
      task, and stops it again;
    * a task that talks to an Engine over HTTP refuses when nothing answers at
      its target, and starts nothing in this VM.

  Exit codes: 0 the task succeeded, 1 it failed, 64 usage (no task or an
  unknown one), 78 refused because the Engine was in the wrong state; a
  refusal changes nothing.
  """

  require Logger

  @app :optimal_engine

  # Task, the Mix task whose main/1 does the work, the Engine state it needs,
  # and the line `help` prints. The order is the one operators see.
  @tasks [
    {"migrate", Mix.Tasks.Optimal.Migrate, :stopped,
     "apply pending schema migrations; --status lists them"},
    {"health", Mix.Tasks.Optimal.Health, :stopped,
     "store diagnostics; exits 1 on a critical finding"},
    {"embed_backfill", Mix.Tasks.Optimal.EmbedBackfill, :stopped,
     "embed chunks with no embedding (--workspace, --limit, --batch, --dry-run)"},
    {"graph_backfill", Mix.Tasks.Optimal.GraphBackfill, :stopped,
     "write the graph edges of contexts and claims (--workspace, --batch, --no-claims)"},
    {"facts", Mix.Tasks.Optimal.Facts, :stopped, "list or show Memory Core facts"},
    {"claims", Mix.Tasks.Optimal.Claims, :stopped,
     "list, show, promote or reject Memory Core claims"},
    {"conformance", Mix.Tasks.Optimal.Conformance, :running,
     "check a running Engine over HTTP (--url, --key or OPTIMAL_ENGINE_API_KEY)"}
  ]

  # Background work a maintenance VM must not start: it would race the task,
  # or be cut off when the VM stops (an offsite backup half uploaded).
  @quiet_intervals ~w(analyses_interval_ms reindex_interval_ms maintenance_interval_ms
                      embedding_sweep_interval_ms viability_interval_ms sync_interval_ms
                      offsite_backup_interval_ms)a
  @quiet_flags ~w(data_quality_scheduler_enabled reconstruction_scheduler_enabled)a
  @quiet_schedulers ~w(pull_scheduler context_refresh_scheduler promotion_scheduler
                       metric_history)a

  @ex_usage 64
  @ex_config 78

  @doc "The maintenance tasks, in order."
  @spec tasks() :: [String.t()]
  def tasks, do: Enum.map(@tasks, &elem(&1, 0))

  @doc "Entry point for `bin/optimal maintenance`: runs the task and halts with its exit code."
  @spec main() :: no_return()
  def main, do: System.halt(run(System.argv()))

  @doc """
  Runs `[task | args]` and returns the exit code (see the module doc).

  Options, for tests: `:engine` (a zero-argument function returning
  `:stopped` or `{:running, evidence}`), `:answers?` (a one-argument function
  taking a URL), and `:start` and `:stop` (zero-argument functions that bring
  the Engine up and down in this VM).
  """
  @spec run([String.t()], keyword()) :: non_neg_integer()
  def run(argv, opts \\ [])

  def run([help], _opts) when help in ["help", "--help", "-h"] do
    IO.puts(usage())
    0
  end

  def run([], _opts) do
    IO.puts(:stderr, usage())
    @ex_usage
  end

  def run([task | args], opts) do
    case List.keyfind(@tasks, task, 0) do
      {^task, module, :stopped, _} ->
        run_stopped(task, module, args, opts)

      {^task, module, :running, _} ->
        run_running(task, module, args, opts)

      nil ->
        usage_error(
          "unknown maintenance task '#{task}'; the tasks are: #{Enum.join(tasks(), ", ")}"
        )
    end
  end

  # ── the two kinds of task ───────────────────────────────────────────────

  defp run_stopped(task, module, args, opts) do
    engine = Keyword.get(opts, :engine, &engine/0)

    case engine.() do
      {:running, evidence} ->
        refuse(
          "'#{task}' opens the store, so it runs only while the Engine is stopped, " <>
            "and an Engine is up (#{evidence}). Stop it first"
        )

      :stopped ->
        start = Keyword.get(opts, :start, &start/0)
        stop = Keyword.get(opts, :stop, &stop/0)

        case start.() do
          :ok ->
            try do
              invoke(task, module, args)
            after
              stop.()
            end

          {:error, reason} ->
            fail("the Engine could not start for '#{task}': #{inspect(reason)}")
        end
    end
  end

  defp run_running(task, module, args, opts) do
    answers? = Keyword.get(opts, :answers?, &answers?/1)
    url = module.target_url(args)

    if answers?.(url) do
      invoke(task, module, args)
    else
      refuse(
        "'#{task}' checks a running Engine over HTTP, and nothing answers at " <>
          "#{url}. Start the Engine, or pass --url"
      )
    end
  end

  # A Mix task's main/1 reports failure with {:error, message} or Mix.raise;
  # anything else it returns is success.
  defp invoke(task, module, args) do
    case module.main(args) do
      {:error, message} when is_binary(message) -> fail("#{task}: #{message}")
      {:error, reason} -> fail("#{task}: #{inspect(reason)}")
      _ -> 0
    end
  rescue
    error ->
      message =
        if error.__struct__ == Mix.Error,
          do: Exception.message(error),
          else: Exception.format(:error, error, __STACKTRACE__)

      fail("#{task}: #{message}")
  end

  defp refuse(message) do
    IO.puts(:stderr, "maintenance: #{message}; nothing was changed")
    @ex_config
  end

  defp usage_error(message) do
    IO.puts(:stderr, "maintenance: #{message}")
    @ex_usage
  end

  defp fail(message) do
    IO.puts(:stderr, "maintenance: #{message}")
    1
  end

  # ── the Engine in this VM ───────────────────────────────────────────────

  @doc false
  # The application environment a maintenance VM starts with: `env` with the
  # HTTP API and the background loops turned off.
  @spec quiet(keyword()) :: keyword()
  def quiet(env) do
    env = Keyword.put(env, :api, Keyword.put(Keyword.get(env, :api, []), :enabled, false))
    env = Enum.reduce(@quiet_intervals, env, &Keyword.put(&2, &1, 0))
    env = Enum.reduce(@quiet_flags, env, &Keyword.put(&2, &1, false))

    Enum.reduce(@quiet_schedulers, env, fn key, env ->
      Keyword.put(env, key, Keyword.put(Keyword.get(env, key, []), :enabled, false))
    end)
  end

  defp start do
    Logger.configure(level: :warning)
    _ = Application.load(@app)

    for {key, value} <- quiet(Application.get_all_env(@app)),
        do: Application.put_env(@app, key, value)

    case Application.ensure_all_started(@app) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp stop do
    _ = Application.stop(@app)
    :ok
  end

  # ── is an Engine up? ────────────────────────────────────────────────────

  @doc false
  @spec engine() :: :stopped | {:running, String.t()}
  def engine do
    host = probe_host(System.get_env("OPTIMAL_API_INTERFACE"))
    port = port(System.get_env("OPTIMAL_API_PORT"), 4200)
    node = System.get_env("RELEASE_NODE", "optimal") |> String.split("@") |> hd()

    cond do
      listening?(host, port) -> {:running, "something is listening on #{host}:#{port}"}
      registered?(node) -> {:running, "the Erlang node #{node} is registered with epmd"}
      true -> :stopped
    end
  end

  defp answers?(url) do
    uri = URI.parse(url)
    is_binary(uri.host) and is_integer(uri.port) and listening?(uri.host, uri.port)
  end

  defp probe_host(interface) when interface in [nil, "", "0.0.0.0", "::"], do: "127.0.0.1"
  defp probe_host(interface), do: interface

  defp port(value, default) do
    case Integer.parse(to_string(value)) do
      {n, ""} when n > 0 -> n
      _ -> default
    end
  end

  defp listening?(host, port) do
    case :gen_tcp.connect(String.to_charlist(host), port, [:binary, active: false], 1_000) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true

      {:error, _} ->
        false
    end
  end

  defp registered?(node) do
    case :erl_epmd.names() do
      {:ok, names} -> Enum.any?(names, fn {name, _port} -> to_string(name) == node end)
      _ -> false
    end
  end

  defp usage do
    rows = fn state ->
      for {task, _module, ^state, line} <- @tasks,
          do: "  #{String.pad_trailing(task, 16)} #{line}"
    end

    Enum.join(
      [
        "Usage: bin/optimal maintenance <task> [args]",
        "",
        "Runs one Engine maintenance task in a new VM that never serves the HTTP API.",
        "",
        "With the Engine stopped (the task opens the store):"
      ] ++
        rows.(:stopped) ++
        ["", "With the Engine running (the task talks to it over HTTP):"] ++
        rows.(:running) ++
        [
          "",
          "Exit codes: 0 ok, 1 the task failed, 64 usage, 78 refused (the Engine is " <>
            "in the wrong state; nothing was changed)."
        ],
      "\n"
    )
  end
end
