defmodule OptimalEngine.API.SessionAPI do
  @moduledoc """
  Handlers for committing and reading chat sessions, called from
  `OptimalEngine.API.Router`:

    * `POST /api/sessions/commit` - commit a finished chat (`write`)
    * `GET /api/sessions` - the workspace's sessions, newest first
    * `GET /api/sessions/:id` - one session, with `?include=transcript`

  Workspace authorization has already run (`WorkspaceAuthPlug`), so the
  workspace is one the caller may use; the actor is the key's principal
  (`OptimalEngine.API.Actor`). A session of another workspace or tenant is
  not found. See `OptimalEngine.ChatSession` for what a commit stores.
  """

  import Plug.Conn

  alias OptimalEngine.API.{Actor, Pagination}
  alias OptimalEngine.ChatSession

  def commit(conn) do
    body = body(conn)

    with {:ok, chat} <- ChatSession.normalize(body),
         {:ok, result, outcome} <-
           ChatSession.commit(tenant(conn), workspace(conn), Actor.of(conn, body), chat) do
      status = if outcome == :created, do: 201, else: 200
      json(conn, status, Map.put(result, :replayed, outcome == :replayed))
    else
      {:error, {:invalid, detail}} ->
        json(conn, 422, %{error: "invalid_session", detail: detail})

      {:error, {:too_large, limit}} ->
        json(conn, 413, Map.put(limit, "error", "session_too_large"))

      {:error, {:idempotency_key_conflict, session_id}} ->
        json(conn, 409, %{error: "idempotency_key_conflict", session_id: session_id})

      {:error, reason} ->
        json(conn, 500, %{error: inspect(reason)})
    end
  end

  def list(conn) do
    conn = fetch_query_params(conn)
    {offset, limit} = Pagination.parse(conn)

    case ChatSession.list(tenant(conn), workspace(conn),
           limit: limit,
           offset: offset,
           correlation_id: conn.query_params["correlation_id"]
         ) do
      {:ok, %{sessions: sessions, total: total}} ->
        json(conn, 200, %{
          workspace_id: workspace(conn),
          count: length(sessions),
          sessions: sessions,
          pagination: Pagination.wrap(sessions, total, offset, limit).pagination
        })

      {:error, reason} ->
        json(conn, 500, %{error: inspect(reason)})
    end
  end

  def show(conn, id) do
    conn = fetch_query_params(conn)
    include = String.split(conn.query_params["include"] || "", ",", trim: true)

    case ChatSession.get(tenant(conn), workspace(conn), id,
           include_transcript: "transcript" in include
         ) do
      {:ok, session} -> json(conn, 200, session)
      {:error, :not_found} -> json(conn, 404, %{error: "session not found"})
      {:error, reason} -> json(conn, 500, %{error: inspect(reason)})
    end
  end

  defp tenant(conn), do: conn.assigns[:current_tenant] || "default"
  defp workspace(conn), do: conn.assigns[:workspace_id] || "default"

  defp body(conn) do
    case conn.body_params do
      %{} = params when not is_struct(params) -> params
      _ -> %{}
    end
  end

  defp json(conn, status, data) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(data))
  end
end
