defmodule OptimalEngine.API.AnalysesAPI do
  @moduledoc """
  Handlers for analyses and the job queue, called from
  `OptimalEngine.API.Router`.

  | Route | Scope |
  | --- | --- |
  | `GET /api/analyses?workspace=&kind=&limit=` | read |
  | `POST /api/analyses/run {workspace, kind, payload}` | admin |
  | `GET /api/jobs?workspace=&status=`, `GET /api/jobs/dead?workspace=` | read |
  | `POST /api/jobs/dead/:id/replay {workspace}` | admin |
  """

  import Plug.Conn

  alias OptimalEngine.{Analyses, Jobs}

  def reports(conn) do
    conn = fetch_query_params(conn)

    json(conn, 200, %{
      reports:
        Analyses.reports(tenant(conn), [workspace(conn)],
          kind: conn.query_params["kind"],
          limit: int(conn.query_params["limit"], 20)
        ),
      kinds: Analyses.kinds()
    })
  end

  def run(conn) do
    body = body(conn)
    payload = if is_map(body["payload"]), do: body["payload"], else: %{}

    case Analyses.run_now(tenant(conn), body["workspace"] || "default", body["kind"] || "", payload) do
      {:ok, result} ->
        json(conn, 200, result)

      {:error, :unknown_analysis} ->
        json(conn, 422, %{error: "unknown_analysis", kinds: Analyses.kinds()})

      {:error, :not_found} ->
        json(conn, 404, %{error: "workspace not found"})

      {:error, reason} ->
        json(conn, 422, %{error: inspect(reason)})
    end
  end

  def jobs(conn) do
    conn = fetch_query_params(conn)

    {:ok, jobs} =
      Jobs.list(workspace(conn),
        status: conn.query_params["status"],
        limit: int(conn.query_params["limit"], 50)
      )

    json(conn, 200, %{jobs: jobs})
  end

  def dead(conn) do
    conn = fetch_query_params(conn)
    {:ok, letters} = Jobs.dead_letters(workspace(conn), limit: int(conn.query_params["limit"], 50))
    json(conn, 200, %{dead_letters: letters})
  end

  def replay(conn, id) do
    body = body(conn)

    case Jobs.replay_dead_letter(id, body["workspace"] || "default") do
      {:ok, job} -> json(conn, 200, job)
      {:error, :not_found} -> json(conn, 404, %{error: "dead letter not found"})
      {:error, reason} -> json(conn, 409, %{error: inspect(reason)})
    end
  end

  # ---------------------------------------------------------------------------

  defp workspace(conn),
    do: conn.query_params["workspace"] || conn.assigns[:workspace_id] || "default"

  defp tenant(conn), do: conn.assigns[:current_tenant] || "default"

  defp body(conn) do
    case conn.body_params do
      %{} = params when not is_struct(params) -> params
      _ -> %{}
    end
  end

  defp int(nil, default), do: default

  defp int(value, default) do
    case Integer.parse(to_string(value)) do
      {n, ""} -> n
      _ -> default
    end
  end

  defp json(conn, status, data) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(data))
  end
end
