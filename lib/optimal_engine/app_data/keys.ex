defmodule OptimalEngine.AppData.Keys do
  @moduledoc """
  Data keys: API keys limited to one workspace's app data.

  An app's server (holding a key with `data:admin`) mints a data key for an
  end user or a component. The key is an ordinary Engine API key
  (`OptimalEngine.Auth.ApiKey`, revocable, expiring) whose metadata carries
  its data access:

      %{"data_access" => %{"workspace" => "default:todo",
                           "collections" => ["tasks"],
                           "operations" => ["read", "create", "update"],
                           "owner" => "user-a"}}

  * The key's workspace scope is exactly that workspace.
  * Its operation scopes are `read`, plus `write` when it may create,
    update or delete. It never holds `data:admin`, `admin` or `*`.
  * It is confined to `/api/data`: every other Engine route refuses it
    (`OptimalEngine.API.PermissionPlug`).
  * With an `owner`, it reads and writes only rows whose owner field holds
    that owner, and every row it creates is owned by that owner. The owner
    comes from the key; a request body cannot change it.

  Delegation only narrows: a minter cannot grant a scope, a workspace, or a
  lifetime it does not hold itself.
  """

  alias OptimalEngine.AppData.{Schema, Scope}
  alias OptimalEngine.Auth.ApiKey

  @default_ttl 3_600
  @max_ttl 30 * 24 * 3_600

  @doc """
  Mints a data key. `parent` is the caller's verified key (nil for a trusted
  local caller). `attrs`: `name`, `owner`, `collections` (default all),
  `operations` (default `["read"]`), `expires_in` seconds (default 3600,
  max 30 days).

  Returns `{:ok, %{"id", "key", "expires_at", "data_access"}}`; the `key`
  is shown once.
  """
  @spec mint(Scope.t(), ApiKey.t() | nil, map()) :: {:ok, map()} | {:error, term()}
  def mint(%Scope{} = scope, parent, attrs) do
    with :ok <- Scope.allow_admin(scope),
         {:ok, name} <- name(attrs["name"]),
         {:ok, owner} <- owner(attrs["owner"]),
         {:ok, collections} <- collections(attrs["collections"]),
         {:ok, operations} <- operations(attrs["operations"]),
         scopes = derived_scopes(operations),
         :ok <- within_parent_scopes(parent, scopes),
         :ok <- within_parent_workspaces(parent, scope.workspace_id),
         {:ok, expires_at} <- expires_at(parent, attrs["expires_in"]) do
      access = %{
        "workspace" => scope.workspace_id,
        "collections" => collections,
        "operations" => operations,
        "owner" => owner
      }

      with {:ok, %{id: id, key: key}} <-
             ApiKey.mint(%{
               tenant_id: scope.tenant_id,
               name: name,
               scopes: scopes,
               workspace_scope: [scope.workspace_id],
               expires_at: expires_at,
               metadata: %{"data_access" => access, "minted_by" => scope.actor}
             }) do
        OptimalEngine.Authority.record_key_minted(
          scope.tenant_id,
          %{
            id: id,
            principal_id: nil,
            scopes: scopes,
            workspace_scope: [scope.workspace_id],
            metadata: %{"data_access" => access}
          },
          scope.actor
        )

        {:ok, %{"id" => id, "key" => key, "expires_at" => expires_at, "data_access" => access}}
      end
    end
  end

  @doc "Active data keys of the scope's workspace (never secrets)."
  @spec list(Scope.t()) :: {:ok, [map()]} | {:error, term()}
  def list(%Scope{} = scope) do
    with :ok <- Scope.allow_admin(scope),
         {:ok, keys} <- ApiKey.list(scope.tenant_id, limit: 1_000) do
      views =
        for key <- keys,
            access = data_access(key),
            access != nil and access["workspace"] == scope.workspace_id do
          %{
            "id" => key.id,
            "name" => key.name,
            "prefix" => key.prefix,
            "expires_at" => key.expires_at,
            "created_at" => key.created_at,
            "last_used_at" => key.last_used_at,
            "data_access" => access
          }
        end

      {:ok, views}
    end
  end

  @doc "Revokes a data key of the scope's workspace."
  @spec revoke(Scope.t(), String.t()) :: :ok | {:error, term()}
  def revoke(%Scope{} = scope, id) do
    with :ok <- Scope.allow_admin(scope),
         {:ok, keys} <- list(scope),
         true <- Enum.any?(keys, &(&1["id"] == id)) || {:error, {:not_found, "key_not_found"}} do
      case ApiKey.revoke(id, scope.tenant_id) do
        :ok -> :ok
        {:ok, _} -> :ok
        {:error, :not_found} -> {:error, {:not_found, "key_not_found"}}
        other -> other
      end
    end
  end

  @doc "The data access of a key, or nil for an ordinary key."
  @spec data_access(ApiKey.t() | nil) :: map() | nil
  def data_access(%ApiKey{metadata: %{"data_access" => %{} = access}}), do: access
  def data_access(_key), do: nil

  defp name(name) when is_binary(name) do
    if String.trim(name) == "" or String.length(name) > 200,
      do: {:error, {:validation, ["name is required (up to 200 characters)"]}},
      else: {:ok, name}
  end

  defp name(_name), do: {:error, {:validation, ["name is required"]}}

  defp owner(nil), do: {:ok, nil}

  defp owner(owner) when is_binary(owner) do
    if owner != "" and String.length(owner) <= 256,
      do: {:ok, owner},
      else: {:error, {:validation, ["owner must be a non-empty string"]}}
  end

  defp owner(_owner), do: {:error, {:validation, ["owner must be a string"]}}

  defp collections(nil), do: {:ok, ["*"]}

  defp collections(list) when is_list(list) and list != [] do
    if Enum.all?(list, &(&1 == "*" or Schema.identifier?(&1))),
      do: {:ok, Enum.uniq(list)},
      else: {:error, {:validation, ["collections must list collection names"]}}
  end

  defp collections(_list), do: {:error, {:validation, ["collections must be a non-empty list"]}}

  defp operations(nil), do: {:ok, ["read"]}

  defp operations(list) when is_list(list) and list != [] do
    if Enum.all?(list, &(&1 in Scope.operations())),
      do: {:ok, Enum.uniq(list)},
      else:
        {:error, {:validation, ["operations must be from #{Enum.join(Scope.operations(), ", ")}"]}}
  end

  defp operations(_list), do: {:error, {:validation, ["operations must be a non-empty list"]}}

  defp derived_scopes(operations) do
    if Enum.any?(operations, &(&1 != "read")), do: ["read", "write"], else: ["read"]
  end

  defp within_parent_scopes(nil, _scopes), do: :ok

  defp within_parent_scopes(%ApiKey{scopes: held}, scopes) do
    if "*" in held or Enum.all?(scopes, &(&1 in held)),
      do: :ok,
      else: {:error, {:forbidden, "scope_exceeds_minter"}}
  end

  defp within_parent_workspaces(nil, _workspace), do: :ok

  defp within_parent_workspaces(%ApiKey{workspace_scope: held}, workspace) do
    if "*" in held or workspace in held,
      do: :ok,
      else: {:error, {:forbidden, "workspace_scope_exceeds_minter"}}
  end

  defp expires_at(parent, nil), do: expires_at(parent, @default_ttl)

  defp expires_at(parent, seconds)
       when is_integer(seconds) and seconds > 0 and seconds <= @max_ttl do
    requested = DateTime.add(DateTime.utc_now(), seconds, :second) |> DateTime.truncate(:second)

    ceiling =
      case parent && parent.expires_at && DateTime.from_iso8601(parent.expires_at) do
        {:ok, dt, _} -> dt
        _ -> nil
      end

    if ceiling && DateTime.compare(requested, ceiling) == :gt,
      do: {:error, {:forbidden, "expiry_exceeds_minter"}},
      else: {:ok, DateTime.to_iso8601(requested)}
  end

  defp expires_at(_parent, _seconds),
    do: {:error, {:validation, ["expires_in must be 1 to #{@max_ttl} seconds"]}}
end
