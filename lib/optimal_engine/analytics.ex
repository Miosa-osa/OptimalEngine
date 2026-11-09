defmodule OptimalEngine.Analytics do
  @moduledoc """
  Workspace analytics on DuckDB and Parquet (`OptimalEngine.Storage.DuckDB`).

  `OptimalEngine.Analytics.Export` rebuilds a workspace's datasets from the
  canonical store as Parquet files under `OPTIMAL_ANALYTICS_PATH`, one
  directory per workspace (`workspace_dir/2`). The files are a projection:
  deleting them loses nothing, and the next export writes them again.

  | Dataset | Rows | From |
  | --- | --- | --- |
  | `metrics` | one per metric sample: `recorded_at`, `metric_name`, `metric_kind`, `value`, `labels` | `metric_samples` |
  | `sync_runs` | one per peer cycle: `peer_id`, `started_at`, `finished_at`, `status`, `pulled`, `pushed`, `conflicts`, `gated`, `duration_ms` | `sync_runs` |
  | `ledger` | changes per hour: `hour`, `entity_type`, `operation`, `origin` (`local` or `peer`), `changes` | `sync_mutations` |
  | `usage` | events per hour: `hour`, `kind`, `events`, `latency_ms_sum`, `latency_ms_count`, `latency_ms_max` | `events` |

  No payload, entity id, message, principal or target leaves the store: the
  ledger and usage datasets are counts.

  `query/2` answers one fixed question per dataset, parameterized and
  validated (`questions/0`); callers never send SQL. DuckDB runs every
  statement locked (`lockdown/2`): external access off, the only readable
  directory the workspace's own, extension loading off, the configuration
  locked so the statement cannot undo it, memory and threads bounded, and a
  spill directory inside the workspace's own. At most
  `OPTIMAL_ANALYTICS_MAX_PROCESSES` duckdb processes run at once
  (`OptimalEngine.Analytics.Slots`).
  """

  alias OptimalEngine.Analytics.Slots
  alias OptimalEngine.Storage.DuckDB
  alias OptimalEngine.Store
  alias OptimalEngine.Telemetry
  alias OptimalEngine.Telemetry.History

  @datasets ~w(metrics sync_runs ledger usage)
  @buckets ~w(hour day week month)
  @default_limit 200
  @max_limit 1_000
  @query_timeout 15_000
  @manifest "manifest.json"
  @memory_limit "512MB"

  # The column each dataset's question buckets by.
  @time_column %{
    "metrics" => "recorded_at",
    "sync_runs" => "started_at",
    "ledger" => "hour",
    "usage" => "hour"
  }

  # The filters each question takes, and what a value must look like.
  @filters %{
    "metrics" => [{"metric", "metric_name", ~r/\A[a-zA-Z_][a-zA-Z0-9_.:]{0,199}\z/}],
    "sync_runs" => [{"peer", "peer_id", ~r/\A[A-Za-z0-9][A-Za-z0-9._:-]{0,127}\z/}],
    "ledger" => [
      {"table", "entity_type", ~r/\A[a-z_][a-z0-9_]{0,63}\z/},
      {"origin", "origin", ~r/\A(local|peer)\z/}
    ],
    "usage" => [{"kind", "kind", ~r/\A[A-Za-z0-9_][A-Za-z0-9_.:-]{0,127}\z/}]
  }

  # Workspace ids are plain identifiers (OptimalEngine.API.WorkspaceAuthPlug).
  @workspace_id ~r/\A[A-Za-z0-9][A-Za-z0-9._-]{0,127}(:[A-Za-z0-9][A-Za-z0-9._-]{0,127})?\z/

  @doc "The datasets an export writes and a query reads."
  @spec datasets() :: [String.t()]
  def datasets, do: @datasets

  @doc "The most rows one query returns."
  @spec max_limit() :: pos_integer()
  def max_limit, do: @max_limit

  @doc "The question each dataset answers and the parameters it takes, for clients."
  @spec questions() :: map()
  def questions do
    Map.new(@datasets, fn dataset ->
      {dataset,
       %{
         answers: answer(dataset),
         bucket: @buckets,
         parameters: ["from", "to", "bucket", "limit" | Enum.map(@filters[dataset], &elem(&1, 0))]
       }}
    end)
  end

  defp answer("metrics"),
    do: "samples, avg, min and max of each metric per bucket"

  defp answer("sync_runs"),
    do:
      "runs per peer and bucket: ok, error and paused counts, changes pulled, pushed, conflicts, gated, average duration"

  defp answer("ledger"),
    do: "changes per bucket by table, operation and origin"

  defp answer("usage"),
    do: "events per bucket by kind, with average and maximum latency"

  @doc """
  The directory a workspace's files live in: `<root>/workspaces/<id>`, the
  `:` between tenant and slug written as `~` (which no id holds). Raises on an
  id that is not a plain workspace identifier, so an id can never name a path.
  """
  @spec workspace_dir(Path.t(), String.t()) :: Path.t()
  def workspace_dir(root, workspace_id) do
    unless workspace_id?(workspace_id) do
      raise ArgumentError, "not a workspace id: #{inspect(workspace_id)}"
    end

    Path.join([Path.expand(root), "workspaces", String.replace(workspace_id, ":", "~")])
  end

  @doc """
  The directory the Engine-wide metrics live in: `<root>/engine`, beside
  `<root>/workspaces` and never inside it, so no workspace's query (locked to
  its own directory) can read it, and no workspace id can name it.
  """
  @spec engine_dir(Path.t()) :: Path.t()
  def engine_dir(root), do: Path.join(Path.expand(root), "engine")

  @doc "The scope the Engine's own samples are recorded under (`OptimalEngine.Telemetry.History`)."
  @spec engine_scope() :: String.t()
  def engine_scope, do: History.engine_scope()

  @doc """
  The metric names the Engine-wide export keeps: the counters and histograms
  `OptimalEngine.Telemetry` declares, each histogram's `.count`, and the
  uptime. Fixed in code, so a sample can never carry a workspace into the
  file by its name.
  """
  @spec engine_metric_names() :: [String.t()]
  def engine_metric_names do
    counters = Enum.map(Telemetry.counter_names(), &Atom.to_string/1)
    histograms = Enum.map(Telemetry.histogram_names(), &Atom.to_string/1)

    counters ++
      histograms ++ Enum.map(histograms, &(&1 <> ".count")) ++ ["optimal_engine.uptime_ms"]
  end

  @doc "What the Engine-wide metrics hold, as `status/1` says it of a workspace."
  @spec engine_status() :: map()
  def engine_status do
    case DuckDB.config() do
      {:ok, config} ->
        manifest = read_manifest(engine_dir(config.path))

        %{
          configured: true,
          executable_present: config.executable != nil,
          exported_at: manifest["exported_at"],
          datasets: Map.get(manifest, "datasets", %{}),
          questions: Map.take(questions(), ["metrics"])
        }

      {:error, _} ->
        %{
          configured: false,
          executable_present: System.find_executable(DuckDB.executable()) != nil,
          exported_at: nil,
          datasets: %{},
          questions: Map.take(questions(), ["metrics"])
        }
    end
  end

  @doc """
  Answers the `metrics` question over the Engine-wide metrics, locked to
  `engine_dir/1`, with the parameters and errors of `query/2`. Any other
  dataset is `{:invalid_parameter, "dataset", ...}`: the Engine export holds
  metrics only.
  """
  @spec query_engine(map()) :: {:ok, map()} | {:error, term()}
  def query_engine(params) when is_map(params) do
    with :ok <- engine_dataset(params["dataset"]),
         {:ok, plan} <- plan(params),
         {:ok, config} <- DuckDB.config() do
      run_question(config, engine_dir(config.path), plan)
    end
  end

  defp engine_dataset("metrics"), do: :ok
  defp engine_dataset(_other), do: {:error, {:invalid_parameter, "dataset", "metrics"}}

  @doc """
  Removes the analytics directory of every workspace that is not active now:
  archived, moved, renamed away, or gone from the store by any path (a hard
  delete, a discarded import, a purge that failed). Run with the daily
  Engine-wide export (`analytics_engine_export`), so a removal path that does
  not purge the files itself is covered within a day. Never touches the
  Engine-wide directory. Returns how many directories went.
  """
  @spec prune_removed() :: {:ok, %{removed: non_neg_integer()}} | {:error, term()}
  def prune_removed do
    with {:ok, config} <- DuckDB.config() do
      root = Path.join(Path.expand(config.path), "workspaces")

      names =
        case File.ls(root) do
          {:ok, names} -> names
          {:error, _} -> []
        end

      removed =
        Enum.count(names, fn name ->
          id = String.replace(name, "~", ":")

          if active_workspace?(id),
            do: false,
            else: match?({:ok, _}, File.rm_rf(Path.join(root, name)))
        end)

      {:ok, %{removed: removed}}
    else
      {:error, :not_configured} -> {:ok, %{removed: 0}}
      other -> other
    end
  end

  defp active_workspace?(id) do
    workspace_id?(id) and
      match?(
        {:ok, [_ | _]},
        Store.raw_query("SELECT 1 FROM workspaces WHERE id = ?1 AND status = 'active'", [id])
      )
  end

  @doc """
  What the workspace's analytics hold: whether the provider is configured,
  when the files were last exported and how many rows each dataset holds.
  Never the server's path.
  """
  @spec status(String.t()) :: map()
  def status(workspace_id) do
    case DuckDB.config() do
      {:ok, config} ->
        manifest = read_manifest(workspace_dir(config.path, workspace_id))

        %{
          configured: true,
          executable_present: config.executable != nil,
          exported_at: manifest["exported_at"],
          datasets: Map.get(manifest, "datasets", %{}),
          questions: questions()
        }

      {:error, _} ->
        %{
          configured: false,
          executable_present: System.find_executable(DuckDB.executable()) != nil,
          exported_at: nil,
          datasets: %{},
          questions: questions()
        }
    end
  end

  @doc """
  Answers the dataset's question for a workspace. `params` are the request's
  string parameters: `dataset` (required), `bucket` (`hour`, `day`, `week`,
  `month`; default `day`), `from` and `to` (ISO-8601 dates or times, `from`
  inclusive, `to` exclusive), `limit` (default #{@default_limit}, at most
  #{@max_limit}) and the dataset's filters.

  Errors: `{:invalid_parameter, name, why}`, `:not_configured`,
  `:not_installed`, `:not_exported` (no export has written the file yet),
  `:busy` (every duckdb slot is taken, `OptimalEngine.Analytics.Slots`), or
  what DuckDB reported.
  """
  @spec query(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def query(workspace_id, params) when is_map(params) do
    with {:ok, plan} <- plan(params),
         {:ok, config} <- DuckDB.config() do
      run_question(config, workspace_dir(config.path, workspace_id), plan)
    end
  end

  defp run_question(config, dir, plan) do
    file = Path.join(dir, plan.dataset <> ".parquet")

    with true <- File.regular?(file) || {:error, :not_exported},
         {:ok, rows} <- run_locked(config, dir, sql(plan, file), timeout: @query_timeout) do
      {:ok,
       %{
         dataset: plan.dataset,
         bucket: plan.bucket,
         from: plan.from,
         to: plan.to,
         limit: plan.limit,
         exported_at: read_manifest(dir)["exported_at"],
         rows: rows
       }}
    end
  end

  @doc """
  The statements that lock a DuckDB process to `dir` before a statement of
  ours runs. External access off with `dir` the only allowed directory, so no
  other file is read or written; autoloading and installing extensions off;
  memory and threads bounded, with what does not fit in memory spilled to
  `temp` (a directory inside `dir`, set while external access is still on,
  as DuckDB requires); and the configuration locked, so nothing after it can
  turn any of this back on.
  """
  @spec lockdown(Path.t(), Path.t()) :: String.t()
  def lockdown(dir, temp) do
    Enum.map_join(
      [
        "SET autoinstall_known_extensions = false",
        "SET autoload_known_extensions = false",
        "SET allowed_directories = [#{literal(Path.expand(dir) <> "/")}]",
        "SET temp_directory = #{literal(temp)}",
        "SET enable_external_access = false",
        "SET memory_limit = '#{@memory_limit}'",
        "SET threads = 2",
        "SET lock_configuration = true"
      ],
      "",
      &(&1 <> "; ")
    )
  end

  @doc false
  # One statement of ours, run after the lockdown on `dir`, holding one of the
  # capped duckdb slots (`OptimalEngine.Analytics.Slots`): `:wait` is how long
  # to queue for one (0, the default, refuses at once with `:busy`). The
  # statement spills into a fresh directory inside `dir`, removed after it.
  # Its name starts with `~` so it sorts after every file DuckDB is asked
  # for: DuckDB 1.3 checks a path only against the allowed directory sorted
  # just before it, so a spill directory such as `dir/duckdb-tmp` would hide
  # `dir/metrics.parquet` and refuse it.
  @spec run_locked(map(), Path.t(), String.t(), keyword()) :: {:ok, list()} | {:error, term()}
  def run_locked(config, dir, sql, opts \\ []) do
    if config.executable == nil do
      {:error, :not_installed}
    else
      Slots.run(Keyword.get(opts, :wait, 0), fn ->
        temp =
          Path.join(
            Path.expand(dir),
            "~duckdb-tmp-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
          )

        try do
          DuckDB.query(config, lockdown(dir, temp) <> sql, Keyword.delete(opts, :wait))
        after
          File.rm_rf(temp)
        end
      end)
    end
  end

  @doc """
  Removes a workspace's analytics files, for a workspace that is archived or
  whose rows moved to another id. Nothing configured, or an id that is not a
  workspace identifier, has nothing to remove.
  """
  @spec purge_workspace(String.t()) :: :ok | {:error, term()}
  def purge_workspace(workspace_id) do
    with {:ok, config} <- DuckDB.config(),
         true <- workspace_id?(workspace_id) do
      case File.rm_rf(workspace_dir(config.path, workspace_id)) do
        {:ok, _} -> :ok
        {:error, reason, _file} -> {:error, {:analytics_purge_failed, reason}}
      end
    else
      _nothing -> :ok
    end
  end

  @doc "True when `value` is a plain workspace identifier (`workspace_dir/2` takes it)."
  @spec workspace_id?(term()) :: boolean()
  def workspace_id?(value) do
    is_binary(value) and Regex.match?(@workspace_id, value) and not String.contains?(value, "..")
  end

  @doc "A SQL string literal: a quote is doubled, so the text cannot end the literal."
  @spec literal(String.t()) :: String.t()
  def literal(text) when is_binary(text), do: "'" <> String.replace(text, "'", "''") <> "'"

  @doc false
  @spec read_manifest(Path.t()) :: map()
  def read_manifest(dir) do
    with {:ok, text} <- File.read(Path.join(dir, @manifest)),
         {:ok, %{} = manifest} <- Jason.decode(text) do
      manifest
    else
      _ -> %{}
    end
  end

  @doc false
  def manifest_name, do: @manifest

  # -- the plan: every parameter validated into a value we write ourselves -----

  defp plan(params) do
    with {:ok, dataset} <- dataset(params["dataset"]),
         :ok <- no_foreign_filters(dataset, params),
         {:ok, bucket} <- one_of("bucket", params["bucket"], @buckets, "day"),
         {:ok, from} <- time("from", params["from"]),
         {:ok, to} <- time("to", params["to"]),
         {:ok, limit} <- limit(params["limit"]),
         {:ok, filters} <- filters(dataset, params) do
      {:ok, %{dataset: dataset, bucket: bucket, from: from, to: to, limit: limit, filters: filters}}
    end
  end

  defp dataset(value) when value in @datasets, do: {:ok, value}

  defp dataset(_value),
    do: {:error, {:invalid_parameter, "dataset", "one of " <> Enum.join(@datasets, ", ")}}

  # A filter of another dataset is refused rather than ignored, so a caller
  # never reads an answer it thinks was filtered.
  defp no_foreign_filters(dataset, params) do
    own = Enum.map(@filters[dataset], &elem(&1, 0))

    foreign =
      for {_dataset, filters} <- @filters,
          {name, _column, _re} <- filters,
          name not in own,
          params[name] not in [nil, ""],
          do: name

    case foreign do
      [] -> :ok
      [name | _] -> {:error, {:invalid_parameter, name, "not a filter of #{dataset}"}}
    end
  end

  defp one_of(_name, value, _allowed, default) when value in [nil, ""], do: {:ok, default}

  defp one_of(name, value, allowed, _default) do
    if value in allowed,
      do: {:ok, value},
      else: {:error, {:invalid_parameter, name, "one of " <> Enum.join(allowed, ", ")}}
  end

  # A date or a time, written back as a UTC `YYYY-MM-DD HH:MM:SS` we format ourselves.
  defp time(_name, value) when value in [nil, ""], do: {:ok, nil}

  defp time(name, value) when is_binary(value) do
    parsed =
      case DateTime.from_iso8601(value) do
        {:ok, dt, _offset} ->
          {:ok, DateTime.to_naive(dt)}

        _ ->
          case NaiveDateTime.from_iso8601(value) do
            {:ok, naive} ->
              {:ok, naive}

            _ ->
              case Date.from_iso8601(value) do
                {:ok, date} -> {:ok, NaiveDateTime.new!(date, ~T[00:00:00])}
                _ -> :error
              end
          end
      end

    case parsed do
      {:ok, naive} ->
        {:ok, naive |> NaiveDateTime.truncate(:second) |> NaiveDateTime.to_string()}

      :error ->
        {:error, {:invalid_parameter, name, "an ISO-8601 date or time"}}
    end
  end

  defp time(name, _value), do: {:error, {:invalid_parameter, name, "an ISO-8601 date or time"}}

  defp limit(value) when value in [nil, ""], do: {:ok, @default_limit}

  defp limit(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} when n > 0 -> {:ok, min(n, @max_limit)}
      _ -> {:error, {:invalid_parameter, "limit", "a whole number above 0"}}
    end
  end

  defp limit(value) when is_integer(value) and value > 0, do: {:ok, min(value, @max_limit)}
  defp limit(_value), do: {:error, {:invalid_parameter, "limit", "a whole number above 0"}}

  defp filters(dataset, params) do
    Enum.reduce_while(@filters[dataset], {:ok, []}, fn {name, column, re}, {:ok, acc} ->
      case params[name] do
        value when value in [nil, ""] ->
          {:cont, {:ok, acc}}

        value when is_binary(value) ->
          if Regex.match?(re, value),
            do: {:cont, {:ok, [{column, value} | acc]}},
            else: {:halt, {:error, {:invalid_parameter, name, "not a valid #{name}"}}}

        _ ->
          {:halt, {:error, {:invalid_parameter, name, "not a valid #{name}"}}}
      end
    end)
  end

  # -- the questions -------------------------------------------------------------

  defp sql(plan, file) do
    time = @time_column[plan.dataset]
    bucket = "strftime(date_trunc(#{literal(plan.bucket)}, #{time}), '%Y-%m-%dT%H:%M:%SZ')"

    where =
      Enum.map(plan.filters, fn {column, value} -> "#{column} = #{literal(value)}" end) ++
        if(plan.from, do: ["#{time} >= TIMESTAMP #{literal(plan.from)}"], else: []) ++
        if(plan.to, do: ["#{time} < TIMESTAMP #{literal(plan.to)}"], else: [])

    where_sql = if where == [], do: "", else: " WHERE " <> Enum.join(where, " AND ")
    {select, group, order} = shape(plan.dataset)

    "SELECT #{bucket} AS bucket, #{select} FROM read_parquet(#{literal(file)})#{where_sql} " <>
      "GROUP BY #{group} ORDER BY bucket DESC, #{order} LIMIT #{plan.limit}"
  end

  defp shape("metrics") do
    {"metric_name, count(*)::BIGINT AS samples, avg(value) AS avg, min(value) AS min, max(value) AS max",
     "bucket, metric_name", "metric_name"}
  end

  defp shape("sync_runs") do
    {"peer_id, count(*)::BIGINT AS runs, count_if(status = 'ok')::BIGINT AS ok, " <>
       "count_if(status = 'error')::BIGINT AS error, count_if(status = 'paused')::BIGINT AS paused, " <>
       "sum(pulled)::BIGINT AS pulled, sum(pushed)::BIGINT AS pushed, sum(conflicts)::BIGINT AS conflicts, " <>
       "sum(gated)::BIGINT AS gated, round(avg(duration_ms))::BIGINT AS avg_duration_ms",
     "bucket, peer_id", "peer_id"}
  end

  defp shape("ledger") do
    {"entity_type, operation, origin, sum(changes)::BIGINT AS changes",
     "bucket, entity_type, operation, origin", "entity_type, operation, origin"}
  end

  defp shape("usage") do
    {"kind, sum(events)::BIGINT AS events, " <>
       "CASE WHEN sum(latency_ms_count) > 0 THEN round(sum(latency_ms_sum) / sum(latency_ms_count), 1) END AS avg_latency_ms, " <>
       "max(latency_ms_max) AS max_latency_ms", "bucket, kind", "kind"}
  end
end
