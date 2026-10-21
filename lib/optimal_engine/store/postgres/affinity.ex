defmodule OptimalEngine.Store.Postgres.Affinity do
  @moduledoc """
  SQLite type affinity at the PostgreSQL driver boundary.

  The engine binds parameters the way `Exqlite` accepts them and reads rows the
  way SQLite returns them. SQLite converts a bound value to the column's
  affinity; PostgreSQL rejects a value whose type does not match the parameter.
  These functions apply SQLite's conversions to each parameter once PostgreSQL
  has described its type, so a statement that works on SQLite binds the same
  values on PostgreSQL.

  | Parameter type | Accepted values |
  | --- | --- |
  | text | binaries, iodata, integers, floats, atoms, `Date`, `Time`, `NaiveDateTime`, UTC `DateTime` (rendered as `Exqlite` renders them), `{:blob, data}` |
  | integer | integers, integral floats, integer text, `true` and `false` as 1 and 0 |
  | float | numbers, numeric text, `true` and `false` as 1.0 and 0.0 |
  | bytea | binaries, iodata, `{:blob, data}` |
  | boolean | `true`, `false`, 1, 0 |

  Anything else raises `DBConnection.EncodeError`, which the store returns as
  an error instead of storing a converted value SQLite would not have stored.

  On the way out, `numeric` values (`SUM` over integers, `AVG`) become the
  integer or float SQLite returns, and `boolean` results become 1 and 0.
  """

  @doc "A parameter for a text column."
  @spec to_text(term()) :: binary()
  def to_text(value) when is_binary(value), do: value
  def to_text(value) when is_integer(value), do: Integer.to_string(value)
  def to_text(value) when is_float(value), do: float_text(value)
  def to_text(value) when is_list(value), do: IO.iodata_to_binary(value)
  def to_text({:blob, value}), do: IO.iodata_to_binary(value)
  def to_text(%Date{} = value), do: Date.to_iso8601(value)
  def to_text(%Time{} = value), do: Time.to_iso8601(value)
  def to_text(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)

  def to_text(%DateTime{time_zone: "Etc/UTC"} = value),
    do: value |> DateTime.to_naive() |> NaiveDateTime.to_iso8601()

  def to_text(value) when is_atom(value) and not is_nil(value), do: Atom.to_string(value)
  def to_text(value), do: reject(value, "text")

  @doc "A parameter for an integer column, checked against the column's range."
  @spec to_integer(term(), Range.t()) :: integer()
  def to_integer(value, range) do
    integer = integer_value(value)

    if integer in range do
      integer
    else
      reject(value, "an integer in #{inspect(range)}")
    end
  end

  defp integer_value(value) when is_integer(value), do: value
  defp integer_value(true), do: 1
  defp integer_value(false), do: 0

  defp integer_value(value) when is_float(value) do
    if value == Float.round(value) do
      trunc(value)
    else
      reject(value, "an integer")
    end
  end

  defp integer_value(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} -> integer
      _ -> reject(value, "an integer")
    end
  end

  defp integer_value(value), do: reject(value, "an integer")

  @doc "A parameter for a floating point column."
  @spec to_float(term()) :: float()
  def to_float(value) when is_float(value), do: value
  def to_float(value) when is_integer(value), do: value * 1.0
  def to_float(true), do: 1.0
  def to_float(false), do: 0.0

  def to_float(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {float, ""} -> float
      _ -> reject(value, "a float")
    end
  end

  def to_float(value), do: reject(value, "a float")

  @doc "A parameter for a bytea column."
  @spec to_bytes(term()) :: binary()
  def to_bytes({:blob, value}), do: IO.iodata_to_binary(value)
  def to_bytes(value) when is_binary(value), do: value
  def to_bytes(value) when is_list(value), do: IO.iodata_to_binary(value)
  def to_bytes(value), do: reject(value, "bytes")

  @doc "A parameter for a boolean expression."
  @spec to_boolean(term()) :: boolean()
  def to_boolean(value) when is_boolean(value), do: value
  def to_boolean(1), do: true
  def to_boolean(0), do: false
  def to_boolean(value), do: reject(value, "a boolean")

  @doc """
  One result value as SQLite returns it.

  A `numeric` with no fractional digits is an integer (`SUM` over integer
  columns); one with fractional digits is a float (`AVG`).
  """
  @spec normalize(term()) :: term()
  def normalize(%Decimal{coef: coef, exp: exp} = decimal) when is_integer(coef) and exp >= 0,
    do: Decimal.to_integer(decimal)

  def normalize(%Decimal{coef: coef} = decimal) when is_integer(coef), do: Decimal.to_float(decimal)
  def normalize(value), do: value

  @doc "Every value of every row, as SQLite returns it."
  @spec normalize_rows([[term()]] | nil) :: [[term()]]
  def normalize_rows(nil), do: []
  def normalize_rows(rows), do: Enum.map(rows, fn row -> Enum.map(row, &normalize/1) end)

  # SQLite renders a REAL with 15 significant digits and keeps the ".0" of an
  # integral value; the shortest round-trip form agrees for every value the
  # engine binds.
  defp float_text(value), do: :erlang.float_to_binary(value, [:short])

  defp reject(value, expected) do
    raise DBConnection.EncodeError,
          "expected #{expected} for a PostgreSQL parameter, got #{inspect(value)}"
  end
end
