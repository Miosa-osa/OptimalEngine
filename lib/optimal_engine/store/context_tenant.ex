defmodule OptimalEngine.Store.ContextTenant do
  @moduledoc """
  The tenant a context row is written under.

  A workspace id does not say whose a write is: a registered workspace has an
  owner, but a bare id (one with no workspace row) is accepted for
  single-tenant compatibility and can be shared by two tenants. Deriving the
  tenant from the workspace row alone would file a non-default tenant's write
  under `default`, in the default tenant's rows. The writer instead decides
  from three facts it reads inside its own transaction:

    * `stated`: the tenant the writer named on the `Context` (`nil` if none),
    * `owner`: the tenant that owns the workspace id: its registered
      workspace's tenant, else the tenant its `"<tenant>:"` prefix names
      (`nil` for a bare id),
    * `existing`: the tenant and workspace of the row with the same id, if
      one is there.

  ## The tenant

  | stated        | workspace  | the row is written under                       |
  | ------------- | ---------- | ---------------------------------------------- |
  | none          | owned      | the owner                                      |
  | none          | bare       | the tenant of the row it replaces, else `default` |
  | the owner     | owned      | the owner                                      |
  | `default`     | owned      | the owner (the trusted local operator)         |
  | another       | owned      | refused, `:workspace_tenant_mismatch`          |
  | any           | bare       | the stated tenant                              |

  ## The row it replaces

  A context id is global. Ids that a connector derives from the workspace id
  and a source id are the same in every tenant that shares a bare workspace
  id, so a write under a bare id that names an id another tenant holds would
  replace that tenant's row. It is refused (`:context_id_in_use`) and the row
  stays as it was. A workspace with an owner keeps ids apart by itself: the
  owner is the authority there, and a row written before the workspace was
  registered, under `default`, is taken over by the owner on its next write.
  """

  alias OptimalEngine.{Context, Store}
  alias OptimalEngine.Tenancy.Tenant

  # The owner of a workspace id: its registered workspace's tenant, else the
  # tenant its "<tenant>:" prefix names, else none (a bare id). Written for
  # SQLite; the PostgreSQL store reads it through the dialect, or with its own
  # statement inside the transaction of a write.
  @owner_sql """
  SELECT COALESCE((SELECT w.tenant_id FROM workspaces w WHERE w.id = ?1),
                  (SELECT t.id FROM tenants t WHERE t.id = substr(?1, 1, instr(?1, ':') - 1)))
  """

  @existing_sql "SELECT tenant_id, workspace_id FROM contexts WHERE id = ?1"

  @typedoc """
  What a store gives `for_context/2` to read the two facts about the database:
  `:owner` is asked with `[workspace_id]` and answers a row holding the
  owner's tenant (`nil` for a bare id); `:existing` is asked with
  `[context_id]` and answers the `[tenant_id, workspace_id]` of the row, or
  `nil`.
  """
  @type lookup ::
          (:owner | :existing, [String.t()] -> {:ok, [term()] | nil} | {:error, term()})

  @type existing :: {tenant_id :: String.t(), workspace_id :: String.t()} | nil

  @doc "The statement `lookup/2` answers `:owner` with, for a store on SQLite's dialect."
  @spec owner_sql() :: String.t()
  def owner_sql, do: @owner_sql

  @doc "The statement `lookup/2` answers `:existing` with, for a store on SQLite's dialect."
  @spec existing_sql() :: String.t()
  def existing_sql, do: @existing_sql

  @doc """
  Whether a write of context `id` into `workspace_id` for `tenant_id` (`nil`
  names none) would be taken, before anything is done for it.

  A pipeline that writes a file before the row asks first, so a refused write
  leaves no file behind. The answer is read outside the write's transaction:
  the store decides again, atomically, when it writes, and its answer is the
  one that counts.
  """
  @spec check(String.t(), String.t(), String.t() | nil) :: :ok | {:error, term()}
  def check(id, workspace_id, tenant_id) do
    context = %Context{id: id, workspace_id: workspace_id, tenant_id: tenant_id}

    with {:ok, _tenant} <-
           for_context(context, fn
             :owner, params -> first_row(@owner_sql, params)
             :existing, params -> first_row(@existing_sql, params)
           end),
         do: :ok
  end

  defp first_row(sql, params) do
    with {:ok, rows} <- Store.raw_query(sql, params), do: {:ok, List.first(rows)}
  end

  @doc """
  The tenant a store writes `context` under, or the reason it refuses.

  `lookup` reads the owner and the existing row from the store's own database,
  in the transaction of the write, so no other write comes between.
  """
  @spec for_context(Context.t(), lookup()) :: {:ok, String.t()} | {:error, term()}
  def for_context(%Context{id: id} = context, lookup) when is_function(lookup, 2) do
    workspace_id = context.workspace_id || "default"

    with {:ok, owner} <- lookup.(:owner, [workspace_id]),
         {:ok, existing} <- lookup.(:existing, [id]) do
      resolve(%{
        id: id,
        workspace_id: workspace_id,
        stated: context.tenant_id,
        owner: owner && hd(owner),
        existing: existing && List.to_tuple(existing)
      })
    end
  end

  @doc """
  Decides the tenant for a context write, or refuses it.

  `facts` has the context `:id` and `:workspace_id`, the `:stated` tenant, the
  workspace's `:owner`, and the `:existing` row (see the moduledoc).
  """
  @spec resolve(%{
          id: String.t(),
          workspace_id: String.t(),
          stated: String.t() | nil,
          owner: String.t() | nil,
          existing: existing()
        }) :: {:ok, String.t()} | {:error, term()}
  def resolve(%{id: id, workspace_id: workspace, owner: owner, existing: existing} = facts) do
    stated = named(facts.stated)

    with {:ok, tenant} <- choose(stated, owner, existing, workspace),
         :ok <- replaceable(id, tenant, owner, existing) do
      {:ok, tenant}
    end
  end

  defp named(tenant) when is_binary(tenant) and tenant != "", do: tenant
  defp named(_tenant), do: nil

  # Nothing named, nothing registered, nothing there: the default tenant.
  defp choose(nil, nil, nil, _workspace), do: {:ok, Tenant.default_id()}
  defp choose(nil, nil, {tenant, _workspace}, _), do: {:ok, tenant}
  defp choose(nil, owner, _existing, _workspace), do: {:ok, owner}
  defp choose(stated, nil, _existing, _workspace), do: {:ok, stated}
  defp choose(owner, owner, _existing, _workspace), do: {:ok, owner}

  defp choose(stated, owner, _existing, workspace) do
    if stated == Tenant.default_id(),
      do: {:ok, owner},
      else: {:error, {:workspace_tenant_mismatch, workspace, stated, owner}}
  end

  # Only under a bare workspace id can the id be another tenant's by design.
  defp replaceable(id, tenant, nil, {held_by, _workspace}) do
    if held_by == tenant, do: :ok, else: {:error, {:context_id_in_use, id}}
  end

  defp replaceable(_id, _tenant, _owner, _existing), do: :ok
end
