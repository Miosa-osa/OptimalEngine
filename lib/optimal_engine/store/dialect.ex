defmodule OptimalEngine.Store.Dialect do
  @moduledoc """
  Mechanical SQLite to PostgreSQL translation for the statements this engine
  writes, and an explicit refusal for everything else.

  The engine writes SQLite SQL by hand (`?1` placeholders, `datetime('now')`,
  `strftime`, `json_extract`, `INSERT OR IGNORE`). Stage 2 of the PostgreSQL
  provider (`docs/guides/postgres-provider.md`) makes those statements run on
  PostgreSQL through this module; stage 3 ports the call sites.

  ## What is translated

  | SQLite | PostgreSQL |
  | --- | --- |
  | `?1`, `?` | `$1`, positional `$n` |
  | `datetime('now')` | `to_char(now() AT TIME ZONE 'utc', 'YYYY-MM-DD HH24:MI:SS')` |
  | `datetime('now', '-90 days')` | the same expression with `- interval '90 days'` |
  | `strftime('%Y-%m-%dT%H:%M:%SZ', 'now')` | `to_char(now() AT TIME ZONE 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')` |
  | `strftime('%Y-%m-%dT%H:%M:%fZ', 'now')` | the same with `MS` for milliseconds |
  | `json_extract(col, '$.a.b')` | `(col::jsonb #>> '{a,b}')` |
  | `INSERT OR IGNORE` | `INSERT ... ON CONFLICT DO NOTHING` |

  ## What is refused

  A refusal is the point, not a gap. `INSERT OR REPLACE` deletes and re-inserts,
  which fires cascades and triggers; rewriting it to `ON CONFLICT DO UPDATE`
  would change what the database does. `MATCH` needs an index the migration
  creates, `AUTOINCREMENT` is DDL, `PRAGMA` is catalog inspection, and
  `last_insert_rowid()` needs `RETURNING`. Each is ported by hand at its call
  site, with the parity test that proves it.

  Anything this module does not map is also refused: a `strftime` with another
  format, a `datetime` with a computed modifier, a `json_extract` with a nested
  or bracketed path. A refusal is visible; a wrong rewrite is not.

  Timestamps stay ISO-8601 text, the format the engine already stores, so a
  migration does not reinterpret an existing value.
  """

  @type refusal ::
          {:error,
           {:unsupported, String.t()}
           | {:mixed_placeholders, String.t()}
           | :unterminated_literal}

  @unsupported [
    {"INSERT OR REPLACE", ~r/\bINSERT\s+OR\s+REPLACE\b/i,
     "delete-and-insert semantics; port the call site with ON CONFLICT DO UPDATE"},
    {"PRAGMA", ~r/\bPRAGMA\b/i, "catalog inspection, not a statement rewrite"},
    {"FTS5 MATCH", ~r/\bMATCH\b/i, "needs the tsvector index and a per-query rewrite"},
    {"AUTOINCREMENT", ~r/\bAUTOINCREMENT\b/i, "DDL identity syntax, rewritten with the schema"},
    {"last_insert_rowid", ~r/\blast_insert_rowid\s*\(/i, "needs RETURNING at the call site"},
    {"WITHOUT ROWID", ~r/\bWITHOUT\s+ROWID\b/i, "DDL, rewritten with the schema"},
    {"unmapped date/time function", ~r/\b(str|date)time\s*\(/i,
     "a format or modifier this module does not map"},
    {"unmapped json_extract", ~r/\bjson_extract\s*\(/i, "a JSON path this module does not map"}
  ]

  @utc_now_ts "(now() AT TIME ZONE 'utc')"
  @utc_now "to_char(#{@utc_now_ts}, 'YYYY-MM-DD HH24:MI:SS')"
  @utc_format "'YYYY-MM-DD HH24:MI:SS'"

  # The formats the engine writes today. Anything else is a call-site port.
  @strftime_formats %{
    "%Y-%m-%dT%H:%M:%SZ" => ~S|'YYYY-MM-DD"T"HH24:MI:SS"Z"'|,
    "%Y-%m-%dT%H:%M:%fZ" => ~S|'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'|,
    "%Y-%m-%dT%H:%M:%f" => ~S|'YYYY-MM-DD"T"HH24:MI:SS.MS"'|,
    "%Y-%m-%d %H:%M:%S" => ~S|'YYYY-MM-DD HH24:MI:SS'|,
    "%Y-%m-%d %H:%M" => ~S|'YYYY-MM-DD HH24:MI'|,
    "%Y-%m-%d" => ~S|'YYYY-MM-DD'|
  }

  @doc """
  Translates one SQLite statement.

  Returns `{:ok, sql}` or `{:error, reason}`. A failure never returns a partial
  rewrite.
  """
  @spec to_postgres(String.t()) :: {:ok, String.t()} | refusal()
  def to_postgres(sql) when is_binary(sql) do
    with {:ok, rewritten} <- rewrite_functions(sql),
         {:ok, rewritten} <- rewrite_insert_or_ignore(rewritten),
         {:ok, masked, _literals} <- masked_sql(rewritten),
         :ok <- reject_unsupported(masked),
         {:ok, translated} <- rewrite_placeholders(rewritten) do
      {:ok, translated}
    end
  end

  @doc "Every construct this module refuses, with the reason."
  @spec refusals() :: [{String.t(), String.t()}]
  def refusals do
    Enum.map(@unsupported, fn {name, _pattern, reason} -> {name, reason} end)
  end

  # ---------------------------------------------------------------------------
  # Refusals
  # ---------------------------------------------------------------------------

  defp reject_unsupported(masked) do
    case Enum.find(@unsupported, fn {_name, pattern, _reason} -> Regex.match?(pattern, masked) end) do
      nil -> :ok
      {name, _pattern, _reason} -> {:error, {:unsupported, name}}
    end
  end

  # ---------------------------------------------------------------------------
  # Functions
  # ---------------------------------------------------------------------------

  defp rewrite_functions(sql) do
    with {:ok, rewritten} <- replace_datetime(sql),
         {:ok, rewritten} <- replace_strftime(rewritten) do
      replace_json_extract(rewritten)
    end
  end

  defp replace_datetime(sql) do
    pattern =
      ~r/datetime\(\s*'now'\s*(?:,\s*'([+-]?\s*\d+)\s+(day|days|hour|hours|minute|minutes|second|seconds)'\s*)?\)/i

    replace_all(sql, pattern, fn
      [_, number, unit] -> {:ok, interval(@utc_now, number, unit)}
      [_] -> {:ok, @utc_now}
      _ -> {:error, {:unsupported, "datetime() modifier"}}
    end)
  end

  defp interval(_base, number, unit) do
    trimmed = String.trim(number)
    sign = if String.starts_with?(trimmed, "-"), do: "-", else: "+"
    amount = trimmed |> String.trim_leading("-") |> String.trim_leading("+")

    "to_char(#{@utc_now_ts} #{sign} interval '#{amount} #{String.downcase(unit)}', " <>
      "#{@utc_format})"
  end

  defp replace_strftime(sql) do
    pattern = ~r/strftime\(\s*'([^']+)'\s*,\s*'now'\s*\)/i

    replace_all(sql, pattern, fn
      [_, format] ->
        case Map.fetch(@strftime_formats, format) do
          {:ok, postgres_format} ->
            {:ok, "to_char(now() AT TIME ZONE 'utc', #{postgres_format})"}

          :error ->
            {:error, {:unsupported, "strftime format #{format}"}}
        end

      _ ->
        {:error, {:unsupported, "strftime call"}}
    end)
  end

  defp replace_json_extract(sql) do
    pattern = ~r/json_extract\(\s*([A-Za-z_][A-Za-z0-9_.]*)\s*,\s*'\$\.([A-Za-z0-9_.]+)'\s*\)/i

    replace_all(sql, pattern, fn
      [_, column, path] ->
        keys = path |> String.split(".") |> Enum.join(",")
        {:ok, "(#{column}::jsonb #>> '{#{keys}}')"}

      _ ->
        {:error, {:unsupported, "json_extract path"}}
    end)
  end

  # Applies `fun` to the first match, then recurses on the suffix. Index-based
  # splicing avoids replacing an identical string inside a literal earlier in
  # the statement.
  defp replace_all(sql, pattern, fun) do
    case Regex.run(pattern, sql, return: :index) do
      nil ->
        {:ok, sql}

      [{start, length} | capture_indexes] ->
        full = binary_part(sql, start, length)

        captures =
          Enum.map(capture_indexes, fn
            {-1, 0} -> nil
            {offset, len} -> binary_part(sql, offset, len)
          end)

        case fun.([full | captures]) do
          {:ok, replacement} ->
            prefix = binary_part(sql, 0, start)
            suffix = binary_part(sql, start + length, byte_size(sql) - start - length)

            case replace_all(suffix, pattern, fun) do
              {:ok, rest} -> {:ok, prefix <> replacement <> rest}
              error -> error
            end

          error ->
            error
        end
    end
  end

  # ---------------------------------------------------------------------------
  # INSERT OR IGNORE
  # ---------------------------------------------------------------------------

  defp rewrite_insert_or_ignore(sql) do
    with {:ok, masked, literals} <- masked_sql(sql) do
      cond do
        not Regex.match?(~r/\bINSERT\s+OR\s+IGNORE\b/i, masked) ->
          {:ok, sql}

        Regex.match?(~r/\bON\s+CONFLICT\b/i, masked) ->
          {:error, {:unsupported, "INSERT OR IGNORE with an explicit ON CONFLICT clause"}}

        true ->
          rewritten = Regex.replace(~r/\bINSERT\s+OR\s+IGNORE\b/i, masked, "INSERT", global: false)
          {:ok, unmask(String.trim_trailing(rewritten) <> " ON CONFLICT DO NOTHING", literals)}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Placeholders
  # ---------------------------------------------------------------------------

  defp rewrite_placeholders(sql) do
    with {:ok, masked, literals} <- masked_sql(sql) do
      numbered? = Regex.match?(~r/\?\d+/, masked)
      positional? = Regex.match?(~r/\?(?!\d)/, masked)

      cond do
        numbered? and positional? ->
          {:error, {:mixed_placeholders, sql}}

        numbered? ->
          {:ok, unmask(Regex.replace(~r/\?(\d+)/, masked, "$\\1"), literals)}

        positional? ->
          {rewritten, _count} =
            masked
            |> String.split("?")
            |> Enum.with_index()
            |> Enum.map_reduce(0, fn
              {part, 0}, count -> {part, count}
              {part, _index}, count -> {"$#{count + 1}" <> part, count + 1}
            end)

          {:ok, unmask(Enum.join(rewritten), literals)}

        true ->
          {:ok, sql}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Literal masking
  # ---------------------------------------------------------------------------

  # Replaces every single-quoted literal with a sentinel so keywords and
  # placeholders inside a literal are never rewritten. A doubled quote inside a
  # literal is an escaped quote and stays part of it.
  defp masked_sql(sql) do
    case literals(sql) do
      {:ok, literals} ->
        {masked, _n} =
          Enum.reduce(literals, {sql, 0}, fn literal, {acc, n} ->
            {String.replace(acc, literal, sentinel(n), global: false), n + 1}
          end)

        {:ok, masked, literals}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp sentinel(n), do: "\x00L#{n}\x00"

  defp unmask(sql, literals) do
    literals
    |> Enum.with_index()
    |> Enum.reduce(sql, fn {literal, n}, acc -> String.replace(acc, sentinel(n), literal) end)
  end

  defp literals(sql), do: do_literals(sql, 0, [], [])

  defp do_literals(sql, index, current, literals) when index >= byte_size(sql) do
    if current == [] do
      {:ok, Enum.reverse(literals)}
    else
      {:error, :unterminated_literal}
    end
  end

  defp do_literals(sql, index, current, literals) do
    char = :binary.at(sql, index)

    cond do
      current == [] and char == ?' ->
        do_literals(sql, index + 1, [?'], literals)

      current != [] and char == ?' and index + 1 < byte_size(sql) and
          :binary.at(sql, index + 1) == ?' ->
        do_literals(sql, index + 2, [?', ?' | current], literals)

      current != [] and char == ?' ->
        text = (current |> Enum.reverse() |> List.to_string()) <> "'"
        do_literals(sql, index + 1, [], [text | literals])

      current != [] ->
        do_literals(sql, index + 1, [char | current], literals)

      true ->
        do_literals(sql, index + 1, current, literals)
    end
  end
end
