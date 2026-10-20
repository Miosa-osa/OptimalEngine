defmodule OptimalEngine.Scope do
  @moduledoc """
  What an Engine serves, and what each workspace shares upward.

  An Engine runs in one of two scopes:

  * `org` (default) - one Engine for an organization; every workspace is a
    walled section of it. A key scoped to one workspace never reads another.
  * `workspace` - an Engine dedicated to a single workspace
    (`OPTIMAL_ENGINE_SCOPE=workspace`, `OPTIMAL_ENGINE_WORKSPACE=<id>`). Every
    request for any other workspace is refused as not found, so data in a
    workspace Engine can never be read through it as another workspace.

  Each workspace has a share-up policy for org-wide views (federated search,
  an all-workspaces chat): `read` shares results upward, `none` keeps them
  inside the workspace. The default is `read`, except workspaces whose
  `visibility` is `private` or `client`, which default to `none`. Changes
  are recorded in the authority evidence chain.
  """

  alias OptimalEngine.Store
  alias OptimalEngine.Workspace

  @share_values ~w(none read)

  @doc "The Engine's scope: `%{mode: \"org\"}` or `%{mode: \"workspace\", workspace_id: id}`."
  @spec engine_scope() :: map()
  def engine_scope do
    case Application.get_env(:optimal_engine, :engine_scope) do
      %{mode: "workspace", workspace_id: id} = scope when is_binary(id) and id != "" -> scope
      _ -> %{mode: "org"}
    end
  end

  @doc "Whether this Engine serves `workspace_id` at all."
  @spec serves?(String.t()) :: boolean()
  def serves?(workspace_id) do
    case engine_scope() do
      %{mode: "workspace", workspace_id: ^workspace_id} -> true
      %{mode: "workspace"} -> false
      _ -> true
    end
  end

  @doc "The share-up policy of a workspace (`none` or `read`)."
  @spec share_up(String.t() | map()) :: String.t()
  def share_up(%{metadata: metadata}) when is_map(metadata) do
    case metadata["share_up"] do
      value when value in @share_values -> value
      _ -> if metadata["visibility"] in ["private", "client"], do: "none", else: "read"
    end
  end

  def share_up(workspace_id) when is_binary(workspace_id) do
    case Workspace.get(workspace_id) do
      {:ok, workspace} -> share_up(workspace)
      _ -> "none"
    end
  end

  @doc """
  Sets a workspace's share-up policy and optional visibility
  (`private`, `client`, `internal`), recording who changed it.
  """
  @spec set_share_up(String.t(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, atom()}
  def set_share_up(tenant_id, workspace_id, value, by, opts \\ [])

  def set_share_up(tenant_id, workspace_id, value, by, opts) when value in @share_values do
    with {:ok, workspace} <- Workspace.get(workspace_id),
         true <- workspace.tenant_id == tenant_id || {:error, :not_found} do
      before = share_up(workspace)

      metadata =
        workspace.metadata
        |> Map.put("share_up", value)
        |> then(fn m ->
          if opts[:visibility], do: Map.put(m, "visibility", opts[:visibility]), else: m
        end)

      # Only these keys are written, so a concurrent write of other metadata
      # (a bound external id, a held slug) is never undone.
      {paths, params} =
        if opts[:visibility],
          do: {"'$.share_up', ?2, '$.visibility', ?3", [workspace_id, value, opts[:visibility]]},
          else: {"'$.share_up', ?2", [workspace_id, value]}

      {:ok, _} =
        Store.raw_query(
          "UPDATE workspaces SET metadata = json_set(CASE WHEN json_valid(metadata) THEN metadata ELSE '{}' END, #{paths}) WHERE id = ?1",
          params
        )

      _ =
        OptimalEngine.Authority.Evidence.append(tenant_id, "settings.changed", %{
          workspace_id: workspace_id,
          detail: %{
            "share_up" => value,
            "previous" => before,
            "visibility" => metadata["visibility"],
            "by" => by
          }
        })

      {:ok,
       %{
         workspace_id: workspace_id,
         share_up: value,
         previous: before,
         visibility: metadata["visibility"]
       }}
    end
  end

  def set_share_up(_tenant_id, _workspace_id, _value, _by, _opts), do: {:error, :invalid_share_up}

  @doc "Workspaces in the tenant that share upward, limited to `allowed` (nil = all)."
  @spec sharing_workspaces(String.t(), [String.t()] | nil) :: [map()]
  def sharing_workspaces(tenant_id, allowed \\ nil) do
    {:ok, workspaces} = Workspace.list(tenant_id: tenant_id)

    Enum.filter(workspaces, fn workspace ->
      share_up(workspace) == "read" and serves?(workspace.id) and
        (is_nil(allowed) or workspace.id in allowed)
    end)
  end
end
