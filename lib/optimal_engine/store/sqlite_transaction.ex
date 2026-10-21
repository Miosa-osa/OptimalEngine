defmodule OptimalEngine.Store.SQLiteTransaction do
  @moduledoc """
  One SQLite transaction on a connection the caller owns: BEGIN, the work,
  then COMMIT, or ROLLBACK when anything fails.

  The COMMIT result is checked. A COMMIT that fails (a busy database, a
  deferred constraint) leaves SQLite's transaction open, and every later BEGIN
  on the connection would then fail with "cannot start a transaction within a
  transaction". So a failed COMMIT is rolled back and reported as
  `{:error, {:commit_failed, reason}}`, and the connection is always left
  outside a transaction. A connection that a ROLLBACK cannot take out of its
  transaction raises `StillOpenError`.

  `OptimalEngine.Store.SQLite` runs every transaction through `run/3`, inside
  its own process. Callers outside the Store use `OptimalEngine.Store.transaction/2`.
  """

  defmodule StillOpenError do
    @moduledoc """
    The connection is still inside a transaction after its ROLLBACK. Every
    later BEGIN on it would fail, so its owner must stop using it.
    """
    defexception message:
                   "the connection is still inside a transaction after ROLLBACK; " <>
                     "it must be replaced"
  end

  @doc """
  Runs `fun` in a transaction opened with `begin_sql` (`"BEGIN"` by default).

  `fun` returns `:ok` or `{:ok, result}` to commit, and anything else to roll
  back; that value is returned. A raise, throw or exit in `fun` rolls back and
  is re-raised. A BEGIN that fails is `{:error, {:begin_failed, reason}}`.
  """
  @spec run(reference(), String.t(), (-> term())) :: term()
  def run(db, begin_sql \\ "BEGIN", fun) when is_function(fun, 0) do
    case Exqlite.Sqlite3.execute(db, begin_sql) do
      :ok ->
        result =
          try do
            fun.()
          catch
            kind, reason ->
              rollback(db)
              :erlang.raise(kind, reason, __STACKTRACE__)
          end

        finish(db, result)

      {:error, reason} ->
        {:error, {:begin_failed, reason}}
    end
  end

  defp finish(db, result) when result == :ok or (is_tuple(result) and elem(result, 0) == :ok) do
    case Exqlite.Sqlite3.execute(db, "COMMIT") do
      :ok ->
        result

      {:error, reason} ->
        rollback(db)
        {:error, {:commit_failed, reason}}
    end
  end

  defp finish(db, result) do
    rollback(db)
    result
  end

  # SQLite may already have ended the transaction (some errors roll back on
  # their own), so a failed ROLLBACK is fine when nothing is left to end.
  defp rollback(db) do
    _ = Exqlite.Sqlite3.execute(db, "ROLLBACK")
    ensure_ended!(db)
  end

  @doc """
  Returns `:ok` when the connection is outside a transaction, and raises
  `StillOpenError` when it is not: every later BEGIN on it would fail, so the
  owner must replace the connection. Runs after every ROLLBACK.
  """
  @spec ensure_ended!(reference()) :: :ok
  def ensure_ended!(db) do
    case Exqlite.Sqlite3.transaction_status(db) do
      {:ok, :transaction} -> raise StillOpenError
      {:ok, :idle} -> :ok
    end
  end
end
