defmodule OptimalEngine.API.AnalyticsAPI do
  @moduledoc """
  Handlers for workspace analytics (`OptimalEngine.Analytics`), called from
  `OptimalEngine.API.Router`. Both routes are workspace scoped
  (`OptimalEngine.API.WorkspaceAuthPlug`) and read-only.

  | Route | Scope |
  | --- | --- |
  | `GET /api/analytics?workspace=` | read |
  | `GET /api/analytics/query?workspace=&dataset=&bucket=&from=&to=&limit=&<filter>=` | read |

  Rebuilding the files is the `analytics_export` analysis
  (`POST /api/analyses/run`, admin).

  | Status | Body |
  | --- | --- |
  | 400 | `{"error": "invalid_parameter", "parameter", "expected"}`, also for a `workspace` given as a list or map |
  | 404 | `{"error": "not_exported"}`: no export has written the dataset yet |
  | 503 | `{"error": "analytics_not_configured"}` without `OPTIMAL_ANALYTICS_PATH`; `{"error": "analytics_unavailable"}` without the `duckdb` executable or when it failed; `{"error": "analytics_busy"}` with `Retry-After: 5` when `OPTIMAL_ANALYTICS_MAX_PROCESSES` duckdb processes are already running |
  """

  import Plug.Conn

  require Logger

  @retry_after "5"

  alias OptimalEngine.Analytics

  @doc "`GET /api/analytics`: what the workspace's analytics hold."
  def status(conn) do
    conn = fetch_query_params(conn)

    case workspace(conn) do
      {:ok, workspace} ->
        json(conn, 200, Map.put(Analytics.status(workspace), :workspace, workspace))

      :invalid ->
        invalid_workspace(conn)
    end
  end

  @doc "`GET /api/analytics/query`: one dataset's question, answered."
  def query(conn) do
    conn = fetch_query_params(conn)

    case workspace(conn) do
      {:ok, workspace} -> answer(conn, workspace)
      :invalid -> invalid_workspace(conn)
    end
  end

  defp answer(conn, workspace) do
    case Analytics.query(workspace, conn.query_params) do
      {:ok, answer} ->
        json(conn, 200, Map.put(answer, :workspace, workspace))

      {:error, {:invalid_parameter, name, expected}} ->
        json(conn, 400, %{error: "invalid_parameter", parameter: name, expected: expected})

      {:error, :not_exported} ->
        json(conn, 404, %{
          error: "not_exported",
          hint: "run the analytics_export analysis (POST /api/analyses/run)"
        })

      {:error, :not_configured} ->
        json(conn, 503, %{error: "analytics_not_configured"})

      {:error, :busy} ->
        conn
        |> put_resp_header("retry-after", @retry_after)
        |> json(503, %{
          error: "analytics_busy",
          hint:
            "every duckdb process allowed (OPTIMAL_ANALYTICS_MAX_PROCESSES) is running; retry shortly"
        })

      {:error, :not_installed} ->
        json(conn, 503, %{error: "analytics_unavailable", reason: "duckdb is not installed"})

      {:error, reason} ->
        # DuckDB's message can name server paths; the log keeps it, the caller does not.
        Logger.warning("[Analytics] query failed: #{inspect(reason)}")
        json(conn, 503, %{error: "analytics_unavailable", reason: "the query failed"})
    end
  end

  # One workspace id. `workspace[]=` or `workspace[k]=` arrive as a list or a
  # map, which no check upstream reads as a workspace, so they are refused here.
  defp workspace(conn) do
    case conn.query_params["workspace"] do
      nil -> {:ok, conn.assigns[:workspace_id] || "default"}
      id when is_binary(id) -> if Analytics.workspace_id?(id), do: {:ok, id}, else: :invalid
      _list_or_map -> :invalid
    end
  end

  defp invalid_workspace(conn) do
    json(conn, 400, %{
      error: "invalid_parameter",
      parameter: "workspace",
      expected: "one workspace id"
    })
  end

  defp json(conn, status, data) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(data))
  end
end
