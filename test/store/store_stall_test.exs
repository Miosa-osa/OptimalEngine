defmodule OptimalEngine.Test.StoreStallTest do
  @moduledoc """
  The test helper that stalls the PostgreSQL store (`OptimalEngine.Test.StoreStall`)
  locks every table of the schema. `LOCK TABLE a, b, …` takes its tables one
  after another and keeps those it has while it waits for the next, so a
  background transaction that holds the last table and then wants the first
  deadlocks with it, and PostgreSQL cancels one side with 40P01. The first test
  reproduces that with one plain `LOCK TABLE` statement, as the helper used to
  take its locks; the second shows the helper no longer deadlocks.
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

  defp tables(conn) do
    %{rows: rows} =
      Postgrex.query!(
        conn,
        "SELECT c.relname::text FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace " <>
          "WHERE n.nspname = current_schema() AND c.relkind IN ('r', 'p') ORDER BY 1",
        []
      )

    List.flatten(rows)
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

  defp wait_until_stall_waits(probe) do
    assert Enum.any?(1..250, fn _ -> stall_waiting?(probe) or (Process.sleep(20) && false) end),
           "the stall never waited for the background transaction's table"
  end

  # The background transaction holds the last table, as a writer of it does,
  # while `stall` (a task) takes every table; once the stall waits for that
  # table, the background transaction asks for the first one.
  defp background_wants_first_table(stall_fun) do
    background = connect()
    probe = connect()
    [first | _] = tables = tables(background)
    last = List.last(tables)

    Postgrex.query!(background, "BEGIN", [])
    Postgrex.query!(background, ~s(LOCK TABLE "#{last}" IN ROW EXCLUSIVE MODE), [])

    stall = Task.async(fn -> stall_fun.(tables) end)
    wait_until_stall_waits(probe)

    wanted =
      Postgrex.query(background, ~s(LOCK TABLE "#{first}" IN ROW EXCLUSIVE MODE), [],
        timeout: 30_000
      )

    {wanted, background, stall}
  end

  test "one LOCK TABLE statement over every table deadlocks with that transaction" do
    {wanted, background, stall} =
      background_wants_first_table(fn tables ->
        conn = connect()
        list = Enum.map_join(tables, ", ", &~s("#{&1}"))
        Postgrex.query!(conn, "BEGIN", [])

        try do
          Postgrex.query(conn, "LOCK TABLE #{list} IN ACCESS EXCLUSIVE MODE", [], timeout: 30_000)
        after
          _ = Postgrex.query(conn, "ROLLBACK", [])
        end
      end)

    # Whichever side PostgreSQL picked, it was cancelled as a deadlock: the
    # other one then went on.
    _ = Postgrex.query(background, "ROLLBACK", [])
    taken = Task.await(stall, 40_000)

    deadlocked =
      for {:error, %Postgrex.Error{postgres: %{code: :deadlock_detected}}} <- [wanted, taken],
          do: :deadlock_detected

    assert deadlocked == [:deadlock_detected],
           "expected one side to be cancelled with 40P01: #{inspect({wanted, taken})}"
  end

  test "the helper does not deadlock with that transaction" do
    {wanted, background, stall} =
      background_wants_first_table(fn _tables -> StoreStall.stalled(fn -> {:ok, :held} end) end)

    # The stall let go of what it held, so the background transaction got its
    # table and commits; then the stall takes every table.
    assert {:ok, _} = wanted
    assert {:ok, %Postgrex.Result{command: :commit}} = Postgrex.query(background, "COMMIT", [])
    assert {:ok, :held} = Task.await(stall, 40_000)
  end
end
