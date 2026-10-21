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
  | `datetime('now')` | `to_char(statement_timestamp() AT TIME ZONE 'utc', 'YYYY-MM-DD HH24:MI:SS')` |
  | `datetime('now', '-90 days')` | the same expression with `- interval '90 days'` |
  | `strftime('%Y-%m-%dT%H:%M:%SZ', 'now')` | `to_char(...)` with `'YYYY-MM-DD"T"HH24:MI:SS"Z"'` |
  | `strftime('%Y-%m-%dT%H:%M:%fZ', 'now')` | the same with `MS` for milliseconds |
  | `INSERT OR IGNORE` | `INSERT ... ON CONFLICT DO NOTHING` |
  | `x LIKE p`, `x NOT LIKE p` | `x ILIKE (p) COLLATE "C" ESCAPE ''`, the same with `NOT` |
  | `x IS ?`, `x IS NOT 'a'` | `x IS NOT DISTINCT FROM $n`, `x IS DISTINCT FROM 'a'` |
  | `IFNULL(a, b)` | `COALESCE(a, b)` |
  | `CAST(x AS INTEGER)`, `CAST(x AS REAL)` | `CAST(x AS BIGINT)`, `CAST(x AS DOUBLE PRECISION)` |
  | `json_valid(col)` | `(col IS JSON)` |
  | `ORDER BY a, b DESC` | `ORDER BY a NULLS FIRST, b DESC NULLS LAST` |
  | `PRAGMA defer_foreign_keys = ON` | `SET CONSTRAINTS ALL DEFERRED` |
  | `json_extract(col, '$.a.b')` | by context, below |

  `datetime('now')` uses the statement's start time: SQLite takes a new time
  for every statement, and PostgreSQL's `now()` would repeat the time the
  transaction began.

  SQLite's `LIKE` ignores the case of ASCII letters, and nothing else, and has
  no escape character. `ILIKE` in the `C` collation, which the pattern carries,
  folds exactly the same letters, and `ESCAPE ''` turns PostgreSQL's default
  backslash escape off, so a backslash in a pattern is an ordinary character on
  both. An explicit `ESCAPE` is kept. The pattern must be a placeholder, a literal, a column, or
  a `||` chain of those; a computed pattern is refused.

  SQLite sorts NULL before every value. Every `ORDER BY` term gets the
  `NULLS FIRST` (ascending) or `NULLS LAST` (descending) that keeps that order.

  ## json_extract

  SQLite returns a JSON string as text, a number as a number, `true` and
  `false` as 1 and 0, and JSON `null` as NULL. The translation keeps those
  semantics where the extracted value is compared, and returns text where it
  is not:

  - Compared with `=`, `!=`, `<>`, `IN` or `IS [NOT]` to a string literal or a
    placeholder, the comparison runs on `jsonb` values, so a JSON number never
    equals text, as on SQLite. The placeholder must be bound to text; the store
    refuses any other value (`translate/1` names those placeholders).
  - Compared to an integer literal, it matches the JSON number, and for 1 and 0
    also `true` and `false`, as SQLite does.
  - `IS NULL` and `IS NOT NULL` treat a JSON `null` as NULL.
  - Compared to a column, the comparison runs on text, as SQLite's text
    affinity does.
  - Anywhere else (a select list, `COALESCE`, a `CASE` branch, `ILIKE`) it is
    the value as text in the `C` collation: exact for JSON strings and nulls;
    a JSON number or boolean comes back as its text.

  An ordered comparison (`<`, `>`, `BETWEEN`), an `ORDER BY` term, a
  comparison to another expression, and `json_extract` on the right of a
  comparison are refused: each orders or compares by SQLite's types, which the
  text does not keep. An object or array comes back as PostgreSQL's JSON text,
  which decodes to the same value as SQLite's.

  ## What is refused

  A refusal is the point, not a gap. `INSERT OR REPLACE` deletes and re-inserts,
  which fires cascades and triggers; rewriting it to `ON CONFLICT DO UPDATE`
  would change what the database does. `MATCH` needs an index the migration
  creates, `AUTOINCREMENT` is DDL, `PRAGMA` and `sqlite_master` are catalog
  inspection, `rowid` does not exist on PostgreSQL, and `last_insert_rowid()`
  needs `RETURNING`. SQLite's JSON functions other than `json_extract` and
  `json_valid`, and `group_concat`, `typeof`, `julianday` and friends are
  refused by name. Each is ported by hand at its call site, with the parity
  test that proves it.

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

  @typedoc "What a translated statement needs from its parameters."
  @type requirements :: %{text_params: [pos_integer()], params: :all | [pos_integer()]}

  @sqlite_json_functions ~w(
    json_set json_each json_tree json_insert json_replace json_remove json_patch
    json_type json_quote json_object json_array json_array_length json_group_array
    json_group_object json_error_position json_pretty json
  )

  @sqlite_functions ~w(
    group_concat typeof julianday unixepoch instr printf total hex randomblob
    zeroblob likelihood unlikely iif changes total_changes sqlite_version date time
  )

  @unsupported [
                 {"INSERT OR REPLACE", ~r/\bINSERT\s+OR\s+REPLACE\b/i,
                  "delete-and-insert semantics; port the call site with ON CONFLICT DO UPDATE"},
                 {"REPLACE INTO", ~r/(\A|;)\s*REPLACE\s+INTO\b/i,
                  "SQLite's INSERT OR REPLACE spelled another way"},
                 {"PRAGMA", ~r/\bPRAGMA\b/i, "catalog inspection, not a statement rewrite"},
                 {"sqlite_master", ~r/\bsqlite_(master|schema|temp_master|sequence)\b/i,
                  "the SQLite catalog; PostgreSQL has information_schema"},
                 {"SQLite catalog function", ~r/\bpragma_\w+\s*\(/i,
                  "the SQLite catalog; PostgreSQL has information_schema"},
                 {"FTS5 MATCH", ~r/\bMATCH\b/i,
                  "full-text search is not available on the PostgreSQL store"},
                 {"GLOB", ~r/\bGLOB\b/i, "case-sensitive wildcard matching; port the call site"},
                 {"SQLite collation", ~r/\bCOLLATE\s+"?(NOCASE|RTRIM|BINARY)\b/i,
                  "a SQLite collation; the store's text compares in the C collation"},
                 {"rowid", ~r/\b(rowid|_rowid_)\b/i, "PostgreSQL tables have no rowid"},
                 {"AUTOINCREMENT", ~r/\bAUTOINCREMENT\b/i,
                  "DDL identity syntax, rewritten with the schema"},
                 {"last_insert_rowid", ~r/\blast_insert_rowid\s*\(/i,
                  "needs RETURNING at the call site"},
                 {"WITHOUT ROWID", ~r/\bWITHOUT\s+ROWID\b/i, "DDL, rewritten with the schema"},
                 {"unmapped date/time function", ~r/\b(str|date)time\s*\(/i,
                  "a format or modifier this module does not map"}
               ] ++
                 Enum.map(@sqlite_json_functions, fn name ->
                   {name, Regex.compile!("\\b#{name}\\s*\\(", "i"),
                    "a SQLite JSON function with no translation"}
                 end) ++
                 Enum.map(@sqlite_functions, fn name ->
                   {name, Regex.compile!("\\b#{name}\\s*\\(", "i"),
                    "a SQLite function with no translation"}
                 end)

  @utc_now_ts "(statement_timestamp() AT TIME ZONE 'utc')"
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

  # A literal, a placeholder, a plain or quoted (and optionally qualified)
  # column: the operands a LIKE pattern or a json_extract comparison may use.
  @sentinel "\\x00L\\d+\\x00"
  @placeholder "\\$\\d+"
  @identifier ~S'(?:[A-Za-z_][A-Za-z0-9_]*|"[^"]+")(?:\.(?:[A-Za-z_][A-Za-z0-9_]*|"[^"]+"))?'

  @order_by_end ~r/\A(LIMIT|OFFSET|FETCH|FOR|UNION|EXCEPT|INTERSECT|ROWS|RANGE|GROUPS|WINDOW|RETURNING)\b/i

  # PRAGMA defer_foreign_keys holds every foreign key check until the commit,
  # for the rest of the transaction; the store's foreign keys are deferrable,
  # so SET CONSTRAINTS does the same.
  @defer_foreign_keys ~r/\A\s*PRAGMA\s+defer_foreign_keys\s*=\s*(ON|OFF|TRUE|FALSE|1|0)\s*;?\s*\z/i

  @doc """
  Translates one SQLite statement.

  Returns `{:ok, sql}` or `{:error, reason}`. A failure never returns a partial
  rewrite.
  """
  @spec to_postgres(String.t()) :: {:ok, String.t()} | refusal()
  def to_postgres(sql) when is_binary(sql) do
    with {:ok, translated, _requirements} <- translate(sql), do: {:ok, translated}
  end

  @doc """
  Translates one SQLite statement and says what its parameters must be:
  `text_params` lists the placeholders a `json_extract` is compared to, which
  must be bound to text.

  SQLite ignores a numbered parameter the statement never names, and
  PostgreSQL cannot type one, so the placeholders are renumbered without
  gaps: `params` is `:all`, or the original numbers of the parameters to
  bind, in order.
  """
  @spec translate(String.t()) :: {:ok, String.t(), requirements()} | refusal()
  def translate(sql) when is_binary(sql) do
    case Regex.run(@defer_foreign_keys, sql) do
      [_, setting] -> {:ok, deferred(setting), %{text_params: [], params: :all}}
      nil -> translate_statement(sql)
    end
  end

  # PRAGMA defer_foreign_keys holds every foreign key check until the commit;
  # the store's foreign keys are deferrable, so SET CONSTRAINTS does the same.
  defp deferred(setting) do
    if String.upcase(setting) in ["ON", "TRUE", "1"],
      do: "SET CONSTRAINTS ALL DEFERRED",
      else: "SET CONSTRAINTS ALL IMMEDIATE"
  end

  defp translate_statement(sql) do
    with {:ok, rewritten} <- rewrite_functions(sql),
         {:ok, rewritten} <- rewrite_insert_or_ignore(rewritten),
         {:ok, masked, literals} <- masked_sql(rewritten),
         :ok <- reject_unsupported(masked),
         masked = rewrite_simple(masked),
         {:ok, masked} <- rewrite_like(masked),
         masked = rewrite_is_placeholder(masked),
         {:ok, masked} <- rewrite_order_by(masked),
         {:ok, masked} <- rewrite_placeholders(masked, rewritten),
         {:ok, masked, text_params} <- rewrite_json_extract(masked, literals),
         :ok <- reject_leftover_json_extract(masked) do
      {masked, requirements} = without_gaps(masked, Enum.sort(Enum.uniq(text_params)))
      {:ok, unmask(masked, literals), requirements}
    end
  end

  @dollar ~r/\$(\d+)(?!\d)/

  defp without_gaps(masked, text_params) do
    used =
      @dollar
      |> Regex.scan(masked, capture: :all_but_first)
      |> Enum.map(fn [n] -> String.to_integer(n) end)
      |> Enum.uniq()
      |> Enum.sort()

    if used == Enum.to_list(1..length(used)//1) do
      {masked, %{text_params: text_params, params: :all}}
    else
      numbers = used |> Enum.with_index(1) |> Map.new()

      renumbered =
        Regex.replace(@dollar, masked, fn _whole, n ->
          "$#{Map.fetch!(numbers, String.to_integer(n))}"
        end)

      {renumbered, %{text_params: Enum.map(text_params, &Map.fetch!(numbers, &1)), params: used}}
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

  defp reject_leftover_json_extract(masked) do
    cond do
      Regex.match?(~r/\bjson_extract\s*\(/i, masked) ->
        {:error, {:unsupported, "json_extract form"}}

      Regex.match?(~r/\bjson_valid\s*\(/i, masked) ->
        {:error, {:unsupported, "json_valid of an expression"}}

      true ->
        :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Functions
  # ---------------------------------------------------------------------------

  defp rewrite_functions(sql) do
    with {:ok, rewritten} <- replace_datetime(sql) do
      replace_strftime(rewritten)
    end
  end

  defp replace_datetime(sql) do
    pattern =
      ~r/datetime\(\s*'now'\s*(?:,\s*'([+-]?\s*\d+)\s+(day|days|hour|hours|minute|minutes|second|seconds)'\s*)?\)/i

    replace_all(sql, pattern, fn
      [_, number, unit] -> {:ok, interval(number, unit)}
      [_] -> {:ok, @utc_now}
      _ -> {:error, {:unsupported, "datetime() modifier"}}
    end)
  end

  defp interval(number, unit) do
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
          {:ok, postgres_format} -> {:ok, "to_char(#{@utc_now_ts}, #{postgres_format})"}
          :error -> {:error, {:unsupported, "strftime format #{format}"}}
        end

      _ ->
        {:error, {:unsupported, "strftime call"}}
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

  # IFNULL is COALESCE with two arguments, json_valid of a column is
  # PostgreSQL's IS JSON predicate (PostgreSQL 16), and SQLite's INTEGER and
  # REAL are eight bytes, PostgreSQL's BIGINT and DOUBLE PRECISION.
  defp rewrite_simple(masked) do
    masked
    |> then(&Regex.replace(~r/\bIFNULL\s*\(/i, &1, "COALESCE("))
    |> then(&Regex.replace(~r/\bjson_valid\s*\(\s*(#{@identifier})\s*\)/i, &1, "(\\1 IS JSON)"))
    |> then(&Regex.replace(~r/\bAS\s+INTEGER\s*\)/i, &1, "AS BIGINT)"))
    |> then(&Regex.replace(~r/\bAS\s+REAL\s*\)/i, &1, "AS DOUBLE PRECISION)"))
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
  # LIKE
  # ---------------------------------------------------------------------------

  @like ~r/\bLIKE\b/i
  @like_operand Regex.compile!(
                  "\\A\\s*(?:#{@sentinel}|\\?\\d*|#{@identifier})(?:\\s*\\|\\|\\s*(?:#{@sentinel}|\\?\\d*|#{@identifier}))*",
                  "i"
                )

  defp rewrite_like(masked), do: rewrite_like(masked, [])

  defp rewrite_like(masked, done) do
    case Regex.run(@like, masked, return: :index) do
      nil ->
        {:ok, IO.iodata_to_binary(Enum.reverse([masked | done]))}

      [{start, length}] ->
        before = binary_part(masked, 0, start)
        rest = binary_part(masked, start + length, byte_size(masked) - start - length)

        case Regex.run(@like_operand, rest) do
          [operand] ->
            after_operand = tail(rest, operand)

            cond do
              Regex.match?(~r/\A\s*[(.]/, after_operand) ->
                {:error, {:unsupported, "LIKE with a computed pattern"}}

              Regex.match?(~r/\A\s*ESCAPE\b/i, after_operand) ->
                rewrite_like(after_operand, [pattern(operand), "ILIKE", before | done])

              true ->
                rewrite_like(after_operand, [" ESCAPE ''", pattern(operand), "ILIKE", before | done])
            end

          nil ->
            {:error, {:unsupported, "LIKE with a computed pattern"}}
        end
    end
  end

  # The pattern decides the collation, so ILIKE folds only ASCII letters, as
  # SQLite's LIKE does, whatever the collation of the value it matches.
  defp pattern(operand), do: ~s| (#{String.trim(operand)}) COLLATE "C"|

  # ---------------------------------------------------------------------------
  # IS with a placeholder
  # ---------------------------------------------------------------------------

  # SQLite's IS and IS NOT compare any two values and treat NULL as a value;
  # PostgreSQL spells that IS [NOT] DISTINCT FROM for a placeholder, a string
  # or a number. IS NULL, IS TRUE and IS FALSE mean the same on both.
  @is_value Regex.compile!(
              "\\bIS\\s+(NOT\\s+)?(\\?\\d*|#{@sentinel}|[+-]?\\d+(?:\\.\\d+)?(?![\\w.]))",
              "i"
            )

  defp rewrite_is_placeholder(masked) do
    Regex.replace(@is_value, masked, fn _whole, negated, value ->
      if negated == "",
        do: "IS NOT DISTINCT FROM #{value}",
        else: "IS DISTINCT FROM #{value}"
    end)
  end

  # ---------------------------------------------------------------------------
  # ORDER BY
  # ---------------------------------------------------------------------------

  defp rewrite_order_by(masked), do: rewrite_order_by(masked, [])

  defp rewrite_order_by(masked, done) do
    case Regex.run(~r/\bORDER\s+BY\b/i, masked, return: :index) do
      nil ->
        {:ok, IO.iodata_to_binary(Enum.reverse([masked | done]))}

      [{start, length}] ->
        head = binary_part(masked, 0, start + length)
        rest = binary_part(masked, start + length, byte_size(masked) - start - length)
        {terms, tail} = order_terms(rest, 0, [], [])

        # SQLite orders json_extract by the value's type and value; its text
        # would sort numbers as text.
        if Enum.any?(terms, &Regex.match?(~r/\bjson_extract\s*\(/i, &1)) do
          {:error, {:unsupported, "json_extract in ORDER BY"}}
        else
          rewritten = Enum.map_join(terms, ",", &with_nulls/1)
          rewrite_order_by(tail, [rewritten, head | done])
        end
    end
  end

  # Splits the ORDER BY list into its terms: commas at depth 0 separate terms,
  # and the list ends at a closing parenthesis it did not open, a clause
  # keyword, or the end of the statement.
  defp order_terms(<<>>, _depth, current, terms), do: finish_terms(current, terms, "")

  defp order_terms(<<?(, rest::binary>>, depth, current, terms),
    do: order_terms(rest, depth + 1, [?( | current], terms)

  defp order_terms(<<?), rest::binary>>, 0, current, terms),
    do: finish_terms(current, terms, ")" <> rest)

  defp order_terms(<<?), rest::binary>>, depth, current, terms),
    do: order_terms(rest, depth - 1, [?) | current], terms)

  defp order_terms(<<?,, rest::binary>>, 0, current, terms),
    do: order_terms(rest, 0, [], [current | terms])

  defp order_terms(<<?;, _::binary>> = rest, 0, current, terms),
    do: finish_terms(current, terms, rest)

  defp order_terms(<<char, rest::binary>> = text, 0, current, terms) do
    if word_start?(current) and clause_end?(text) do
      finish_terms(current, terms, text)
    else
      order_terms(rest, 0, [char | current], terms)
    end
  end

  defp order_terms(<<char, rest::binary>>, depth, current, terms),
    do: order_terms(rest, depth, [char | current], terms)

  defp finish_terms(current, terms, tail) do
    terms =
      [current | terms]
      |> Enum.reverse()
      |> Enum.map(&(&1 |> Enum.reverse() |> IO.iodata_to_binary()))

    {terms, tail}
  end

  defp word_start?([]), do: true

  defp word_start?([previous | _]),
    do: not (previous in ?a..?z or previous in ?A..?Z or previous in ?0..?9 or previous == ?_)

  defp clause_end?(text), do: Regex.match?(@order_by_end, text)

  defp with_nulls(term) do
    trimmed = String.trim_trailing(term)
    trailing = binary_part(term, byte_size(trimmed), byte_size(term) - byte_size(trimmed))

    cond do
      String.trim(term) == "" -> term
      Regex.match?(~r/\bNULLS\s+(FIRST|LAST)\z/i, trimmed) -> term
      Regex.match?(~r/\bDESC\z/i, trimmed) -> trimmed <> " NULLS LAST" <> trailing
      true -> trimmed <> " NULLS FIRST" <> trailing
    end
  end

  # ---------------------------------------------------------------------------
  # Placeholders
  # ---------------------------------------------------------------------------

  defp rewrite_placeholders(masked, original) do
    numbered? = Regex.match?(~r/\?\d+/, masked)
    positional? = Regex.match?(~r/\?(?!\d)/, masked)

    cond do
      numbered? and positional? ->
        {:error, {:mixed_placeholders, original}}

      numbered? ->
        {:ok, Regex.replace(~r/\?(\d+)/, masked, "$\\1")}

      positional? ->
        {rewritten, _count} =
          masked
          |> String.split("?")
          |> Enum.with_index()
          |> Enum.map_reduce(0, fn
            {part, 0}, count -> {part, count}
            {part, _index}, count -> {"$#{count + 1}" <> part, count + 1}
          end)

        {:ok, Enum.join(rewritten)}

      true ->
        {:ok, masked}
    end
  end

  # ---------------------------------------------------------------------------
  # json_extract
  # ---------------------------------------------------------------------------

  @json_extract Regex.compile!(
                  "\\bjson_extract\\(\\s*(#{@identifier})\\s*,\\s*(#{@sentinel})\\s*\\)",
                  "i"
                )

  defp rewrite_json_extract(masked, literals), do: rewrite_json_extract(masked, literals, [], [])

  defp rewrite_json_extract(masked, literals, done, params) do
    case Regex.run(@json_extract, masked, return: :index) do
      nil ->
        {:ok, IO.iodata_to_binary(Enum.reverse([masked | done])), params}

      [{start, length}, column, path] ->
        before = binary_part(masked, 0, start)
        rest = binary_part(masked, start + length, byte_size(masked) - start - length)
        column = slice(masked, column)

        with {:ok, keys} <- json_path(literal_text(slice(masked, path), literals)),
             :ok <- reject_right_operand(before),
             {:ok, replacement, rest, used} <- json_context(column, keys, rest) do
          rewrite_json_extract(rest, literals, [replacement, before | done], used ++ params)
        end
    end
  end

  defp slice(text, {offset, length}), do: binary_part(text, offset, length)

  defp literal_text(sentinel, literals) do
    [_, index] = Regex.run(~r/\x00L(\d+)\x00/, sentinel)
    Enum.at(literals, String.to_integer(index))
  end

  defp json_path("'$." <> path) do
    path = String.trim_trailing(path, "'")

    if Regex.match?(~r/\A[A-Za-z0-9_]+(\.[A-Za-z0-9_]+)*\z/, path),
      do: {:ok, String.replace(path, ".", ",")},
      else: {:error, {:unsupported, "json_extract path"}}
  end

  defp json_path(_literal), do: {:error, {:unsupported, "json_extract path"}}

  defp reject_right_operand(before) do
    if Regex.match?(~r/([=<>!]|\bIS(\s+NOT)?|\bIN|\bFROM)\s*\(?\s*\z/i, before) and
         not Regex.match?(~r/\bSELECT\s*\z/i, before),
       do: {:error, {:unsupported, "json_extract on the right of a comparison"}},
       else: :ok
  end

  # The value as jsonb, with JSON null as NULL: compared to another jsonb value
  # it keeps SQLite's typed comparison (a JSON number never equals text).
  defp jsonb_value(column, keys), do: "NULLIF((#{column}::jsonb #> '{#{keys}}'), 'null'::jsonb)"

  defp text_value(column, keys), do: "((#{column}::jsonb #>> '{#{keys}}') COLLATE \"C\")"

  @operand "(?:#{@sentinel}|#{@placeholder}|[+-]?\\d+(?:\\.\\d+)?|#{@identifier})"
  @is_null ~r/\A\s*IS\s+(NOT\s+)?NULL\b/i
  @is_distinct Regex.compile!("\\A\\s*IS\\s+(NOT\\s+)?DISTINCT\\s+FROM\\s+(#{@operand})", "i")
  @equality Regex.compile!("\\A\\s*(==|=|!=|<>)\\s*(#{@operand})", "i")
  @in_list ~r/\A\s*(NOT\s+)?IN\s*\(/i
  @ordered ~r/\A\s*(<=|>=|<|>|(NOT\s+)?BETWEEN\b)/i
  @other_comparison ~r/\A\s*(==|=|!=|<>|IS\b)/i
  @number ~r/\A[+-]?\d+(\.\d+)?\z/
  @operand_end ~r/\A\s*(\z|\)|,|;|(AND|OR|THEN|ELSE|END|WHEN|ORDER|GROUP|LIMIT|OFFSET|UNION|EXCEPT|INTERSECT|HAVING|WINDOW|RETURNING)\b)/i
  @bound Regex.compile!("\\A(?:#{@sentinel}|#{@placeholder})\\z")

  defp json_context(column, keys, rest) do
    jsonb = jsonb_value(column, keys)

    cond do
      match = Regex.run(@is_null, rest) ->
        [whole | _] = match
        {:ok, jsonb <> whole, tail(rest, whole), []}

      match = Regex.run(@is_distinct, rest) ->
        [whole, negated, operand] = match
        comparison = if negated == "", do: "IS DISTINCT FROM", else: "IS NOT DISTINCT FROM"

        with :ok <- operand_ends(tail(rest, whole)),
             {:ok, rhs, used} <- jsonb_operand(operand) do
          {:ok, "#{jsonb} #{comparison} #{rhs}", tail(rest, whole), used}
        end

      match = Regex.run(@equality, rest) ->
        [whole, operator, operand] = match
        operator = if operator == "==", do: "=", else: operator

        with :ok <- operand_ends(tail(rest, whole)) do
          compare(column, keys, operator, operand, tail(rest, whole))
        end

      match = Regex.run(@in_list, rest) ->
        [whole | negated] = match
        in_list(column, keys, negated not in [[], [""]], tail(rest, whole))

      Regex.match?(@ordered, rest) ->
        {:error, {:unsupported, "json_extract ordered comparison"}}

      Regex.match?(@other_comparison, rest) ->
        {:error, {:unsupported, "json_extract compared to an expression"}}

      true ->
        {:ok, text_value(column, keys), rest, []}
    end
  end

  # The compared value must be the whole right side: `= ?1 || 'x'` compares
  # to an expression.
  defp operand_ends(rest) do
    if Regex.match?(@operand_end, rest),
      do: :ok,
      else: {:error, {:unsupported, "json_extract compared to an expression"}}
  end

  defp tail(rest, whole),
    do: binary_part(rest, byte_size(whole), byte_size(rest) - byte_size(whole))

  defp compare(column, keys, operator, operand, rest) do
    jsonb = jsonb_value(column, keys)

    cond do
      Regex.match?(@number, operand) ->
        matches = "#{jsonb} IN (#{Enum.join(number_values(operand), ", ")})"
        {:ok, if(operator == "=", do: matches, else: "NOT (#{matches})"), rest, []}

      Regex.match?(@bound, operand) ->
        {:ok, rhs, used} = jsonb_operand(operand)
        {:ok, "#{jsonb} #{operator} #{rhs}", rest, used}

      String.upcase(operand) in ~w(CASE SELECT EXISTS NOT TRUE FALSE CAST) ->
        {:error, {:unsupported, "json_extract compared to an expression"}}

      true ->
        # A column: SQLite applies the column's text affinity to the value.
        {:ok, "#{text_value(column, keys)} #{operator} #{operand}", rest, []}
    end
  end

  # An integer literal matches the JSON number, and 1 and 0 also match true
  # and false, which SQLite's json_extract returns as 1 and 0.
  defp number_values(operand) do
    booleans =
      case operand do
        "1" -> ["'true'::jsonb"]
        "0" -> ["'false'::jsonb"]
        _ -> []
      end

    ["'#{operand}'::jsonb" | booleans]
  end

  # A placeholder must be bound to text (the store checks); a literal is text.
  defp jsonb_operand("$" <> number = operand) do
    case Integer.parse(number) do
      {index, ""} -> {:ok, "to_jsonb(#{operand}::text)", [index]}
      _ -> {:error, {:unsupported, "json_extract compared to an expression"}}
    end
  end

  defp jsonb_operand(operand) do
    if Regex.match?(@bound, operand),
      do: {:ok, "to_jsonb(#{operand}::text)", []},
      else: {:error, {:unsupported, "json_extract compared to an expression"}}
  end

  defp in_list(column, keys, negated?, rest) do
    case Regex.run(~r/\A([^()]*)\)/, rest) do
      [whole, items] ->
        values =
          items
          |> String.split(",")
          |> Enum.map(&String.trim/1)
          |> Enum.reduce_while({:ok, [], []}, fn item, {:ok, acc, used} ->
            cond do
              Regex.match?(@number, item) ->
                {:cont, {:ok, acc ++ number_values(item), used}}

              Regex.match?(@bound, item) ->
                {:ok, rhs, more} = jsonb_operand(item)
                {:cont, {:ok, acc ++ [rhs], used ++ more}}

              true ->
                {:halt, {:error, {:unsupported, "json_extract IN with an expression"}}}
            end
          end)

        with {:ok, values, used} <- values do
          operator = if negated?, do: "NOT IN", else: "IN"
          rewritten = "#{jsonb_value(column, keys)} #{operator} (#{Enum.join(values, ", ")})"
          {:ok, rewritten, tail(rest, whole), used}
        end

      nil ->
        {:error, {:unsupported, "json_extract IN with a subquery"}}
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

  # `current` holds bytes, so the literal is rebuilt byte for byte: a literal
  # with non-ASCII text must come back exactly as it was written.
  defp do_literals(sql, index, current, literals) do
    char = :binary.at(sql, index)

    cond do
      current == [] and char == ?' ->
        do_literals(sql, index + 1, [?'], literals)

      current != [] and char == ?' and index + 1 < byte_size(sql) and
          :binary.at(sql, index + 1) == ?' ->
        do_literals(sql, index + 2, [?', ?' | current], literals)

      current != [] and char == ?' ->
        text = :erlang.list_to_binary(Enum.reverse([?' | current]))
        do_literals(sql, index + 1, [], [text | literals])

      current != [] ->
        do_literals(sql, index + 1, [char | current], literals)

      true ->
        do_literals(sql, index + 1, current, literals)
    end
  end
end
