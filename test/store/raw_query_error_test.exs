defmodule OptimalEngine.Store.RawQueryErrorTest do
  @moduledoc """
  raw_query must surface statement-execution errors.

  Measured failure this guards against: an api_keys INSERT referencing a
  principal that does not exist returned `{:ok, []}` while writing nothing —
  ApiKey.mint reported success for a key that was never stored, and the first
  authenticated request with it got 401. Any caller doing a write through
  raw_query was exposed to the same silent data loss.
  """

  use ExUnit.Case, async: false

  alias OptimalEngine.Store

  test "a constraint-violating INSERT surfaces an error instead of silent success" do
    result =
      Store.raw_query(
        """
        INSERT INTO api_keys (id, tenant_id, principal_id, hashed_secret, prefix, name)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6)
        """,
        [
          "cafebabe0000000000000000",
          "default",
          "principal:bestaat-niet",
          "hash",
          "prefix00",
          "fk-guard"
        ]
      )

    assert {:error, _reason} = result

    assert {:ok, [[0]]} =
             Store.raw_query("SELECT COUNT(*) FROM api_keys WHERE name = ?1", ["fk-guard"])
  end

  test "txn_query surfaces statement errors and rolls back" do
    result =
      Store.transaction(fn txn ->
        Store.txn_query(
          txn,
          """
          INSERT INTO api_keys (id, tenant_id, principal_id, hashed_secret, prefix, name)
          VALUES (?1, ?2, ?3, ?4, ?5, ?6)
          """,
          [
            "cafebabe1111111111111111",
            "default",
            "principal:bestaat-niet",
            "hash",
            "prefix11",
            "fk-guard-txn"
          ]
        )
      end)

    assert {:error, _reason} = result

    assert {:ok, [[0]]} =
             Store.raw_query("SELECT COUNT(*) FROM api_keys WHERE name = ?1", ["fk-guard-txn"])
  end
end
