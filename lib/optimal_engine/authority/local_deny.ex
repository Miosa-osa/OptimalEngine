defmodule OptimalEngine.Authority.LocalDeny do
  @moduledoc """
  Independent local denies: a stop the enforcing system keeps for itself.

  A local deny names a subject, action, and resource pattern (and optionally
  a workspace) that this Engine refuses no matter what any policy says or any
  grant carries. A fresh, validly signed grant never overrides it; only
  lifting the deny does, and lifting is itself recorded as evidence. This is
  the control a data owner keeps even when authority is delegated elsewhere.

  A deny never stops applying because an operator repaired a workspace id.
  It matches as it was written, and also as it reads after the id repairs
  recorded since it was added (`OptimalEngine.Authority.WorkspaceRekeys`): a
  deny for the old id applies to the new id, and after a merge to the
  workspace the rows were merged into.

  Following can only add denials, so it reads the recorded repairs without
  requiring their signatures: a forged repair record cannot lift a deny, it
  can only make one apply to more. (Someone who can write rows into the
  evidence table can write denies into their table as well, so a signature
  on a repair would protect nothing here.) Where a deny was added is the
  first record of it in the chain: a later record of the same deny, forged or
  not, cannot move that position forward and so cannot cut the deny off from
  a repair.
  """

  alias OptimalEngine.Authority.{Policy, WorkspaceRekeys}
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
    Store.transaction(fn txn -> add_in(txn, tenant_id, attrs, created_by) end)
  end

  @doc """
  Adds a local deny inside a Store transaction the caller already holds, so
  the deny commits or rolls back with the caller's own writes (the record of
  it in the evidence chain).
  """
  @spec add_in(term(), String.t(), map(), String.t()) :: {:ok, t()} | {:error, term()}
  def add_in(txn, tenant_id, attrs, created_by) do
    id = "deny_" <> (:crypto.strong_rand_bytes(9) |> Base.url_encode64(padding: false))

    row = [
      id,
      tenant_id,
      field(attrs, :workspace_id),
      field(attrs, :subject) || "**",
      field(attrs, :action) || "**",
      field(attrs, :resource) || "**",
      field(attrs, :reason),
      created_by
    ]

    with {:ok, _} <-
           Store.txn_execute(
             txn,
             """
             INSERT INTO authority_local_denies
               (id, tenant_id, workspace_id, subject, action, resource, reason, created_by)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
             """,
             row
           ),
         {:ok, [stored]} <-
           Store.txn_query(txn, select_sql("WHERE tenant_id = ?1 AND id = ?2"), [tenant_id, id]) do
      {:ok, to_deny(stored)}
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

  @doc """
  The first active local deny matching the request, or nil. A deny matches
  as written, or as it reads after the workspace id repairs recorded since it
  was added, against the request as asked or as it reads after any repair.
  """
  @spec matching(String.t(), map()) :: t() | nil
  def matching(tenant_id, request) do
    denies = active(tenant_id)

    # Without a repair on record this is the plain match, and costs one read.
    rekeys =
      if denies == [], do: [], else: WorkspaceRekeys.list(tenant_id, trust: :recorded)

    added = if rekeys == [], do: %{}, else: added_seqs(tenant_id)

    Enum.find(denies, &applies?(&1, request, rekeys, Map.get(added, &1.id, 0)))
  end

  defp applies?(deny, request, rekeys, seq) do
    workspace_matches?(deny.workspace_id, request[:workspace_id], rekeys, seq) and
      Policy.glob?(deny.subject, request[:subject]) and
      Policy.glob?(deny.action, request[:action]) and
      resource_matches?(deny.resource, request[:resource], rekeys, seq)
  end

  defp workspace_matches?(nil, _asked, _rekeys, _seq), do: true

  defp workspace_matches?(written, asked, rekeys, seq) do
    written_as = Enum.uniq([written, WorkspaceRekeys.current(rekeys, written, seq)])
    asked_as = Enum.uniq([asked, WorkspaceRekeys.current(rekeys, asked, 0)])
    Enum.any?(asked_as, &(&1 in written_as))
  end

  defp resource_matches?(pattern, resource, rekeys, seq) do
    patterns = Enum.uniq([pattern, WorkspaceRekeys.current_resource(rekeys, pattern, seq)])
    resources = Enum.uniq([resource, WorkspaceRekeys.current_resource(rekeys, resource, 0)])
    Enum.any?(for(p <- patterns, r <- resources, do: Policy.glob?(p, r)))
  end

  # Where in the evidence chain each deny was first recorded, so a repair made
  # before the deny was added does not reach it. The first record counts: a
  # later record of the same deny cannot push the position forward. A deny
  # with no record (the Engine could not sign evidence when it was added)
  # reads every repair.
  defp added_seqs(tenant_id) do
    {:ok, rows} =
      Store.raw_query(
        """
        SELECT json_extract(detail, '$.deny_id'), MIN(tenant_seq) FROM authority_evidence
        WHERE tenant_id = ?1 AND kind = 'local_deny.added' AND json_valid(detail)
        GROUP BY json_extract(detail, '$.deny_id')
        """,
        [tenant_id]
      )

    Map.new(rows, fn [id, seq] -> {id, seq} end)
  end

  @doc "One local deny, active or lifted."
  @spec get(String.t(), String.t()) :: {:ok, t()} | {:error, :not_found}
  def get(tenant_id, id) do
    case Store.raw_query(select_sql("WHERE tenant_id = ?1 AND id = ?2"), [tenant_id, id]) do
      {:ok, [row]} -> {:ok, to_deny(row)}
      _ -> {:error, :not_found}
    end
  end

  defp field(attrs, name) when is_atom(name) do
    case Map.get(attrs, Atom.to_string(name)) || Map.get(attrs, name) do
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
