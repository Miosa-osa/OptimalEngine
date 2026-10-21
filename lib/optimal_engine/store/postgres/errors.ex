defmodule OptimalEngine.Store.Postgres.Errors do
  @moduledoc """
  PostgreSQL errors as the messages SQLite returns for the same failure.

  Callers of the store read error text for control flow: a `UNIQUE constraint
  failed` turns an insert into an update, `duplicate column name` makes an
  `ALTER TABLE ... ADD COLUMN` idempotent, and `no such table` marks an
  optional table as absent. The store returns the SQLite wording for those
  conditions so a caller behaves the same on either database.

  | SQLSTATE | Message |
  | --- | --- |
  | `23505` unique_violation | `UNIQUE constraint failed: table.column, ...` |
  | `23502` not_null_violation | `NOT NULL constraint failed: table.column` |
  | `23503` foreign_key_violation | `FOREIGN KEY constraint failed` |
  | `23514` check_violation | `CHECK constraint failed: constraint` |
  | `42P01` undefined_table | `no such table: name` |
  | `42703` undefined_column | `no such column: name` |
  | `42701` duplicate_column | `duplicate column name: name` |
  | `42P07` duplicate_table | `table name already exists` |

  Any other server error keeps the PostgreSQL message with its SQLSTATE, so
  nothing is reworded into a SQLite condition it is not.
  """

  @retryable [:serialization_failure, :deadlock_detected]

  @doc "The error as SQLite would word it."
  @spec message(term()) :: String.t()
  def message(%Postgrex.Error{postgres: %{code: code} = fields}), do: worded(code, fields)
  def message(%Postgrex.Error{message: message}) when is_binary(message), do: message
  def message(%{__exception__: true} = exception), do: Exception.message(exception)
  def message(other), do: inspect(other)

  @doc """
  True for the failures PostgreSQL asks the client to retry: a serialization
  failure or a detected deadlock. The statement or transaction did not commit.
  """
  @spec retryable?(term()) :: boolean()
  def retryable?(%Postgrex.Error{postgres: %{code: code}}), do: code in @retryable
  def retryable?(_error), do: false

  defp worded(:unique_violation, fields) do
    "UNIQUE constraint failed: " <> qualified(fields, key_columns(fields))
  end

  defp worded(:not_null_violation, fields) do
    "NOT NULL constraint failed: " <> qualified(fields, List.wrap(fields[:column]))
  end

  defp worded(:foreign_key_violation, _fields), do: "FOREIGN KEY constraint failed"

  defp worded(:check_violation, fields) do
    "CHECK constraint failed: " <> to_string(fields[:constraint] || fields.message)
  end

  defp worded(:undefined_table, fields), do: "no such table: " <> quoted_name(fields.message)
  defp worded(:undefined_column, fields), do: "no such column: " <> quoted_name(fields.message)

  defp worded(:duplicate_column, fields),
    do: "duplicate column name: " <> quoted_name(fields.message)

  defp worded(:duplicate_table, fields), do: "table #{quoted_name(fields.message)} already exists"

  defp worded(_code, fields), do: "#{fields.message} (SQLSTATE #{fields[:pg_code]})"

  # "Key (context_id, name)=(c1, alice) already exists." names the columns.
  defp key_columns(%{detail: detail}) when is_binary(detail) do
    case Regex.run(~r/^Key \((.+?)\)=/, detail) do
      [_, columns] -> columns |> String.split(",") |> Enum.map(&String.trim/1)
      _ -> []
    end
  end

  defp key_columns(_fields), do: []

  defp qualified(%{table: table}, [_ | _] = columns) when is_binary(table) do
    Enum.map_join(columns, ", ", &"#{table}.#{&1}")
  end

  defp qualified(fields, [_ | _] = columns), do: qualified(Map.put(fields, :table, "?"), columns)
  defp qualified(fields, []), do: to_string(fields[:constraint] || fields[:table] || "")

  # PostgreSQL quotes the object (relation "x" does not exist) unless it is
  # qualified (column t.y does not exist).
  defp quoted_name(message) do
    case Regex.run(~r/"([^"]+)"/, message) || Regex.run(~r/column (\S+) does not/, message) do
      [_, name] -> name
      _ -> message
    end
  end
end
