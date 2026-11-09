defmodule OptimalEngine.Connectors.IngestFence do
  @moduledoc """
  The last check of a connector's ingest, made inside the transaction that
  writes it: the workspace is still the tenant's and active, and the connector
  still exists. On PostgreSQL both rows are locked (`FOR UPDATE`) first, so an
  archive, a move or a connector delete that commits before the write makes
  the write refuse; on SQLite the store runs one writer at a time, so the
  check and the write cannot be split by another write.

  A queued Signal (`OptimalEngine.Storage.NATS.IntakeQueue`) is checked when
  it is taken off the queue and again here, where the source package and the
  context are written (`OptimalEngine.Pipeline.Intake`).
  """

  @type t :: %{tenant_id: String.t(), workspace_id: String.t(), connector_id: String.t()}

  @doc "The fence a scope asks for (`fence: true`), or nil."
  @spec from_scope(String.t(), String.t(), map()) :: t() | nil
  def from_scope(tenant_id, workspace_id, scope) do
    if Map.get(scope, :fence) == true and is_binary(Map.get(scope, :connector_id)) do
      %{tenant_id: tenant_id, workspace_id: workspace_id, connector_id: scope.connector_id}
    end
  end

  @doc """
  Checks `fence` with `query` (`(sql, params) -> {:ok, rows} | {:error, reason}`),
  in the dialect `:sqlite` (`?n`, no lock) or `:postgres` (`$n`, row locks).
  `:ok`, `{:error, {:fenced, :workspace_not_active}}`,
  `{:error, {:fenced, :connector_gone}}`, or the query's error.
  """
  @spec check(
          (String.t(), list() -> {:ok, list()} | {:error, term()}),
          t() | nil,
          :sqlite | :postgres
        ) ::
          :ok | {:error, term()}
  def check(_query, nil, _dialect), do: :ok

  def check(query, %{} = fence, dialect) do
    {workspace_sql, connector_sql} = statements(dialect)

    with {:ok, workspace} <- query.(workspace_sql, [fence.workspace_id]),
         {:ok, connector} <- query.(connector_sql, [fence.connector_id, fence.tenant_id]) do
      cond do
        workspace != [[fence.tenant_id, "active"]] -> {:error, {:fenced, :workspace_not_active}}
        connector == [] -> {:error, {:fenced, :connector_gone}}
        true -> :ok
      end
    end
  end

  @doc """
  Checks `fence` inside a `OptimalEngine.Store.transaction/2`, after locking
  the workspace's and the connector's rows (`Store.txn_lock_row/4`, nothing on
  SQLite).
  """
  @spec check_in(term(), t() | nil) :: :ok | {:error, term()}
  def check_in(_txn, nil), do: :ok

  def check_in(txn, fence) do
    alias OptimalEngine.Store

    with :ok <- Store.txn_lock_row(txn, "workspaces", "id", fence.workspace_id),
         :ok <- Store.txn_lock_row(txn, "connectors", "id", fence.connector_id) do
      check(&Store.txn_query(txn, &1, &2), fence, :sqlite)
    end
  end

  defp statements(:sqlite) do
    {"SELECT tenant_id, status FROM workspaces WHERE id = ?1",
     "SELECT 1 FROM connectors WHERE id = ?1 AND tenant_id = ?2"}
  end

  defp statements(:postgres) do
    {"SELECT tenant_id, status FROM workspaces WHERE id = $1 FOR UPDATE",
     "SELECT 1 FROM connectors WHERE id = $1 AND tenant_id = $2 FOR UPDATE"}
  end
end
