defmodule OptimalEngine.API.ConnectorScopePlug do
  @moduledoc """
  Confines the `/api/connectors/:id` routes to the connectors a caller may see.

  Runs after `OptimalEngine.API.WorkspaceAuthPlug` and before
  `OptimalEngine.API.PermissionPlug`. A connector id names a row and the row
  names its workspace, so this plug reads the row in the caller's tenant and
  authorizes its workspace the way a named workspace is authorized: the key's
  `workspace_scope` must cover it and the Engine must serve it. A connector
  the caller may not see answers `404`, exactly like one that does not exist.

  A visible connector's workspace becomes `conn.assigns[:workspace_id]`, so
  `OptimalEngine.API.AuthorityPlug` governs the request against the
  connector's own workspace, and its view is assigned as `:connector` for the
  handler. Credentials are never part of that view.
  """

  @behaviour Plug

  import Plug.Conn

  alias OptimalEngine.API.ConnectorsAPI
  alias OptimalEngine.Connectors.Rows

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%{halted: true} = conn, _opts), do: conn
  def call(%{method: "OPTIONS"} = conn, _opts), do: conn

  def call(%{path_info: ["api", "connectors", id | _]} = conn, _opts) do
    tenant_id = conn.assigns[:current_tenant] || "default"

    with {:ok, view} <- Rows.get(tenant_id, URI.decode(id)),
         true <- visible?(conn, view.workspace_id) do
      conn
      |> assign(:workspace_id, view.workspace_id)
      |> assign(:connector, view)
    else
      _hidden_or_missing ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(404, Jason.encode!(%{error: "connector not found"}))
        |> halt()
    end
  end

  def call(conn, _opts), do: conn

  defp visible?(conn, workspace_id) do
    case ConnectorsAPI.visible_workspaces(conn) do
      :all -> true
      workspace_ids -> workspace_id in workspace_ids
    end
  end
end
