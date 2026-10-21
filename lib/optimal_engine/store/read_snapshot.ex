defmodule OptimalEngine.Store.ReadSnapshot do
  @moduledoc """
  A consistent read of the embedded SQLite store on a connection of its own.

  `run/1` opens a read-only connection to the Store's database file, begins a
  transaction, and hands it to a function. Every query through it sees the
  database as it was at its first read, whatever the Store commits in the
  meantime: in WAL mode SQLite keeps that version for the reader. The reads
  run in the caller's process, outside the Store GenServer, so a long read
  neither holds up requests nor runs into the Store's call timeout.

  It is for an answer that must come from one moment, such as a workspace
  bundle, whose ledger mark and rows must describe the same database. Backup
  opens its own connection for `VACUUM INTO` for the same reason.
  """

  @busy_timeout_ms 5_000

  @opaque t :: {:snapshot, reference()}

  @doc """
  Runs `fun` with a snapshot of the database and returns what it returns. The
  transaction is rolled back and the connection closed however `fun` ends.
  """
  @spec run((t() -> result)) :: result | {:error, term()} when result: term()
  def run(fun) when is_function(fun, 1) do
    path = Application.fetch_env!(:optimal_engine, :db_path)

    with {:ok, db} <- Exqlite.Sqlite3.open(path, mode: :readonly) do
      try do
        with :ok <- Exqlite.Sqlite3.execute(db, "PRAGMA busy_timeout = #{@busy_timeout_ms}"),
             :ok <- Exqlite.Sqlite3.execute(db, "BEGIN") do
          try do
            fun.({:snapshot, db})
          after
            Exqlite.Sqlite3.execute(db, "ROLLBACK")
          end
        end
      after
        Exqlite.Sqlite3.close(db)
      end
    end
  end

  @doc "Runs a query in the snapshot and returns every row."
  @spec query(t(), String.t(), [term()]) :: {:ok, [[term()]]} | {:error, term()}
  def query({:snapshot, db}, sql, params \\ []) do
    with {:ok, stmt} <- Exqlite.Sqlite3.prepare(db, sql) do
      try do
        with :ok <- Exqlite.Sqlite3.bind(stmt, params), do: collect(db, stmt, [])
      after
        Exqlite.Sqlite3.release(db, stmt)
      end
    end
  end

  @doc """
  Streams the rows of a query in the snapshot as lists of at most
  `chunk_rows` rows, so a large table is read without holding it whole. The
  statement is released when the stream ends or is abandoned. Raises when
  the query fails.
  """
  @spec stream(t(), String.t(), [term()], pos_integer()) :: Enumerable.t()
  def stream({:snapshot, db}, sql, params, chunk_rows)
      when is_integer(chunk_rows) and chunk_rows > 0 do
    Stream.resource(
      fn ->
        {:ok, stmt} = Exqlite.Sqlite3.prepare(db, sql)

        case Exqlite.Sqlite3.bind(stmt, params) do
          :ok ->
            {stmt, :more}

          {:error, reason} ->
            Exqlite.Sqlite3.release(db, stmt)
            raise ArgumentError, "snapshot query could not bind: #{inspect(reason)}"
        end
      end,
      fn
        {stmt, :done} ->
          {:halt, {stmt, :done}}

        {stmt, :more} ->
          case Exqlite.Sqlite3.multi_step(db, stmt, chunk_rows) do
            {:rows, rows} -> {[rows], {stmt, :more}}
            {:done, []} -> {:halt, {stmt, :done}}
            {:done, rows} -> {[rows], {stmt, :done}}
            {:error, reason} -> raise "snapshot query failed: #{inspect(reason)}"
            :busy -> raise "snapshot query failed: the database stayed busy"
          end
      end,
      fn {stmt, _} -> Exqlite.Sqlite3.release(db, stmt) end
    )
  end

  defp collect(db, stmt, acc) do
    case Exqlite.Sqlite3.multi_step(db, stmt, 500) do
      {:rows, rows} -> collect(db, stmt, [rows | acc])
      {:done, rows} -> {:ok, [rows | acc] |> Enum.reverse() |> Enum.concat()}
      {:error, reason} -> {:error, reason}
      :busy -> {:error, :busy}
    end
  end
end
