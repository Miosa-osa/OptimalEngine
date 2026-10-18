defmodule OptimalEngine.AppData.Scope do
  @moduledoc """
  Who is acting on app data and what they may touch.

  Built by the HTTP layer from the authenticated key (never from the request
  body) and passed to every `OptimalEngine.AppData` call:

  * `tenant_id`, `workspace_id` - every collection belongs to one workspace.
  * `actor` - the acting principal, recorded on records and changes.
  * `owner` - set for owner-bound credentials (data keys minted with an
    owner). Reads, updates and deletes of collections with an owner field
    only see that owner's rows, and new rows are owned by it.
  * `collections`, `operations` - `:all` or the lists a data key allows.
    Operations are `read`, `create`, `update`, `delete`.
  * `admin` - may change schemas and write rows owned by someone else.
    Trusted local callers and keys holding `*` or `data:admin` are admins.
  * `keyed` - the caller authenticated with an API key.
  """

  @operations ~w(read create update delete)

  defstruct tenant_id: "default",
            workspace_id: nil,
            actor: "local:operator",
            owner: nil,
            collections: :all,
            operations: :all,
            admin: true,
            keyed: false

  @type t :: %__MODULE__{
          tenant_id: String.t(),
          workspace_id: String.t(),
          actor: String.t(),
          owner: String.t() | nil,
          collections: :all | [String.t()],
          operations: :all | [String.t()],
          admin: boolean(),
          keyed: boolean()
        }

  @doc "Operations a data key may be limited to."
  @spec operations() :: [String.t()]
  def operations, do: @operations

  @doc "Builds a scope from keyword options (see the struct fields)."
  @spec new(keyword()) :: t()
  def new(opts), do: struct!(__MODULE__, opts)

  @doc "True when rows are filtered to the scope's owner."
  @spec owner_bound?(t()) :: boolean()
  def owner_bound?(%__MODULE__{owner: owner}), do: is_binary(owner)

  @doc "Checks the scope may perform `operation` on collection `name`."
  @spec allow(t(), String.t(), String.t()) :: :ok | {:error, {:forbidden, String.t()}}
  def allow(%__MODULE__{} = scope, name, operation) do
    cond do
      not allowed?(scope.collections, name) -> {:error, {:forbidden, "collection_not_allowed"}}
      not allowed?(scope.operations, operation) -> {:error, {:forbidden, "operation_not_allowed"}}
      true -> :ok
    end
  end

  @doc "Checks the scope may change schemas."
  @spec allow_admin(t()) :: :ok | {:error, {:forbidden, String.t()}}
  def allow_admin(%__MODULE__{admin: true, owner: nil, collections: :all}), do: :ok
  def allow_admin(_scope), do: {:error, {:forbidden, "data_admin_required"}}

  @doc "True when the scope may read collection `name`."
  @spec readable?(t(), String.t()) :: boolean()
  def readable?(scope, name), do: allow(scope, name, "read") == :ok

  defp allowed?(:all, _value), do: true
  defp allowed?(list, value) when is_list(list), do: "*" in list or value in list
end
