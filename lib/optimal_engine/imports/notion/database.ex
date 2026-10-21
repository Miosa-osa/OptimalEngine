defmodule OptimalEngine.Imports.Notion.Database do
  @moduledoc """
  Reads a Notion database CSV and renders it as text.

  Notion exports a database as RFC 4180 CSV with a header row; the first
  column is the title property. A byte order mark is dropped, invalid UTF-8 is
  repaired, and a ragged row is padded or trimmed to the header's width.

  A database becomes one context with a Markdown table of its rows (at most
  `@table_rows`, then a count of the rest); each row is either an exported
  row page or, when the export holds no page for it, a context of its own
  rendered by `row_text/3`.
  """

  NimbleCSV.define(__MODULE__.Parser, separator: ",", escape: "\"")

  alias __MODULE__.Parser

  @table_rows 200
  @cell_chars 200

  @type table :: %{columns: [String.t()], rows: [[String.t()]]}

  @doc "Parses CSV bytes into columns and rows."
  @spec parse(binary()) :: {:ok, table()} | {:error, :csv_unreadable}
  def parse(data) do
    data = data |> String.replace_prefix("\uFEFF", "") |> String.replace_invalid("\uFFFD")

    case Parser.parse_string(data, skip_headers: false) do
      [] ->
        {:ok, %{columns: [], rows: []}}

      [header | rows] ->
        columns = Enum.map(header, &String.trim/1)
        width = length(columns)

        rows =
          rows
          |> Enum.reject(fn row -> Enum.all?(row, &(String.trim(&1) == "")) end)
          |> Enum.map(&fit(&1, width))

        {:ok, %{columns: columns, rows: rows}}
    end
  rescue
    _ in [NimbleCSV.ParseError] -> {:error, :csv_unreadable}
  end

  @doc """
  The database's own text: its title, size, columns and a table of its rows.
  `row_uri` maps a row index to the URI of the row's context, or `nil`.
  """
  @spec text(String.t(), table(), (non_neg_integer() -> String.t() | nil)) :: String.t()
  def text(title, %{columns: columns, rows: rows}, row_uri) do
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

    summary =
      "Notion database with #{length(rows)} rows." <>
        if(columns == [], do: "", else: " Columns: #{Enum.join(columns, ", ")}.")

    more = if rest > 0, do: ["", "#{rest} more rows are imported as their own pages."], else: []
    table = if columns == [], do: [], else: [header, rule | lines]

    Enum.join(["# #{title}", "", summary, "" | table] ++ more, "\n")
  end

  @doc "The text of a row that has no exported page: its title and its properties."
  @spec row_text([String.t()], [String.t()], String.t()) :: String.t()
  def row_text(columns, row, database_title) do
    properties =
      columns
      |> Enum.zip(row)
      |> Enum.drop(1)
      |> Enum.reject(fn {_column, value} -> String.trim(value) == "" end)
      |> Enum.map(fn {column, value} -> "#{column}: #{String.trim(value)}" end)

    Enum.join(
      ["# #{row_title(row)}", "", "Row of the Notion database #{database_title}."] ++
        properties_block(properties),
      "\n"
    )
  end

  @doc "The title of a row: its first cell, or `Untitled`."
  @spec row_title([String.t()]) :: String.t()
  def row_title([first | _]) do
    case String.trim(first) do
      "" -> "Untitled"
      title -> title
    end
  end

  def row_title([]), do: "Untitled"

  defp properties_block([]), do: []
  defp properties_block(properties), do: ["" | properties]

  defp fit(row, width) do
    row = Enum.take(row, width)
    row ++ List.duplicate("", width - length(row))
  end

  defp cell(value) do
    value
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> String.slice(0, @cell_chars)
    |> String.replace("|", "\\|")
  end
end
