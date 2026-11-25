defmodule OptimalEngine.API.TenantAPI do
  @moduledoc """
  Tenants an Engine's operator makes for the organizations it holds, called
  from `OptimalEngine.API.Router`.

  A laptop Engine keeps each organization it syncs with in a tenant of its
  own, so two organizations never share rows, keys or workspaces. The client
  that connects the laptop to an organization (the MIOSA CLI, Business OS)
  creates the organization's tenant here, mints a key in it, and works in it
  with that key.

  | Route | Scope |
  | --- | --- |
  | `POST /api/tenants {id, name}` (with the tenant's organization, `<id>:org`) | admin |
  | `POST /api/tenants/:id/keys` (the body of `POST /api/auth/keys`) | admin |

  Only the operator may call either: a key of the `default` tenant whose
  scopes include `*` and whose workspace scope is `*`, or a trusted local
  caller when authentication is not required. Keys are minted only in a
  tenant this route created (its metadata says `created_via: "api"`), so the
  route never opens a key into a tenant made any other way, and the minted
  key follows `OptimalEngine.Auth.KeyIssuance` as `POST /api/auth/keys` does.
  """

  import Plug.Conn

  alias OptimalEngine.API.Actor
  alias OptimalEngine.Auth.{ApiKey, KeyIssuance}
  alias OptimalEngine.Organization
  alias OptimalEngine.Tenancy.Tenant

  @operator_tenant "default"
  @created_via "api"
  @name_max 200

  @doc "`POST /api/tenants`: creates a tenant, or answers the one this route already made."
  def create(conn) do
    body = body(conn)

    with :ok <- operator(conn),
         {:ok, id, name} <- tenant_attrs(body) do
      case Tenant.get(id) do
        {:ok, %Tenant{metadata: %{"created_via" => @created_via}} = tenant} ->
          json(conn, 200, view(tenant))

        {:ok, _other} ->
          json(conn, 409, %{error: "tenant_exists"})

        _missing ->
          create_new(conn, id, name)
      end
    else
      {:error, status, reason} -> json(conn, status, %{error: reason})
    end
  end

  @doc "`POST /api/tenants/:id/keys`: mints a key in a tenant this route created."
  def mint_key(conn, tenant_id) do
    body = body(conn)

    with :ok <- operator(conn),
         :ok <- created_here(tenant_id),
         {:ok, attrs} <- issuance(conn, tenant_id, body),
         {:ok, %{id: id, key: key}} <- ApiKey.mint(attrs) do
      OptimalEngine.Authority.record_key_minted(
        tenant_id,
        %{
          id: id,
          principal_id: attrs[:principal_id],
          scopes: attrs[:scopes] || ["*"],
          workspace_scope: attrs[:workspace_scope] || ["*"],
          metadata: attrs[:metadata] || %{}
        },
        Actor.of(conn)
      )

      json(conn, 201, %{id: id, key: key, prefix: String.slice(key, 0, 8), tenant_id: tenant_id})
    else
      {:error, status, reason} -> json(conn, status, %{error: reason})
      {:error, reason} when is_binary(reason) -> json(conn, 422, %{error: reason})
      {:error, reason} -> json(conn, 422, %{error: inspect(reason)})
    end
  end

  # The operator: the default tenant's root key over every workspace, or a trusted
  # local caller (no key, which the auth plug lets through only when
  # authentication is not required).
  defp operator(conn) do
    key = conn.assigns[:current_api_key]
    tenant = conn.assigns[:current_tenant] || @operator_tenant

    cond do
      tenant != @operator_tenant ->
        {:error, 403, "operator_only"}

      is_nil(key) ->
        :ok

      "*" in (key.scopes || []) and key.workspace_scope == ["*"] ->
        :ok

      true ->
        {:error, 403, "operator_only"}
    end
  end

  defp tenant_attrs(%{"id" => id} = body) when is_binary(id) do
    name = body["name"] || id

    cond do
      id == @operator_tenant -> {:error, 400, "invalid tenant id"}
      Tenant.check_id(id) != :ok -> {:error, 400, "invalid tenant id"}
      not is_binary(name) or name == "" -> {:error, 400, "invalid name"}
      String.length(name) > @name_max -> {:error, 400, "invalid name"}
      true -> {:ok, id, name}
    end
  end

  defp tenant_attrs(_body), do: {:error, 400, "id is required"}

  defp create_new(conn, id, name) do
    metadata = %{"created_via" => @created_via, "created_by" => Actor.of(conn)}

    with {:ok, tenant} <- Tenant.create(%{id: id, name: name, metadata: metadata}),
         {:ok, _organization} <-
           Organization.create(%{id: organization_id(id), tenant_id: id, slug: "org", name: name}) do
      json(conn, 201, view(tenant))
    else
      {:error, :tenant_id_taken} -> json(conn, 409, %{error: "tenant_exists"})
      {:error, :invalid_tenant_id} -> json(conn, 400, %{error: "invalid tenant id"})
      {:error, _reason} -> json(conn, 500, %{error: "tenant_not_created"})
    end
  end

  # The one organization of a tenant made here, which its workspaces belong to.
  defp organization_id(tenant_id), do: tenant_id <> ":org"

  defp created_here(tenant_id) when is_binary(tenant_id) do
    case Tenant.get(tenant_id) do
      {:ok, %Tenant{metadata: %{"created_via" => @created_via}}} -> :ok
      {:ok, _other} -> {:error, 403, "tenant_not_created_here"}
      _missing -> {:error, 404, "tenant_not_found"}
    end
  end

  # The minter is the operator's key, so the new key never exceeds it; for a
  # trusted local caller there is no minter and the request must name its scopes.
  defp issuance(conn, tenant_id, body) do
    case KeyIssuance.attrs(conn.assigns[:current_api_key], tenant_id, body) do
      {:ok, attrs} ->
        {:ok, attrs}

      {:error, reason} when reason in ["name is required", "scopes_required"] ->
        {:error, 400, reason}

      {:error, "invalid " <> _ = reason} ->
        {:error, 400, reason}

      {:error, reason} ->
        {:error, 403, reason}
    end
  end

  defp view(%Tenant{} = tenant),
    do: %{
      id: tenant.id,
      name: tenant.name,
      organization_id: organization_id(tenant.id),
      created_at: tenant.created_at
    }

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
