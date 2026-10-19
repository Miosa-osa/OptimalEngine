defmodule OptimalEngine.API.OrgPolicyAPI do
  @moduledoc """
  Handlers for the org section and the policy that flows down from it,
  called from `OptimalEngine.API.Router`:

    * `GET /api/org-section` - the tenant's org section
    * `PUT /api/org-section {"workspace_id"}` - designate it (`admin`)
    * `DELETE /api/org-section` - clear it (`admin`)
    * `GET /api/org-policy?workspace=` - the policy the workspace reads

  `WorkspaceAuthPlug` has already authorized the workspace a request names
  (the designated workspace on `PUT`, the reading workspace on
  `GET /api/org-policy`). See `OptimalEngine.OrgPolicy`.
  """

  import Plug.Conn

  alias OptimalEngine.API.Actor
  alias OptimalEngine.OrgPolicy

  def section(conn), do: json(conn, 200, OrgPolicy.status(tenant(conn)))

  def designate(conn) do
    body = body(conn)

    case body["workspace_id"] do
      id when is_binary(id) and id != "" ->
        case OrgPolicy.designate(tenant(conn), id, Actor.of(conn, body)) do
          {:ok, status} -> json(conn, 200, status)
          {:error, :not_found} -> json(conn, 404, %{error: "workspace not found"})
          {:error, :archived} -> json(conn, 422, %{error: "workspace_archived"})
          {:error, reason} -> json(conn, 500, %{error: inspect(reason)})
        end

      _ ->
        json(conn, 400, %{error: "workspace_id is required"})
    end
  end

  def clear(conn) do
    tenant = tenant(conn)
    previous = (OrgPolicy.section(tenant) || %{})["workspace_id"]

    case OrgPolicy.clear(tenant, Actor.of(conn, body(conn))) do
      :ok -> json(conn, 200, Map.put(OrgPolicy.status(tenant), :previous, previous))
      {:error, reason} -> json(conn, 500, %{error: inspect(reason)})
    end
  end

  def policy(conn) do
    workspace_id = conn.assigns[:workspace_id] || "default"

    policy = OrgPolicy.for_workspace(tenant(conn), workspace_id, actor: Actor.of(conn))
    json(conn, 200, Map.put(policy, :workspace_id, workspace_id))
  end

  defp tenant(conn), do: conn.assigns[:current_tenant] || "default"

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
