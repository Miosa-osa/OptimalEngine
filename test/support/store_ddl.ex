defmodule OptimalEngine.Test.StoreDDL do
  @moduledoc false
  # Schema statements a test runs beside the store's own: scratch tables, and
  # triggers that make a write fail the way a full disk or a locked row would.
  # The store's schema comes from its migrations, so the PostgreSQL store
  # refuses a schema change sent as an ordinary statement; a test runs its own
  # here instead, written for SQLite, on whichever store this Engine has.
  #
  #     StoreDDL.execute("CREATE TABLE txn_test_1 (id INTEGER PRIMARY KEY, val TEXT)")
  #     StoreDDL.execute("CREATE TRIGGER t BEFORE UPDATE ON contexts WHEN NEW.id = 'x'
  #                       BEGIN SELECT RAISE(ABORT, 'boom'); END")
  #     StoreDDL.execute("DROP TRIGGER IF EXISTS t")
  #
  # On PostgreSQL a trigger becomes a PL/pgSQL function of the same name with
  # the same WHEN condition; RAISE(ABORT, msg) raises msg, and any other body
  # statement runs through the dialect.

  alias OptimalEngine.Store
  alias OptimalEngine.Store.Dialect

  @create_trigger ~r/\A\s*CREATE\s+TRIGGER\s+(?:IF\s+NOT\s+EXISTS\s+)?("?[\w]+"?)\s+(BEFORE|AFTER)\s+(INSERT|UPDATE|DELETE)(\s+OF\s+[^\n]+?)?\s+ON\s+("?[\w]+"?)\s+(?:FOR\s+EACH\s+ROW\s+)?(?:WHEN\s+(.+?)\s+)?BEGIN\s+(.+?)\s*END\s*;?\s*\z/is
  @drop_trigger ~r/\A\s*DROP\s+TRIGGER\s+(IF\s+EXISTS\s+)?("?[\w]+"?)\s*;?\s*\z/i

  @doc "Runs a schema statement written for SQLite on the Engine's store."
  def execute(sql, params \\ []) do
    if Store.selected?(OptimalEngine.Store.Postgres),
      do: postgres(sql, params),
      else: Store.raw_execute(sql, params)
  end

  def execute!(sql, params \\ []), do: :ok = execute(sql, params)

  defp postgres(sql, params) do
    cond do
      match = Regex.run(@create_trigger, sql) -> create_trigger(match)
      match = Regex.run(@drop_trigger, sql) -> drop_trigger(match)
      true -> with {:ok, statement} <- to_postgres(sql), do: native([{statement, params}])
    end
  end

  defp native(statements) do
    result =
      OptimalEngine.Store.Postgres.transaction(fn txn ->
        Enum.reduce_while(statements, {:ok, 0}, fn {sql, params}, {:ok, n} ->
          case OptimalEngine.Store.Postgres.txn_execute_native(txn, sql, params) do
            {:ok, count} -> {:cont, {:ok, n + count}}
            {:error, _} = error -> {:halt, error}
          end
        end)
      end)

    with {:ok, _} <- result, do: :ok
  end

  defp unquote_name(name), do: String.trim(name, ~s("))

  defp create_trigger([_, name, timing, event, columns, table, condition, body]) do
    name = unquote_name(name)
    row = if event == "DELETE", do: "OLD", else: "NEW"

    with {:ok, statements} <- body_statements(body),
         {:ok, condition} <- condition(condition) do
      function = """
      CREATE OR REPLACE FUNCTION "#{name}_fn"() RETURNS trigger LANGUAGE plpgsql AS $fn$
      BEGIN
        IF #{condition} THEN
          #{Enum.join(statements, "\n      ")}
        END IF;
        RETURN #{if timing =~ ~r/BEFORE/i, do: row, else: "NULL"};
      END
      $fn$
      """

      native([
        {function, []},
        {~s(DROP TRIGGER IF EXISTS "#{name}" ON #{table}), []},
        {~s(CREATE TRIGGER "#{name}" #{timing} #{event}#{columns || ""} ON #{table} ) <>
           ~s|FOR EACH ROW EXECUTE FUNCTION "#{name}_fn"()|, []}
      ])
    end
  end

  defp condition(nil), do: {:ok, "TRUE"}
  defp condition(""), do: {:ok, "TRUE"}

  defp condition(sql) do
    with {:ok, translated} <- Dialect.to_postgres("SELECT 1 WHERE " <> sql) do
      {:ok, "(" <> String.replace_prefix(translated, "SELECT 1 WHERE ", "") <> ")"}
    end
  end

  defp body_statements(body) do
    body
    |> String.split(";", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.reduce_while({:ok, []}, fn statement, {:ok, acc} ->
      case body_statement(statement) do
        {:ok, translated} -> {:cont, {:ok, acc ++ [translated]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp body_statement(statement) do
    case Regex.run(
           ~r/\ASELECT\s+RAISE\s*\(\s*(?:ABORT|FAIL|ROLLBACK)\s*,\s*'((?:[^']|'')*)'\s*\)\z/is,
           statement
         ) do
      [_, message] ->
        {:ok, "RAISE EXCEPTION '%', '#{message}';"}

      nil ->
        if Regex.match?(~r/\ASELECT\s+1\z/i, statement) do
          {:ok, "NULL;"}
        else
          with {:ok, translated} <- Dialect.to_postgres(statement) do
            {:ok, String.replace(translated, ~r/\A\s*SELECT\b/i, "PERFORM") <> ";"}
          end
        end
    end
  end

  defp drop_trigger([_, if_exists, name]) do
    name = unquote_name(name)

    {:ok, rows} =
      OptimalEngine.Store.Postgres.transaction(fn txn ->
        OptimalEngine.Store.Postgres.txn_query_native(
          txn,
          "SELECT tgrelid::regclass::text FROM pg_trigger WHERE tgname = $1 AND NOT tgisinternal",
          [name]
        )
      end)

    case rows do
      [] when if_exists != "" ->
        :ok

      [] ->
        {:error, "no such trigger: #{name}"}

      tables ->
        native(
          Enum.map(tables, fn [table] -> {~s(DROP TRIGGER IF EXISTS "#{name}" ON #{table}), []} end) ++
            [{~s|DROP FUNCTION IF EXISTS "#{name}_fn"()|, []}]
        )
    end
  end

  @doc "The PostgreSQL form of a SQLite table or index statement, with SQLite's types."
  def to_postgres(sql) do
    sql
    |> String.replace(~r/\)\s*STRICT\s*;?\s*\z/i, ")")
    |> String.replace(~r/\bWITHOUT\s+ROWID\b/i, "")
    |> String.replace(
      ~r/\bINTEGER\s+PRIMARY\s+KEY(\s+AUTOINCREMENT)?\b/i,
      "BIGINT GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY"
    )
    |> String.replace(~r/\b(INTEGER|INT|BOOLEAN)\b/i, "BIGINT")
    |> String.replace(~r/\bREAL\b/i, "DOUBLE PRECISION")
    |> String.replace(~r/\bBLOB\b/i, "BYTEA")
    |> String.replace(~r/\bTEXT\b(?!\s+COLLATE)/i, ~s(TEXT COLLATE "C"))
    |> Dialect.to_postgres()
  end
end
