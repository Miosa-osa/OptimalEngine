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
  statement locked (`lockdown/1`): external access off, the only readable
  directory the workspace's own, extension loading off, the configuration
  locked so the statement cannot undo it, memory and threads bounded.
  """

  alias OptimalEngine.Storage.DuckDB

  @datasets ~w(metrics sync_runs ledger usage)
  @buckets ~w(hour day week month)
  @default_limit 200
  @max_limit 1_000
  @query_timeout 15_000
  @manifest "manifest.json"

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
    unless is_binary(workspace_id) and Regex.match?(@workspace_id, workspace_id) and
             not String.contains?(workspace_id, "..") do
      raise ArgumentError, "not a workspace id: #{inspect(workspace_id)}"
    end

    Path.join([Path.expand(root), "workspaces", String.replace(workspace_id, ":", "~")])
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
  `:not_installed`, `:not_exported` (no export has written the file yet), or
  what DuckDB reported.
  """
  @spec query(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def query(workspace_id, params) when is_map(params) do
    with {:ok, plan} <- plan(params),
         {:ok, config} <- DuckDB.config(),
         dir = workspace_dir(config.path, workspace_id),
         file = Path.join(dir, plan.dataset <> ".parquet"),
         true <- File.regular?(file) || {:error, :not_exported},
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
  memory and threads bounded; and the configuration locked, so nothing after
  it can turn any of this back on.
  """
  @spec lockdown(Path.t()) :: String.t()
  def lockdown(dir) do
    Enum.map_join(
      [
        "SET autoinstall_known_extensions = false",
        "SET autoload_known_extensions = false",
        "SET allowed_directories = [#{literal(Path.expand(dir) <> "/")}]",
        "SET enable_external_access = false",
        "SET memory_limit = '512MB'",
        "SET threads = 2",
        "SET lock_configuration = true"
      ],
      "",
      &(&1 <> "; ")
    )
  end

  @doc false
  # One statement of ours, run after the lockdown on `dir`.
  @spec run_locked(map(), Path.t(), String.t(), keyword()) :: {:ok, list()} | {:error, term()}
  def run_locked(config, dir, sql, opts \\ []) do
    if config.executable == nil,
      do: {:error, :not_installed},
      else: DuckDB.query(config, lockdown(dir) <> sql, opts)
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

  defp limit(value) do
    case Integer.parse(to_string(value)) do
      {n, ""} when n > 0 -> {:ok, min(n, @max_limit)}
      _ -> {:error, {:invalid_parameter, "limit", "a whole number above 0"}}
    end
  end

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
