defmodule OptimalEngine.Authority.LocalDeny do
  @moduledoc """
  Independent local denies: a stop the enforcing system keeps for itself.

  A local deny names a subject, action, and resource pattern (and optionally
  a workspace) that this Engine refuses no matter what any policy says or any
  grant carries. A fresh, validly signed grant never overrides it; only
  lifting the deny does, and lifting is itself recorded as evidence. This is
  the control a data owner keeps even when authority is delegated elsewhere.
  """

  alias OptimalEngine.Authority.Policy
  alias OptimalEngine.Store

  @type t :: %{
          id: String.t(),
          tenant_id: String.t(),
          workspace_id: String.t() | nil,
          subject: String.t(),
          action: String.t(),
          resource: String.t(),
          reason: String.t() | nil,
          created_by: String.t() | nil,
          created_at: String.t() | nil
        }

  @doc "Adds a local deny. Patterns default to `**` (everything)."
  @spec add(String.t(), map(), String.t()) :: {:ok, t()} | {:error, term()}
  def add(tenant_id, attrs, created_by) do
    id = "deny_" <> (:crypto.strong_rand_bytes(9) |> Base.url_encode64(padding: false))

    row = [
      id,
      tenant_id,
      field(attrs, "workspace_id"),
      field(attrs, "subject") || "**",
      field(attrs, "action") || "**",
      field(attrs, "resource") || "**",
      field(attrs, "reason"),
      created_by
    ]

    case Store.raw_query(
           """
           INSERT INTO authority_local_denies
             (id, tenant_id, workspace_id, subject, action, resource, reason, created_by)
           VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
           """,
           row
         ) do
      {:ok, _} -> get(tenant_id, id)
      error -> error
    end
  end

  @doc "Lifts a local deny. Returns `{:error, :not_found}` if it is not active."
  @spec lift(String.t(), String.t(), String.t()) :: {:ok, t()} | {:error, :not_found}
  def lift(tenant_id, id, lifted_by) do
    with {:ok, deny} <- get(tenant_id, id),
         {:ok, 1} <-
           Store.transaction(fn txn ->
             Store.txn_execute(
               txn,
               """
               UPDATE authority_local_denies SET lifted_at = datetime('now'), lifted_by = ?3
               WHERE tenant_id = ?1 AND id = ?2 AND lifted_at IS NULL
               """,
               [tenant_id, id, lifted_by]
             )
           end) do
      {:ok, deny}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc "Active local denies in the tenant."
  @spec active(String.t()) :: [t()]
  def active(tenant_id) do
    {:ok, rows} =
      Store.raw_query(
        select_sql("WHERE tenant_id = ?1 AND lifted_at IS NULL ORDER BY created_at"),
        [tenant_id]
      )

    Enum.map(rows, &to_deny/1)
  end

  @doc "The first active local deny matching the request, or nil."
  @spec matching(String.t(), map()) :: t() | nil
  def matching(tenant_id, request) do
    Enum.find(active(tenant_id), fn deny ->
      (is_nil(deny.workspace_id) or deny.workspace_id == request[:workspace_id]) and
        Policy.glob?(deny.subject, request[:subject]) and
        Policy.glob?(deny.action, request[:action]) and
        Policy.glob?(deny.resource, request[:resource])
    end)
  end

  @doc "One local deny, active or lifted."
  @spec get(String.t(), String.t()) :: {:ok, t()} | {:error, :not_found}
  def get(tenant_id, id) do
    case Store.raw_query(select_sql("WHERE tenant_id = ?1 AND id = ?2"), [tenant_id, id]) do
      {:ok, [row]} -> {:ok, to_deny(row)}
      _ -> {:error, :not_found}
    end
  end

  defp field(attrs, name) do
    case Map.get(attrs, name) || Map.get(attrs, String.to_atom(name)) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp select_sql(where) do
    """
    SELECT id, tenant_id, workspace_id, subject, action, resource, reason, created_by, created_at,
           lifted_at, lifted_by
    FROM authority_local_denies #{where}
    """
  end

  defp to_deny([
         id,
         tenant,
         workspace,
         subject,
         action,
         resource,
         reason,
         by,
         at,
         lifted_at,
         lifted_by
       ]) do
    %{
      id: id,
      tenant_id: tenant,
      workspace_id: workspace,
      subject: subject,
      action: action,
      resource: resource,
      reason: reason,
      created_by: by,
      created_at: at,
      lifted_at: lifted_at,
      lifted_by: lifted_by
    }
  end
end
