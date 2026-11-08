defmodule OptimalEngine.Store.FullText do
  @moduledoc """
  Full-text search on both stores, with SQLite FTS5's tokens and BM25 ranking.

  On SQLite the indexes are FTS5 tables (`contexts_fts`, `memories_fts`)
  maintained by triggers, and a search is a `MATCH` statement ranked by
  `bm25()`.

  On PostgreSQL the same indexes are posting lists
  (`OptimalEngine.Store.Postgres.FullText`): a trigger on each indexed table
  queues the keys of the rows that changed, and before a search reads an index
  the queued rows are tokenized and their postings rewritten. A search calls
  `optimal_fts_match(index, query)`, which matches the query and computes
  FTS5's BM25 over the whole index.

  ## The same tokens

  A row is tokenized by SQLite itself: an in-memory FTS5 table with the index's
  own `tokenize` option, read back through `fts5vocab`. A query's phrases are
  tokenized the same way. The PostgreSQL index therefore holds exactly the
  terms and positions the FTS5 table holds, including the case folding,
  diacritics and Porter stemming of `porter unicode61`, with no second
  tokenizer to keep in step.

  ## The same ranking

  FTS5's `bm25()` with its defaults (k1 = 1.2, b = 0.75, every column weighted
  1): for each phrase of the query, IDF = ln((N - n + 0.5) / (n + 0.5)), or
  1e-6 when that is not positive, where N is the number of rows in the index
  and n the number of rows the phrase matches; the score of a row sums
  IDF * f * (k1 + 1) / (f + k1 * (1 - b + b * D / avgdl)) over the phrases, in
  query order, where f is how often the phrase occurs in the row, D the row's
  token count and avgdl the average token count of the index. N, n and avgdl
  are over the whole index, as in FTS5, not the workspace searched.
  `optimal_fts_match` returns that sum, which is `-bm25(...)` on SQLite.

  ## Query syntax

  The engine builds every `MATCH` string itself from quoted phrases: phrases
  joined by ` OR ` (any) or by spaces (all), the last of which may end in `*`
  (a prefix). `parse/1` accepts exactly that and refuses anything else by
  name, so a query FTS5 would read differently never runs.
  """

  alias OptimalEngine.Store

  @typedoc "One indexed table."
  @type index :: %{
          name: String.t(),
          table: String.t(),
          key: String.t(),
          columns: [String.t()],
          tokenize: String.t() | nil
        }

  # The FTS5 tables of the SQLite migrations, by name: the table they index,
  # its key, the indexed columns in FTS5's column order, and FTS5's tokenize
  # option (nil is FTS5's default, unicode61).
  @indexes %{
    "contexts_fts" => %{
      name: "contexts_fts",
      table: "contexts",
      key: "id",
      columns: ["title", "content"],
      tokenize: nil
    },
    "memories_fts" => %{
      name: "memories_fts",
      table: "memories",
      key: "id",
      columns: ["content"],
      tokenize: "porter unicode61"
    }
  }

  @doc "The indexes, by name."
  @spec indexes() :: %{String.t() => index()}
  def indexes, do: @indexes

  @doc "One index by name."
  @spec index!(String.t()) :: index()
  def index!(name), do: Map.fetch!(@indexes, name)

  @doc "True when this build's store keeps its full-text indexes on PostgreSQL."
  @spec postgres?() :: boolean()
  def postgres?, do: Store.selected?(OptimalEngine.Store.Postgres)

  @doc """
  Brings the named indexes up to date on PostgreSQL before they are read. On
  SQLite the triggers keep them current and this does nothing.
  """
  @spec refresh([String.t()]) :: :ok | {:error, term()}
  def refresh(names) when is_list(names) do
    if postgres?(), do: OptimalEngine.Store.Postgres.refresh_full_text(names), else: :ok
  end

  # ---------------------------------------------------------------------------
  # Queries
  # ---------------------------------------------------------------------------

  @typedoc "A parsed MATCH string: its phrases and whether any one or all must match."
  @type query :: %{any: boolean(), phrases: [%{text: String.t(), prefix: boolean()}]}

  @phrase ~r/\A"((?:[^"]|"")*)"(\*?)/u

  @doc """
  Parses a `MATCH` string the engine built: quoted phrases joined by ` OR ` or
  by spaces, never both, the last optionally a prefix.
  """
  @spec parse(String.t()) :: {:ok, query()} | {:error, {:unsupported, String.t()}}
  def parse(match) when is_binary(match), do: parse_phrases(String.trim(match), [], nil)

  defp parse_phrases(rest, phrases, joiner) do
    case Regex.run(@phrase, rest) do
      [whole, text, star] ->
        phrase = %{text: String.replace(text, ~s(""), ~s(")), prefix: star == "*"}
        after_phrase = binary_part(rest, byte_size(whole), byte_size(rest) - byte_size(whole))
        next(after_phrase, [phrase | phrases], joiner)

      nil ->
        {:error, {:unsupported, "FTS5 query syntax"}}
    end
  end

  defp next("", phrases, joiner) do
    phrases = Enum.reverse(phrases)

    if Enum.any?(Enum.drop(phrases, -1), & &1.prefix),
      do: {:error, {:unsupported, "FTS5 query syntax"}},
      else: {:ok, %{any: joiner == :or, phrases: phrases}}
  end

  defp next(rest, phrases, joiner) do
    {found, rest} =
      case Regex.run(~r/\A\s+OR\s+/, rest) do
        [whole] -> {:or, drop(rest, whole)}
        nil -> spaces(rest)
      end

    cond do
      found == :error -> {:error, {:unsupported, "FTS5 query syntax"}}
      joiner not in [nil, found] -> {:error, {:unsupported, "FTS5 query syntax"}}
      true -> parse_phrases(rest, phrases, found)
    end
  end

  defp spaces(rest) do
    case Regex.run(~r/\A\s+/, rest) do
      [whole] -> {:and, drop(rest, whole)}
      nil -> {:error, rest}
    end
  end

  defp drop(rest, whole),
    do: binary_part(rest, byte_size(whole), byte_size(rest) - byte_size(whole))

  @doc """
  The argument `optimal_fts_match` takes for a `MATCH` string on `index`: its
  phrases tokenized as FTS5 tokenizes them, as JSON text.
  """
  @spec query_param(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def query_param(name, match), do: query_json(index!(name).tokenize, match)

  @doc """
  `query_param/2` for an index created at runtime, by its FTS5 `tokenize`
  option (`nil` for FTS5's default).
  """
  @spec query_json(String.t() | nil, String.t()) :: {:ok, String.t()} | {:error, term()}
  def query_json(tokenize, match) do
    with {:ok, %{any: any, phrases: phrases}} <- parse(match) do
      tokens = phrase_tokens(tokenize, Enum.map(phrases, & &1.text))

      json =
        phrases
        |> Enum.zip(tokens)
        |> Enum.map(fn {phrase, terms} -> %{terms: terms, prefix: phrase.prefix} end)
        |> then(&Jason.encode!(%{any: any, phrases: &1}))

      {:ok, json}
    end
  end

  # ---------------------------------------------------------------------------
  # Tokenizing with SQLite's own tokenizer
  # ---------------------------------------------------------------------------

  @doc """
  Tokenizes rows with FTS5's `tokenize` option (`nil` for FTS5's default).

  Each row is `{key, [column_text]}` and comes back as
  `{key, size, %{term => [position]}}`: `size` is the row's token count over
  every column, and a position is the column index times 2^32 plus the token's
  offset in that column, so a phrase only matches within one column.
  """
  @spec tokenize(String.t() | nil, [{term(), [String.t() | nil]}]) ::
          [{term(), non_neg_integer(), %{String.t() => [non_neg_integer()]}}]
  def tokenize(_tokenize, []), do: []

  def tokenize(tokenize, [{_key, columns} | _] = rows) do
    count = length(columns)

    with_vocabulary(tokenize, count, fn db ->
      insert_rows(db, count, rows)

      by_row =
        db
        |> all("SELECT doc, col, \"offset\", term FROM v")
        |> Enum.group_by(&hd/1, fn [_doc, col, offset, term] ->
          {term, column_index(col) * 4_294_967_296 + offset}
        end)

      rows
      |> Enum.with_index(1)
      |> Enum.map(fn {{key, _columns}, rowid} ->
        instances = Map.get(by_row, rowid, [])
        terms = Enum.group_by(instances, &elem(&1, 0), &elem(&1, 1))
        {key, length(instances), Map.new(terms, fn {term, ps} -> {term, Enum.sort(ps)} end)}
      end)
    end)
  end

  @doc "The tokens of each text in order, as FTS5 tokenizes a query phrase."
  @spec phrase_tokens(String.t() | nil, [String.t()]) :: [[String.t()]]
  def phrase_tokens(_tokenize, []), do: []

  def phrase_tokens(tokenize, texts) do
    rows = texts |> Enum.with_index() |> Enum.map(fn {text, i} -> {i, [text]} end)

    tokenize
    |> tokenize(rows)
    |> Enum.map(fn {_key, _size, terms} ->
      terms
      |> Enum.flat_map(fn {term, positions} -> Enum.map(positions, &{&1, term}) end)
      |> Enum.sort()
      |> Enum.map(&elem(&1, 1))
    end)
  end

  defp column_index("c" <> n), do: String.to_integer(n)

  defp with_vocabulary(tokenize, count, fun) do
    {:ok, db} = Exqlite.Sqlite3.open(":memory:")

    try do
      columns = Enum.map_join(0..(count - 1), ", ", &"c#{&1}")
      option = if tokenize, do: ", tokenize = '#{tokenize}'", else: ""
      :ok = Exqlite.Sqlite3.execute(db, "CREATE VIRTUAL TABLE t USING fts5(#{columns}#{option})")
      :ok = Exqlite.Sqlite3.execute(db, "CREATE VIRTUAL TABLE v USING fts5vocab(t, 'instance')")
      fun.(db)
    after
      Exqlite.Sqlite3.close(db)
    end
  end

  defp insert_rows(db, count, rows) do
    marks = Enum.map_join(1..count, ", ", fn _ -> "?" end)
    {:ok, statement} = Exqlite.Sqlite3.prepare(db, "INSERT INTO t VALUES (#{marks})")

    try do
      :ok = Exqlite.Sqlite3.execute(db, "BEGIN")

      for {{_key, columns}, _rowid} <- Enum.with_index(rows, 1) do
        :ok = Exqlite.Sqlite3.bind(statement, Enum.map(columns, &text/1))
        :done = Exqlite.Sqlite3.step(db, statement)
        :ok = Exqlite.Sqlite3.reset(statement)
      end

      :ok = Exqlite.Sqlite3.execute(db, "COMMIT")
    after
      Exqlite.Sqlite3.release(db, statement)
    end
  end

  # FTS5 indexes the text of a value; NULL is an empty column.
  defp text(nil), do: nil
  defp text(value) when is_binary(value), do: value
  defp text(value), do: to_string(value)

  defp all(db, sql) do
    {:ok, statement} = Exqlite.Sqlite3.prepare(db, sql)

    try do
      {:ok, rows} = Exqlite.Sqlite3.fetch_all(db, statement)
      rows
    after
      Exqlite.Sqlite3.release(db, statement)
    end
  end
end
