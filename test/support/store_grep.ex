defmodule OptimalEngine.Test.StoreGrep do
  @moduledoc false
  # Where a piece of text is in the Engine's store: every table (on SQLite
  # the virtual full-text tables and their content tables too) and every
  # column, read as text. For erasure tests: after an erasure the text must
  # be nowhere.

  alias OptimalEngine.Store
  alias OptimalEngine.Store.Catalog

  @doc "Every `{table, column}` holding `text`, on the store this run uses."
  @spec find(String.t()) :: [{String.t(), String.t()}]
  def find(text) when is_binary(text) and byte_size(text) >= 8 do
    for table <- tables(), column <- columns(table), holds?(table, column, text) do
      {table, column}
    end
  end

  defp tables do
    if Store.selected?(OptimalEngine.Store.Postgres) do
      # Every table of the schema, the full-text posting lists
      # (`optimal_fts_*`) included: they hold the tokens of the text.
      {:ok, rows} =
        Store.raw_query(
          """
          SELECT c.relname::text FROM pg_class c
          JOIN pg_namespace n ON n.oid = c.relnamespace
          WHERE n.nspname = current_schema() AND c.relkind IN ('r', 'p')
          ORDER BY 1
          """,
          []
        )

      List.flatten(rows)
    else
      # Ordinary tables, the FTS5 tables and their content shadows: an FTS
      # index with its own content keeps a copy of the text there.
      {:ok, rows} =
        Store.raw_query(
          "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name",
          []
        )

      rows
      |> List.flatten()
      |> Enum.reject(&Regex.match?(~r/_fts_(data|idx|docsize|config)\z/, &1))
    end
  end

  defp columns(table) do
    if Store.selected?(OptimalEngine.Store.Postgres) do
      {:ok, names} = Catalog.column_names(table)
      names
    else
      case Store.raw_query("SELECT name FROM pragma_table_info(?1)", [table]) do
        {:ok, rows} -> List.flatten(rows)
        _ -> []
      end
    end
  end

  defp holds?(table, column, text) do
    sql = ~s|SELECT 1 FROM "#{table}" WHERE CAST("#{column}" AS TEXT) LIKE ?1 LIMIT 1|

    match?({:ok, [_ | _]}, Store.raw_query(sql, ["%" <> text <> "%"]))
  end
end
