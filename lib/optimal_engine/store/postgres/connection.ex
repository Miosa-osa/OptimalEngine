defmodule OptimalEngine.Store.Postgres.Connection do
  @moduledoc """
  The connection pool of the PostgreSQL store, and the boundary where the
  engine's SQLite statements run on PostgreSQL.

  `query/4` takes a statement in the dialect the engine writes, translates it
  with `OptimalEngine.Store.Dialect`, binds the parameters with SQLite's type
  affinity (`OptimalEngine.Store.Postgres.Types`), and returns rows and errors
  in the shape SQLite returns them. A construct the dialect refuses comes back
  as `{:error, {:unsupported, name}}` and never reaches the database, and so
  does a schema change (the schema comes from the migrations). A transaction
  statement raises `ArgumentError` before it reaches the database, as on
  SQLite (`OptimalEngine.Store.TransactionControl`): transactions go through
  `transaction/3`, and inside one `SAVEPOINT`, `RELEASE` and `ROLLBACK TO` work
  as on SQLite. A statement already written for PostgreSQL passes
  `dialect: :postgres`.

  ## Sessions

  Every connection runs at `SERIALIZABLE` with the store's schema as its
  `search_path`, in a UTF8 database, and is checked on connect; a pool whose
  first connection does not have all three fails to start. SQLite's text
  functions count characters, and PostgreSQL's do so only in a UTF8 database
  (in `SQL_ASCII` they count bytes). Each session has a statement timeout (60
  seconds), a lock timeout (15 seconds) and an idle-in-transaction timeout (60
  seconds), so a stuck statement or an abandoned transaction cannot hold rows
  forever. `:statement_timeout`, `:lock_timeout` and
  `:idle_in_transaction_session_timeout` override them, in milliseconds.

  ## Isolation

  On SQLite one engine owns the only writer, so a read-check-write inside a
  transaction cannot interleave with any other write. Several engines on one
  PostgreSQL database keep that guarantee only at `SERIALIZABLE`: PostgreSQL
  aborts one side of any interleaving that no serial order could produce, and
  this module runs it again. Every transaction begins with
  `BEGIN ISOLATION LEVEL SERIALIZABLE`, whatever the server's default.

  - A single statement that fails with a serialization failure or a detected
    deadlock did not commit, and is retried.
  - A transaction that meets either one is rolled back and its fun runs again
    from the start, so a fun must not have effects outside the database.

  Retries back off exponentially with full jitter (a random pause up to a
  window that doubles from 4 ms to 1 second), at most 25 attempts, and stop at
  the call's timeout: each attempt gets only the time that is left, and a
  timeout must be finite. Each retry emits `[:optimal_engine, :store, :retry]`
  with the attempt number and, as metadata, the scope (`:statement` or
  `:transaction`) and the reason. A call that runs out of attempts or time
  returns `{:error, {:serialization_failure, detail}}`, where the detail says
  how many attempts ran over how long, and which statement met the last
  conflict and why.

  A transaction that by its nature conflicts with every concurrent writer
  should not lean on these retries: under load it loses every time. It takes
  the locks it needs before it reads instead (`Store.txn_read_committed/1` with
  row locks, `Store.skip_locked/0` for a queue, `Store.txn_lock_tables/2` for a
  long rewrite of many tables).

  ## Statements inside a transaction

  PostgreSQL aborts a transaction at its first failed statement; every later
  statement fails and the commit rolls back. A statement whose failure the fun
  handles and goes on from, as SQLite allows, passes `recoverable: true` and
  runs in its own savepoint: its failure is undone and the transaction goes on.

  ## Identity columns

  SQLite moves a table's rowid past any id written explicitly. After an
  `INSERT` that names a table's identity column, the column's sequence is moved
  past the largest id, under a lock per sequence, so the next generated id does
  not collide with it. The identity columns come from the derived schema
  (`OptimalEngine.Store.Postgres.Schema.identity_columns/0`), read when the
  pool starts.
  """

  require Logger

  alias OptimalEngine.Storage.Postgres, as: Provider
  alias OptimalEngine.Store.{Dialect, TransactionControl}
  alias OptimalEngine.Store.Postgres.{Affinity, Errors, Schema}

  @default_timeout 15_000
  @max_attempts 25
  @unique_violation {__MODULE__, :unique_violation}
  @last_conflict {__MODULE__, :last_conflict}
  @max_pause 1_000
  @rollback_to ~r/\A\s*ROLLBACK\s+(TRANSACTION\s+)?TO\b/i
  @dollar ~r/\$(\d+)(?!\d)/
  # A retry starts only with at least this much of the call's time left, and a
  # checked-out connection is held this much longer than the call's time, so a
  # rollback can always finish without the pool closing the connection.
  @min_attempt 100
  @rollback_grace 5_000
  @schema_name ~r/\A[a-z_][a-z0-9_]{0,62}\z/
  @session_timeouts [
    statement_timeout: 60_000,
    lock_timeout: 15_000,
    idle_in_transaction_session_timeout: 60_000
  ]

  @schema_change ~r/\A(CREATE|ALTER|DROP|REINDEX|VACUUM|ANALYZE|ATTACH|DETACH)\b/i
  @insert ~r/\A\s*INSERT\s+INTO\s+("(?:[^"]|"")+"|[A-Za-z_][A-Za-z0-9_]*)\s*(\(([^)]*)\))?/i

  @typedoc "Columns, rows as SQLite returns them, and the affected or returned row count."
  @type result :: %{columns: [String.t()], rows: [[term()]], num_rows: non_neg_integer()}

  @typedoc "The handle a transaction fun receives."
  @opaque txn :: {module(), DBConnection.t(), :atomics.atomics_ref(), integer()}

  @doc false
  def child_spec(opts) do
    %{id: Keyword.get(opts, :id, __MODULE__), start: {__MODULE__, :start_link, [opts]}}
  end

  @doc """
  Starts a pool and checks its first session.

  Options: `:url` (default `OPTIMAL_POSTGRES_URL`), `:name`, `:pool_size`
  (default 10), `:schema`, the PostgreSQL schema the store lives in (default
  `public`), and the session timeouts above.
  """
  @spec start_link(keyword()) :: GenServer.on_start() | {:error, term()}
  def start_link(opts \\ []) do
    with {:ok, config} <- Provider.config(Keyword.take(opts, [:url])),
         {:ok, schema} <- schema(opts),
         :ok <- warn_without_tls(config),
         {:ok, pool} <- Postgrex.start_link(options(config, schema, opts)) do
      case check_session(pool, schema) do
        :ok ->
          _ = Schema.identity_columns()
          {:ok, pool}

        {:error, reason} ->
          Process.unlink(pool)
          GenServer.stop(pool)
          {:error, reason}
      end
    end
  end

  @doc "The PostgreSQL schema named by `opts`, validated as a plain identifier."
  @spec schema(keyword()) :: {:ok, String.t()} | {:error, {:invalid_schema, term()}}
  def schema(opts) do
    schema = Keyword.get(opts, :schema, "public")

    if is_binary(schema) and Regex.match?(@schema_name, schema) do
      {:ok, schema}
    else
      {:error, {:invalid_schema, schema}}
    end
  end

  defp options(config, schema, opts) do
    timeouts =
      Enum.map(@session_timeouts, fn {name, default} ->
        {name, Integer.to_string(Keyword.get(opts, name, default))}
      end)

    [
      hostname: config.hostname,
      port: config.port,
      database: config.database,
      username: config.username,
      password: config.password,
      ssl: config.ssl,
      name: Keyword.get(opts, :name),
      pool_size: Keyword.get(opts, :pool_size, 10),
      types: OptimalEngine.Store.Postgres.Types,
      parameters:
        [
          application_name: config.application_name,
          search_path: schema,
          default_transaction_isolation: "serializable"
        ] ++ timeouts,
      after_connect: {__MODULE__, :verify_session!, [schema]},
      show_sensitive_data_on_connection_error: false
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  @doc false
  # Runs on every new connection: a connection that does not run serializable
  # in the store's schema (a pooler that drops startup parameters, say) is
  # closed rather than used.
  def verify_session!(conn, schema) do
    case session(conn, schema) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("[Store.Postgres] #{reason}")
        raise reason
    end
  end

  defp check_session(pool, schema) do
    case session(pool, schema) do
      :ok -> :ok
      {:error, reason} -> {:error, {:session_check_failed, reason}}
    end
  end

  defp session(conn, schema) do
    sql =
      "SELECT current_setting('transaction_isolation'), current_setting('search_path'), " <>
        "current_setting('server_encoding')"

    case Postgrex.query(conn, sql, []) do
      {:ok, %Postgrex.Result{rows: [row]}} -> session_problem(row, schema)
      {:error, error} -> {:error, Errors.message(error)}
    end
  end

  @doc false
  # What is wrong with a session's isolation, search_path and database
  # encoding, if anything.
  @spec session_problem([String.t()], String.t()) :: :ok | {:error, String.t()}
  def session_problem([isolation, search_path, encoding], schema) do
    cond do
      isolation != "serializable" or search_path != schema ->
        {:error,
         "store session runs #{isolation} with search_path #{search_path}; " <>
           "expected serializable with #{schema}"}

      encoding != "UTF8" ->
        {:error,
         "store database is #{encoding}; the store needs a UTF8 database, " <>
           "where text functions count characters as SQLite's do"}

      true ->
        :ok
    end
  end

  # sslmode=prefer falls back to plain text in libpq; Postgrex has no
  # fallback, so this store connects without TLS. Loopback hosts are exempt.
  defp warn_without_tls(%{ssl: true}), do: :ok

  defp warn_without_tls(config) do
    mode = Map.get(config, :sslmode)
    loopback? = config.hostname in ["localhost", "127.0.0.1", "::1"]

    if mode in [nil, "prefer", "allow"] and not loopback? and
         not :persistent_term.get({__MODULE__, :warned_tls}, false) do
      :persistent_term.put({__MODULE__, :warned_tls}, true)

      Logger.warning(
        "[Store.Postgres] connecting to #{config.hostname} without TLS " <>
          "(sslmode=#{mode || "unset"}); set sslmode=require or verify-full"
      )
    end

    :ok
  end

  @doc """
  Runs one statement on the pool and retries it when PostgreSQL reports a
  serialization failure or a deadlock.
  """
  @spec query(GenServer.server(), String.t(), [term()], keyword()) ::
          {:ok, result()} | {:error, term()}
  def query(pool, sql, params \\ [], opts \\ []) do
    timeout = timeout!(Keyword.get(opts, :timeout, @default_timeout))

    with {:ok, statement, bound, identity, json} <- prepare(sql, params, opts, :outside) do
      if identity do
        transaction(pool, &txn_query(&1, sql, params, opts), timeout)
      else
        deadline = deadline(timeout)
        Process.put({@last_conflict, :started, deadline}, System.monotonic_time(:millisecond))

        try do
          fn remaining ->
            execute(pool, statement, bound, Keyword.put(opts, :timeout, remaining))
          end
          |> retrying(1, deadline, statement)
          |> json_columns(json)
        after
          Process.delete({@last_conflict, :started, deadline})
        end
      end
    end
  end

  @doc """
  Runs `fun` in one transaction and returns what the store's `transaction/2`
  returns: `{:ok, result}` on commit, the fun's `{:error, reason}` after a
  rollback, `{:error, {:invalid_transaction_return, other}}` for any other
  return, and the fun's own exception re-raised in the caller.
  """
  @spec transaction(GenServer.server(), (txn() -> {:ok, term()} | {:error, term()}), timeout()) ::
          {:ok, term()} | {:error, term()}
  def transaction(pool, fun, timeout) when is_function(fun, 1) do
    deadline = deadline(timeout!(timeout))
    Process.put({@last_conflict, :started, deadline}, System.monotonic_time(:millisecond))

    try do
      attempt_transaction(pool, fun, 1, deadline)
    after
      Process.delete({@last_conflict, :started, deadline})
      Process.delete({@last_conflict, deadline})
    end
  end

  # A statement of the transaction met a conflict: the transaction is rolled
  # back and run again, and the statement is kept for the error a transaction
  # that runs out of attempts returns.
  defp doomed_by(doomed, deadline, statement, error) do
    Process.put({@last_conflict, deadline}, {statement, error})
    :atomics.put(doomed, 1, 1)
  end

  @doc """
  Runs a statement inside a transaction.

  Options: `recoverable: true` runs it in a savepoint, so its failure leaves
  the transaction usable; `:timeout`, at most the transaction's remaining time.
  """
  @spec txn_query(txn(), String.t(), [term()], keyword()) :: {:ok, result()} | {:error, term()}
  def txn_query({__MODULE__, conn, doomed, deadline} = txn, sql, params \\ [], opts \\ []) do
    remaining = min(Keyword.get(opts, :timeout, remaining(deadline)), remaining(deadline))
    mode = if Keyword.get(opts, :recoverable, false), do: [mode: :savepoint], else: []

    with {:ok, statement, bound, identity, json} <- prepare(sql, params, opts, :inside) do
      case execute(conn, statement, bound, [timeout: max(remaining, @min_attempt)] ++ mode)
           |> json_columns(json) do
        {:ok, result} ->
          # The caller's own savepoint undid the violation: the transaction goes on.
          if Regex.match?(@rollback_to, statement) and
               :atomics.compare_exchange(doomed, 1, 2, 0) == :ok,
             do: Process.delete(@unique_violation)

          with :ok <- advance_identity(txn, identity, max(remaining(deadline), @min_attempt)) do
            {:ok, result}
          end

        {:error, error} ->
          cond do
            Errors.retryable?(error) -> doomed_by(doomed, deadline, statement, error)
            mode == [] and unique_violation?(error) -> unique_met(doomed, error)
            true -> :ok
          end

          {:error, Errors.failure(error)}
      end
    end
  end

  # SQLite has one writer, so a fun that reads MAX(seq) or checks for an
  # absent key and then inserts never meets a concurrent insert of the same
  # key. At SERIALIZABLE PostgreSQL reports that interleaving as a unique
  # violation, not always a serialization failure, when the read was not an
  # equality probe of the key. A transaction that met one is run again: a key
  # a concurrent writer took is visible to the next attempt, which picks
  # another (the next sequence number) or none. A run that meets the same
  # violation, the same key, as the one before it repeats the key itself, and
  # its answer is the fun's.
  defp unique_met(doomed, error) do
    if :atomics.compare_exchange(doomed, 1, 0, 2) == :ok do
      Process.put(@unique_violation, {error.postgres[:constraint], error.postgres[:detail]})
    end
  end

  defp unique_violation?(%Postgrex.Error{postgres: %{code: :unique_violation}}), do: true
  defp unique_violation?(_error), do: false

  # ---------------------------------------------------------------------------
  # Statements
  # ---------------------------------------------------------------------------

  # `where` is `:outside` a transaction or `:inside` one.
  defp prepare(sql, params, opts, where) do
    TransactionControl.refuse!(sql, where)

    case Keyword.get(opts, :dialect, :sqlite) do
      :postgres ->
        # A native statement may bind arrays; a map or a tuple is no value
        # either store stores.
        if Enum.any?(params, &unbindable_native?/1),
          do: {:error, :invalid_parameter},
          else: {:ok, sql, params, nil, {[], []}}

      :sqlite ->
        with :ok <- refuse_schema_change(sql),
             {:ok, statement, requirements} <- Dialect.translate(sql),
             :ok <- bindable(params, statement, requirements.params),
             bound = bound(params, requirements.params),
             :ok <- check_text_params(requirements.text_params, bound),
             :ok <- check_number_params(requirements.number_params, bound) do
          {:ok, statement, bound, identity_insert(statement),
           {requirements.json_columns, selected_values(requirements.param_columns, bound)}}
        end
    end
  end

  # Result columns SQLite returns differently than PostgreSQL types them: a
  # selected json_extract (SQLite's value, from the JSON text) and a selected
  # placeholder (the value bound).
  defp json_columns({:ok, result}, {json, values}) when json != [] or values != [] do
    rows =
      result.rows
      |> Affinity.json_columns(json)
      |> Enum.map(fn row ->
        Enum.reduce(values, row, fn {position, value}, row ->
          List.replace_at(row, position, value)
        end)
      end)

    {:ok, %{result | rows: rows}}
  end

  defp json_columns(outcome, _columns), do: outcome

  defp selected_values(columns, bound) do
    for {position, n} <- columns,
        value <- [Enum.at(bound, n - 1)],
        is_integer(value) or is_float(value) or is_binary(value) or is_nil(value),
        do: {position, value}
  end

  # The schema comes from the migrations; a schema change written as a
  # statement is refused, whatever comments come first.
  defp refuse_schema_change(sql) do
    if Regex.match?(@schema_change, TransactionControl.statement(sql)),
      do: {:error, {:unsupported, "schema change outside the migrations"}},
      else: :ok
  end

  # What SQLite cannot bind is refused as SQLite refuses it
  # (`OptimalEngine.Store.SQLite.bind/3`): an integer past 64 bits, a map, a
  # list or a tuple other than {:blob, data}, and fewer parameters than the
  # statement names.
  @int64 -9_223_372_036_854_775_808..9_223_372_036_854_775_807

  defp bindable(params, statement, used) do
    named =
      case used do
        :all ->
          @dollar
          |> Regex.scan(statement, capture: :all_but_first)
          |> Enum.map(fn [n] -> String.to_integer(n) end)

        used ->
          used
      end

    cond do
      Enum.max(named, fn -> 0 end) > length(params) -> {:error, :invalid_parameter}
      Enum.all?(params, &bindable_value?/1) -> :ok
      true -> {:error, :invalid_parameter}
    end
  end

  defp bindable_value?(value) when is_integer(value), do: value in @int64
  defp bindable_value?({:blob, data}), do: is_binary(data)
  defp bindable_value?(value) when is_struct(value), do: true
  defp bindable_value?(value) when is_map(value) or is_list(value) or is_tuple(value), do: false
  defp bindable_value?(_value), do: true

  defp unbindable_native?({:blob, data}), do: not is_binary(data)
  defp unbindable_native?(value) when is_struct(value), do: false
  defp unbindable_native?(value), do: is_map(value) or is_tuple(value)

  # The parameters the translated statement names, in its numbering.
  defp bound(params, :all), do: params
  defp bound(params, used), do: Enum.map(used, &Enum.at(params, &1 - 1))

  # A placeholder a json_extract is compared to is compared as JSON text; a
  # number or boolean bound to it would compare differently on SQLite.
  defp check_text_params(indexes, params) do
    if Enum.all?(indexes, &(Enum.at(params, &1 - 1) |> text_or_nil?())),
      do: :ok,
      else: {:error, {:unsupported, "json_extract compared to a non-text value"}}
  end

  # A placeholder a json_extract is ordered against is a number; text would
  # be ordered as text on SQLite.
  defp check_number_params(indexes, params) do
    if Enum.all?(indexes, &(Enum.at(params, &1 - 1) |> number_or_nil?())),
      do: :ok,
      else: {:error, {:unsupported, "json_extract ordered against a non-number value"}}
  end

  defp number_or_nil?(value), do: is_number(value) or is_nil(value)

  defp text_or_nil?(value), do: is_binary(value) or is_nil(value)

  # A parameter the affinity rules reject raises before anything reaches the
  # server, so it is returned like a server error.
  defp execute(conn, statement, params, opts) do
    options = Keyword.take(opts, [:mode, :timeout])

    case Postgrex.query(conn, statement, params, options) do
      {:ok, %Postgrex.Result{} = result} ->
        {:ok,
         %{
           columns: result.columns || [],
           rows: Affinity.normalize_rows(result.rows),
           num_rows: result.num_rows || 0
         }}

      {:error, error} ->
        {:error, error}
    end
  rescue
    error in [DBConnection.EncodeError, ArgumentError] -> {:error, error}
  end

  defp retrying(run, attempt, deadline, statement) do
    case run.(max(remaining(deadline), @min_attempt)) do
      {:ok, result} ->
        {:ok, result}

      {:error, error} ->
        cond do
          not Errors.retryable?(error) ->
            {:error, Errors.failure(error)}

          attempt < @max_attempts and retry_after_backoff?(attempt, deadline) ->
            retried(:statement, error.postgres.code, attempt)
            retrying(run, attempt + 1, deadline, statement)

          true ->
            {:error,
             {:serialization_failure,
              gave_up(error.postgres.code, attempt, deadline, {:conflict, {statement, error}})}}
        end
    end
  end

  # What a call that ran out of attempts or time was doing, for the error it
  # returns: how many attempts over how long, and the statement that met the
  # last conflict with the server's reason.
  defp gave_up(reason, attempt, deadline, conflict) do
    started = Process.get({@last_conflict, :started, deadline})
    elapsed = if started, do: " in #{System.monotonic_time(:millisecond) - started} ms", else: ""

    "#{reason}; gave up after #{attempt} attempts#{elapsed}" <> conflict_detail(conflict)
  end

  defp conflict_detail({:conflict, nil}), do: ""

  defp conflict_detail({:conflict, {statement, error}}),
    do: "; last conflict at: #{excerpt(statement)}#{server_detail(error)}"

  defp server_detail(%Postgrex.Error{postgres: %{} = fields}) do
    case fields[:detail] || fields[:hint] do
      nil -> ""
      text -> " (#{text})"
    end
  end

  defp server_detail(_error), do: ""

  defp excerpt(nil), do: "(statement)"
  defp excerpt(%{statement: statement}), do: excerpt(statement)

  defp excerpt(statement) do
    flat = statement |> String.replace(~r/\s+/, " ") |> String.trim()
    if String.length(flat) > 160, do: String.slice(flat, 0, 160) <> "...", else: flat
  end

  defp timeout!(timeout) when is_integer(timeout) and timeout > 0, do: timeout

  defp timeout!(timeout) do
    raise ArgumentError,
          "the PostgreSQL store needs a finite timeout in milliseconds, got: #{inspect(timeout)}"
  end

  defp deadline(timeout), do: System.monotonic_time(:millisecond) + timeout

  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  # Full jitter over an exponential window (4 ms after the first attempt,
  # doubling to at most a second), so writers that met the same conflict do not
  # meet again at once; true when enough of the call's time is left after the
  # pause for another attempt.
  defp retry_after_backoff?(attempt, deadline) do
    pause = :rand.uniform(min(@max_pause, 2 ** min(attempt + 1, 10)))

    if remaining(deadline) - pause >= @min_attempt do
      Process.sleep(pause)
      true
    else
      false
    end
  end

  # ---------------------------------------------------------------------------
  # Identity columns
  # ---------------------------------------------------------------------------

  # The table and identity column of an INSERT that writes the column
  # explicitly; nil for any other statement. An INSERT without a column list
  # writes every column.
  defp identity_insert(statement) do
    with [_ | captures] <- Regex.run(@insert, statement),
         table = captures |> hd() |> unquote_name(),
         {:ok, column} <- Map.fetch(Schema.identity_columns(), table) do
      case captures do
        [_table] ->
          {table, column}

        [_table, _list, columns] ->
          named = columns |> String.split(",") |> Enum.map(&(&1 |> String.trim() |> unquote_name()))
          if column in named, do: {table, column}
      end
    else
      _ -> nil
    end
  end

  defp unquote_name(~s(") <> _ = name),
    do: name |> String.slice(1..-2//1) |> String.replace(~s(""), ~s("))

  defp unquote_name(name), do: name

  defp advance_identity(_txn, nil, _timeout), do: :ok

  # The lock comes first, in a statement of its own, so the sequence is read
  # and moved by one transaction at a time.
  defp advance_identity({__MODULE__, conn, doomed, deadline}, {table, column}, timeout) do
    table_name = ~s("#{String.replace(table, ~s("), ~s(""))}")
    column_name = ~s("#{String.replace(column, ~s("), ~s(""))}")

    lock = "SELECT pg_advisory_xact_lock(hashtext(pg_get_serial_sequence($1, $2)))"

    advance = """
    SELECT setval(seq, top)
    FROM (
      SELECT pg_get_serial_sequence($1, $2)::regclass AS seq,
             (SELECT MAX(#{column_name}) FROM #{table_name}) AS top
    ) s
    WHERE seq IS NOT NULL AND top IS NOT NULL
      AND top > COALESCE(pg_sequence_last_value(seq), 0)
    """

    with {:ok, _} <- Postgrex.query(conn, lock, [table_name, column], timeout: timeout),
         {:ok, _} <- Postgrex.query(conn, advance, [table_name, column], timeout: timeout) do
      :ok
    else
      {:error, error} ->
        if Errors.retryable?(error), do: doomed_by(doomed, deadline, advance, error)
        {:error, Errors.message(error)}
    end
  end

  @doc """
  Runs `fun` in a read-only `REPEATABLE READ` transaction, which sees the
  database as it was at its first statement whatever commits meanwhile, and
  rolls it back. `fun` gets a handle for `txn_query/4` and its value is
  returned. A read-only transaction at this level is never aborted to keep it
  serializable, so `fun` runs once, and may have effects of its own.
  """
  @spec snapshot(GenServer.server(), (txn() -> result), timeout()) :: result | {:error, term()}
        when result: term()
  def snapshot(pool, fun, timeout) when is_function(fun, 1) do
    deadline = deadline(timeout!(timeout))

    DBConnection.run(
      pool,
      fn conn ->
        case Postgrex.query(conn, "BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY", []) do
          {:ok, _} ->
            try do
              fun.({__MODULE__, conn, :atomics.new(1, []), deadline})
            after
              _ = Postgrex.query(conn, "ROLLBACK", [], timeout: 5_000)
            end

          {:error, error} ->
            {:error, {:begin_failed, Errors.message(error)}}
        end
      end,
      timeout: timeout + @rollback_grace
    )
  end

  # ---------------------------------------------------------------------------
  # Transactions
  # ---------------------------------------------------------------------------

  defp attempt_transaction(pool, fun, attempt, deadline, last_unique \\ nil) do
    Process.delete(@unique_violation)
    doomed = :atomics.new(1, [])
    timeout = remaining(deadline) + @rollback_grace

    outcome =
      try do
        DBConnection.run(pool, &run_transaction(&1, doomed, fun, deadline), timeout: timeout)
      rescue
        error in DBConnection.ConnectionError -> {:begin, error}
      end

    case outcome do
      {:ok, value} ->
        {:ok, value}

      {:fun, reason} ->
        {:error, reason}

      {:raised, kind, reason, stacktrace} ->
        :erlang.raise(kind, reason, stacktrace)

      :retry ->
        retry_transaction(pool, fun, {attempt, deadline}, :serialization_failure)

      {:unique_retry, fallback} ->
        case Process.delete(@unique_violation) do
          violation when violation != last_unique ->
            retry_transaction(pool, fun, {attempt, deadline}, :unique_violation, violation)

          _same ->
            unique_answer(fallback)
        end

      {:commit, error} ->
        if Errors.retryable?(error) do
          Process.put({@last_conflict, deadline}, {"COMMIT", error})
          retry_transaction(pool, fun, {attempt, deadline}, error.postgres.code)
        else
          {:error, {:commit_failed, commit_reason(error)}}
        end

      {:begin, error} ->
        {:error, {:begin_failed, Errors.message(error)}}
    end
  end

  defp unique_answer({:fun, reason}), do: {:error, reason}

  defp unique_answer({:raised, kind, reason, stacktrace}),
    do: :erlang.raise(kind, reason, stacktrace)

  defp unique_answer(_other), do: {:error, {:commit_failed, :rollback}}

  defp commit_reason({:rolled_back, _command}), do: :rollback
  defp commit_reason(error), do: Errors.message(error)

  defp retry_transaction(pool, fun, {attempt, deadline}, reason, last_unique \\ nil) do
    if attempt < @max_attempts and retry_after_backoff?(attempt, deadline) do
      retried(:transaction, reason, attempt)
      attempt_transaction(pool, fun, attempt + 1, deadline, last_unique)
    else
      conflict = Process.get({@last_conflict, deadline})

      {:error, {:serialization_failure, gave_up(reason, attempt, deadline, {:conflict, conflict})}}
    end
  end

  defp retried(scope, reason, attempt) do
    :telemetry.execute(
      [:optimal_engine, :store, :retry],
      %{count: 1, attempt: attempt},
      %{scope: scope, reason: reason}
    )
  end

  # BEGIN and COMMIT are ordinary statements on a checked-out connection rather
  # than DBConnection's transaction callbacks: Postgrex closes the connection
  # when a COMMIT issued through those callbacks fails, and at SERIALIZABLE a
  # COMMIT can fail with a serialization failure that only asks for a retry.
  # As a statement, a failed COMMIT ends the transaction and returns an error,
  # and the connection stays open. Every path out of this function leaves the
  # connection outside a transaction; a caller that dies holding it gets the
  # connection closed by the pool.
  #
  # The caller's fun runs in the caller's process. A fun whose statement met a
  # serialization failure is rolled back and run again even when it ignored or
  # raised on that error.
  defp run_transaction(conn, doomed, fun, deadline) do
    case Postgrex.query(conn, "BEGIN ISOLATION LEVEL SERIALIZABLE", [],
           timeout: max(remaining(deadline), @min_attempt)
         ) do
      {:ok, _} ->
        case bound_waits(conn, deadline) do
          :ok -> run_fun(conn, doomed, fun, deadline)
          {:error, error} -> rollback(conn, {:begin, error}, deadline)
        end

      {:error, error} ->
        {:begin, error}
    end
  end

  defp run_fun(conn, doomed, fun, deadline) do
    returned =
      try do
        {:returned, fun.({__MODULE__, conn, doomed, deadline})}
      catch
        kind, reason -> {:raised, kind, reason, __STACKTRACE__}
      end

    case :atomics.get(doomed, 1) do
      2 -> rollback(conn, {:unique_retry, unique_fallback(returned)}, deadline)
      doomed -> conclude(conn, doomed == 1, returned, deadline)
    end
  end

  # A statement inside a transaction waits as long as the connection is held,
  # not its own timeout, so a transaction shorter than the session's lock and
  # statement timeouts takes its own: a statement that waits for a lock past
  # the transaction's time is cancelled, and the store answers busy, as
  # SQLite's store answers a call it cannot serve in time. SET LOCAL takes no
  # snapshot, so the fun may still set the transaction's isolation first.
  defp bound_waits(conn, deadline) do
    ms = max(remaining(deadline), @min_attempt)

    if ms < @session_timeouts[:lock_timeout] do
      Enum.reduce_while(["lock_timeout", "statement_timeout"], :ok, fn setting, :ok ->
        case Postgrex.query(conn, "SET LOCAL #{setting} = #{ms}", [], timeout: ms + @rollback_grace) do
          {:ok, _} -> {:cont, :ok}
          {:error, _} = error -> {:halt, error}
        end
      end)
    else
      :ok
    end
  end

  defp unique_fallback({:returned, {:error, reason}}), do: {:fun, reason}
  defp unique_fallback({:raised, _kind, _reason, _stacktrace} = raised), do: raised
  defp unique_fallback(other), do: other

  defp conclude(conn, true = _doomed, _returned, deadline), do: rollback(conn, :retry, deadline)

  # PostgreSQL answers COMMIT on a transaction it already aborted with
  # ROLLBACK and no error, so the command tag is checked, not only the result.
  defp conclude(conn, false, {:returned, {:ok, value}}, deadline) do
    case Postgrex.query(conn, "COMMIT", [], timeout: max(remaining(deadline), 1_000)) do
      {:ok, %Postgrex.Result{command: :commit}} -> {:ok, value}
      {:ok, %Postgrex.Result{command: command}} -> {:commit, {:rolled_back, command}}
      {:error, error} -> {:commit, error}
    end
  end

  defp conclude(conn, false, {:returned, {:error, reason}}, deadline),
    do: rollback(conn, {:fun, reason}, deadline)

  defp conclude(conn, false, {:returned, other}, deadline),
    do: rollback(conn, {:fun, {:invalid_transaction_return, other}}, deadline)

  defp conclude(conn, false, {:raised, _kind, _reason, _stacktrace} = raised, deadline),
    do: rollback(conn, raised, deadline)

  # A rollback always gets time of its own: the connection must leave the
  # transaction even when the call's time is spent.
  defp rollback(conn, outcome, _deadline) do
    _ = Postgrex.query(conn, "ROLLBACK", [], timeout: 5_000)
    outcome
  end
end
