defmodule OptimalEngine.Analytics.Export do
  @moduledoc """
  Rebuilds one workspace's analytics datasets (`OptimalEngine.Analytics`) as
  Parquet files from the canonical store.

  Each dataset is read from the store a page at a time (keyset order, so the
  same statements run on SQLite and PostgreSQL), written as NDJSON into a
  fresh staging directory inside the workspace's directory, and converted by
  DuckDB (`COPY ... TO ... (FORMAT PARQUET)`), locked to that staging
  directory. Only when every dataset converted are the files moved into place,
  each by a rename, and the manifest rewritten; a failed export leaves the
  previous files as they were and removes its staging directory. DuckDB spills
  what does not fit in its memory limit into the staging directory too.

  The export always starts again from the store, so it is safe to run at any
  time and twice in a row. It runs as the `analytics_export` analysis
  (`OptimalEngine.Analyses`), scheduled once a day for every active workspace
  while `OPTIMAL_ANALYTICS_PATH` is set, and on demand through
  `POST /api/analyses/run`.
  """

  require Logger

  alias OptimalEngine.{Analytics, AtomicFile, Store}
  alias OptimalEngine.Storage.DuckDB

  @page 5_000
  @convert_timeout 120_000
  # An export queues for a duckdb slot (OptimalEngine.Analytics.Slots) rather
  # than failing while a query or another export holds it.
  @slot_wait 300_000

  # What each dataset's NDJSON holds, as DuckDB reads it, and how the rows
  # become the Parquet file.
  @columns %{
    "metrics" =>
      "{recorded_at: 'TIMESTAMP', metric_name: 'VARCHAR', metric_kind: 'VARCHAR', value: 'DOUBLE', labels: 'VARCHAR'}",
    "sync_runs" =>
      "{peer_id: 'VARCHAR', started_at: 'TIMESTAMP', finished_at: 'TIMESTAMP', status: 'VARCHAR', pulled: 'BIGINT', pushed: 'BIGINT', conflicts: 'BIGINT', gated: 'BIGINT'}",
    "ledger" =>
      "{occurred_at: 'TIMESTAMP', entity_type: 'VARCHAR', operation: 'VARCHAR', origin: 'VARCHAR'}",
    "usage" => "{ts: 'TIMESTAMP', kind: 'VARCHAR', latency_ms: 'BIGINT'}"
  }

  @transform %{
    "metrics" => "SELECT * FROM src ORDER BY recorded_at",
    "sync_runs" =>
      "SELECT *, date_diff('millisecond', started_at, finished_at)::BIGINT AS duration_ms FROM src ORDER BY started_at",
    "ledger" =>
      "SELECT date_trunc('hour', occurred_at) AS hour, entity_type, operation, origin, count(*)::BIGINT AS changes FROM src GROUP BY ALL ORDER BY hour, entity_type, operation, origin",
    "usage" =>
      "SELECT date_trunc('hour', ts) AS hour, kind, count(*)::BIGINT AS events, coalesce(sum(latency_ms), 0)::BIGINT AS latency_ms_sum, count(latency_ms)::BIGINT AS latency_ms_count, max(latency_ms)::BIGINT AS latency_ms_max FROM src GROUP BY ALL ORDER BY hour, kind"
  }

  @doc """
  Exports the workspace's datasets. Returns the directory, the time and each
  dataset's row count, or `:not_configured`, `:not_installed`,
  `:workspace_not_found` (not an active workspace of `tenant_id`), or
  `{:export_failed, %{dataset => reason}}`.
  """
  @spec run(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(tenant_id, workspace_id, opts \\ []) do
    with {:ok, config} <- DuckDB.config(opts),
         true <- config.executable != nil || {:error, :not_installed},
         :ok <- active_workspace(tenant_id, workspace_id) do
      dir = Analytics.workspace_dir(config.path, workspace_id)
      staging = Path.join(dir, ".staging-" <> random())
      File.mkdir_p!(staging)

      try do
        export(config, tenant_id, workspace_id, dir, staging)
      rescue
        # A purge beside the export (an archive, a discarded import) removed
        # the directory: the export has nothing to write into.
        error in [File.Error, File.RenameError, File.CopyError] ->
          Logger.warning(
            "[Analytics] export of #{workspace_id} lost its directory: #{error.reason}"
          )

          {:error, {:export_failed, :directory_removed}}
      after
        File.rm_rf(staging)
      end
    end
  end

  @doc """
  Exports the Engine-wide metrics: the samples the Engine records about itself
  (`OptimalEngine.Telemetry.History`, scope `"engine"`), into
  `OptimalEngine.Analytics.engine_dir/1`, a directory outside every
  workspace's. Only the metric names `OptimalEngine.Telemetry` declares are
  kept, and of their labels only `quantile`: a sample written under the
  Engine scope with any other name or label is left out, so nothing a
  workspace wrote can reach the file. Returns what `run/3` returns, or
  `:not_configured` and `:not_installed`.
  """
  @spec run_engine(keyword()) :: {:ok, map()} | {:error, term()}
  def run_engine(opts \\ []) do
    with {:ok, config} <- DuckDB.config(opts),
         true <- config.executable != nil || {:error, :not_installed} do
      dir = Analytics.engine_dir(config.path)
      staging = Path.join(dir, ".staging-" <> random())
      File.mkdir_p!(staging)

      try do
        export(config, ["metrics"], dir, staging, %{scope: "engine"}, fn dataset, ndjson ->
          write_engine_rows(dataset, ndjson)
        end)
      after
        File.rm_rf(staging)
      end
    end
  end

  defp export(config, tenant_id, workspace_id, dir, staging) do
    local = replica_id()

    export(config, Analytics.datasets(), dir, staging, %{workspace_id: workspace_id}, fn
      dataset, ndjson -> write_rows(dataset, tenant_id, workspace_id, local, ndjson)
    end)
  end

  defp export(config, datasets, dir, staging, manifest_scope, write) do
    results =
      Map.new(datasets, fn dataset ->
        {dataset, stage(config, dataset, staging, write)}
      end)

    failed = for {dataset, {:error, reason}} <- results, into: %{}, do: {dataset, reason}

    if failed == %{} do
      exported_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

      datasets =
        Map.new(results, fn {dataset, {:ok, rows}} ->
          File.rename!(
            Path.join(staging, dataset <> ".parquet"),
            Path.join(dir, dataset <> ".parquet")
          )

          {dataset, %{rows: rows}}
        end)

      manifest = Map.merge(manifest_scope, %{exported_at: exported_at, datasets: datasets})
      :ok = AtomicFile.write(Path.join(dir, Analytics.manifest_name()), Jason.encode!(manifest))
      {:ok, %{path: dir, exported_at: exported_at, datasets: datasets}}
    else
      Logger.warning(
        "[Analytics] export of #{manifest_scope[:workspace_id] || "the Engine"} failed for #{Enum.join(Map.keys(failed), ", ")}"
      )

      {:error, {:export_failed, failed}}
    end
  end

  # The dataset's rows into NDJSON, then DuckDB into Parquet. Returns the row count.
  defp stage(config, dataset, staging, write) do
    ndjson = Path.join(staging, dataset <> ".ndjson")
    parquet = Path.join(staging, dataset <> ".parquet")

    with :ok <- write.(dataset, ndjson),
         {:ok, _} <-
           Analytics.run_locked(config, staging, convert(dataset, ndjson, parquet),
             timeout: @convert_timeout,
             wait: @slot_wait
           ),
         {:ok, [%{"n" => rows}]} <-
           Analytics.run_locked(
             config,
             staging,
             "SELECT count(*) AS n FROM read_parquet(#{Analytics.literal(parquet)})",
             wait: @slot_wait
           ) do
      {:ok, rows}
    else
      {:ok, other} -> {:error, {:unexpected, other}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp convert(dataset, ndjson, parquet) do
    "COPY (WITH src AS (SELECT * FROM read_json(#{Analytics.literal(ndjson)}, " <>
      "format = 'newline_delimited', columns = #{@columns[dataset]})) #{@transform[dataset]}) " <>
      "TO #{Analytics.literal(parquet)} (FORMAT PARQUET)"
  end

  defp write_rows(dataset, tenant_id, workspace_id, local, path) do
    File.open!(path, [:write, :binary], fn file ->
      page(dataset, tenant_id, workspace_id, 0, fn rows ->
        IO.binwrite(file, Enum.map(rows, &[Jason.encode!(row(dataset, &1, local)), ?\n]))
      end)
    end)
  end

  # The Engine's own samples, kept to the declared metric names and the
  # quantile label (`run_engine/1`).
  defp write_engine_rows("metrics", path) do
    names = Analytics.engine_metric_names()

    File.open!(path, [:write, :binary], fn file ->
      engine_page(0, fn rows ->
        lines =
          for [_id, _at, name, _kind, _value, _labels] = row <- rows, name in names do
            [Jason.encode!(row("metrics", engine_labels(row), nil)), ?\n]
          end

        IO.binwrite(file, lines)
      end)
    end)
  end

  defp engine_labels([id, at, name, kind, value, labels]) do
    kept =
      case Jason.decode(labels || "{}") do
        {:ok, %{"quantile" => quantile}} when is_binary(quantile) -> %{"quantile" => quantile}
        _ -> %{}
      end

    [id, at, name, kind, value, Jason.encode!(kept)]
  end

  defp engine_page(cursor, fun) do
    case Store.raw_query(
           """
           SELECT id, recorded_at, metric_name, metric_kind, value, labels FROM metric_samples
           WHERE workspace_id = ?1 AND id > ?2 ORDER BY id LIMIT ?3
           """,
           [Analytics.engine_scope(), cursor, @page]
         ) do
      {:ok, []} ->
        :ok

      {:ok, rows} ->
        fun.(rows)
        if length(rows) < @page, do: :ok, else: engine_page(hd(List.last(rows)), fun)

      {:error, reason} ->
        {:error, {:source, reason}}
    end
  end

  # Reads the dataset's source a page at a time after `cursor`, handing each page to `fun`.
  defp page(dataset, tenant_id, workspace_id, cursor, fun) do
    case Store.raw_query(source(dataset), [tenant_id, workspace_id, cursor, @page]) do
      {:ok, []} ->
        :ok

      {:ok, rows} ->
        fun.(rows)

        if length(rows) < @page,
          do: :ok,
          else: page(dataset, tenant_id, workspace_id, hd(List.last(rows)), fun)

      {:error, reason} ->
        {:error, {:source, reason}}
    end
  end

  # The first column is the keyset cursor; it is never exported.
  defp source("metrics") do
    """
    SELECT id, recorded_at, metric_name, metric_kind, value, labels FROM metric_samples
    WHERE tenant_id = ?1 AND workspace_id = ?2 AND id > ?3 ORDER BY id LIMIT ?4
    """
  end

  defp source("sync_runs") do
    """
    SELECT id, peer_id, started_at, finished_at, status, pulled, pushed, conflicts, gated FROM sync_runs
    WHERE tenant_id = ?1 AND workspace_id = ?2 AND id > ?3 ORDER BY id LIMIT ?4
    """
  end

  defp source("ledger") do
    """
    SELECT sequence, occurred_at, entity_type, operation, device_id FROM sync_mutations
    WHERE tenant_id = ?1 AND workspace_id = ?2 AND sequence > ?3 ORDER BY sequence LIMIT ?4
    """
  end

  defp source("usage") do
    """
    SELECT id, ts, kind, latency_ms FROM events
    WHERE tenant_id = ?1 AND workspace_id = ?2 AND id > ?3 ORDER BY id LIMIT ?4
    """
  end

  defp row("metrics", [_id, at, name, kind, value, labels], _local),
    do: %{
      recorded_at: timestamp(at),
      metric_name: name,
      metric_kind: kind,
      value: value,
      labels: labels
    }

  defp row(
         "sync_runs",
         [_id, peer, started, finished, status, pulled, pushed, conflicts, gated],
         _
       ),
       do: %{
         peer_id: peer,
         started_at: timestamp(started),
         finished_at: timestamp(finished),
         status: status,
         pulled: pulled,
         pushed: pushed,
         conflicts: conflicts,
         gated: gated
       }

  defp row("ledger", [_sequence, at, table, operation, device], local),
    do: %{
      occurred_at: timestamp(at),
      entity_type: table,
      operation: operation,
      origin: if(device == local, do: "local", else: "peer")
    }

  defp row("usage", [_id, ts, kind, latency], _local),
    do: %{ts: timestamp(ts), kind: kind, latency_ms: latency}

  # Every store timestamp as `YYYY-MM-DD HH:MM:SS[.ffffff]` UTC, which DuckDB
  # reads as a TIMESTAMP; one it cannot read is left out rather than guessed.
  defp timestamp(%DateTime{} = dt), do: dt |> DateTime.to_naive() |> NaiveDateTime.to_string()
  defp timestamp(%NaiveDateTime{} = naive), do: NaiveDateTime.to_string(naive)

  defp timestamp(text) when is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, dt, _offset} ->
        timestamp(dt)

      _ ->
        case NaiveDateTime.from_iso8601(text) do
          {:ok, naive} -> timestamp(naive)
          _ -> nil
        end
    end
  end

  defp timestamp(_value), do: nil

  defp active_workspace(tenant_id, workspace_id) do
    case Store.raw_query(
           "SELECT 1 FROM workspaces WHERE id = ?1 AND tenant_id = ?2 AND status = 'active'",
           [workspace_id, tenant_id]
         ) do
      {:ok, [_ | _]} -> :ok
      _ -> {:error, :workspace_not_found}
    end
  end

  # This Engine's replica id, which marks a ledger change as made here; `nil`
  # while replication was never enabled.
  defp replica_id do
    case Store.raw_query("SELECT replica_id FROM sync_identity WHERE id = 1", []) do
      {:ok, [[id]]} -> id
      _ -> nil
    end
  end

  defp random, do: Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
end
