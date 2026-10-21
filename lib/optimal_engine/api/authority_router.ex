defmodule OptimalEngine.API.AuthorityRouter do
  @moduledoc """
  HTTP API for Optimal Authority, forwarded from `/api/authority`.

  The tenant is always the caller's authenticated tenant; the acting
  identity is always `OptimalEngine.API.Actor`. Operation scopes are
  enforced by `OptimalEngine.API.PermissionPlug`:

  | Route | Scope |
  | --- | --- |
  | `GET /keys`, `GET /revocations`, `POST /decide` | read |
  | `POST /requests` | write |
  | `GET /effective`, `GET /grants`, `GET /policies`, `GET /requests`, `GET /evidence*`, `GET /integrity` | authority:read |
  | `POST /grants`, `POST /grants/:jti/(narrow\\|suspend\\|restore\\|revoke)` | authority:issue |
  | `POST /requests/:id/(approve\\|deny)` | authority:approve |
  | `POST /admit`, `POST /checkpoint`, `POST /release`, `POST /evidence` | authority:enforce |
  | `POST /policies`, `POST/DELETE /local-denies`, `POST /issuers`, `POST /issuers/:issuer/revocations`, `PUT /settings`, `POST /keys/rotate`, `POST /evidence/checkpoint` | authority:admin |
  """

  use Plug.Router

  alias OptimalEngine.API.Actor
  alias OptimalEngine.Authority

  alias OptimalEngine.Authority.{
    Decision,
    Evidence,
    Grants,
    Integrity,
    Issuers,
    Keys,
    LocalDeny,
    Policy,
    Requests
  }

  plug(:match)
  plug(:dispatch)

  # -- public verification material -------------------------------------------

  get "/keys" do
    json(conn, 200, Keys.jwks(tenant(conn)) |> Map.put("issuer", Grants.issuer()))
  end

  get "/revocations" do
    conn = fetch_query_params(conn)

    json(conn, 200, %{
      revocations: Issuers.local_revocations(tenant(conn), conn.query_params["since"])
    })
  end

  # -- decisions and state -----------------------------------------------------

  post "/decide" do
    body = body(conn)

    decision =
      Authority.decide(%{
        tenant_id: tenant(conn),
        workspace_id: body["workspace_id"],
        subject: body["subject"] || Actor.of(conn),
        action: body["action"],
        resource: body["resource"],
        data_class: body["data_class"]
      })

    json(conn, 200, Decision.to_map(decision))
  end

  # Anyone may read their own effective state; reading another subject's
  # needs authority:read.
  get "/effective" do
    conn = fetch_query_params(conn)
    subject = conn.query_params["subject"] || Actor.of(conn)

    if subject == Actor.of(conn) or holds?(conn, "authority:read"),
      do:
        json(
          conn,
          200,
          Authority.effective(tenant(conn), subject, conn.query_params["workspace_id"])
        ),
      else: error(conn, 403, "permission_scope_denied")
  end

  # -- policy packs ------------------------------------------------------------

  get "/policies" do
    conn = fetch_query_params(conn)
    active_only = conn.query_params["active"] == "true"
    json(conn, 200, %{policies: Policy.list(tenant(conn), active_only: active_only)})
  end

  get "/policies/default" do
    json(conn, 200, Authority.default_pack())
  end

  get "/policies/:id" do
    case Policy.get(tenant(conn), id) do
      {:ok, policy} -> json(conn, 200, policy)
      {:error, :not_found} -> error(conn, 404, "policy not found")
    end
  end

  post "/policies" do
    body = body(conn)
    scope_type = body["scope_type"] || "tenant"
    scope_id = if scope_type == "tenant", do: tenant(conn), else: body["scope_id"]

    case Authority.publish_policy(
           tenant(conn),
           scope_type,
           scope_id || "",
           body["pack"] || %{},
           Actor.of(conn),
           grant: body["grant"]
         ) do
      {:ok, policy} ->
        json(conn, 201, policy)

      {:error, errors} when is_list(errors) ->
        json(conn, 422, %{error: "invalid_policy", details: errors})

      {:error, :loosening_requires_grant} ->
        error(conn, 403, "loosening_requires_grant")

      {:error, reason} when is_atom(reason) ->
        error(conn, 403, Atom.to_string(reason))
    end
  end

  # -- grants ------------------------------------------------------------------

  get "/grants" do
    conn = fetch_query_params(conn)
    q = conn.query_params

    grants =
      Grants.list(tenant(conn),
        subject: q["subject"],
        status: q["status"],
        workspace_id: q["workspace_id"]
      )

    json(conn, 200, %{grants: Enum.map(grants, &Map.delete(&1, :claims))})
  end

  get "/grants/:jti" do
    case Grants.fetch(tenant(conn), jti) do
      {:ok, grant} -> json(conn, 200, grant)
      {:error, :not_found} -> error(conn, 404, "grant not found")
    end
  end

  post "/grants" do
    conn |> grant_response(Authority.issue_grant(tenant(conn), body(conn), Actor.of(conn)))
  end

  post "/grants/:jti/narrow" do
    conn |> grant_response(Authority.narrow_grant(tenant(conn), jti, body(conn), Actor.of(conn)))
  end

  post "/grants/:jti/suspend" do
    state_response(
      conn,
      Authority.suspend_grant(tenant(conn), jti, Actor.of(conn), body(conn)["reason"])
    )
  end

  post "/grants/:jti/restore" do
    state_response(conn, Authority.restore_grant(tenant(conn), jti, Actor.of(conn)))
  end

  post "/grants/:jti/revoke" do
    case Authority.revoke_grant(tenant(conn), jti, Actor.of(conn), body(conn)["reason"]) do
      {:ok, jtis} -> json(conn, 200, %{revoked: jtis})
      {:error, :not_found} -> error(conn, 404, "grant not found")
      {:error, reason} -> error(conn, 422, Atom.to_string(reason))
    end
  end

  # -- enforcement -------------------------------------------------------------

  post "/admit" do
    body = body(conn)

    request = %{
      tenant_id: tenant(conn),
      audience: body["audience"],
      subject: body["subject"],
      workspace_id: body["workspace_id"],
      action: body["action"],
      resource: body["resource"],
      data_class: body["data_class"],
      amounts: body["amounts"] || %{}
    }

    request =
      cond do
        Map.has_key?(body, "command") -> Map.put(request, :command, body["command"])
        body["command_sha256"] -> Map.put(request, :command_sha256, body["command_sha256"])
        true -> request
      end

    measurable = body["measurable"]
    opts = if is_list(measurable), do: [measurable: measurable], else: []

    case Authority.admit(body["grant"], request, opts) do
      {:ok, admission} ->
        json(conn, 200, %{admitted: true, jti: admission.jti, origin: admission.origin})

      {:error, reason} ->
        json(conn, 403, %{admitted: false, error: "grant_denied", reason: Atom.to_string(reason)})
    end
  end

  post "/checkpoint" do
    body = body(conn)

    case Authority.checkpoint(tenant(conn), body["jti"] || "", %{subject: body["subject"]}) do
      :ok -> json(conn, 200, %{in_force: true})
      {:error, reason} -> json(conn, 409, %{in_force: false, reason: Atom.to_string(reason)})
    end
  end

  post "/release" do
    body = body(conn)

    case Authority.release(tenant(conn), body["jti"] || "", body["result"], %{
           subject: body["subject"]
         }) do
      :ok -> json(conn, 200, %{released: true})
      {:error, reason} -> json(conn, 409, %{released: false, reason: Atom.to_string(reason)})
    end
  end

  # -- approvals ---------------------------------------------------------------

  get "/requests" do
    conn = fetch_query_params(conn)
    json(conn, 200, %{requests: Requests.list(tenant(conn), status: conn.query_params["status"])})
  end

  # A subject files requests for itself; filing for another subject needs
  # authority:issue.
  post "/requests" do
    body = body(conn)
    body = Map.put_new(body, "subject", Actor.of(conn))

    if body["subject"] != Actor.of(conn) and not holds?(conn, "authority:issue") do
      error(conn, 403, "permission_scope_denied")
    else
      file_request(conn, body)
    end
  end

  defp file_request(conn, body) do
    case Authority.request_approval(tenant(conn), body, Actor.of(conn)) do
      {:ok, :allowed, decision} ->
        json(conn, 200, %{status: "allowed", decision: Decision.to_map(decision)})

      {:ok, request, decision} ->
        json(conn, 201, %{status: "pending", request: request, decision: Decision.to_map(decision)})

      {:error, :denied, %{decision: decision}} ->
        json(conn, 403, %{error: "denied", decision: Decision.to_map(decision)})

      {:error, reason, _} ->
        error(conn, 422, Atom.to_string(reason))
    end
  end

  post "/requests/:id/approve" do
    case Authority.approve(tenant(conn), id, Actor.of(conn)) do
      {:ok, request, grant} -> json(conn, 200, %{request: request, grant: grant_view(grant)})
      {:error, :not_found} -> error(conn, 404, "request not found")
      {:error, :self_approval} -> error(conn, 403, "self_approval")
      {:error, reason} -> error(conn, 422, Atom.to_string(reason))
    end
  end

  post "/requests/:id/deny" do
    case Authority.deny_request(tenant(conn), id, Actor.of(conn), body(conn)["reason"]) do
      {:ok, request} -> json(conn, 200, %{request: request})
      {:error, :not_found} -> error(conn, 404, "request not found")
      {:error, :self_approval} -> error(conn, 403, "self_approval")
      {:error, reason} -> error(conn, 422, Atom.to_string(reason))
    end
  end

  # -- local denies ------------------------------------------------------------

  get "/local-denies" do
    json(conn, 200, %{local_denies: LocalDeny.active(tenant(conn))})
  end

  post "/local-denies" do
    case Authority.add_local_deny(tenant(conn), body(conn), Actor.of(conn)) do
      {:ok, deny} -> json(conn, 201, deny)
      {:error, reason} -> error(conn, 422, inspect(reason))
    end
  end

  delete "/local-denies/:id" do
    case Authority.lift_local_deny(tenant(conn), id, Actor.of(conn)) do
      {:ok, deny} -> json(conn, 200, deny)
      {:error, :not_found} -> error(conn, 404, "local deny not found")
    end
  end

  # -- outside issuers ---------------------------------------------------------

  post "/issuers" do
    body = body(conn)

    opts =
      if is_integer(body["max_staleness_seconds"]),
        do: [max_staleness_seconds: body["max_staleness_seconds"]],
        else: []

    case Authority.register_issuer(
           tenant(conn),
           body["issuer"] || "",
           body["jwks"] || %{},
           Actor.of(conn),
           opts
         ) do
      {:ok, issuer} -> json(conn, 201, issuer)
      {:error, reason} -> error(conn, 422, Atom.to_string(reason))
    end
  end

  post "/issuers/:issuer/revocations" do
    case Authority.receive_revocations(
           tenant(conn),
           URI.decode(issuer),
           body(conn)["revocations"] || []
         ) do
      {:ok, count} -> json(conn, 200, %{received: count})
      {:error, :not_found} -> error(conn, 404, "issuer not registered")
      {:error, reason} -> error(conn, 422, Atom.to_string(reason))
    end
  end

  # -- evidence ----------------------------------------------------------------

  get "/evidence" do
    conn = fetch_query_params(conn)
    q = conn.query_params

    entries =
      Evidence.list(tenant(conn),
        after: parse_int(q["after"], 0),
        limit: parse_int(q["limit"], 500),
        jti: q["jti"],
        subject: q["subject"],
        kind: q["kind"]
      )

    json(conn, 200, %{entries: entries})
  end

  get "/evidence/verify" do
    case Evidence.verify(tenant(conn)) do
      {:ok, result} -> json(conn, 200, Map.put(result, :valid, true))
      {:error, failure} -> json(conn, 409, %{valid: false, failure: inspect_map(failure)})
    end
  end

  get "/evidence/export" do
    conn = fetch_query_params(conn)
    q = conn.query_params

    json(
      conn,
      200,
      Evidence.export(tenant(conn), parse_int(q["after"], 0), parse_int(q["limit"], 10_000))
    )
  end

  post "/evidence/checkpoint" do
    case Evidence.checkpoint(tenant(conn), body(conn)["anchor"]) do
      {:ok, checkpoint} -> json(conn, 201, checkpoint)
      {:error, reason} -> error(conn, 422, Atom.to_string(reason))
    end
  end

  post "/evidence" do
    case Authority.record_receipt(tenant(conn), body(conn), Actor.of(conn)) do
      {:ok, entry} -> json(conn, 201, entry)
      {:error, reason} -> error(conn, 422, inspect(reason))
    end
  end

  get "/integrity" do
    conn = fetch_query_params(conn)
    json(conn, 200, Integrity.scan(tenant(conn), record: conn.query_params["record"] == "true"))
  end

  # -- settings and keys -------------------------------------------------------

  get "/settings" do
    json(conn, 200, %{mode: OptimalEngine.Authority.Settings.mode(tenant(conn))})
  end

  put "/settings" do
    case Authority.set_mode(tenant(conn), body(conn)["mode"], Actor.of(conn)) do
      :ok -> json(conn, 200, %{mode: body(conn)["mode"]})
      {:error, :invalid_mode} -> error(conn, 422, "mode must be off, observe, or enforce")
    end
  end

  post "/keys/rotate" do
    case Authority.rotate_key(tenant(conn), body(conn)["purpose"] || "grant", Actor.of(conn)) do
      {:ok, key} -> json(conn, 201, %{kid: key.kid, purpose: key.purpose})
      {:error, reason} -> error(conn, 422, inspect(reason))
    end
  end

  match _ do
    error(conn, 404, "not found")
  end

  # ---------------------------------------------------------------------------

  defp grant_response(conn, {:ok, grant}), do: json(conn, 201, grant_view(grant))

  defp grant_response(conn, {:error, reason, detail}) do
    status =
      if reason in [:denied, :approval_required, :not_delegable, :delegation_not_permitted],
        do: 403,
        else: 422

    decision = detail[:decision]

    json(conn, status, %{
      error: Atom.to_string(reason),
      decision: decision && Decision.to_map(decision)
    })
  end

  defp grant_view(grant) do
    %{
      token: grant.token,
      jti: grant.jti,
      claims: grant.claims,
      decision: Decision.to_map(grant.decision)
    }
  end

  defp state_response(conn, {:ok, grant}), do: json(conn, 200, Map.delete(grant, :claims))
  defp state_response(conn, {:error, :not_found}), do: error(conn, 404, "grant not found")
  defp state_response(conn, {:error, reason}), do: error(conn, 409, Atom.to_string(reason))

  defp tenant(conn), do: conn.assigns[:current_tenant] || "default"

  # Anonymous local callers (auth not required) are the trusted operator.
  defp holds?(conn, scope) do
    case conn.assigns[:current_api_key] do
      nil -> true
      key -> "*" in key.scopes or scope in key.scopes
    end
  end

  defp body(conn) do
    case conn.body_params do
      %{} = params when not is_struct(params) -> params
      _ -> %{}
    end
  end

  defp parse_int(nil, default), do: default

  defp parse_int(value, default) do
    case Integer.parse(to_string(value)) do
      {int, ""} -> int
      _ -> default
    end
  end

  defp inspect_map(map),
    do:
      Map.new(map, fn {key, value} ->
        {key, if(is_atom(value), do: Atom.to_string(value), else: value)}
      end)

  defp error(conn, status, message), do: json(conn, status, %{error: message})

  defp json(conn, status, data) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(data))
  end
end
