defmodule OptimalEngine.Store.Catalog do
  @moduledoc """
  What the canonical store holds, read the same way on both stores: its
  tables, their columns, keys and foreign keys, and its integrity checks.

  On SQLite each answer comes from `sqlite_master` and the `PRAGMA` functions,
  exactly as the call sites read them before. On PostgreSQL it comes from
  `pg_catalog`, limited to the store's schema (the session's
  `current_schema()`), and leaves out the store's own bookkeeping tables
  (`optimal_*`): those hold no engine rows.

  Every function takes an optional transaction handle and reads inside it
  when one is given.
  """

  alias OptimalEngine.Store

  @postgres OptimalEngine.Store.Postgres

  # The store this process reads: the build's, or one a test names with
  # `using/2` to read the other store's catalog in the same build.
  defp store, do: Process.get({__MODULE__, :store}, Store)

  defp postgres?,
    do: if(store() == Store, do: Store.selected?(@postgres), else: store() == @postgres)

  @doc false
  # Runs `fun` with every read of this module going to `store`.
  def using(store, fun) do
    previous = Process.put({__MODULE__, :store}, store)

    try do
      fun.()
    after
      if previous,
        do: Process.put({__MODULE__, :store}, previous),
        else: Process.delete({__MODULE__, :store})
    end
  end

  @doc """
  The store's ordinary tables, by name. SQLite's own tables (`sqlite_*`),
  virtual tables and FTS5 shadow tables are left out.
  """
  @spec tables(term()) :: {:ok, [String.t()]} | {:error, term()}
  def tables(txn \\ nil) do
    if postgres?() do
      with {:ok, rows} <-
             query(
               txn,
               """
               SELECT c.relname::text FROM pg_class c
               JOIN pg_namespace n ON n.oid = c.relnamespace
               WHERE n.nspname = current_schema() AND c.relkind IN ('r', 'p')
                 AND c.relname::text NOT LIKE 'optimal\\_%' ESCAPE '\\'
               ORDER BY 1
               """,
               []
             ) do
        {:ok, List.flatten(rows)}
      end
    else
      with {:ok, rows} <-
             query(
               txn,
               "SELECT name, sql FROM sqlite_master WHERE type = 'table' ORDER BY name",
               []
             ) do
        names =
          for [name, sql] <- rows,
              not String.starts_with?(name, "sqlite_"),
              not (is_binary(sql) and String.contains?(sql, "VIRTUAL")),
              not fts_shadow?(name),
              do: name

        {:ok, names}
      end
    end
  end

  defp fts_shadow?(name), do: Regex.match?(~r/_fts_(data|idx|docsize|config|content)\z/, name)

  @doc """
  True when the store has a table (an ordinary or, on SQLite, a virtual one)
  named `name`. `case_insensitive: true` matches the name without regard to
  case, as SQLite resolves table names.
  """
  @spec table_exists?(String.t(), keyword()) :: boolean()
  def table_exists?(name, opts \\ []) when is_binary(name) do
    txn = Keyword.get(opts, :txn)
    fold? = Keyword.get(opts, :case_insensitive, false)

    sql =
      cond do
        postgres?() ->
          compare = if fold?, do: "lower(c.relname::text) = lower(?1)", else: "c.relname::text = ?1"

          """
          SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
          WHERE n.nspname = current_schema() AND c.relkind IN ('r', 'p') AND #{compare}
          """

        fold? ->
          "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?1 COLLATE NOCASE"

        true ->
          "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?1"
      end

    match?({:ok, [_ | _]}, query(txn, sql, [name]))
  end

  @doc """
  The columns of `table` in order, as `{name, type, pk}`: `pk` is the
  column's position in the primary key (1-based) or 0. On SQLite `type` is the
  declared type; on PostgreSQL it is `INTEGER` for an identity column (what
  SQLite's `INTEGER PRIMARY KEY` becomes), `BIGINT`, `TEXT`, `REAL` or `BLOB`.
  """
  @spec columns(String.t(), term()) ::
          {:ok, [{String.t(), String.t(), non_neg_integer()}]} | {:error, term()}
  def columns(table, txn \\ nil) when is_binary(table) do
    if postgres?() do
      sql = """
      SELECT a.attname::text, format_type(a.atttypid, a.atttypmod)::text,
             CASE WHEN a.attidentity <> '' THEN 1 ELSE 0 END,
             COALESCE(array_position(i.indkey::int2[], a.attnum), 0)
      FROM pg_attribute a
      JOIN pg_class c ON c.oid = a.attrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace
      LEFT JOIN pg_index i ON i.indrelid = c.oid AND i.indisprimary
      WHERE n.nspname = current_schema() AND c.relname::text = ?1
        AND a.attnum > 0 AND NOT a.attisdropped
      ORDER BY a.attnum
      """

      with {:ok, rows} <- query(txn, sql, [table]) do
        key = planned_key(table)

        {:ok,
         Enum.map(rows, fn [name, type, identity, pk] ->
           {name, postgres_type(type, identity), key_position(key, name, pk)}
         end)}
      end
    else
      with {:ok, rows} <-
             query(txn, "SELECT name, type, pk FROM pragma_table_info(?1) ORDER BY cid", [table]) do
        {:ok, Enum.map(rows, fn [name, type, pk] -> {name, String.upcase(type || ""), pk} end)}
      end
    end
  end

  # SQLite's primary key, as the migrations declare it; the PostgreSQL schema
  # may carry a nullable one as a unique index instead.
  defp planned_key(table) do
    with {:ok, plan} <- OptimalEngine.Store.Postgres.Schema.derive(),
         %{primary_key: key} <- Enum.find(plan.tables, &(&1.name == table)) do
      key
    else
      _ -> nil
    end
  end

  defp key_position(nil, _name, pk), do: pk

  defp key_position(key, name, _pk) do
    case Enum.find_index(key, &(&1 == name)) do
      nil -> 0
      index -> index + 1
    end
  end

  defp postgres_type(_type, 1), do: "INTEGER"
  defp postgres_type("bigint", _), do: "BIGINT"
  defp postgres_type("text", _), do: "TEXT"
  defp postgres_type("double precision", _), do: "REAL"
  defp postgres_type("bytea", _), do: "BLOB"
  defp postgres_type(other, _), do: String.upcase(other)

  @doc "The column names of `table`, in order."
  @spec column_names(String.t(), term()) :: {:ok, [String.t()]} | {:error, term()}
  def column_names(table, txn \\ nil) do
    with {:ok, columns} <- columns(table, txn), do: {:ok, Enum.map(columns, &elem(&1, 0))}
  end

  @doc """
  The foreign keys of `table`, one entry per column pair:
  `%{table: parent, from: column, to: parent_column}`.
  """
  @spec foreign_keys(String.t(), term()) :: {:ok, [map()]} | {:error, term()}
  def foreign_keys(table, txn \\ nil) when is_binary(table) do
    sql =
      if postgres?() do
        """
        SELECT p.relname::text, af.attname::text, ap.attname::text
        FROM pg_constraint k
        JOIN pg_class c ON c.oid = k.conrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        JOIN pg_class p ON p.oid = k.confrelid
        CROSS JOIN LATERAL unnest(k.conkey, k.confkey) WITH ORDINALITY AS u(f, t, ord)
        JOIN pg_attribute af ON af.attrelid = k.conrelid AND af.attnum = u.f
        JOIN pg_attribute ap ON ap.attrelid = k.confrelid AND ap.attnum = u.t
        WHERE k.contype = 'f' AND n.nspname = current_schema() AND c.relname::text = ?1
        ORDER BY k.conname, u.ord
        """
      else
        "SELECT \"table\", \"from\", \"to\" FROM pragma_foreign_key_list(?1)"
      end

    with {:ok, rows} <- query(txn, sql, [table]) do
      {:ok, Enum.map(rows, fn [parent, from, to] -> %{table: parent, from: from, to: to} end)}
    end
  end

  @doc """
  The tables with an index (a key's index included) whose first column is
  `column`.
  """
  @spec tables_indexed_by(String.t(), term()) :: {:ok, [String.t()]} | {:error, term()}
  def tables_indexed_by(column, txn \\ nil) when is_binary(column) do
    sql =
      if postgres?() do
        """
        SELECT DISTINCT c.relname::text FROM pg_index i
        JOIN pg_class c ON c.oid = i.indrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum = i.indkey[0]
        WHERE n.nspname = current_schema() AND c.relkind IN ('r', 'p') AND a.attname::text = ?1
          AND c.relname::text NOT LIKE 'optimal\\_%' ESCAPE '\\'
        ORDER BY 1
        """
      else
        """
        SELECT m.name FROM sqlite_master m
        WHERE m.type = 'table' AND m.sql NOT LIKE 'CREATE VIRTUAL TABLE%'
          AND EXISTS (
            SELECT 1 FROM pragma_index_list(m.name) il
            JOIN pragma_index_info(il.name) ii
            WHERE ii.seqno = 0 AND ii.name = ?1
          )
        """
      end

    with {:ok, rows} <- query(txn, sql, [column]), do: {:ok, List.flatten(rows)}
  end

  @doc """
  The columns of each index of `table` (its keys' indexes included), each in
  index order, sorted. Index names differ between the stores (PostgreSQL's
  are named for their definition), so a check of an index reads its columns.
  """
  @spec index_columns(String.t(), term()) :: {:ok, [[String.t()]]} | {:error, term()}
  def index_columns(table, txn \\ nil) when is_binary(table) do
    sql =
      if postgres?() do
        """
        SELECT i.indexrelid::text, a.attname::text, k.ord FROM pg_index i
        JOIN pg_class c ON c.oid = i.indrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        CROSS JOIN LATERAL unnest(i.indkey::int2[]) WITH ORDINALITY AS k(attnum, ord)
        JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum = k.attnum
        WHERE n.nspname = current_schema() AND c.relname::text = ?1
        """
      else
        """
        SELECT il.name, ii.name, ii.seqno FROM pragma_index_list(?1) il
        JOIN pragma_index_info(il.name) ii
        """
      end

    with {:ok, rows} <- query(txn, sql, [table]) do
      columns =
        rows
        |> Enum.group_by(&Enum.at(&1, 0), &{Enum.at(&1, 2), Enum.at(&1, 1)})
        |> Enum.map(fn {_index, cols} -> cols |> Enum.sort() |> Enum.map(&elem(&1, 1)) end)
        |> Enum.sort()

      {:ok, columns}
    end
  end

  @doc """
  SQLite's `PRAGMA integrity_check` result: `"ok"` or the problems it found.
  PostgreSQL checks its pages and constraints as it writes them and has no
  such pass, so a store that answers a query answers `"ok"`.
  """
  @spec integrity_check() :: {:ok, String.t()} | {:error, term()}
  def integrity_check do
    sql = if postgres?(), do: "SELECT 'ok'", else: "PRAGMA integrity_check"

    case store().raw_query(sql, []) do
      {:ok, [[result] | _]} -> {:ok, result}
      {:ok, other} -> {:error, other}
      {:error, _} = error -> error
    end
  end

  @doc """
  Rows that break a foreign key (SQLite's `PRAGMA foreign_key_check`). Every
  foreign key of the PostgreSQL store is enforced at the latest at commit, so
  it holds none.
  """
  @spec foreign_key_violations() :: {:ok, [[term()]]} | {:error, term()}
  def foreign_key_violations do
    if postgres?(), do: {:ok, []}, else: store().raw_query("PRAGMA foreign_key_check", [])
  end

  @doc """
  The names of the store's triggers (each named once, whatever tables it is
  on), sorted. PostgreSQL's internal triggers (foreign keys) are left out.
  """
  @spec triggers(term()) :: {:ok, [String.t()]} | {:error, term()}
  def triggers(txn \\ nil) do
    sql =
      if postgres?() do
        """
        SELECT DISTINCT t.tgname::text FROM pg_trigger t
        JOIN pg_class c ON c.oid = t.tgrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = current_schema() AND NOT t.tgisinternal
        ORDER BY 1
        """
      else
        "SELECT name FROM sqlite_master WHERE type = 'trigger' ORDER BY name"
      end

    with {:ok, rows} <- query(txn, sql, []), do: {:ok, List.flatten(rows)}
  end

  @doc """
  The tie-break that keeps rows written in the same second in a stable order:
  SQLite's `rowid`, the order they were written in; PostgreSQL has no such
  order, so there it is `key`, a unique column of the table.
  """
  @spec insertion_order(String.t()) :: String.t()
  def insertion_order(key), do: if(postgres?(), do: key, else: "rowid")

  defp query(nil, sql, params), do: store().raw_query(sql, params)
  defp query(txn, sql, params), do: store().txn_query(txn, sql, params)
end
