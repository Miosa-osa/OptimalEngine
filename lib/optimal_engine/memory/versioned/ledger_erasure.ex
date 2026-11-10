defmodule OptimalEngine.Memory.Versioned.LedgerErasure do
  @moduledoc """
  What forgetting or deleting a memory takes out of the replication ledger
  (`OptimalEngine.Sync.Redaction`), in the transaction of the write.

  * A forget marks the row and, in the same transaction, redacts every change
    of it the ledger holds: the create and every update keep their place with
    the row's key and a `redacted` marker, the captured rows not sealed yet
    (the mark included) are dropped, the memory's embeddings' changes go too,
    and, for a workspace that replicates, a redaction request is recorded. A
    peer that applies it erases by its own rule for memories
    (`Sync.Redaction.erasure_rule/1`): it redacts its copies, deletes its
    embeddings of the memory and marks its row forgotten with no text. A
    replica that never had the memory never gets it.
  * A delete removes the row and, in the same transaction, redacts the earlier
    changes of it and of the rows its foreign keys cascade to (relations,
    embeddings); the deletes replicate as deletes.

  Afterwards `flush/1` has the NATS ledger publisher purge the row's subjects.
  """

  alias OptimalEngine.Store
  alias OptimalEngine.Sync.Redaction

  @doc "Marks memory `id` forgotten and redacts its changes, in one transaction."
  @spec forget(map() | nil, String.t(), String.t() | nil, String.t() | nil) ::
          {:ok, term()} | {:error, term()}
  def forget(memory, id, reason, forget_after) do
    Store.transaction(fn txn ->
      with {:ok, _} <-
             Store.txn_execute(
               txn,
               """
               UPDATE memories
               SET is_forgotten = 1, forget_reason = ?2, forget_after = ?3,
                   updated_at = datetime('now')
               WHERE id = ?1
               """,
               [id, reason, forget_after]
             ) do
        redact(txn, memory, id)
      end
    end)
  end

  @doc "Deletes memory `id` and redacts its changes, in one transaction."
  @spec delete(map() | nil, String.t()) :: {:ok, term()} | {:error, term()}
  def delete(memory, id) do
    result =
      Store.transaction(fn txn ->
        with {:ok, deleted} <- Store.txn_execute(txn, "DELETE FROM memories WHERE id = ?1", [id]),
             {:ok, _} <- Redaction.redact_deleted(txn, workspaces(memory)) do
          {:ok, deleted}
        end
      end)

    # A workspace that does not replicate captured no delete.
    if match?({:ok, _}, result), do: Redaction.redact_missing(workspaces(memory))
    result
  end

  @doc "After the commit: the publisher's pass over the memory's workspace."
  @spec flush(map() | nil) :: :ok
  def flush(memory) do
    _ = Redaction.flush_nats(workspaces(memory))
    :ok
  end

  # Erased after the mark, so what the request restates is the row as the
  # forget left it.
  defp redact(_txn, nil, _id), do: {:ok, 0}

  defp redact(txn, memory, id) do
    case memory.workspace_id do
      ws when is_binary(ws) ->
        Redaction.redact_rows(txn, ws, "memories", [id],
          tenant_id: memory.tenant_id || "default",
          reason: "memory_forget"
        )

      _ ->
        {:ok, 0}
    end
  end

  defp workspaces(%{workspace_id: ws}) when is_binary(ws), do: [ws]
  defp workspaces(_memory), do: []
end
