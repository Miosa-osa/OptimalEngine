defmodule OptimalEngine.Telemetry.History do
  @moduledoc """
  Durable metric history on the `metric_samples` table.

  `OptimalEngine.Telemetry` keeps live counters and histograms in memory, so
  they reset on restart. This module persists point-in-time samples so
  operators can read measurements across restarts:

    * `record/4` writes one sample for a workspace
    * `snapshot_telemetry/1` persists the live Telemetry snapshot (counters as
      `counter` samples, histogram quantiles and counts as `gauge` samples
      labelled by `quantile`) in one transaction
    * `list/2` and `latest/2` read samples back, newest first
    * `prune/1` enforces retention

  Engine-wide samples use the `"engine"` scope; workspace measurements use
  the workspace id. Labels must be a flat map of scalar values.
  """

  alias OptimalEngine.Store
  alias OptimalEngine.Telemetry

  @engine_scope "engine"
  @kinds ~w(counter gauge histogram)
  @name_pattern ~r/^[a-zA-Z_][a-zA-Z0-9_.:]*$/

  @type sample :: %{
          id: pos_integer(),
          tenant_id: String.t(),
          workspace_id: String.t(),
          metric_name: String.t(),
          metric_kind: String.t(),
          value: float(),
          labels: map(),
          recorded_at: String.t()
        }

  @doc "Scope used for engine-wide samples."
  @spec engine_scope() :: String.t()
  def engine_scope, do: @engine_scope

  @doc """
  Record one sample. Options: `:kind` (`"counter" | "gauge" | "histogram"`,
  default `"gauge"`), `:labels`, and `:tenant_id` (default `"default"`).
  """
  @spec record(String.t(), String.t(), number(), keyword()) :: {:ok, sample()} | {:error, term()}
  def record(workspace_id, metric_name, value, opts \\ []) do
    with {:ok, row} <- build_row(workspace_id, metric_name, value, opts),
         {:ok, [[id]]} <-
           Store.raw_query(
             """
             INSERT INTO metric_samples (tenant_id, workspace_id, metric_name, metric_kind, value, labels)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6)
             RETURNING id
             """,
             row
           ) do
      get(id)
    end
  end

  @doc """
  Persist the current `OptimalEngine.Telemetry` snapshot under `scope`.
  Returns the number of samples written.
  """
  @spec snapshot_telemetry(String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def snapshot_telemetry(scope \\ @engine_scope) do
    snapshot = Telemetry.snapshot()

    counters =
      Enum.map(snapshot.counters, fn {name, value} -> {to_string(name), value, "counter", %{}} end)

    histograms =
      Enum.flat_map(snapshot.histograms, fn {name, summary} ->
        name = to_string(name)

        [
          {name, summary.p50, "gauge", %{"quantile" => "0.5"}},
          {name, summary.p95, "gauge", %{"quantile" => "0.95"}},
          {name, summary.p99, "gauge", %{"quantile" => "0.99"}},
          {name <> ".count", summary.count, "counter", %{}}
        ]
      end)

    uptime = [{"optimal_engine.uptime_ms", snapshot.uptime_ms, "gauge", %{}}]

    with {:ok, rows} <- build_rows(scope, counters ++ histograms ++ uptime) do
      Store.transaction(fn txn ->
        Enum.reduce_while(rows, {:ok, 0}, fn row, {:ok, count} ->
          case Store.txn_execute(
                 txn,
                 "INSERT INTO metric_samples (tenant_id, workspace_id, metric_name, metric_kind, value, labels) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
                 row
               ) do
            {:ok, 1} -> {:cont, {:ok, count + 1}}
            {:ok, _} -> {:halt, {:error, :insert_failed}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
      end)
    end
  end

  @doc "List samples newest first. Options: `:metric_name`, `:since` (`DateTime`), `:limit`."
  @spec list(String.t(), keyword()) :: {:ok, [sample()]} | {:error, term()}
  def list(workspace_id, opts \\ []) when is_binary(workspace_id) do
    limit = opts |> Keyword.get(:limit, 100) |> max(1) |> min(10_000)

    {filters, params} =
      [
        {Keyword.get(opts, :metric_name), "metric_name = ?"},
        {since(opts), "recorded_at >= ?"}
      ]
      |> Enum.reject(fn {value, _sql} -> is_nil(value) end)
      |> Enum.with_index(3)
      |> Enum.map_reduce([], fn {{value, sql}, index}, acc ->
        {" AND " <> sql <> Integer.to_string(index), acc ++ [value]}
      end)

    sql = """
    SELECT id, tenant_id, workspace_id, metric_name, metric_kind, value, labels, recorded_at
    FROM metric_samples
    WHERE workspace_id = ?1#{Enum.join(filters)}
    ORDER BY recorded_at DESC, id DESC
    LIMIT ?2
    """

    with {:ok, rows} <- Store.raw_query(sql, [workspace_id, limit | params]) do
      {:ok, Enum.map(rows, &sample_from_row/1)}
    end
  end

  @doc "Most recent sample of `metric_name` in `workspace_id`."
  @spec latest(String.t(), String.t()) :: {:ok, sample()} | {:error, :not_found | term()}
  def latest(workspace_id, metric_name) do
    case list(workspace_id, metric_name: metric_name, limit: 1) do
      {:ok, [sample]} -> {:ok, sample}
      {:ok, []} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Delete samples older than `max_age_seconds`. Returns the number deleted."
  @spec prune(non_neg_integer()) :: {:ok, non_neg_integer()} | {:error, term()}
  def prune(max_age_seconds) when is_integer(max_age_seconds) and max_age_seconds >= 0 do
    Store.transaction(fn txn ->
      Store.txn_execute(
        txn,
        "DELETE FROM metric_samples WHERE recorded_at < datetime('now', '-' || ?1 || ' seconds')",
        [max_age_seconds]
      )
    end)
  end

  # ─── private ─────────────────────────────────────────────────────────────

  defp get(id) do
    case Store.raw_query(
           "SELECT id, tenant_id, workspace_id, metric_name, metric_kind, value, labels, recorded_at FROM metric_samples WHERE id = ?1",
           [id]
         ) do
      {:ok, [row]} -> {:ok, sample_from_row(row)}
      {:ok, []} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_rows(scope, entries) do
    Enum.reduce_while(entries, {:ok, []}, fn {name, value, kind, labels}, {:ok, acc} ->
      case build_row(scope, name, value, kind: kind, labels: labels) do
        {:ok, row} -> {:cont, {:ok, [row | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, rows} -> {:ok, Enum.reverse(rows)}
      error -> error
    end
  end

  defp build_row(workspace_id, metric_name, value, opts) do
    kind = opts |> Keyword.get(:kind, "gauge") |> to_string()
    labels = Keyword.get(opts, :labels, %{})

    cond do
      not (is_binary(workspace_id) and String.trim(workspace_id) != "") ->
        {:error, :workspace_required}

      not (is_binary(metric_name) and Regex.match?(@name_pattern, metric_name)) ->
        {:error, {:invalid_metric_name, metric_name}}

      not is_number(value) ->
        {:error, {:invalid_value, value}}

      kind not in @kinds ->
        {:error, {:invalid_kind, kind}}

      not flat_labels?(labels) ->
        {:error, :invalid_labels}

      true ->
        {:ok,
         [
           Keyword.get(opts, :tenant_id, "default"),
           workspace_id,
           metric_name,
           kind,
           value / 1,
           Jason.encode!(labels)
         ]}
    end
  end

  defp flat_labels?(labels) when is_map(labels) do
    Enum.all?(labels, fn {key, value} ->
      (is_binary(key) or is_atom(key)) and
        (is_binary(value) or is_number(value) or is_boolean(value))
    end)
  end

  defp flat_labels?(_), do: false

  defp since(opts) do
    case Keyword.get(opts, :since) do
      %DateTime{} = dt ->
        dt
        |> DateTime.shift_zone!("Etc/UTC")
        |> DateTime.truncate(:second)
        |> Calendar.strftime("%Y-%m-%d %H:%M:%S")

      _ ->
        nil
    end
  end

  defp sample_from_row([
         id,
         tenant_id,
         workspace_id,
         metric_name,
         metric_kind,
         value,
         labels,
         recorded_at
       ]) do
    %{
      id: id,
      tenant_id: tenant_id,
      workspace_id: workspace_id,
      metric_name: metric_name,
      metric_kind: metric_kind,
      value: value,
      labels: decode_labels(labels),
      recorded_at: recorded_at
    }
  end

  defp decode_labels(nil), do: %{}

  defp decode_labels(json) do
    case Jason.decode(json) do
      {:ok, labels} when is_map(labels) -> labels
      _ -> %{}
    end
  end
end
