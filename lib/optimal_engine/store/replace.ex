defmodule OptimalEngine.Store.Replace do
  @moduledoc """
  SQLite's `INSERT OR REPLACE` on both stores.

  SQLite's replace deletes every row the new row conflicts with, on its
  primary key or on any unique key, with their `ON DELETE` actions, and then
  inserts the new row, whose unnamed columns take their defaults. An
  `ON CONFLICT DO UPDATE` is not that: it conflicts on one key only and keeps
  the old row's other columns.

  On SQLite the statement runs as written. On PostgreSQL the same statement
  runs as a delete of the row each key of the table names, then the insert
  without `OR REPLACE`, in one transaction (the caller's, when one is given),
  which is what SQLite does. The keys come from the store's derived schema
  (`OptimalEngine.Store.Postgres.Schema`), and a key's values from the
  statement's `VALUES`: a key column whose value is an expression rather than
  a placeholder or a literal raises `ArgumentError`, because which row it
  replaces could not be told.
  """

  alias OptimalEngine.Store

  @postgres OptimalEngine.Store.Postgres
  @statement ~r/\A\s*INSERT\s+OR\s+REPLACE\s+INTO\s+("?)([A-Za-z_][A-Za-z0-9_]*)\1\s*\((.*?)\)\s*VALUES\s*\((.*)\)\s*;?\s*\z/is

  @doc "Runs an `INSERT OR REPLACE` statement outside a transaction."
  @spec raw_query(String.t(), [term()]) :: {:ok, [[term()]]} | {:error, term()}
  def raw_query(sql, params) do
    if Store.selected?(@postgres) do
      Store.transaction(fn txn ->
        with {:ok, _count} <- txn_execute(txn, sql, params), do: {:ok, []}
      end)
    else
      Store.raw_query(sql, params)
    end
  end

  @doc "Runs an `INSERT OR REPLACE` statement outside a transaction and returns `:ok`."
  @spec raw_execute(String.t(), [term()]) :: :ok | {:error, term()}
  def raw_execute(sql, params) do
    with {:ok, _} <- raw_query(sql, params), do: :ok
  end

  @doc "Runs an `INSERT OR REPLACE` statement inside `txn`; returns the rows it wrote."
  @spec txn_execute(term(), String.t(), [term()]) :: {:ok, non_neg_integer()} | {:error, term()}
  def txn_execute(txn, sql, params) do
    if Store.selected?(@postgres),
      do: as_delete_and_insert(Store, txn, sql, params),
      else: Store.txn_execute(txn, sql, params)
  end

  @doc false
  # The PostgreSQL form, on `store` (the facade, or a store module a test names).
  def as_delete_and_insert(store, txn, sql, params) do
    {table, insert, deletes} = plan(sql, params)

    Enum.reduce_while(deletes, :ok, fn {delete, values}, :ok ->
      case store.txn_execute(txn, delete, values) do
        {:ok, _} -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      :ok -> store.txn_execute(txn, insert, params)
      {:error, reason} -> {:error, {:replace_failed, table, reason}}
    end
  end

  @doc false
  # The insert without OR REPLACE, and one delete per key of the table whose
  # values are all known and not NULL (SQLite's NULL never conflicts).
  def plan(sql, params) do
    case Regex.run(@statement, sql) do
      [_, _quote, table, columns, values] ->
        columns = columns |> split() |> Enum.map(&(&1 |> String.trim() |> String.trim(~s("))))
        values = split(values)

        if length(columns) != length(values),
          do: raise(ArgumentError, "INSERT OR REPLACE with a column count unlike its values")

        bound = Map.new(Enum.zip(columns, values_of(values, params)))

        insert =
          Regex.replace(
            ~r/\AINSERT\s+OR\s+REPLACE\s+INTO/i,
            String.trim_leading(sql),
            "INSERT INTO"
          )

        {table, insert, deletes(table, bound)}

      nil ->
        raise ArgumentError, "not a single-row INSERT OR REPLACE ... VALUES (...): #{sql}"
    end
  end

  defp deletes(table, bound) do
    {:ok, plan} = OptimalEngine.Store.Postgres.Schema.derive()

    definition =
      Enum.find(plan.tables, &(&1.name == table)) ||
        raise ArgumentError, "INSERT OR REPLACE into #{table}, which the schema does not have"

    keys = Enum.reject([definition.primary_key | definition.uniques], &(&1 == []))

    for key <- keys,
        values = Enum.map(key, &key_value(table, bound, &1)),
        not Enum.any?(values, &is_nil/1) do
      where =
        key |> Enum.with_index(1) |> Enum.map_join(" AND ", fn {c, i} -> ~s("#{c}" = ?#{i}) end)

      {~s(DELETE FROM "#{table}" WHERE #{where}), values}
    end
  end

  # A key column the insert does not name takes its default: none of the keys
  # replaced through this module has one, so it cannot conflict.
  defp key_value(table, bound, column) do
    case Map.fetch(bound, column) do
      {:ok, {:value, value}} -> value
      {:ok, :expression} -> raise ArgumentError, "#{table}.#{column} is an expression in a replace"
      :error -> nil
    end
  end

  # Each value as {:value, term} for a placeholder or literal, else :expression.
  defp values_of(values, params) do
    {resolved, _next} =
      Enum.map_reduce(values, 1, fn value, next ->
        value = String.trim(value)

        cond do
          match = Regex.run(~r/\A\?(\d+)\z/, value) ->
            {{:value, Enum.at(params, String.to_integer(Enum.at(match, 1)) - 1)}, next}

          value == "?" ->
            {{:value, Enum.at(params, next - 1)}, next + 1}

          Regex.match?(~r/\A'([^']|'')*'\z/, value) ->
            {{:value, value |> String.slice(1..-2//1) |> String.replace("''", "'")}, next}

          Regex.match?(~r/\A-?\d+(\.\d+)?\z/, value) ->
            {{:value, number(value)}, next}

          String.upcase(value) == "NULL" ->
            {{:value, nil}, next}

          true ->
            {:expression, next + count_positional(value)}
        end
      end)

    resolved
  end

  defp number(text) do
    case Integer.parse(text) do
      {int, ""} -> int
      _ -> String.to_float(text)
    end
  end

  defp count_positional(expr), do: length(Regex.scan(~r/\?(?!\d)/, expr))

  # Splits on commas outside parentheses and quotes.
  defp split(text) do
    {parts, current, _depth, _quoted} =
      text
      |> String.graphemes()
      |> Enum.reduce({[], "", 0, false}, fn
        "'", {parts, current, depth, quoted} -> {parts, current <> "'", depth, not quoted}
        char, {parts, current, depth, true} -> {parts, current <> char, depth, true}
        "(", {parts, current, depth, false} -> {parts, current <> "(", depth + 1, false}
        ")", {parts, current, depth, false} -> {parts, current <> ")", depth - 1, false}
        ",", {parts, current, 0, false} -> {[current | parts], "", 0, false}
        char, {parts, current, depth, false} -> {parts, current <> char, depth, false}
      end)

    Enum.reverse([current | parts])
  end
end
