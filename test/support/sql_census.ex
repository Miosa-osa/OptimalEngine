defmodule OptimalEngine.Test.SqlCensus do
  @moduledoc false
  # Measures how much of the SQL the engine actually runs works on the
  # PostgreSQL store, and keeps it from getting worse unseen.
  #
  # With OPTIMAL_SQL_CENSUS=<report path> (and OPTIMAL_TEST_POSTGRES_URL), the
  # test suite records every distinct statement the embedded SQLite store
  # executes, by tracing its calls; nothing in the store changes. After the
  # suite, each statement is translated by the dialect and prepared on a
  # PostgreSQL schema derived from the same migrations. Preparing parses the
  # statement and resolves every table, column, function and parameter type
  # without running it.
  #
  # Every statement is then one of: supported (it prepares), refused (the
  # dialect refuses it by name), or rejected (PostgreSQL does not accept the
  # translation). A supported statement with a top-level LIMIT and no
  # top-level ORDER BY is also unordered: SQLite returns its rows in rowid
  # order and PostgreSQL in no promised order. An existence probe (SELECT 1
  # ... LIMIT 1) is not: every matching row gives the same answer.
  #
  # Every refused, rejected and unordered statement shape must be listed in
  # test/support/sql_census_allowlist.txt. A shape the suite runs that the
  # list does not have fails the suite, so a new SQLite-only statement shows
  # up in review rather than on a PostgreSQL store. CI runs the census.
  #
  #     OPTIMAL_SQL_CENSUS=/tmp/sql-census.txt mix test
  #
  # OPTIMAL_SQL_CENSUS_WRITE=1 adds the run's shapes to the allowlist instead
  # of checking it, and keeps the lines already there: a run does not reach
  # every statement, so a shape it did not meet is not gone. It reports how
  # many it did not meet; remove a line by hand once its statement is gone.
  # Review the diff before committing it.

  alias OptimalEngine.Store.Dialect
  alias OptimalEngine.Store.Postgres.{Connection, Errors, Schema}
  alias OptimalEngine.Test.PostgresStore

  @table :optimal_sql_census
  @allowlist "test/support/sql_census_allowlist.txt"

  # The PostgreSQL store refuses a schema change outside the migrations
  # (OptimalEngine.Store.Postgres.Connection), whatever the table; such
  # statements are listed by their kind, not one line per table.
  @schema_change ~r/\A\s*(CREATE|ALTER|DROP|REINDEX|VACUUM|ANALYZE|ATTACH|DETACH)\b/i

  # The SQLite features a statement can depend on, most specific first.
  @causes [
    {"app data collection tables (created at runtime with an FTS5 table and triggers)",
     ~r/appdata_|data_collections/i},
    {"full-text search (FTS5 tables and MATCH)", ~r/_fts\b|\bMATCH\b/i},
    {"SQLite catalog (sqlite_master, PRAGMA)", ~r/sqlite_master|\bPRAGMA\b|pragma_/i},
    {"SQLite triggers", ~r/\b(CREATE|DROP)\s+TRIGGER\b/i},
    {"transaction control sent as a statement",
     ~r/^\s*(BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE)\b/i},
    {"rowid", ~r/\browid\b/i},
    {"SQLite JSON functions",
     ~r/\bjson_(set|each|object|group_array|array_length|insert|remove|patch|type|tree)\s*\(|\bjson\s*\(/i},
    {"date and time arithmetic", ~r/\b(datetime|strftime|julianday|date|time|unixepoch)\s*\(/i}
  ]

  def enabled?, do: System.get_env("OPTIMAL_SQL_CENSUS") not in [nil, ""]

  @doc "Starts tracing the embedded store's statements."
  def start do
    :ets.new(@table, [:named_table, :public, :set])
    tracer = spawn(&trace_loop/0)

    # Every process, not the Store's pid: a test that crashes the Store (one
    # does, on purpose) has it restarted as a new process, and its statements
    # would go unrecorded after that, so a run's census would depend on the
    # order the tests ran in. The patterns below limit tracing to the three
    # Store functions.
    :erlang.trace(:all, true, [:call, {:tracer, tracer}])
    :persistent_term.put({__MODULE__, :tracer}, tracer)

    for {function, arity} <- [handle_call: 3, txn_query: 4, txn_execute: 4] do
      :erlang.trace_pattern({OptimalEngine.Store.SQLite, function, arity}, true, [:local])
    end

    ExUnit.after_suite(fn _results -> finish(System.get_env("OPTIMAL_SQL_CENSUS")) end)
    :ok
  end

  defp trace_loop do
    receive do
      {:trace, _pid, :call, {_module, :handle_call, [{kind, sql, _params}, _from, _state]}}
      when kind in [:raw_query, :raw_execute] and is_binary(sql) ->
        record(sql)

      {:trace, _pid, :call, {_module, function, [_txn, sql | _]}}
      when function in [:txn_query, :txn_execute] and is_binary(sql) ->
        record(sql)

      {:sync, from} ->
        send(from, :synced)

      _other ->
        :ok
    end

    trace_loop()
  end

  # Every traced call is recorded before the census is classified, or the run
  # fails: a statement left out would show up as a new shape in another run.
  defp drain_tracer do
    tracer = :persistent_term.get({__MODULE__, :tracer}, nil)

    :erlang.trace(:all, false, [:call])

    ref = :erlang.trace_delivered(:all)

    with true <- is_pid(tracer) and Process.alive?(tracer),
         :ok <- await({:trace_delivered, :all, ref}),
         _ = send(tracer, {:sync, self()}),
         :ok <- await(:synced) do
      :ok
    else
      _ -> {:error, "the tracer stopped before every traced statement was recorded"}
    end
  end

  defp await(message) do
    receive do
      ^message -> :ok
    after
      30_000 -> :timeout
    end
  end

  defp record(sql), do: :ets.insert_new(@table, {shape(sql), sql})

  # Statements that differ only in generated names, literals, numbers or the
  # length of a placeholder list are one shape. Each shape is classified.
  @doc false
  def shape(sql) do
    sql
    |> String.replace(~r/'(?:[^']|'')*'/, "'…'")
    |> String.replace(~r/appdata_[0-9a-f]+/, "appdata_N")
    |> String.replace(~r/\b([A-Za-z][A-Za-z0-9_]*?)_\d+\b/, "\\1_N")
    |> String.replace(~r/\?\d*/, "?")
    |> String.replace(~r/\?(\s*,\s*\?)+/, "?")
    |> String.replace(~r/(?<![\w.])\d+(?![\w.])/, "N")
    |> String.replace(~r/'…'(\s*,\s*'…')+/, "'…'")
    |> String.replace(~r/\bN(\s*,\s*N)+\b/, "N")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  # An allowlist line names the shape with its quoted identifiers left out: a
  # quoted identifier is a name the code put there, such as the table of a
  # statement it runs on every table of the schema, and one line covers every
  # table such a statement meets.
  @doc false
  def allowlist_shape(sql), do: sql |> shape() |> String.replace(~r/"[^"]*"/, ~s("…"))

  defp finish(path) do
    case drain_tracer() do
      :ok ->
        report(path)

      {:error, reason} ->
        IO.puts(:stderr, "SQL census: #{reason}; the census of this run is incomplete.")
        System.at_exit(fn _status -> exit({:shutdown, 1}) end)
    end
  end

  defp report(path) do
    results = classify_all()
    File.write!(path, render(results))
    entries = entries(results)

    if System.get_env("OPTIMAL_SQL_CENSUS_WRITE") in ["1", "true"] do
      write(entries)
    else
      check(entries, examples(results))
    end
  end

  defp write(entries) do
    listed = allowlist()
    met = MapSet.new(entries)
    lines = listed |> MapSet.union(met) |> Enum.sort()
    File.write!(@allowlist, Enum.map_join(lines, "", &(Enum.join(&1, "\t") <> "\n")))

    IO.puts(
      "SQL census: wrote #{length(lines)} entries to #{@allowlist} " <>
        "(#{MapSet.size(MapSet.difference(met, listed))} new, " <>
        "#{MapSet.size(MapSet.difference(listed, met))} not met in this run)"
    )
  end

  # Statement shapes the allowlist does not have fail the suite the way a
  # failed test does.
  defp check(entries, examples) do
    allowed = allowlist()
    new = Enum.reject(entries, &MapSet.member?(allowed, &1))

    if new == [] do
      IO.puts("SQL census: every refused, rejected and unordered statement is on the allowlist")
    else
      IO.puts(:stderr, explain(Enum.map(new, &{&1, Map.get(examples, &1)})))
      System.at_exit(fn _status -> exit({:shutdown, 1}) end)
    end
  end

  @doc false
  # What a contributor reads when the suite runs a statement shape the
  # allowlist does not have: each line to add, why PostgreSQL cannot run the
  # statement, and what to do about it.
  @spec explain([{[String.t()], {String.t() | nil, String.t()} | nil}]) :: String.t()
  def explain(new) do
    lines =
      for {[kind, shape], example} <- new do
        {reason, sql} = example || {nil, nil}

        [
          kind <> "\t" <> shape <> "\n",
          if(reason, do: "      #{kind}: #{one_line(reason)}\n", else: ""),
          if(sql, do: "      e.g. #{one_line(sql)}\n", else: "")
        ]
      end

    IO.iodata_to_binary([
      """

      SQL census: #{length(new)} statement shapes the suite ran are not in #{@allowlist}.
      Each works on SQLite but is refused, rejected or unordered on the PostgreSQL store
      (docs/guides/postgres-provider.md, What Does Not Work On PostgreSQL).

      For each one below, fix the statement or list it:

        refused    The dialect refuses a SQLite-only construct, named after "refused:".
                   Write the statement without it (ON CONFLICT DO UPDATE instead of
                   INSERT OR REPLACE, a key column instead of rowid), or list it when
                   its feature is one Storage.Postgres.unavailable/0 names.
        rejected   PostgreSQL rejects the dialect's translation, with the error shown.
                   Write it so both databases accept it, or make the dialect refuse the
                   construct by name (@unsupported in lib/optimal_engine/store/dialect.ex,
                   under a feature of Storage.Postgres.unavailable/0), then list it.
        unordered  A LIMIT without an ORDER BY can return other rows on PostgreSQL.
                   Order by a unique key, or list it when any matching row will do.

      To list a statement, copy its line (the kind, a tab, the shape) into
      #{@allowlist}, or run the suite again with the census in write mode,
      which adds every new line and keeps the others:

          OPTIMAL_TEST_POSTGRES_URL=postgres://... OPTIMAL_SQL_CENSUS=/tmp/sql-census.txt OPTIMAL_SQL_CENSUS_WRITE=1 mix test

      The diff is reviewed like code.

      """,
      lines
    ])
  end

  # One refusal reason or PostgreSQL error, and one statement, for each line.
  defp examples(results) do
    for {kind, reason, sql} <- results, label <- labels(kind, sql), into: %{} do
      {[label, entry_shape(kind, reason, sql)], {reason, sql}}
    end
  end

  defp allowlist do
    case File.read(@allowlist) do
      {:ok, text} ->
        text
        |> String.split("\n", trim: true)
        |> Enum.map(&String.split(&1, "\t", parts: 2))
        |> MapSet.new()

      {:error, :enoent} ->
        MapSet.new()
    end
  end

  defp entries(results) do
    entries =
      for {kind, reason, sql} <- results, label <- labels(kind, sql), uniq: true do
        [label, entry_shape(kind, reason, sql)]
      end

    Enum.sort(entries)
  end

  defp labels(:prepared, sql), do: if(unordered?(sql), do: ["unordered"], else: [])
  defp labels(kind, _sql), do: [Atom.to_string(kind)]

  defp entry_shape(:refused, "schema change outside the migrations", sql) do
    words = sql |> String.trim() |> String.split(~r/\s+/, parts: 4) |> Enum.take(3)

    kind =
      case Enum.map(words, &String.upcase/1) do
        ["CREATE", "VIRTUAL", "TABLE"] -> "CREATE VIRTUAL TABLE"
        ["CREATE", "UNIQUE", "INDEX"] -> "CREATE UNIQUE INDEX"
        [first, second | _] -> "#{first} #{second}"
        other -> Enum.join(other, " ")
      end

    "schema change: " <> kind
  end

  defp entry_shape(_kind, _reason, sql), do: allowlist_shape(sql)

  # A LIMIT outside every parenthesis with no ORDER BY outside them, unless
  # the statement only asks whether a row exists.
  @doc false
  def unordered?(sql) do
    top = sql |> String.replace(~r/'(?:[^']|'')*'/, "''") |> top_level()

    Regex.match?(~r/\bLIMIT\b/i, top) and not Regex.match?(~r/\bORDER\s+BY\b/i, top) and
      not existence_probe?(top)
  end

  # Every top-level select list is one integer, so every matching row gives
  # the same answer.
  defp existence_probe?(top) do
    lists = Regex.scan(~r/\bSELECT\s+(.+?)\s+FROM\b/is, top, capture: :all_but_first)
    lists != [] and Enum.all?(lists, fn [list] -> String.trim(list) =~ ~r/\A\d+\z/ end)
  end

  defp top_level(sql) do
    reduced = Regex.replace(~r/\([^()]*\)/, sql, "")
    if reduced == sql, do: sql, else: top_level(reduced)
  end

  defp classify_all do
    statements = @table |> :ets.tab2list() |> Enum.map(&elem(&1, 1)) |> Enum.sort()
    schema = PostgresStore.unique_schema("oe_census")
    {:ok, pool} = Connection.start_link(PostgresStore.options(schema, pool_size: 2))

    try do
      {:ok, _} = Schema.sync(pool, schema: schema)
      Enum.map(statements, &classify(pool, &1))
    after
      GenServer.stop(pool)
      PostgresStore.drop_schema(schema)
    end
  end

  defp classify(pool, sql) do
    if Regex.match?(@schema_change, sql),
      do: {:refused, "schema change outside the migrations", sql},
      else: translate_and_prepare(pool, sql)
  end

  defp translate_and_prepare(pool, sql) do
    case Dialect.to_postgres(sql) do
      {:ok, translated} ->
        case Postgrex.prepare(pool, "", translated) do
          {:ok, _query} -> {:prepared, nil, sql}
          {:error, error} -> {:rejected, Errors.message(error), sql}
        end

      {:error, {:unsupported, name}} ->
        {:refused, name, sql}

      {:error, reason} ->
        {:refused, inspect(reason), sql}
    end
  end

  defp render(results) do
    failed = Enum.reject(results, &match?({:prepared, _, _}, &1))
    unordered = Enum.filter(results, fn {kind, _, sql} -> kind == :prepared and unordered?(sql) end)

    by_cause =
      failed
      |> Enum.group_by(fn {_kind, _reason, sql} -> cause(sql) end)
      |> Enum.sort_by(fn {_cause, items} -> -length(items) end)

    [
      "statements: #{length(results)}\n",
      "prepared on PostgreSQL: #{length(results) - length(failed)}\n",
      "refused by the dialect: #{Enum.count(failed, &match?({:refused, _, _}, &1))}\n",
      "rejected by PostgreSQL: #{Enum.count(failed, &match?({:rejected, _, _}, &1))}\n",
      "prepared but unordered (LIMIT without ORDER BY): #{length(unordered)}\n\n",
      for {cause, items} <- by_cause do
        reasons =
          items
          |> Enum.frequencies_by(fn {kind, reason, _sql} -> "#{kind}: #{reason}" end)
          |> Enum.sort_by(fn {_reason, n} -> -n end)
          |> Enum.take(6)

        [
          "#{length(items)}  #{cause}\n",
          for({reason, n} <- reasons, do: "    #{n}  #{one_line(reason)}\n"),
          for({_kind, _reason, sql} <- Enum.take(items, 2), do: "      e.g. #{one_line(sql)}\n"),
          "\n"
        ]
      end,
      "unordered:\n",
      for({_kind, _reason, sql} <- unordered, do: "  #{one_line(sql)}\n")
    ]
  end

  defp cause(sql) do
    Enum.find_value(@causes, "other", fn {name, pattern} ->
      if Regex.match?(pattern, sql), do: name
    end)
  end

  defp one_line(text), do: text |> String.replace(~r/\s+/, " ") |> String.slice(0, 150)
end
