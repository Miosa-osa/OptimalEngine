defmodule OptimalEngine.API.PoolScopePlug do
  @moduledoc """
  Confines the `/api/memory-core/active-pools/:id` routes to the pools a
  caller may use.

  Runs after `OptimalEngine.API.WorkspaceAuthPlug` and before
  `OptimalEngine.API.PermissionPlug`. A pool id names a row and the row names
  its tenant and workspace, so this plug reads the row and lets the request
  through only when

  * the pool belongs to the caller's tenant,
  * the Engine serves the pool's workspace and the key's `workspace_scope`
    covers it, and
  * the request, if it names a workspace at all, names the pool's own.

  A pool that fails any of these answers `404` exactly like one that does not
  exist, so a pool of another tenant or workspace can be neither read nor
  changed by guessing its id.

  A pool id is the only thing most pool routes name, so `WorkspaceAuthPlug`
  does not ask for the implicit `default` workspace there; this plug
  authorizes the pool's own workspace instead and assigns it as
  `conn.assigns[:workspace_id]` (which `OptimalEngine.API.AuthorityPlug`
  governs the request against). The pool is assigned as `:active_pool` for the
  handler, which reads and retrieves in the pool's tenant and workspace, never
  in a default.
  """

  @behaviour Plug

  import Plug.Conn

  alias OptimalEngine.API.WorkspaceAuthPlug
  alias OptimalEngine.MemoryCore.ActiveMemoryPool
  alias OptimalEngine.Scope

  @workspace_fields ~w(workspace workspace_id)

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%{halted: true} = conn, _opts), do: conn
  def call(%{method: "OPTIONS"} = conn, _opts), do: conn

  def call(%{path_info: ["api", "memory-core", "active-pools", id | _]} = conn, _opts) do
    case ActiveMemoryPool.get(URI.decode(id)) do
      {:ok, pool} ->
        if visible?(conn, pool) do
          conn
          |> assign(:workspace_id, pool.workspace_id)
          |> assign(:active_pool, pool)
        else
          not_found(conn)
        end

      {:error, :not_found} ->
        not_found(conn)

      {:error, _unavailable} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(500, Jason.encode!(%{error: "active pool lookup failed"}))
        |> halt()
    end
  end

  def call(conn, _opts), do: conn

  defp visible?(conn, pool) do
    pool.tenant_id == (conn.assigns[:current_tenant] || "default") and
      Scope.serves?(pool.workspace_id) and
      WorkspaceAuthPlug.key_holds?(conn.assigns[:current_api_key], pool.workspace_id) and
      Enum.all?(named_workspaces(conn), &(&1 == pool.workspace_id))
  end

  # Every workspace the request names, in the body or the query.
  defp named_workspaces(conn) do
    conn = fetch_query_params(conn)

    body =
      if is_map(conn.body_params) and not is_struct(conn.body_params),
        do: conn.body_params,
        else: %{}

    [body, conn.query_params]
    |> Enum.flat_map(fn params -> Enum.map(@workspace_fields, &Map.get(params, &1)) end)
    |> Enum.reject(&(&1 in [nil, ""]))
  end

  defp not_found(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(404, Jason.encode!(%{error: "active pool not found"}))
    |> halt()
  end
end
