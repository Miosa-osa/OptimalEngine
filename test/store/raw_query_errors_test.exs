defmodule OptimalEngine.Store.RawQueryErrorsTest do
  use ExUnit.Case, async: false

  alias OptimalEngine.{Store, Workspace, WorkspaceTopology}

  test "a constraint violation in raw_query is an error, not an empty success" do
    id = "raw-query-#{System.unique_integer([:positive])}"

    assert {:ok, []} =
             Store.raw_query(
               "INSERT INTO backup_records (id, storage_uri) VALUES (?1, 'file:///a')",
               [id]
             )

    assert {:error, _} =
             Store.raw_query(
               "INSERT INTO backup_records (id, storage_uri) VALUES (?1, 'file:///b')",
               [id]
             )

    assert {:ok, [["file:///a"]]} =
             Store.raw_query("SELECT storage_uri FROM backup_records WHERE id = ?1", [id])
  end

  test "a runtime query error in raw_query is reported" do
    assert {:error, _} =
             Store.raw_query("SELECT id FROM contexts_fts WHERE contexts_fts MATCH ?1", [
               "\"unbalanced"
             ])
  end

  test "a failing statement inside a transaction rolls the transaction back" do
    id = "raw-txn-#{System.unique_integer([:positive])}"

    assert {:error, _} =
             Store.transaction(fn txn ->
               with {:ok, _} <-
                      Store.txn_query(
                        txn,
                        "INSERT INTO backup_records (id, storage_uri) VALUES (?1, 'x')",
                        [id]
                      ),
                    {:ok, _} <-
                      Store.txn_query(
                        txn,
                        "INSERT INTO backup_records (id, storage_uri) VALUES (?1, 'y')",
                        [id]
                      ) do
                 {:ok, :committed}
               end
             end)

    assert {:ok, [[0]]} = Store.raw_query("SELECT COUNT(*) FROM backup_records WHERE id = ?1", [id])
  end

  test "creating a duplicate workspace fails and leaves the original intact" do
    suffix = System.unique_integer([:positive])

    {:ok, original} =
      WorkspaceTopology.create_workspace(%{slug: "raw-dup-#{suffix}", name: "Original"})

    assert {:error, _} =
             WorkspaceTopology.create_workspace(%{slug: "raw-dup-#{suffix}", name: "Duplicate"})

    assert {:ok, %{name: "Original"}} = Workspace.get(original.id)
  end
end
