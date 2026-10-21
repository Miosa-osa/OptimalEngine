defmodule OptimalEngine.Connectors.PullScheduler do
  @moduledoc """
  Periodic connector pull loop, the engine's intake FEED.

  The scheduler runs the connectors table. On every tick it reads the
  tenant's enabled connector rows, starts the ones that are due, and drives
  the signals they emit through `Pipeline.Intake.process/2`, so external
  evidence flows into the lifecycle: Source → Signal → Claim → Fact → Memory.

  The Runner owns per-connector state (cursor advance on success,
  retry/backoff, disable-on-fatal, one run per connector at a time). This
  scheduler is the driver: it decides which connectors run and when, and
  supplies the `signal_sink` that turns each emitted `%Signal{}` into an
  intake call.

  ## What runs

    * Every enabled row of the scheduler's tenant, however it was
      registered: `mix optimal.connector register`, `POST /api/connectors`,
      or a config spec.
    * Config specs (`config :optimal_engine, :connectors, enabled: [...]`)
      only provision. A spec whose row does not exist yet is inserted,
      enabled, once; an existing row is never changed by a spec, so an
      operator's workspace, config and enabled state always win. A spec
      without a workspace is provisioned into the tenant's intake workspace
      (`OptimalEngine.Connectors.Rows.default_workspace/2`), never into an
      archived one; with no active intake workspace the spec is reported as
      a failed pull with `:no_intake_workspace` and nothing is inserted.
      Deleting a row a spec provisions brings it back on the next tick; to
      stop it, disable the row.

  ## When it runs

  The scheduler wakes every `:tick_ms`. A connector is due when its cadence
  (`OptimalEngine.Connectors.Cadence`) has passed since its last run
  started, or when it has never run. Due connectors start oldest first, at
  most `:max_concurrency` at a time, each in its own task, so one slow
  connector never holds up the others. A connector still running is never
  started again, and the Runner refuses a second run of the same connector
  from any caller, so runs never overlap.

  ## Failures

  A failed pull is logged as a warning naming the connector and the reason,
  kept as that connector's result in `status/1`, and recorded in
  `connector_runs`, where `GET /api/connectors` and `GET /api/metrics` show
  it as the connector's last error.

  ## Config (`config :optimal_engine, :pull_scheduler`)

    * `:enabled`         - start the loop? (default `true`)
    * `:boot_delay_ms`   - first tick delay (default 2 min)
    * `:tick_ms`         - how often due connectors are checked (default 1 min)
    * `:interval_ms`     - cadence for kinds without one of their own (default 24 h)
    * `:max_concurrency` - connectors pulling at once (default 3)
    * `:tenant_id`       - tenant scope (default `"default"`)

  ## Config (`config :optimal_engine, :connectors`)

    * `:enabled` - connector specs to provision. Each spec is a bare `kind`
      atom or a map `%{kind: :sources_folder, workspace_id: "...", config: %{...}}`.
      Default: `[:sources_folder]`.

  `run_once/1` is the synchronous, unit-testable entry point that needs no
  live process; `mix optimal.pull` uses it to run every enabled connector
  once.
  """

  use GenServer
  require Logger

  alias OptimalEngine.Connectors
  alias OptimalEngine.Connectors.{Cadence, Registry, Routing, Rows, Runner}
  alias OptimalEngine.Tenancy.Tenant

  @default_boot_delay_ms 2 * 60 * 1_000
  @default_tick_ms 60 * 1_000
  @default_interval_ms 24 * 60 * 60 * 1_000
  @default_max_concurrency 3
  @default_tenant_id "default"
  @default_connectors [:sources_folder]
  @task_supervisor OptimalEngine.Connectors.TaskSupervisor

  defstruct timer_ref: nil,
            last_run_at: nil,
            last_result: nil,
            enabled: true,
            boot_delay_ms: @default_boot_delay_ms,
            tick_ms: @default_tick_ms,
            interval_ms: @default_interval_ms,
            max_concurrency: @default_max_concurrency,
            tenant_id: @default_tenant_id,
            defaults: nil,
            run_opts: [],
            running: %{},
            attempted: %{},
            connectors: %{}

  @type connector_result :: %{
          connector_id: String.t(),
          kind: atom() | String.t(),
          workspace_id: String.t() | nil,
          status: :ok | :error | :skipped,
          signals: non_neg_integer(),
          reason: term() | nil
        }

  @type summary :: %{
          tenant_id: String.t(),
          connector_results: [connector_result()],
          ingested_count: non_neg_integer(),
          error_count: non_neg_integer()
        }

  # ── client API ─────────────────────────────────────────────────────────

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Current scheduler state: settings, connectors running now, and each connector's last result."
  @spec status(GenServer.server()) :: map()
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @doc "Run every enabled connector once, through the scheduler process, and wait for the summary."
  @spec force_run(keyword()) :: {:ok, summary()} | {:error, term()}
  def force_run(opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, {:force_run, opts}, :infinity)
  end

  @doc """
  Start one enabled connector now, in the scheduler's task pool, without
  waiting for it. Returns `{:ok, :started}`, `{:error, :already_running}`,
  or `{:error, :not_found}` for a connector that is missing, disabled, or in
  another tenant. Options: `:server`, `:tenant_id`.
  """
  @spec start_run(String.t(), keyword()) :: {:ok, :started} | {:error, term()}
  def start_run(connector_id, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, {:start_run, connector_id, Keyword.get(opts, :tenant_id)})
  end

  @doc "The cadence for connector kinds without a default of their own, in milliseconds."
  @spec default_interval_ms() :: pos_integer()
  def default_interval_ms do
    :optimal_engine
    |> Application.get_env(:pull_scheduler, [])
    |> Keyword.get(:interval_ms, @default_interval_ms)
  end

  @doc """
  Run one pull cycle without a live process: the unit-testable entry point.

  Options:
    * `:tenant_id`   - tenant scope (default "default")
    * `:connectors`  - run exactly these specs (each provisioned first when
      its row is missing) instead of every enabled row of the tenant
    * `:defaults`    - the specs to provision before running every enabled
      row (default: the configured `:connectors` list)
    * `:due_only`    - run only the connectors whose cadence has passed
      (default `false`: run every enabled connector once)
    * `:adapter`     - adapter module override (test seam, passed to Runner)
    * `:signal_sink` - override the default intake sink (test seam)
    * `:max_retries` - passed through to the Runner
  """
  @spec run_once(keyword()) :: {:ok, summary()}
  def run_once(opts \\ []) do
    tenant_id = Keyword.get(opts, :tenant_id, @default_tenant_id)
    {entries, failures} = plan(tenant_id, opts)
    now = DateTime.utc_now()

    entries =
      if Keyword.get(opts, :due_only, false),
        do: Enum.filter(entries, &due?(&1, now, %{})),
        else: entries

    results = failures ++ Enum.map(entries, &run_entry(&1, opts))
    Enum.each(results, &log_failure/1)

    {:ok, summarize(tenant_id, results)}
  end

  # ── planning ─────────────────────────────────────────────────────────────

  # Provisions the specs, then reads what to run from the connectors table.
  # Returns the runnable entries and a failed result for every spec that
  # could not be provisioned.
  defp plan(tenant_id, opts) do
    {specs, selection} =
      case Keyword.fetch(opts, :connectors) do
        {:ok, specs} ->
          {Enum.map(specs, &normalize_spec/1), :listed}

        :error ->
          {opts |> Keyword.get(:defaults, configured_connectors()) |> Enum.map(&normalize_spec/1),
           :all}
      end

    {ids, failures} = provision_all(specs, tenant_id)
    interval_ms = Keyword.get(opts, :interval_ms, default_interval_ms())

    entries =
      tenant_id
      |> Rows.schedulable(if(selection == :all, do: :all, else: ids))
      |> Enum.map(&entry(&1, interval_ms))

    {entries, failures}
  end

  defp provision_all(specs, tenant_id) do
    {ids, failures} =
      Enum.reduce(specs, {[], []}, fn spec, {ids, failures} ->
        id = spec[:id] || connector_id(spec.kind, tenant_id)

        case provision(spec, id, tenant_id) do
          :ok -> {[id | ids], failures}
          {:error, reason} -> {ids, [failed(id, spec.kind, spec[:workspace_id], reason) | failures]}
        end
      end)

    {Enum.reverse(ids), Enum.reverse(failures)}
  end

  defp provision(%{kind: kind} = spec, id, tenant_id) do
    with {:ok, _module} <- ensure_known(kind),
         {:ok, _created_or_exists} <-
           Rows.provision(%{
             id: id,
             kind: kind,
             tenant_id: tenant_id,
             workspace_id: spec[:workspace_id],
             config: spec[:config] || %{}
           }) do
      :ok
    end
  end

  defp ensure_known(kind) do
    case Registry.fetch(kind) do
      {:ok, module} -> {:ok, module}
      {:error, _} -> {:error, {:unknown_connector, kind}}
    end
  end

  defp entry(row, interval_ms) do
    %{
      id: row.id,
      kind: row.kind,
      workspace_id: row.workspace_id,
      cadence_ms: Cadence.interval_ms(row.config, row.kind, interval_ms),
      last_started_at: row.last_started_at
    }
  end

  # A connector whose run failed before it could open a run row (an adapter
  # that is gone, a row disabled meanwhile) has no start time in the table,
  # so the scheduler also remembers when it last tried, and the cadence holds
  # either way.
  defp due?(entry, now, attempted) do
    entry
    |> last_start(attempted)
    |> Cadence.due?(entry.cadence_ms, now)
  end

  defp last_start(entry, attempted) do
    case {entry.last_started_at, Map.get(attempted, entry.id)} do
      {nil, tried} -> tried
      {started, nil} -> started
      {started, tried} -> if DateTime.compare(started, tried) == :gt, do: started, else: tried
    end
  end

  # Never-run connectors first, then the longest-waiting.
  defp waiting_order(entry, attempted) do
    case last_start(entry, attempted) do
      nil -> {0, 0}
      at -> {1, DateTime.to_unix(at, :millisecond)}
    end
  end

  # ── per-connector ────────────────────────────────────────────────────────

  defp run_entry(entry, opts) do
    case Connectors.run(entry.id, runner_opts(opts)) do
      {:ok, run_result} ->
        result(
          entry,
          status_of(run_result),
          Map.get(run_result, :signals, 0),
          Map.get(run_result, :reason)
        )

      {:error, :already_running} ->
        result(entry, :skipped, 0, :already_running)

      {:error, reason} ->
        result(entry, :error, 0, reason)
    end
  end

  # `:disabled` is the Runner disabling the connector after a fatal error,
  # so it is a failed pull, not a quiet one.
  defp status_of(%{status: :success}), do: :ok
  defp status_of(_failed_or_disabled), do: :error

  defp result(entry, status, signals, reason) do
    %{
      connector_id: entry.id,
      kind: kind_atom(entry.kind),
      workspace_id: entry.workspace_id,
      status: status,
      signals: signals,
      reason: reason
    }
  end

  defp failed(id, kind, workspace_id, reason) do
    %{
      connector_id: id,
      kind: kind,
      workspace_id: workspace_id,
      status: :error,
      signals: 0,
      reason: reason
    }
  end

  defp summarize(tenant_id, results) do
    %{
      tenant_id: tenant_id,
      connector_results: results,
      ingested_count: results |> Enum.map(& &1.signals) |> Enum.sum(),
      error_count: Enum.count(results, &(&1.status == :error))
    }
  end

  defp log_failure(%{status: :error} = result) do
    Logger.warning(
      "[Connectors.PullScheduler] #{result.connector_id} (#{result.kind}) failed: #{inspect(result.reason)}"
    )
  end

  defp log_failure(_result), do: :ok

  defp runner_opts(opts) do
    sink = Keyword.get(opts, :signal_sink, intake_sink())

    [signal_sink: sink]
    |> maybe_put(:adapter, Keyword.get(opts, :adapter))
    |> maybe_put(:max_retries, Keyword.get(opts, :max_retries))
  end

  # The sink the Runner invokes with the connector's emitted signals + a
  # scope map carrying the workspace, the connector id and its config. Each
  # signal's body is re-driven through the full intake pipeline, attributed to
  # the workspace `Connectors.Routing` resolves for it, and what it implies
  # (open loops, outward evidence) is recorded alongside the ingest.
  @doc false
  def intake_sink do
    fn signals, scope ->
      Enum.each(signals, fn signal ->
        ingest_signal(signal, scope)
      end)

      :ok
    end
  end

  defp ingest_signal(signal, scope) do
    content = signal.content || ""

    if String.trim(content) == "" do
      :ok
    else
      tenant_id = Map.get(scope, :tenant_id) || Tenant.default_id()

      case Routing.intake_signal(tenant_id, signal, scope) do
        {:ok, _result} ->
          :ok

        {:error, reason} ->
          Logger.warning("[Connectors.PullScheduler] intake failed: #{inspect(reason)}")
      end
    end
  end

  # ── spec + config plumbing ───────────────────────────────────────────────

  defp configured_connectors do
    :optimal_engine
    |> Application.get_env(:connectors, [])
    |> Keyword.get(:enabled, @default_connectors)
  end

  defp normalize_spec(kind) when is_atom(kind), do: %{kind: kind}
  defp normalize_spec(%{kind: kind} = spec) when is_atom(kind), do: spec
  defp normalize_spec(%{"kind" => kind} = spec), do: Map.put(spec, :kind, String.to_atom(kind))

  defp connector_id(kind, tenant_id), do: "pull:#{tenant_id}:#{kind}"

  defp kind_atom(kind) when is_binary(kind) do
    case Registry.fetch_by_name(kind) do
      {:ok, module} -> module.kind()
      {:error, _} -> kind
    end
  end

  defp kind_atom(kind), do: kind

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  # ── GenServer ────────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    state = opts |> scheduler_config() |> struct_state()

    state =
      if state.enabled do
        Logger.info(
          "[Connectors.PullScheduler] started, first tick in #{state.boot_delay_ms}ms, " <>
            "then every #{state.tick_ms}ms"
        )

        schedule(state, state.boot_delay_ms)
      else
        Logger.info("[Connectors.PullScheduler] disabled")
        state
      end

    {:ok, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    running =
      Enum.map(state.running, fn {id, run} ->
        %{
          connector_id: id,
          kind: run.kind,
          workspace_id: run.workspace_id,
          started_at: run.started_at
        }
      end)

    {:reply,
     %{
       enabled: state.enabled,
       tenant_id: state.tenant_id,
       tick_ms: state.tick_ms,
       interval_ms: state.interval_ms,
       boot_delay_ms: state.boot_delay_ms,
       max_concurrency: state.max_concurrency,
       last_run_at: state.last_run_at,
       last_result: state.last_result,
       running: running,
       connectors: state.connectors
     }, state}
  end

  @impl true
  def handle_call({:force_run, opts}, _from, state) do
    opts =
      [tenant_id: state.tenant_id]
      |> Keyword.merge(state.run_opts)
      |> maybe_put(:defaults, state.defaults)
      |> Keyword.merge(Keyword.drop(opts, [:server]))

    {:ok, summary} = reply = run_once(opts)

    connectors =
      Map.merge(state.connectors, Map.new(summary.connector_results, &{&1.connector_id, &1}))

    {:reply, reply,
     %{state | last_run_at: DateTime.utc_now(), last_result: summary, connectors: connectors}}
  end

  @impl true
  def handle_call({:start_run, connector_id, tenant_id}, _from, state) do
    cond do
      Map.has_key?(state.running, connector_id) or Runner.running?(connector_id) ->
        {:reply, {:error, :already_running}, state}

      true ->
        case Rows.schedulable(tenant_id || state.tenant_id, [connector_id]) do
          [row] -> {:reply, {:ok, :started}, start_task(state, entry(row, state.interval_ms))}
          [] -> {:reply, {:error, :not_found}, state}
        end
    end
  end

  @impl true
  def handle_info(:tick, state) do
    state = state |> cancel_timer() |> dispatch()
    {:noreply, schedule(state, state.tick_ms)}
  end

  def handle_info({ref, result}, state) when is_reference(ref) do
    case pop_running(state, ref) do
      {nil, state} ->
        {:noreply, state}

      {_run, state} ->
        Process.demonitor(ref, [:flush])
        log_failure(result)
        {:noreply, put_result(state, result)}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case pop_running(state, ref) do
      {nil, state} ->
        {:noreply, state}

      {run, state} ->
        result = failed(run.id, kind_atom(run.kind), run.workspace_id, {:crashed, reason})
        log_failure(result)
        {:noreply, put_result(state, result)}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  # One tick: provision the specs, then start the due connectors that are not
  # already running, oldest first, up to the free slots. A store error is
  # logged and the loop keeps ticking.
  defp dispatch(state) do
    now = DateTime.utc_now()

    {entries, failures} =
      plan(state.tenant_id,
        defaults: state.defaults || configured_connectors(),
        interval_ms: state.interval_ms
      )

    state = Enum.reduce(failures, state, &note_failure/2)
    slots = max(state.max_concurrency - map_size(state.running), 0)

    entries
    |> Enum.reject(&(Map.has_key?(state.running, &1.id) or Runner.running?(&1.id)))
    |> Enum.filter(&due?(&1, now, state.attempted))
    |> Enum.sort_by(&waiting_order(&1, state.attempted))
    |> Enum.take(slots)
    |> Enum.reduce(%{state | last_run_at: now}, &start_task(&2, &1))
  rescue
    error ->
      Logger.warning("[Connectors.PullScheduler] tick failed: #{Exception.message(error)}")
      state
  end

  # A provisioning failure repeats every tick until someone fixes it, so it
  # is logged when it first appears or changes, not every minute.
  defp note_failure(result, state) do
    previous = Map.get(state.connectors, result.connector_id)

    unless previous && previous.status == :error && previous.reason == result.reason do
      log_failure(result)
    end

    put_result(state, result)
  end

  defp start_task(state, entry) do
    run_opts = state.run_opts
    task = Task.Supervisor.async_nolink(@task_supervisor, fn -> run_entry(entry, run_opts) end)
    started_at = DateTime.utc_now()

    run = %{
      id: entry.id,
      ref: task.ref,
      kind: entry.kind,
      workspace_id: entry.workspace_id,
      started_at: started_at
    }

    %{
      state
      | running: Map.put(state.running, entry.id, run),
        attempted: Map.put(state.attempted, entry.id, started_at)
    }
  end

  defp pop_running(state, ref) do
    case Enum.find(state.running, fn {_id, run} -> run.ref == ref end) do
      nil -> {nil, state}
      {id, run} -> {run, %{state | running: Map.delete(state.running, id)}}
    end
  end

  defp put_result(state, result) do
    %{state | connectors: Map.put(state.connectors, result.connector_id, result)}
  end

  defp schedule(state, delay_ms) do
    %{state | timer_ref: Process.send_after(self(), :tick, delay_ms)}
  end

  defp cancel_timer(%{timer_ref: nil} = state), do: state

  defp cancel_timer(%{timer_ref: ref} = state) do
    Process.cancel_timer(ref)
    %{state | timer_ref: nil}
  end

  defp scheduler_config(opts) do
    config = Application.get_env(:optimal_engine, :pull_scheduler, [])

    %{
      enabled: get(opts, config, :enabled, true),
      boot_delay_ms: get(opts, config, :boot_delay_ms, @default_boot_delay_ms),
      tick_ms: get(opts, config, :tick_ms, @default_tick_ms),
      interval_ms: get(opts, config, :interval_ms, @default_interval_ms),
      max_concurrency: get(opts, config, :max_concurrency, @default_max_concurrency),
      tenant_id: get(opts, config, :tenant_id, @default_tenant_id),
      defaults: Keyword.get(opts, :defaults),
      run_opts: Keyword.get(opts, :run_opts, [])
    }
  end

  defp get(opts, config, key, default) do
    Keyword.get(opts, key, Keyword.get(config, key, default))
  end

  defp struct_state(map), do: struct(__MODULE__, map)
end
