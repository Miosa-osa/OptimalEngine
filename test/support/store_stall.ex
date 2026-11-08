defmodule OptimalEngine.Test.StoreStall do
  @moduledoc false
  # Runs `fun` while the Engine's store does not answer, as a long write or a
  # store warming up after boot would leave it.
  #
  # SQLite's store is one process: it is suspended. PostgreSQL's store answers
  # from a pool in the caller, so a connection of its own holds every table of
  # the store's schema in ACCESS EXCLUSIVE mode, and every statement waits.

  alias OptimalEngine.Store

  @doc """
  Stalls the store for `ms` from a task of its own and returns once it is
  stalled; the task answers `{:ok, :released}` when the store answers again.
  """
  def hold(ms) do
    parent = self()

    task =
      Task.async(fn ->
        stalled(fn ->
          send(parent, {__MODULE__, :holding})
          Process.sleep(ms)
          {:ok, :released}
        end)
      end)

    receive do
      {__MODULE__, :holding} -> task
    after
      5_000 -> raise "the store did not stall"
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
      Postgrex.query!(conn, "BEGIN", [])

      # Every table of the schema, the full-text index's own included.
      %{rows: rows} =
        Postgrex.query!(
          conn,
          "SELECT c.relname::text FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace " <>
            "WHERE n.nspname = current_schema() AND c.relkind IN ('r', 'p') ORDER BY 1",
          []
        )

      list = Enum.map_join(rows, ", ", fn [table] -> ~s("#{table}") end)
      Postgrex.query!(conn, "LOCK TABLE #{list} IN ACCESS EXCLUSIVE MODE", [], timeout: 60_000)
      fun.()
    after
      _ = Postgrex.query(conn, "ROLLBACK", [])
      GenServer.stop(conn)
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
