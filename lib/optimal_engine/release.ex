defmodule OptimalEngine.Release do
  @moduledoc """
  Release-time entry points invoked from the release runtime.

  `mix release` builds the engine into a self-contained OTP tarball
  with its own ERTS. When that tarball is deployed, the normal
  Mix-driven boot flow (migrations, seeds, sanity checks) is gone —
  this module is what operators call instead:

      bin/optimal eval 'OptimalEngine.Release.migrate()'
      bin/optimal eval 'OptimalEngine.Release.preflight()'
      bin/optimal eval 'OptimalEngine.Release.backup("/backups/$(date +%F).db")'
      bin/optimal eval 'OptimalEngine.Release.graph_backfill()'
      bin/optimal eval 'OptimalEngine.Release.redact_ledger(dry_run: true)'

  Every function here must:
    * start only the apps it actually needs (not the full supervision tree)
    * return a status / exit cleanly for scripted use
    * never assume an interactive console — no IO.gets, no prompts
  """

  require Logger

  alias OptimalEngine.{Backup, Graph, Health, Store}

  @app :optimal_engine

  @doc """
  Apply any pending schema migrations. Safe to run on every boot —
  `Store.Migrations` is idempotent.
  """
  @spec migrate() :: :ok
  def migrate do
    load_app()
    {:ok, _} = Application.ensure_all_started(@app)

    # Store.init/1 already runs migrations during supervisor boot.
    # Log the result so the release operator has a trail.
    case Store.raw_query("SELECT COUNT(*) FROM schema_migrations", []) do
      {:ok, [[n]]} -> Logger.info("[Release] migrations ok — #{n} applied")
      other -> Logger.warning("[Release] migration check returned #{inspect(other)}")
    end

    :ok
  end

  @doc """
  Run a preflight sanity check — meant to exit non-zero and fail the
  deployment if anything critical is down.
  """
  @spec preflight() :: :ok | no_return()
  def preflight do
    load_app()
    {:ok, _} = Application.ensure_all_started(@app)

    result = Health.ready(skip: [:embedder])

    Enum.each(result.checks, fn {name, status} ->
      Logger.info("[Release] preflight #{name}: #{inspect(status)}")
    end)

    if result.ok? do
      :ok
    else
      Logger.error("[Release] preflight FAILED: #{inspect(result.checks)}")
      System.halt(1)
    end
  end

  @doc """
  Move connector credentials sealed into the database into OpenBao, with
  `OPTIMAL_CONNECTOR_CREDENTIAL_STORE=openbao` set. `dry_run: true` reports
  and changes nothing. See `OptimalEngine.Connectors.CredentialVault.Migration`.
  Exits non-zero when any connector was not migrated (its row is unchanged).
  """
  @spec migrate_connector_credentials(keyword()) :: :ok | no_return()
  def migrate_connector_credentials(opts \\ []) do
    load_app()
    {:ok, _} = Application.ensure_all_started(@app)

    case OptimalEngine.Connectors.CredentialVault.migrate(opts) do
      {:ok, report} ->
        Logger.info(
          "[Release] connector credentials#{if report.dry_run, do: " (dry run)", else: ""}: " <>
            "migrated #{inspect(report.migrated)}, would migrate #{inspect(report.would_migrate)}, " <>
            "already #{inspect(report.already_migrated)}, skipped #{inspect(report.skipped)}, " <>
            "failed #{inspect(report.failed)}"
        )

        if report.failed == [], do: :ok, else: System.halt(1)

      {:error, reason} ->
        Logger.error("[Release] connector credential migration refused: #{inspect(reason)}")
        System.halt(1)
    end
  end

  @doc "Create a backup file. See `OptimalEngine.Backup.create/1`."
  @spec backup(String.t()) :: :ok | no_return()
  def backup(path) when is_binary(path) do
    load_app()
    {:ok, _} = Application.ensure_all_started(@app)

    case Backup.create(path) do
      {:ok, result} ->
        Logger.info(
          "[Release] backup OK — #{result.size_bytes} bytes, " <>
            "#{result.rows_backed_up} rows, #{result.duration_ms}ms → #{result.target}"
        )

        :ok

      {:error, reason} ->
        Logger.error("[Release] backup failed: #{inspect(reason)}")
        System.halt(1)
    end
  end

  @doc """
  Write the graph edges of every indexed context and claim
  (`OptimalEngine.Graph.backfill/1`), the one run the upgrade that created
  `graph_edges` needs; afterwards `GET /api/maintenance/graph` reads
  `"backfill_needed": false`. Safe to run again: it adds only missing edges.
  Takes `Graph.backfill/1`'s options (`workspace_id:` limits it to one
  workspace).

  It boots the Engine application, HTTP listener and triple store included,
  so stop the running Engine service first. Exits non-zero when an edge write
  failed, and the run is then not recorded.
  """
  @spec graph_backfill(keyword()) :: :ok | no_return()
  def graph_backfill(opts \\ []) do
    load_app()
    {:ok, _} = Application.ensure_all_started(@app)

    case Graph.backfill(opts) do
      {:ok, %{failed_edges: 0} = result} ->
        Logger.info(
          "[Release] graph backfill OK: #{result.contexts} contexts, #{result.claims} claims, " <>
            "edges #{result.edges_before} -> #{result.edges_after}" <>
            if(result.recorded, do: "", else: " (not recorded: the claim pass was skipped)")
        )

        :ok

      {:ok, result} ->
        Logger.error(
          "[Release] graph backfill incomplete: #{result.failed_edges} edge writes failed; " <>
            "run it again"
        )

        System.halt(1)

      {:error, reason} ->
        Logger.error("[Release] graph backfill failed: #{inspect(reason)}")
        System.halt(1)
    end
  end

  @doc """
  Redacts erased content from the replication ledger, once, for an Engine that
  erased rows before it redacted its ledger (`OptimalEngine.Sync.Redaction.backfill/1`).
  `dry_run: true` changes nothing. Prints the report as JSON (counts only, no
  ids or content) and returns it. Safe to run again: a second run finds
  nothing.
  """
  @spec redact_ledger(keyword()) :: map()
  def redact_ledger(opts \\ []) do
    load_app()
    {:ok, _} = Application.ensure_all_started(@app)

    {:ok, report} =
      OptimalEngine.Sync.Redaction.backfill(dry_run: Keyword.get(opts, :dry_run, false))

    Logger.info(
      "[Release] ledger redaction #{if report.dry_run, do: "dry run", else: "done"}: " <>
        "#{Enum.reduce(Map.values(report.exposed), 0, &(&1.rows + &2))} rows exposed"
    )

    IO.puts(Jason.encode!(report, pretty: true))
    report
  end

  @doc "Current health status — exits 0 when :up, non-zero otherwise."
  @spec healthcheck() :: :ok | no_return()
  def healthcheck do
    load_app()
    {:ok, _} = Application.ensure_all_started(@app)

    case Health.status() do
      :up ->
        IO.puts("up")
        :ok

      :degraded ->
        IO.puts("degraded")
        System.halt(2)

      :down ->
        IO.puts("down")
        System.halt(1)
    end
  end

  # ─── private ─────────────────────────────────────────────────────────────

  # `load_app/0` guarantees the app spec is on the path even before
  # the supervisor starts. No-op once the app is loaded.
  defp load_app do
    Application.load(@app)
  rescue
    _ -> :ok
  end
end
