defmodule OptimalEngine.Test.StoreGrep do
  @moduledoc false
  # Where a piece of text is in the Engine's store, for erasure tests: after an
  # erasure the text must be nowhere.
  #
  # * Every table and every column, read as text. On SQLite that includes the
  #   FTS5 virtual tables and all their shadow tables (`_content`, `_data`,
  #   `_idx`, `_docsize`, `_config`); on PostgreSQL every table of the schema,
  #   the full-text posting lists (`optimal_fts_*`) included.
  # * The FTS5 index itself: each FTS5 table is merged (`optimize`) first, so a
  #   deleted document's terms are gone from its segments rather than masked by
  #   a delete marker, and its vocabulary (`fts5vocab`) is asked for the term,
  #   so a term kept only in the compressed index is found too.
  # * `find_all/1` looks for every distinctive token of a text, not only the
  #   first: a copy that kept part of the text is found.

  alias OptimalEngine.Store

  @doc "Every `{table, column}` holding `text`, on the store this run uses."
  @spec find(String.t()) :: [{String.t(), String.t()}]
  def find(text) when is_binary(text) and byte_size(text) >= 8 do
    if postgres?(), do: optimize_fts([]), else: optimize_fts(fts_tables())

    hits =
      for table <- tables(), column <- columns(table), holds?(table, column, text) do
        {table, column}
      end

    Enum.uniq(hits ++ vocabulary_hits(text))
  end

  @doc """
  Every `{table, column}` holding any distinctive token of `text`: each
  whitespace-separated word of 8 or more characters.
  """
  @spec find_all(String.t()) :: [{String.t(), String.t()}]
  def find_all(text) when is_binary(text) do
    text
    |> String.split(~r/\s+/, trim: true)
    |> Enum.filter(&(String.length(&1) >= 8))
    |> Enum.flat_map(&find/1)
    |> Enum.uniq()
  end

  defp postgres?, do: Store.selected?(OptimalEngine.Store.Postgres)

  defp tables do
    if postgres?() do
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
      # Every table, the FTS5 tables and all their shadow tables included.
      {:ok, rows} =
        Store.raw_query(
          "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name",
          []
        )

      List.flatten(rows)
    end
  end

  defp fts_tables do
    {:ok, rows} =
      Store.raw_query(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND sql LIKE '%USING fts5%'",
        []
      )

    List.flatten(rows)
  end

  # Merges every segment of each FTS5 index into one, applying its deletes.
  defp optimize_fts(tables) do
    for table <- tables do
      Store.raw_query(~s|INSERT INTO "#{table}"("#{table}") VALUES ('optimize')|, [])
    end

    :ok
  end

  # The terms each FTS5 index holds, through a temporary vocabulary table.
  defp vocabulary_hits(text) do
    if postgres?() do
      []
    else
      for table <- fts_tables(), vocabulary_holds?(table, text), do: {table, "<index>"}
    end
  end

  # Quoted, so every statement has one shape (the census normalizes a quoted
  # name) whichever FTS5 tables the store holds.
  defp vocabulary_holds?(table, text) do
    vocab = ~s|temp."grep_vocab_#{table}"|

    {:ok, _} =
      Store.raw_query(
        ~s|CREATE VIRTUAL TABLE IF NOT EXISTS #{vocab} USING fts5vocab(main, "#{table}", 'row')|,
        []
      )

    match?(
      {:ok, [_ | _]},
      Store.raw_query("SELECT 1 FROM #{vocab} WHERE term LIKE ?1 LIMIT 1", [
        "%" <> String.downcase(text) <> "%"
      ])
    )
  end

  defp columns(table) do
    if postgres?() do
      {:ok, names} = OptimalEngine.Store.Catalog.column_names(table)
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
