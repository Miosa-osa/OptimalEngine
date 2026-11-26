defmodule OptimalEngine.Test.StoreStall do
  @moduledoc false
  # Runs `fun` while the Engine's store does not answer, as a long write or a
  # store warming up after boot would leave it.
  #
  # SQLite's store is one process: it is suspended. PostgreSQL's store answers
  # from a pool in the caller, so a connection of its own holds every table of
  # the store's schema in ACCESS EXCLUSIVE mode, and every statement waits.
  #
  # LOCK TABLE takes its tables one after another and keeps the ones it has
  # while it waits for the next. A background statement (a job, a seal) that
  # holds a later table and then wants an earlier one would wait on the stall
  # while the stall waits on it: a deadlock, in which PostgreSQL cancels one of
  # them. So the stall waits for its locks only briefly (less than the
  # server's deadlock_timeout, so no cycle lasts long enough to be detected),
  # and when they do not all come it lets go of every table, waits a little
  # and takes them again.

  alias OptimalEngine.Store

  # How long the stall keeps trying to take every table, and how long each
  # try waits for a lock.
  @acquire_ms 30_000
  @try_lock_ms 200

  # A hold the test never releases ends here and answers `:never_released`, so a
  # forgotten `release/1` fails the test instead of hanging it.
  @max_hold_ms 60_000

  @doc """
  Stalls the store from a task of its own and returns once it is stalled. The
  store stays stalled until `release/1`: a fixed window lets a slow caller (one
  queued behind a reconnecting pool connection) reach the store after it is
  answering again, and pass or fail by timing alone.
  """
  def hold do
    parent = self()

    task =
      Task.async(fn ->
        stalled(fn ->
          send(parent, {__MODULE__, :holding})
          until_released()
        end)
      end)

    receive do
      {__MODULE__, :holding} -> task
    after
      @acquire_ms + 5_000 -> raise "the store did not stall"
    end
  end

  @doc "Ends a stall from `hold/0` or `hold_tables/1`; answers `{:ok, :released}`."
  def release(%Task{pid: pid} = task) do
    send(pid, {__MODULE__, :release})
    Task.await(task, 10_000)
  end

  defp until_released do
    receive do
      {__MODULE__, :release} -> {:ok, :released}
    after
      @max_hold_ms -> :never_released
    end
  end

  @doc """
  On PostgreSQL, holds `tables` in ACCESS EXCLUSIVE mode from a connection of
  its own until `release/1`, and returns once they are held.
  """
  def hold_tables(tables) do
    parent = self()

    task =
      Task.async(fn ->
        conn = connect()

        try do
          Postgrex.query!(conn, "BEGIN", [])
          list = Enum.map_join(tables, ", ", &~s("#{&1}"))
          Postgrex.query!(conn, "LOCK TABLE #{list} IN ACCESS EXCLUSIVE MODE", [], timeout: 60_000)
          send(parent, {__MODULE__, :holding})
          until_released()
        after
          _ = Postgrex.query(conn, "ROLLBACK", [])
          GenServer.stop(conn)
        end
      end)

    receive do
      {__MODULE__, :holding} -> task
    after
      5_000 -> raise "the tables were not held"
    end
  end

  def stalled(fun) do
    if Store.selected?(OptimalEngine.Store.Postgres), do: postgres(fun), else: sqlite(fun)
  end

  defp sqlite(fun) do
    store = Process.whereis(OptimalEngine.Store.SQLite)
    :sys.suspend(store)

    try do
      fun.()
    after
      :sys.resume(store)
    end
  end

  defp postgres(fun) do
    conn = connect()

    try do
      # Every table of the schema, the full-text index's own included.
      %{rows: rows} =
        Postgrex.query!(
          conn,
          "SELECT c.relname::text FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace " <>
            "WHERE n.nspname = current_schema() AND c.relkind IN ('r', 'p') ORDER BY 1",
          []
        )

      list = Enum.map_join(rows, ", ", fn [table] -> ~s("#{table}") end)
      lock_all(conn, list, System.monotonic_time(:millisecond) + @acquire_ms)
      fun.()
    after
      _ = Postgrex.query(conn, "ROLLBACK", [])
      GenServer.stop(conn)
    end
  end

  # Holds every table in one transaction, or none: a try that a lock does not
  # come to in time, or that PostgreSQL picks to end a deadlock, is rolled
  # back, so the stall never waits while holding part of the schema.
  defp lock_all(conn, list, deadline) do
    Postgrex.query!(conn, "BEGIN", [])
    Postgrex.query!(conn, "SET LOCAL lock_timeout = #{@try_lock_ms}", [])

    case Postgrex.query(conn, "LOCK TABLE #{list} IN ACCESS EXCLUSIVE MODE", [], timeout: 60_000) do
      {:ok, _} ->
        :ok

      {:error, %Postgrex.Error{postgres: %{code: code}} = error}
      when code in [:lock_not_available, :deadlock_detected] ->
        Postgrex.query!(conn, "ROLLBACK", [])

        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(10 + :rand.uniform(90))
          lock_all(conn, list, deadline)
        else
          raise error
        end

      {:error, error} ->
        raise error
    end
  end

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
end
