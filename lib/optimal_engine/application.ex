defmodule OptimalEngine.Application do
  @moduledoc """
  OTP Application entry point for the Optimal Engine.

  Single unified supervision tree covering all four formerly-separate subsystems:
  the engine core, Knowledge (graph + OWL reasoning), Memory (episodic + cortex +
  learning), and Signal (classification + pub/sub + journal).

  Strategy: `:one_for_one` — each process is independent.

  Children are grouped below by origin for readability; at runtime they form a
  single flat supervision tree under `OptimalEngine.Supervisor`.
  """

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    OptimalEngine.Sizing.boot_started()

    children =
      base_children() ++ OptimalEngine.API.Endpoint.children()

    opts = [strategy: :one_for_one, name: OptimalEngine.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        OptimalEngine.Sizing.boot_finished()
        Logger.info("[OptimalEngine] Supervision tree started (#{inspect(pid)})")

        case OptimalEngine.Auth.Bootstrap.run() do
          :ok -> {:ok, pid}
          {:error, _} = err -> err
        end

      {:error, reason} = err ->
        Logger.error("[OptimalEngine] Failed to start: #{inspect(reason)}")
        err
    end
  end

  defp base_children do
    [
      # ── Observability (comes up first so every other child's metrics are captured) ─
      OptimalEngine.Telemetry,

      # ── Core engine (SQLite-backed, must start first) ─────────────────────
      OptimalEngine.Store,
      OptimalEngine.Pipeline.Router,
      OptimalEngine.Pipeline.Indexer,
      OptimalEngine.Retrieval.Search,
      OptimalEngine.Pipeline.Intake,
      OptimalEngine.Insight.Simulate,
      {Registry, keys: :unique, name: OptimalEngine.SessionRegistry},
      {DynamicSupervisor, name: OptimalEngine.SessionSupervisor, strategy: :one_for_one},

      # ── App data (collections API): change-feed wakeups, semantic indexing ─
      {Registry, keys: :duplicate, name: OptimalEngine.AppData.Registry},
      {Task.Supervisor, name: OptimalEngine.AppData.TaskSupervisor},

      # ── Knowledge subsystem (graph store + OWL 2 RL reasoner) ────────────
      # The registry is permanent. The default store is started as a permanent
      # named GenServer so Graph.assert_edge can find it via Registry lookup.
      # Hydration (SQLite edges -> ETS triples) runs asynchronously after boot
      # so it never delays the supervision tree startup.
      {Registry, keys: :unique, name: OptimalEngine.Knowledge.Registry},
      OptimalEngine.Knowledge.DefaultStore,

      # ── Memory subsystem (episodic, cortex, learning, session store) ─────
      {Registry, keys: :unique, name: OptimalEngine.Memory.SessionRegistry},
      OptimalEngine.Memory.Store.ETS,
      {DynamicSupervisor, name: OptimalEngine.Memory.SessionSupervisor, strategy: :one_for_one},
      {Task.Supervisor, name: OptimalEngine.Memory.EmbeddingTaskSupervisor},
      OptimalEngine.Memory.Cortex,
      OptimalEngine.Memory.Learning,
      OptimalEngine.Memory.Surfacer,
      OptimalEngine.Retrieval.L0Cache,

      # ── Signal subsystem (pub/sub broker + journal for causality tracking) ─
      {OptimalEngine.Signal.PubSub, name: OptimalEngine.Signal.PubSub},
      {OptimalEngine.Signal.Journal, name: OptimalEngine.Signal.Journal},

      # ── HTTP API rate limiter (owns the ETS bucket table) ────────────────
      OptimalEngine.API.RateLimiter,

      # ── Verified API key cache (bcrypt once per key and secret) ──────────
      OptimalEngine.Auth.KeyCache,

      # ── Wiki maintenance (periodic staleness scan + re-curation) ─────────
      OptimalEngine.Wiki.Scheduler,

      # ── Memory Core maintenance (periodic stale Context Package refresh) ──
      OptimalEngine.MemoryCore.ContextRefreshScheduler,

      # ── Memory Core promotion loop (autonomous Claim → Fact → Memory) ────
      OptimalEngine.MemoryCore.PromotionScheduler,

      # ── Reconstructive memory maintenance (projection + reviewed proposals) ──
      OptimalEngine.MemoryCore.ReconstructionScheduler,

      # ── Read-only data-quality drift snapshots ───────────────────────────
      OptimalEngine.DataQualityScheduler,

      # ── Durable metric history (Telemetry snapshots into metric_samples) ─
      OptimalEngine.Telemetry.HistorySampler,

      # ── Connector pull loop (periodic intake FEED from enabled connectors) ─
      OptimalEngine.Connectors.PullScheduler,

      # ── Replication: change capture triggers, sealing, peer sync ─────────
      OptimalEngine.Sync.Scheduler,

      # ── Viability: daily snapshots and the weekly System 3* audit ────────
      OptimalEngine.Viability.Scheduler,

      # ── Analyses as scheduled jobs (promises, audits, usage, retention) ──
      OptimalEngine.Analyses.Worker,

      # ── Reindex requests posted by writers after they change files ───────
      OptimalEngine.Reindex.Worker
    ]
  end

  @impl true
  def stop(_state) do
    Logger.info("[OptimalEngine] Application stopping")
    :ok
  end
end
