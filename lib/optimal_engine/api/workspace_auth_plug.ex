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
     `"workspace"`, `"workspace_id"`, `"source_workspace_id"` and
     `"target_workspace_id"` body fields and query parameters, and the
     `"target_workspace_id"` of each of a body's `"items"`. Authorizing all
     of them (not just the one a given handler happens to read) means a
     body/query mismatch can never smuggle a second, unauthorized workspace
     past the check. Every `/api` route is workspace-scoped except the global families in
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
  3. Refuses a key restricted to named workspaces (**403**
     `{"error":"workspace_scope_denied"}`) on the routes that act on the whole
     tenant (`@tenant_wide`), and on the routes that work the tenant's intake
     workspace unless its scope holds that workspace.
  4. Assigns the primary requested workspace (path > body > query >
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

  alias OptimalEngine.{CorpusOrganizer, Workspace}

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
      outside_key_scope?(conn) ->
        halt_json(conn, 403, "workspace_scope_denied")

      requested == [] and not workspace_scoped_path?(conn) ->
        conn

      Enum.any?(requested, &(not valid_workspace_id?(&1))) ->
        halt_json(conn, 400, "invalid workspace")

      requested == [] and org_scope_request?(conn) ->
        assign(conn, :org_scope, true)

      # A pool id names the pool's own workspace, which PoolScopePlug authorizes
      # (the implicit default is not this request's workspace).
      requested == [] and pool_path?(conn) ->
        conn

      requested == [] and not key_allows_implicit_default?(conn.assigns[:current_api_key]) ->
        halt_json(conn, 400, "workspace_required")

      true ->
        authorize_all(
          conn,
          if(requested == [], do: ["default"], else: requested),
          target_workspaces(conn)
        )
    end
  end

  # ---------------------------------------------------------------------------
  # Routes that are not about one workspace
  # ---------------------------------------------------------------------------

  # These act on every workspace of the tenant, so a key restricted to named
  # workspaces is refused: the corpus organizer and the steward's node type and
  # hierarchy repairs.
  @tenant_wide [
    ["api", "maintenance", "corpus-organization"],
    ["api", "data-steward", "nodes", "repair-types"],
    ["api", "data-steward", "hierarchy", "repair-deterministic"]
  ]

  # These work the tenant's intake workspace (OptimalEngine.CorpusOrganizer),
  # which is a workspace of the tenant like any other: a key restricted to
  # named workspaces needs it in its scope.
  defp intake_route?(["api", "review", "routing" | _]), do: true
  defp intake_route?(["api", "data-steward", "routes", "decide"]), do: true
  defp intake_route?(_path_info), do: false

  # The organizer also runs as an analysis: placing the intake's records is
  # tenant wide however the request reaches it.
  defp tenant_wide?(%{path_info: ["api", "analyses", "run"], body_params: %{"kind" => kind}}),
    do: kind == "workspace_population"

  defp tenant_wide?(conn), do: conn.path_info in @tenant_wide

  defp outside_key_scope?(conn) do
    case conn.assigns[:current_api_key] do
      nil ->
        false

      api_key ->
        cond do
          key_holds?(api_key, "*") -> false
          tenant_wide?(conn) -> true
          intake_route?(conn.path_info) -> not key_holds?(api_key, intake(conn))
          true -> false
        end
    end
  end

  @doc """
  Whether an API key may use a workspace: its scope lists the workspace or
  holds `"*"`. An anonymous caller (`nil`) has no key scope to enforce.
  """
  @spec key_holds?(map() | nil, String.t()) :: boolean()
  def key_holds?(nil, _workspace_id), do: true

  def key_holds?(api_key, workspace_id) do
    scope = api_key.workspace_scope || []
    "*" in scope or workspace_id in scope
  end

  defp intake(conn),
    do: CorpusOrganizer.source_workspace(conn.assigns[:current_tenant] || "default")

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

  # `source_workspace_id` and `target_workspace_id` are the two workspaces a
  # steward id repair names (`/api/data-steward/workspaces/{rename,repair}`);
  # each is authorized like any other workspace the request names. The target
  # of a rename is, by definition, the "<tenant>:<slug>" name of the source's
  # current slug and not yet an id, so it is checked for its tenant and the
  # key's scope but is not refused as a slug named where an id belongs.
  #
  # A batch names its targets one by one: `items[].target_workspace_id`
  # (`/api/data-steward/routes/decide`) is a target like the field of the same
  # name at the top, authorized the same way.
  @workspace_fields ~w(workspace workspace_id source_workspace_id)
  @target_field "target_workspace_id"

  defp requested_workspaces(conn), do: strict_workspaces(conn) ++ target_workspaces(conn)

  # Every workspace named as an id.
  defp strict_workspaces(conn) do
    [path_workspace(conn) | body_workspaces(conn) ++ query_workspaces(conn)]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
  end

  defp target_workspaces(conn) do
    named =
      case conn.body_params do
        params when is_map(params) and not is_struct(params) ->
          [Map.get(params, @target_field) | item_targets(params)]

        _ ->
          []
      end

    (named ++ [Map.get(conn.query_params, @target_field)])
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
    |> Kernel.--(strict_workspaces(conn))
  end

  defp item_targets(%{"items" => items}) when is_list(items),
    do: for(%{"target_workspace_id" => target} <- items, do: target)

  defp item_targets(_params), do: []

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

  defp pool_path?(%{path_info: ["api", "memory-core", "active-pools", _id | _]}), do: true
  defp pool_path?(_conn), do: false

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
  # The Engine's table classification names no workspace and serves no workspace data.
  def workspace_scoped?(["api", "sync", "tables"]), do: false
  # Maintenance is a global family, but these act on one workspace, so the
  # implicit default is authorized like any other workspace.
  def workspace_scoped?(["api", "maintenance", route]) when route in ~w(index graph), do: true
  # The steward's node type and hierarchy repairs act on the whole tenant, not
  # on a workspace (a key needs the whole tenant: `@tenant_wide`).
  def workspace_scoped?(["api", "data-steward", "nodes", "repair-types"]), do: false
  def workspace_scoped?(["api", "data-steward", "hierarchy", "repair-deterministic"]), do: false
  def workspace_scoped?(["api", "maintenance", "graph", "backfill"]), do: true
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

  defp authorize_all(conn, [primary | _] = workspace_ids, targets) do
    tenant_id = conn.assigns[:current_tenant] || "default"
    api_key = conn.assigns[:current_api_key]
    conn = assign(conn, :workspace_id, primary)

    Enum.reduce_while(workspace_ids, conn, fn workspace_id, conn ->
      case authorize(workspace_id, tenant_id, api_key, workspace_id in targets) do
        :ok ->
          {:cont, conn}

        {:error, :foreign_tenant} ->
          {:halt, halt_json(conn, 404, "workspace not found")}

        {:error, :scope_denied} ->
          {:halt, halt_json(conn, 403, "workspace_scope_denied")}

        {:error, {:not_a_workspace_id, id}} ->
          {:halt, halt_json(conn, 409, %{error: "not_a_workspace_id", workspace_id: id})}

        {:error, :invalid_workspace_directory} ->
          {:halt, halt_json(conn, 400, "invalid workspace")}
      end
    end)
  end

  # Tenant ownership first: a foreign tenant's workspace is always 404 —
  # indistinguishable from a workspace that does not exist — regardless of the
  # key's workspace_scope. Scope mismatches inside the caller's own tenant
  # are 403.
  defp authorize(workspace_id, tenant_id, api_key, slug_named?) do
    with :ok <- check_engine_scope(workspace_id),
         :ok <- check_tenant_ownership(workspace_id, tenant_id, slug_named?) do
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

  defp check_tenant_ownership(workspace_id, tenant_id, slug_named?) do
    case Workspace.get(workspace_id) do
      {:ok, workspace} ->
        if workspace.tenant_id == tenant_id, do: :ok, else: {:error, :foreign_tenant}

      {:error, :not_found} ->
        # Unregistered id. The "<tenant>:<slug>" id convention
        # (Workspace.derive_id) still names an owner — fail closed on a
        # foreign prefix. Bare unregistered ids pass for single-tenant
        # compatibility (handlers still workspace-filter every row), but not
        # one whose directory is not its own (`own_directory/1`).
        case String.split(workspace_id, ":", parts: 2) do
          [prefix, _slug] when prefix != tenant_id ->
            {:error, :foreign_tenant}

          [_prefix, _slug] when slug_named? ->
            own_directory(workspace_id)

          [_prefix, slug] ->
            with :ok <- own_directory(workspace_id), do: renamed(slug, tenant_id)

          _ ->
            own_directory(workspace_id)
        end

      _other ->
        # Store unavailable — fail closed.
        {:error, :foreign_tenant}
    end
  end

  # An unregistered id still names a directory (`Filesystem.path/2`), and what is
  # written under it goes there: a bare `tenants`, `nodes` or `cache`, or
  # `default:tenants`, is one the Engine root uses for itself, so a request that
  # names it is refused as it would write into them.
  defp own_directory(workspace_id) do
    case OptimalEngine.Portability.WorkspaceBundle.movable(workspace_id) do
      :ok -> :ok
      {:error, :workspace_directory_shared} -> {:error, :invalid_workspace_directory}
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

  defp check_key_scope(workspace_id, api_key) do
    if key_holds?(api_key, workspace_id), do: :ok, else: {:error, :scope_denied}
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
