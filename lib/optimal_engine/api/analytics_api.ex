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
  | 400 | `{"error": "invalid_parameter", "parameter", "expected"}` |
  | 404 | `{"error": "not_exported"}`: no export has written the dataset yet |
  | 503 | `{"error": "analytics_not_configured"}` without `OPTIMAL_ANALYTICS_PATH`; `{"error": "analytics_unavailable"}` without the `duckdb` executable or when it failed |
  """

  import Plug.Conn

  require Logger

  alias OptimalEngine.Analytics

  @doc "`GET /api/analytics`: what the workspace's analytics hold."
  def status(conn) do
    conn = fetch_query_params(conn)
    json(conn, 200, Map.put(Analytics.status(workspace(conn)), :workspace, workspace(conn)))
  end

  @doc "`GET /api/analytics/query`: one dataset's question, answered."
  def query(conn) do
    conn = fetch_query_params(conn)
    workspace = workspace(conn)

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

      {:error, :not_installed} ->
        json(conn, 503, %{error: "analytics_unavailable", reason: "duckdb is not installed"})

      {:error, reason} ->
        # DuckDB's message can name server paths; the log keeps it, the caller does not.
        Logger.warning("[Analytics] query failed: #{inspect(reason)}")
        json(conn, 503, %{error: "analytics_unavailable", reason: "the query failed"})
    end
  end

  defp workspace(conn),
    do: conn.query_params["workspace"] || conn.assigns[:workspace_id] || "default"

  defp json(conn, status, data) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(data))
  end
end
