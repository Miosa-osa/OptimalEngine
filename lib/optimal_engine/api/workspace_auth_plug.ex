defmodule OptimalEngine.API.WorkspaceAuthPlug do
  @moduledoc """
  Workspace authorization for the HTTP API.

  Runs AFTER `OptimalEngine.API.AuthPlug` (which authenticates the caller and
  assigns `:current_tenant` / `:current_api_key`) and BEFORE `:dispatch`, so
  no workspace-parameterized handler can run for a workspace the caller is
  not allowed to read.

  For every request it:

  1. Resolves EVERY workspace id the request names — the `:id` path segment
     on `/api/workspaces/:id*` and `/api/storage/workspaces/:id*`, and the
     `"workspace"` and `"workspace_id"` body fields and query parameters. Authorizing all of them (not just the one
     a given handler happens to read) means a body/query mismatch can never
     smuggle a second, unauthorized workspace past the check. Every `/api`
     route is workspace-scoped except the global families in
     `@global_roots`; when a workspace-scoped route names no workspace, the
     implicit `"default"` workspace is authorized instead — preserving
     single-workspace behavior while keeping it tenant-checked. A key
     restricted to named workspaces must name one: if its scope does not
     include `"default"`, the request is refused with **400**
     `{"error":"workspace_required"}` instead of silently reading the
     default workspace.
  2. Enforces, for each requested workspace id:
     * **tenant ownership** — a workspace registered to another tenant (or an
       unregistered `"<tenant>:<slug>"` id with a foreign tenant prefix)
       returns **404** `{"error":"workspace not found"}`. Fails closed:
       foreign workspaces are indistinguishable from absent ones.
     * **the API key's `workspace_scope`** — the id must be listed or the
       scope must contain `"*"`, otherwise **403**
       `{"error":"workspace_scope_denied"}`. Anonymous mode
       (`auth_required: false`, no key) has no key scope to enforce.
  3. Assigns the primary requested workspace (path > body > query >
     `"default"`) to `conn.assigns[:workspace_id]` — closing the loop with
     `AuthPlug`'s documented workspace-scope contract, which reads that
     assign.

  Unregistered workspace ids without a tenant prefix (single-tenant
  deployments using ad hoc workspace ids) pass the tenant check for
  compatibility; per-row `workspace_id` filtering in the handlers still
  scopes the data, and keyed callers remain bound by `workspace_scope`.
  """

  @behaviour Plug

  import Plug.Conn

  alias OptimalEngine.Workspace

  # Endpoint families that serve no workspace data: engine status, catalogs,
  # tenant-level administration and keys. Connectors list across the key's
  # workspaces, and a connector id is authorized against its own workspace by
  # OptimalEngine.API.ConnectorScopePlug. Every other /api family is
  # workspace-scoped and authorized even when no workspace is named
  # (implicit "default"), so a new route is scoped unless it is listed here.
  # Global routes are still checked when they explicitly name a workspace.
  @global_roots ~w(architectures auth authority backup bundles connectors federation health
                   init maintenance metrics org-section organizations principals resolve
                   routing scope status storage stores topology version)

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    conn = fetch_query_params(conn)
    requested = requested_workspaces(conn)

    cond do
      requested == [] and not workspace_scoped_path?(conn) ->
        conn

      Enum.any?(requested, &(not valid_workspace_id?(&1))) ->
        halt_json(conn, 400, "invalid workspace")

      requested == [] and org_scope_request?(conn) ->
        assign(conn, :org_scope, true)

      requested == [] and not key_allows_implicit_default?(conn.assigns[:current_api_key]) ->
        halt_json(conn, 400, "workspace_required")

      true ->
        authorize_all(conn, if(requested == [], do: ["default"], else: requested))
    end
  end

  # ---------------------------------------------------------------------------
  # Requested-workspace resolution
  # ---------------------------------------------------------------------------

  # Workspace ids name directories and object keys, so a requested id is a
  # plain identifier: letters, digits, '.', '_', '-', one ':' between tenant
  # and slug, and never a path.
  @workspace_id ~r/\A[A-Za-z0-9][A-Za-z0-9._-]{0,127}(:[A-Za-z0-9][A-Za-z0-9._-]{0,127})?\z/

  defp valid_workspace_id?(id) when is_binary(id),
    do: Regex.match?(@workspace_id, id) and not String.contains?(id, "..")

  defp valid_workspace_id?(_id), do: false

  @workspace_fields ~w(workspace workspace_id)

  defp requested_workspaces(conn) do
    [path_workspace(conn) | body_workspaces(conn) ++ query_workspaces(conn)]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
  end

  # /api/workspaces/:id, /api/workspaces/:id/config, /api/workspaces/:id/archive…
  defp path_workspace(%{path_info: ["api", "workspaces", id | _]}), do: URI.decode(id)

  defp path_workspace(%{path_info: ["api", "storage", "workspaces", id | _]}),
    do: URI.decode(id)

  defp path_workspace(_conn), do: nil

  defp body_workspaces(%{body_params: %Plug.Conn.Unfetched{}}), do: []

  defp body_workspaces(%{body_params: params}) when is_map(params),
    do: Enum.map(@workspace_fields, &Map.get(params, &1))

  defp body_workspaces(_conn), do: []

  # "workspaces" names several at once, comma-separated. "workspaces=*" asks
  # for every workspace the caller may see and is honored only by routes
  # that filter by the caller's scope themselves (@org_scope_paths).
  defp query_workspaces(conn) do
    named = Enum.map(@workspace_fields, &Map.get(conn.query_params, &1))

    case Map.get(conn.query_params, "workspaces") do
      "*" -> named
      list when is_binary(list) -> named ++ String.split(list, ",", trim: true)
      _ -> named
    end
  end

  @org_scope_paths [
    ["api", "brief"],
    ["api", "loops"],
    ["api", "viability"],
    ["api", "viability", "history"],
    ["api", "viability", "metrics"],
    ["api", "viability", "audit"]
  ]

  defp org_scope_request?(conn) do
    conn.method == "GET" and conn.path_info in @org_scope_paths and
      Map.get(conn.query_params, "workspaces") == "*"
  end

  defp workspace_scoped_path?(conn), do: workspace_scoped?(conn.path_info)

  @doc """
  Whether a route is workspace-scoped: authorized for the workspaces it
  names, or for the implicit `"default"` when it names none. Every other
  route is tenant-wide, though a workspace it names is still checked. The
  public API reference (`OptimalEngine.API.Reference`) labels every route
  with this function.
  """
  @spec workspace_scoped?([String.t()]) :: boolean()
  # GET/POST /api/workspaces (list/create) are tenant-parameterized, not
  # workspace-parameterized — only the /:id subroutes name a workspace, and
  # those are caught by path_workspace/1 above.
  def workspace_scoped?(["api", "workspaces"]), do: false
  def workspace_scoped?(["api", root | _]), do: root not in @global_roots
  def workspace_scoped?(_path_info), do: false

  # Anonymous callers and keys whose scope covers "default" may rely on the
  # implicit default workspace; a key restricted to other workspaces must
  # name the one it means.
  defp key_allows_implicit_default?(nil), do: true

  defp key_allows_implicit_default?(api_key) do
    scope = api_key.workspace_scope || []
    "*" in scope or "default" in scope
  end

  # ---------------------------------------------------------------------------
  # Authorization
  # ---------------------------------------------------------------------------

  defp authorize_all(conn, [primary | _] = workspace_ids) do
    tenant_id = conn.assigns[:current_tenant] || "default"
    api_key = conn.assigns[:current_api_key]
    conn = assign(conn, :workspace_id, primary)

    Enum.reduce_while(workspace_ids, conn, fn workspace_id, conn ->
      case authorize(workspace_id, tenant_id, api_key) do
        :ok ->
          {:cont, conn}

        {:error, :foreign_tenant} ->
          {:halt, halt_json(conn, 404, "workspace not found")}

        {:error, :scope_denied} ->
          {:halt, halt_json(conn, 403, "workspace_scope_denied")}

        {:error, {:not_a_workspace_id, id}} ->
          {:halt, halt_json(conn, 409, %{error: "not_a_workspace_id", workspace_id: id})}
      end
    end)
  end

  # Tenant ownership first: a foreign tenant's workspace is always 404 —
  # indistinguishable from a workspace that does not exist — regardless of the
  # key's workspace_scope. Scope mismatches inside the caller's own tenant
  # are 403.
  defp authorize(workspace_id, tenant_id, api_key) do
    with :ok <- check_engine_scope(workspace_id),
         :ok <- check_tenant_ownership(workspace_id, tenant_id) do
      check_key_scope(workspace_id, api_key)
    else
      # The id is named only to a caller whose key may use that workspace.
      {:error, {:not_a_workspace_id, id}} = renamed ->
        with :ok <- check_key_scope(id, api_key), do: renamed

      error ->
        error
    end
  end

  # A workspace-scoped Engine serves exactly one workspace; any other is
  # indistinguishable from one that does not exist.
  defp check_engine_scope(workspace_id) do
    if OptimalEngine.Scope.serves?(workspace_id), do: :ok, else: {:error, :foreign_tenant}
  end

  defp check_tenant_ownership(workspace_id, tenant_id) do
    case Workspace.get(workspace_id) do
      {:ok, workspace} ->
        if workspace.tenant_id == tenant_id, do: :ok, else: {:error, :foreign_tenant}

      {:error, :not_found} ->
        # Unregistered id. The "<tenant>:<slug>" id convention
        # (Workspace.derive_id) still names an owner — fail closed on a
        # foreign prefix. Bare unregistered ids pass for single-tenant
        # compatibility (handlers still workspace-filter every row).
        case String.split(workspace_id, ":", parts: 2) do
          [prefix, _slug] when prefix != tenant_id -> {:error, :foreign_tenant}
          [_prefix, slug] -> renamed(slug, tenant_id)
          _ -> :ok
        end

      _other ->
        # Store unavailable — fail closed.
        {:error, :foreign_tenant}
    end
  end

  # A renamed workspace keeps its id, so "<tenant>:<slug>" built from the
  # slug it has now (or an intermediate one) is not its id. Answering with
  # the id, instead of letting the request act on an empty unregistered
  # workspace, keeps writes from landing beside the real one.
  defp renamed(slug, tenant_id) do
    case Workspace.get_by_handle(slug, tenant_id) do
      {:ok, workspace} -> {:error, {:not_a_workspace_id, workspace.id}}
      _ -> :ok
    end
  end

  defp check_key_scope(_workspace_id, nil), do: :ok

  defp check_key_scope(workspace_id, api_key) do
    scope = api_key.workspace_scope || []

    if "*" in scope or workspace_id in scope do
      :ok
    else
      {:error, :scope_denied}
    end
  end

  # ---------------------------------------------------------------------------
  # Error responses
  # ---------------------------------------------------------------------------

  defp halt_json(conn, status, %{} = body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
    |> halt()
  end

  defp halt_json(conn, status, error), do: halt_json(conn, status, %{error: error})
end
