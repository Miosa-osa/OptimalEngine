defmodule OptimalEngine.Identity.ACL do
  @moduledoc """
  Access Control List primitive.

  An ACL row grants a permission (`:read | :write | :admin`) on a resource
  (identified by URI) to either a principal OR a group — never both. A deny
  row (`deny/1`) refuses every permission on the resource to its principal or
  group, whatever else grants it: deny wins.

  ACLs propagate by **intersection**: a wiki page's visibility is the
  intersection of visibilities of all cited chunks. This is enforced at
  curation time (Phase 7) and at retrieval time (Phase 8).

  ## Resource URI conventions

  - `"optimal://nodes/project-platform-launch/signals/2026-04-17-ed-call.md"`
  - `"chunk:{chunk_id}"` — per-chunk ACL
  - `"wiki:{slug}:{audience}"` — per-wiki-page ACL
  - `"tenant:{tenant_id}"` — tenant-wide grant
  """

  alias OptimalEngine.Store
  alias OptimalEngine.Tenancy.Tenant

  @type permission :: :read | :write | :admin

  @type t :: %__MODULE__{
          id: integer() | nil,
          tenant_id: String.t(),
          resource_uri: String.t(),
          principal_id: String.t() | nil,
          group_id: String.t() | nil,
          permission: permission(),
          granted_at: String.t() | nil
        }

  defstruct id: nil,
            tenant_id: Tenant.default_id(),
            resource_uri: nil,
            principal_id: nil,
            group_id: nil,
            permission: :read,
            granted_at: nil

  @doc """
  Grant a permission on a resource to a principal or group. Exactly one of
  `principal_id` / `group_id` must be set.
  """
  @spec grant(map()) :: :ok | {:error, term()}
  def grant(%{resource_uri: uri, permission: perm} = attrs)
      when is_binary(uri) and perm in [:read, :write, :admin] do
    tenant_id = Map.get(attrs, :tenant_id, Tenant.default_id())
    principal_id = Map.get(attrs, :principal_id)
    group_id = Map.get(attrs, :group_id)

    cond do
      is_binary(principal_id) and is_nil(group_id) ->
        do_insert(tenant_id, uri, principal_id, nil, perm)

      is_nil(principal_id) and is_binary(group_id) ->
        do_insert(tenant_id, uri, nil, group_id, perm)

      true ->
        {:error, :must_set_exactly_one_of_principal_or_group}
    end
  end

  @doc """
  Deny every permission on a resource to a principal or group. Exactly one of
  `principal_id` / `group_id` must be set. A matching deny row makes `can?/4`
  false whatever grants exist for the resource.
  """
  @spec deny(map()) :: :ok | {:error, term()}
  def deny(%{resource_uri: uri} = attrs) when is_binary(uri) do
    tenant_id = Map.get(attrs, :tenant_id, Tenant.default_id())
    principal_id = Map.get(attrs, :principal_id)
    group_id = Map.get(attrs, :group_id)

    cond do
      is_binary(principal_id) and is_nil(group_id) ->
        do_insert(tenant_id, uri, principal_id, nil, :deny)

      is_nil(principal_id) and is_binary(group_id) ->
        do_insert(tenant_id, uri, nil, group_id, :deny)

      true ->
        {:error, :must_set_exactly_one_of_principal_or_group}
    end
  end

  defp do_insert(tenant_id, uri, principal_id, group_id, perm) do
    sql = """
    INSERT INTO acls (tenant_id, resource_uri, principal_id, group_id, permission)
    VALUES (?1, ?2, ?3, ?4, ?5)
    """

    case Store.raw_query(sql, [tenant_id, uri, principal_id, group_id, Atom.to_string(perm)]) do
      {:ok, _} -> :ok
      other -> other
    end
  end

  @doc """
  Returns `true` if the principal can `permission` the given resource URI.

  A deny row naming the principal, or a group the principal belongs to, makes
  the answer `false` whatever else grants it. Otherwise a principal `can?` a
  resource when **any** of the following is true:
    * an ACL grants it directly to the principal
    * an ACL grants it to any group the principal belongs to

  A resource with no grant rows follows the absent policy: `opts[:absent]` when
  given, else `config :optimal_engine, :acl_absent` (`:deny` whenever
  authentication is required, `:allow` for anonymous local use; see
  `OPTIMAL_ACL_ABSENT`). Permissions are ranked: `admin` satisfies `write`
  and `read`, `write` satisfies `read`.
  """
  @spec can?(String.t(), String.t(), permission(), keyword()) :: boolean()
  def can?(principal_id, resource_uri, permission, opts \\ [])
      when is_binary(principal_id) and is_binary(resource_uri) and
             permission in [:read, :write, :admin] do
    tenant_id = Keyword.get(opts, :tenant_id, Tenant.default_id())
    acls = list_for_resource(tenant_id, resource_uri)
    groups = if acls == [], do: MapSet.new(), else: principal_groups(principal_id)

    decide(acls, principal_id, groups, rank(Atom.to_string(permission)), absent_policy(opts))
  end

  @doc """
  The items of `items` the principal can `permission`, each decided by the
  resource URI `uri_of.(item)` returns, with the same rules and options as
  `can?/4`. Items whose URI is nil are kept. Reads the ACL rows of every URI
  in one query and the principal's groups at most once, so retrieval can
  filter a whole result set without a query per hit.
  """
  @spec filter(String.t(), [term()], (term() -> String.t() | nil), permission(), keyword()) ::
          [term()]
  def filter(principal_id, items, uri_of, permission, opts \\ [])
      when is_binary(principal_id) and is_list(items) and is_function(uri_of, 1) and
             permission in [:read, :write, :admin] do
    tenant_id = Keyword.get(opts, :tenant_id, Tenant.default_id())
    uris = items |> Enum.map(uri_of) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    case list_for_resources(tenant_id, uris) do
      {:ok, rows} ->
        groups = if rows == %{}, do: MapSet.new(), else: principal_groups(principal_id)
        needed = rank(Atom.to_string(permission))
        absent = absent_policy(opts)

        Enum.filter(items, fn item ->
          case uri_of.(item) do
            nil -> true
            uri -> decide(Map.get(rows, uri, []), principal_id, groups, needed, absent)
          end
        end)

      # The rows could not be read: keep only what no access list can govern.
      :error ->
        Enum.filter(items, &is_nil(uri_of.(&1)))
    end
  end

  # Deny rows naming the principal or one of its groups win; otherwise a
  # resource without grant rows follows the absent policy, and one with grant
  # rows needs a grant to the principal or a group at the needed rank.
  defp decide([], _principal_id, _groups, _needed, absent), do: absent == :allow

  defp decide(acls, principal_id, groups, needed, absent) do
    {denies, grants} = Enum.split_with(acls, &(&1.permission == "deny"))

    cond do
      Enum.any?(denies, &names?(&1, principal_id, groups)) ->
        false

      grants == [] ->
        absent == :allow

      true ->
        Enum.any?(grants, &(names?(&1, principal_id, groups) and rank(&1.permission) >= needed))
    end
  end

  defp names?(%{principal_id: principal_id}, principal_id, _groups) when is_binary(principal_id),
    do: true

  defp names?(%{group_id: group_id}, _principal_id, groups) when is_binary(group_id),
    do: MapSet.member?(groups, group_id)

  defp names?(_acl, _principal_id, _groups), do: false

  defp principal_groups(principal_id) do
    case OptimalEngine.Identity.Principal.groups(principal_id) do
      {:ok, group_ids} -> MapSet.new(group_ids)
      _ -> MapSet.new()
    end
  end

  @doc "The policy for resources with no ACL rows: `:allow` or `:deny`."
  @spec absent_policy(keyword()) :: :allow | :deny
  def absent_policy(opts \\ []) do
    case Keyword.get(opts, :absent, Application.get_env(:optimal_engine, :acl_absent, :allow)) do
      :allow -> :allow
      _ -> :deny
    end
  end

  defp rank("admin"), do: 3
  defp rank("write"), do: 2
  defp rank("read"), do: 1
  defp rank(_unknown), do: 0

  # ACL rows of many resources in one tenant, keyed by resource URI.
  defp list_for_resources(_tenant_id, []), do: {:ok, %{}}

  defp list_for_resources(tenant_id, uris) do
    uris
    |> Enum.chunk_every(500)
    |> Enum.reduce_while({:ok, []}, fn chunk, {:ok, acc} ->
      placeholders = Enum.map_join(2..(length(chunk) + 1), ", ", &"?#{&1}")

      case Store.raw_query(
             """
             SELECT resource_uri, principal_id, group_id, permission
             FROM acls
             WHERE tenant_id = ?1 AND resource_uri IN (#{placeholders})
             """,
             [tenant_id | chunk]
           ) do
        {:ok, rows} -> {:cont, {:ok, rows ++ acc}}
        _ -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, rows} ->
        {:ok,
         Enum.group_by(rows, &hd/1, fn [_uri, principal_id, group_id, permission] ->
           %{principal_id: principal_id, group_id: group_id, permission: permission}
         end)}

      :error ->
        :error
    end
  end

  @doc "Returns the list of ACL rows for a resource within a tenant."
  @spec list_for_resource(String.t(), String.t()) :: [map()]
  def list_for_resource(tenant_id, resource_uri)
      when is_binary(tenant_id) and is_binary(resource_uri) do
    case Store.raw_query(
           """
           SELECT principal_id, group_id, permission
           FROM acls
           WHERE tenant_id = ?1 AND resource_uri = ?2
           """,
           [tenant_id, resource_uri]
         ) do
      {:ok, rows} ->
        Enum.map(rows, fn [principal_id, group_id, permission] ->
          %{principal_id: principal_id, group_id: group_id, permission: permission}
        end)

      _ ->
        []
    end
  end
end
