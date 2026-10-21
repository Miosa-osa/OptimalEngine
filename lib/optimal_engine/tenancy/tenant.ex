defmodule OptimalEngine.Tenancy.Tenant do
  @moduledoc """
  A tenant is the hard security and account boundary for isolated data and ACLs.
  One tenant can contain many organizations, and each organization can own many
  workspaces.
  For v0.1, single-tenant deployments use the `"default"` tenant seeded
  automatically by migration 015.

  ## Invariants

  - Every primary table row carries a `tenant_id`.
  - No cross-tenant reads, ever. Queries must pass a tenant scope.
  - The `default` tenant is reserved and cannot be deleted.
  """

  alias OptimalEngine.Store

  @default_id "default"

  # What a tenant id is: it prefixes the ids of the tenant's workspaces
  # (`<tenant_id>:<slug>`) and names a directory (`<root>/tenants/<tenant_id>`),
  # so it holds no colon or slash, starts with a letter or digit, and is no
  # relative path segment.
  @id_format ~r/\A[A-Za-z0-9][A-Za-z0-9._-]{0,127}\z/

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          plan: String.t(),
          region: String.t() | nil,
          created_at: String.t() | nil,
          metadata: map()
        }

  defstruct id: nil,
            name: nil,
            plan: "default",
            region: nil,
            created_at: nil,
            metadata: %{}

  @doc "Returns the reserved default-tenant id."
  @spec default_id() :: String.t()
  def default_id, do: @default_id

  @doc "Returns the tenant with the given id, or `{:error, :not_found}`."
  @spec get(String.t()) :: {:ok, t()} | {:error, :not_found}
  def get(id) when is_binary(id) do
    case Store.raw_query(
           "SELECT id, name, plan, region, created_at, metadata FROM tenants WHERE id = ?1",
           [id]
         ) do
      {:ok, [[tid, name, plan, region, created_at, meta_json]]} ->
        {:ok,
         %__MODULE__{
           id: tid,
           name: name,
           plan: plan,
           region: region,
           created_at: created_at,
           metadata: decode_json(meta_json)
         }}

      {:ok, []} ->
        {:error, :not_found}

      other ->
        other
    end
  end

  @doc """
  Checks a tenant id: letters, digits, dots, dashes and underscores, starting
  with a letter or digit, at most 128 characters and no `..`
  (`{:error, :invalid_tenant_id}` otherwise). A tenant whose id holds a colon
  would have no workspace ids, because the id of a workspace is the tenant's id,
  a colon and a slug.
  """
  @spec check_id(term()) :: :ok | {:error, :invalid_tenant_id}
  def check_id(id) when is_binary(id) do
    if Regex.match?(@id_format, id) and not String.contains?(id, ".."),
      do: :ok,
      else: {:error, :invalid_tenant_id}
  end

  def check_id(_id), do: {:error, :invalid_tenant_id}

  @doc """
  Creates a new tenant. Returns `{:ok, tenant}` or `{:error, reason}`
  (`:invalid_tenant_id` for an id `check_id/1` refuses). A tenant row from
  before ids were checked keeps working.
  """
  @spec create(map()) :: {:ok, t()} | {:error, term()}
  def create(%{id: id, name: name} = attrs) when is_binary(id) and is_binary(name) do
    plan = Map.get(attrs, :plan, "default")
    region = Map.get(attrs, :region)
    metadata = Map.get(attrs, :metadata, %{})

    with :ok <- check_id(id) do
      case Store.raw_query(
             """
             INSERT INTO tenants (id, name, plan, region, metadata)
             VALUES (?1, ?2, ?3, ?4, ?5)
             """,
             [id, name, plan, region, Jason.encode!(metadata)]
           ) do
        {:ok, _} ->
          {:ok, %__MODULE__{id: id, name: name, plan: plan, region: region, metadata: metadata}}

        other ->
          other
      end
    end
  end

  @doc "Lists all tenants."
  @spec list() :: {:ok, [t()]}
  def list do
    case Store.raw_query(
           "SELECT id, name, plan, region, created_at, metadata FROM tenants ORDER BY id",
           []
         ) do
      {:ok, rows} ->
        tenants =
          Enum.map(rows, fn [id, name, plan, region, created_at, meta_json] ->
            %__MODULE__{
              id: id,
              name: name,
              plan: plan,
              region: region,
              created_at: created_at,
              metadata: decode_json(meta_json)
            }
          end)

        {:ok, tenants}

      other ->
        other
    end
  end

  @doc """
  Sets one key of the tenant's metadata; `nil` removes it. The read and the
  write run in one Store transaction, so concurrent changes to other keys
  are kept.
  """
  @spec put_metadata(String.t(), String.t(), term()) :: {:ok, map()} | {:error, term()}
  def put_metadata(id, key, value) when is_binary(id) and is_binary(key) do
    Store.transaction(fn txn ->
      case Store.txn_query(txn, "SELECT metadata FROM tenants WHERE id = ?1", [id]) do
        {:ok, [[meta_json]]} ->
          metadata = decode_json(meta_json)

          metadata =
            if is_nil(value), do: Map.delete(metadata, key), else: Map.put(metadata, key, value)

          with {:ok, _} <-
                 Store.txn_execute(txn, "UPDATE tenants SET metadata = ?2 WHERE id = ?1", [
                   id,
                   Jason.encode!(metadata)
                 ]) do
            {:ok, metadata}
          end

        {:ok, []} ->
          {:error, :not_found}

        error ->
          error
      end
    end)
  end

  defp decode_json(nil), do: %{}
  defp decode_json(""), do: %{}

  defp decode_json(str) when is_binary(str) do
    case Jason.decode(str) do
      {:ok, m} -> m
      _ -> %{}
    end
  end
end
