defmodule OptimalEngine.AppData.SQL do
  @moduledoc false
  # Statement helpers that run either inside a `Store.transaction/2` fun
  # (`{:txn, _}` handle) or as single Store calls (`:store`).

  alias OptimalEngine.Store

  @spec query(:store | term(), String.t(), list()) :: {:ok, [list()]} | {:error, term()}
  def query(:store, sql, params), do: Store.raw_query(sql, params)
  def query(txn, sql, params), do: Store.txn_query(txn, sql, params)

  @spec exec(term(), String.t(), list()) :: {:ok, non_neg_integer()} | {:error, term()}
  def exec(txn, sql, params \\ []), do: Store.txn_execute(txn, sql, params)

  @doc "Runs `exec/3` for each statement, stopping at the first error."
  @spec exec_all(term(), [String.t() | {String.t(), list()}]) :: :ok | {:error, term()}
  def exec_all(txn, statements) do
    Enum.reduce_while(statements, :ok, fn statement, :ok ->
      {sql, params} = if is_tuple(statement), do: statement, else: {statement, []}

      case exec(txn, sql, params) do
        {:ok, _changes} -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  @doc "A single integer from `SELECT COUNT(*) ...`-shaped queries."
  @spec scalar(:store | term(), String.t(), list()) :: {:ok, term()} | {:error, term()}
  def scalar(conn, sql, params) do
    case query(conn, sql, params) do
      {:ok, [[value | _] | _]} -> {:ok, value}
      {:ok, []} -> {:ok, nil}
      {:error, _} = error -> error
    end
  end

  @doc "`?, ?, ?` for `count` parameters."
  @spec placeholders(non_neg_integer()) :: String.t()
  def placeholders(count), do: List.duplicate("?", count) |> Enum.join(", ")
end
