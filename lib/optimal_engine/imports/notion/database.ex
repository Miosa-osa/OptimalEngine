defmodule OptimalEngine.Imports.Notion.Database do
  @moduledoc """
  Reads a Notion database CSV and renders it as text.

  Notion exports a database as RFC 4180 CSV with a header row; the first
  column is the title property. The CSV is parsed as a stream and at most
  `max_rows` rows are read, so a small zip holding a huge CSV cannot fill
  memory or the workspace: the rest is reported as truncated. A byte order
  mark is dropped, invalid UTF-8 is repaired, and a ragged row is padded or
  trimmed to the header's width.

  A database becomes one context with a Markdown table of its rows (at most
  `@table_rows`, then a count of the rest); each row is either an exported
  row page or, when the export holds no page for it, a context of its own
  rendered by `row_text/4`. Both texts are clipped to the page text limit.
  """

  NimbleCSV.define(__MODULE__.Parser, separator: ",", escape: "\"")

  alias __MODULE__.Parser

  @table_rows 200
  @cell_chars 200

  @type table :: %{columns: [String.t()], rows: [[String.t()]], truncated: boolean()}

  @doc "Parses the CSV file at `path`, reading at most `max_rows` rows."
  @spec read(Path.t(), pos_integer()) :: {:ok, table()} | {:error, :csv_unreadable}
  def read(path, max_rows) do
    path |> File.stream!() |> parse_lines(max_rows)
  rescue
    _ in [File.Error] -> {:error, :csv_unreadable}
  end

  @doc "Parses CSV bytes, reading at most `max_rows` rows."
  @spec parse(binary(), pos_integer()) :: {:ok, table()} | {:error, :csv_unreadable}
  def parse(data, max_rows \\ 1_000_000) do
    data
    |> :binary.split("\n", [:global])
    |> then(fn lines -> Enum.map(Enum.drop(lines, -1), &(&1 <> "\n")) ++ [List.last(lines)] end)
    |> Enum.reject(&(&1 == ""))
    |> parse_lines(max_rows)
  end

  defp parse_lines(lines, max_rows) do
    # The header, the rows kept, and one more that shows the CSV was cut.
    parsed =
      lines
      |> Stream.with_index()
      |> Stream.map(fn
        {line, 0} -> line |> String.replace_prefix("\uFEFF", "") |> repair()
        {line, _} -> repair(line)
      end)
      |> Parser.parse_stream(skip_headers: false)
      |> Stream.reject(fn row -> Enum.all?(row, &(String.trim(&1) == "")) end)
      |> Enum.take(max_rows + 2)

    case parsed do
      [] ->
        {:ok, %{columns: [], rows: [], truncated: false}}

      [header | rows] ->
        columns = Enum.map(header, &String.trim/1)
        width = length(columns)
        truncated = length(rows) > max_rows
        rows = rows |> Enum.take(max_rows) |> Enum.map(&fit(&1, width))
        {:ok, %{columns: columns, rows: rows, truncated: truncated}}
    end
  rescue
    _ in [NimbleCSV.ParseError] -> {:error, :csv_unreadable}
  end

  defp repair(line),
    do: if(String.valid?(line), do: line, else: String.replace_invalid(line, "\uFFFD"))

  @doc """
  The database's own text: its title, size, columns and a table of its rows,
  clipped to `max_bytes`. `row_uri` maps a row index to the URI of the row's
  context, or `nil`.
  """
  @spec text(String.t(), table(), (non_neg_integer() -> String.t() | nil), pos_integer()) ::
          String.t()
  def text(title, %{columns: columns, rows: rows} = table, row_uri, max_bytes) do
    shown = Enum.take(rows, @table_rows)
    rest = length(rows) - length(shown)

    header = "| " <> Enum.map_join(columns, " | ", &cell/1) <> " |"
    rule = "|" <> String.duplicate(" --- |", max(length(columns), 1))

    lines =
      shown
      |> Enum.with_index()
      |> Enum.map(fn {row, index} ->
        [first | others] = if row == [], do: [""], else: row

        first =
          case row_uri.(index) do
            nil -> cell(first)
            uri -> "[#{cell(first)}](#{uri})"
          end

        "| " <> Enum.join([first | Enum.map(others, &cell/1)], " | ") <> " |"
      end)

    count = if table[:truncated], do: "the first #{length(rows)}", else: "#{length(rows)}"

    summary =
      "Notion database with #{count} rows." <>
        if(columns == [], do: "", else: " Columns: #{Enum.join(columns, ", ")}.")

    more = if rest > 0, do: ["", "#{rest} more rows are imported as their own pages."], else: []
    table_lines = if columns == [], do: [], else: [header, rule | lines]

    (["# #{title}", "", summary, "" | table_lines] ++ more)
    |> Enum.join("\n")
    |> clip(max_bytes)
  end

  @doc """
  The text of a row that has no exported page: its title and its properties,
  clipped to `max_bytes`.
  """
  @spec row_text([String.t()], [String.t()], String.t(), pos_integer()) :: String.t()
  def row_text(columns, row, database_title, max_bytes) do
    properties =
      columns
      |> Enum.zip(row)
      |> Enum.drop(1)
      |> Enum.reject(fn {_column, value} -> String.trim(value) == "" end)
      |> Enum.map(fn {column, value} -> "#{column}: #{String.trim(value)}" end)

    (["# #{row_title(row)}", "", "Row of the Notion database #{database_title}."] ++
       properties_block(properties))
    |> Enum.join("\n")
    |> clip(max_bytes)
  end

  @doc "The title of a row: its first cell, or `Untitled`."
  @spec row_title([String.t()]) :: String.t()
  def row_title([first | _]) do
    case String.trim(first) do
      "" -> "Untitled"
      title -> String.slice(title, 0, 500)
    end
  end

  def row_title([]), do: "Untitled"

  @doc "Cuts `text` to at most `max_bytes`, on a character boundary."
  @spec clip(String.t(), pos_integer()) :: String.t()
  def clip(text, max_bytes) when byte_size(text) <= max_bytes, do: text

  def clip(text, max_bytes) do
    case :unicode.characters_to_binary(binary_part(text, 0, max_bytes)) do
      clipped when is_binary(clipped) -> clipped
      {:incomplete, clipped, _rest} -> clipped
      {:error, clipped, _rest} -> clipped
    end
  end

  defp properties_block([]), do: []
  defp properties_block(properties), do: ["" | properties]

  defp fit(row, width) do
    row = Enum.take(row, width)
    row ++ List.duplicate("", width - length(row))
  end

  defp cell(value) do
    value
    |> String.slice(0, @cell_chars * 2)
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> String.slice(0, @cell_chars)
    |> String.replace("|", "\\|")
  end
end
