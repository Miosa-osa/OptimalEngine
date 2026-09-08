defmodule OptimalEngine.API.PermissionPlug do
  @moduledoc """
  Enforces API-key operation grants after authentication and workspace checks.

  `read` and `write` grant ordinary operations; governed review, topology changes,
  and administration require `claims:review`, `topology:write`, and `admin`.
  `*` is an explicit unrestricted grant. Trusted local anonymous development
  remains available, but claim review still requires an explicit reviewer.
  Authenticated review identities come from the key, never request input.
  """
  @read_posts ~w(/api/rag /api/assemble /api/reconstruct /api/render/context /api/storage/plan /api/optimality/classify)
  @topology_roots ~w(nodes organizations entities entity-mentions entity-relationships review data-steward workspaces)
  @behaviour Plug
  import Plug.Conn

  def init(opts), do: opts

  def call(%{method: "OPTIONS"} = conn, _opts), do: conn

  def call(conn, _opts) do
    conn = bind_authenticated_tenant(conn)
    if conn.halted, do: conn, else: authorize_operation(conn)
  end

  defp authorize_operation(conn) do
    scope = required_scope(conn)
    key = conn.assigns[:current_api_key]

    cond do
      key && "*" not in key.scopes && scope not in key.scopes ->
        deny(conn, "permission_scope_denied")

      scope == "claims:review" ->
        authorize_reviewer(conn, key)

      true ->
        conn
    end
  end

  defp bind_authenticated_tenant(%{assigns: %{current_api_key: nil}} = conn), do: conn

  defp bind_authenticated_tenant(conn) do
    tenant = conn.assigns.current_tenant
    body = if is_struct(conn.body_params), do: %{}, else: conn.body_params
    query = conn.query_params
    supplied = for params <- [body, query], field <- ["tenant", "tenant_id"], do: params[field]

    if Enum.any?(supplied, &(&1 != nil and &1 != tenant)) do
      deny(conn, "tenant_scope_denied")
    else
      scope = %{"tenant" => tenant, "tenant_id" => tenant}

      %{
        conn
        | body_params: Map.merge(body, scope),
          query_params: Map.merge(query, scope),
          params: Map.merge(conn.params, scope)
      }
    end
  end

  defp required_scope(conn) do
    path = "/" <> Enum.join(conn.path_info, "/")
    mutation = conn.method not in ["GET", "HEAD", "OPTIONS"]

    cond do
      String.starts_with?(path, "/api/auth/keys") or path == "/api/backup" or
          (mutation and String.starts_with?(path, "/api/maintenance/")) ->
        "admin"

      mutation and
          (Regex.match?(~r{^/api/memory-core/claims/[^/]+/(promote|reject)$}, path) or
             path == "/api/data-steward/claims/decide") ->
        "claims:review"

      mutation and topology_path?(conn.path_info) ->
        "topology:write"

      conn.method == "POST" and path in @read_posts ->
        "read"

      mutation ->
        "write"

      true ->
        "read"
    end
  end

  defp topology_path?(["api", "storage", "workspaces", _, "policy"]), do: true
  defp topology_path?(["api", root | _]), do: root in @topology_roots
  defp topology_path?(_), do: false

  defp authorize_reviewer(conn, nil) do
    body = conn.body_params
    reviewer = body["verifier_id"] || body["actor_id"]

    if is_binary(reviewer) and String.trim(reviewer) != "" and reviewer != "anonymous",
      do: conn,
      else: deny(conn, "reviewer_required")
  end

  defp authorize_reviewer(conn, key) do
    reviewer = key.principal_id || "api_key:" <> key.id
    body = conn.body_params

    if Enum.any?(["actor_id", "verifier_id"], fn field ->
         supplied = body[field]
         supplied != nil and supplied != reviewer
       end) do
      deny(conn, "reviewer_identity_mismatch")
    else
      body = body |> Map.put("actor_id", reviewer) |> Map.put("verifier_id", reviewer)
      %{conn | body_params: body, params: Map.merge(conn.params, body)}
    end
  end

  defp deny(conn, error) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(403, Jason.encode!(%{error: error}))
    |> halt()
  end
end
