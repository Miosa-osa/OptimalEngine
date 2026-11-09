defmodule OptimalEngine.Test.StoreStallTest do
  @moduledoc """
  The test helper that stalls the PostgreSQL store (`OptimalEngine.Test.StoreStall`)
  locks every table of the schema, one after another. A background transaction
  that holds the last of them and then wants the first must not deadlock with it.
  """
  use ExUnit.Case, async: false

  @moduletag :postgres_store

  alias OptimalEngine.Test.StoreStall

  defp connect do
    {:ok, config} = OptimalEngine.Storage.Postgres.config()

    schema =
      Keyword.get(Application.get_env(:optimal_engine, :postgres_store, []), :schema, "public")

    {:ok, conn} =
      config
      |> Map.take([:hostname, :port, :database, :username, :password, :ssl])
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Keyword.merge(pool_size: 1, parameters: [search_path: schema])
      |> Postgrex.start_link()

    conn
  end

  defp stall_waiting?(conn) do
    %{rows: [[n]]} =
      Postgrex.query!(
        conn,
        "SELECT COUNT(*) FROM pg_locks WHERE locktype = 'relation' AND mode = 'AccessExclusiveLock' AND NOT granted",
        []
      )

    n > 0
  end

  test "a transaction that holds a late table and then wants an early one is not deadlocked" do
    background = connect()
    probe = connect()

    %{rows: rows} =
      Postgrex.query!(
        background,
        "SELECT c.relname::text FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace " <>
          "WHERE n.nspname = current_schema() AND c.relkind IN ('r', 'p') ORDER BY 1",
        []
      )

    [first | _] = tables = List.flatten(rows)
    last = List.last(tables)

    # The background transaction holds the last table, as a writer of it does.
    Postgrex.query!(background, "BEGIN", [])
    Postgrex.query!(background, ~s(LOCK TABLE "#{last}" IN ROW EXCLUSIVE MODE), [])

    stall = Task.async(fn -> StoreStall.stalled(fn -> {:ok, :held} end) end)
    assert Enum.any?(1..100, fn _ -> stall_waiting?(probe) or (Process.sleep(20) && false) end)

    # Now it wants the first table, which the stall took already.
    assert {:ok, _} =
             Postgrex.query(background, ~s(LOCK TABLE "#{first}" IN ROW EXCLUSIVE MODE), [],
               timeout: 30_000
             )

    assert {:ok, %Postgrex.Result{command: :commit}} = Postgrex.query(background, "COMMIT", [])
    assert {:ok, :held} = Task.await(stall, 40_000)
  end
end
