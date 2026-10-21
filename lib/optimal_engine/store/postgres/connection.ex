defmodule OptimalEngine.Store.Postgres.Connection do
  @moduledoc """
  The connection pool of the PostgreSQL store, and the boundary where the
  engine's SQLite statements run on PostgreSQL.

  `query/4` takes a statement in the dialect the engine writes, translates it
  with `OptimalEngine.Store.Dialect`, binds the parameters with SQLite's type
  affinity (`OptimalEngine.Store.Postgres.Types`), and returns rows and errors
  in the shape SQLite returns them. A construct the dialect refuses comes back
  as `{:error, {:unsupported, name}}` and never reaches the database, and so do
  a schema change (the schema comes from the migrations) and a transaction
  statement (transactions go through `transaction/3`; inside one, `SAVEPOINT`,
  `RELEASE` and `ROLLBACK TO` work as on SQLite). A statement already written
  for PostgreSQL passes `dialect: :postgres`.

  ## Sessions

  Every connection runs at `SERIALIZABLE` with the store's schema as its
  `search_path`, and is checked on connect; a pool whose first connection does
  not have both fails to start. Each session has a statement timeout (60
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

  Retries back off with jitter, at most 25 attempts, and stop at the call's
  timeout: each attempt gets only the time that is left, and a timeout must be
  finite. Each retry emits `[:optimal_engine, :store, :retry]` with the attempt
  number and, as metadata, the scope (`:statement` or `:transaction`) and the
  reason. A call that runs out of attempts or time returns
  `{:error, {:serialization_failure, detail}}`.

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
  alias OptimalEngine.Store.Dialect
  alias OptimalEngine.Store.Postgres.{Affinity, Errors, Schema}

  @default_timeout 15_000
  @max_attempts 25
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
  @transaction_control ~r/\A(BEGIN|COMMIT|END|ROLLBACK|SAVEPOINT|RELEASE)\b/i
  @savepoint ~r/\A(SAVEPOINT\b|RELEASE\b|ROLLBACK\s+TO\b)/i
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
    sql = "SELECT current_setting('transaction_isolation'), current_setting('search_path')"

    case Postgrex.query(conn, sql, []) do
      {:ok, %Postgrex.Result{rows: [["serializable", ^schema]]}} ->
        :ok

      {:ok, %Postgrex.Result{rows: [[isolation, search_path]]}} ->
        {:error,
         "store session runs #{isolation} with search_path #{search_path}; " <>
           "expected serializable with #{schema}"}

      {:error, error} ->
        {:error, Errors.message(error)}
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

    with {:ok, statement, bound, identity} <- prepare(sql, params, opts, :query) do
      if identity do
        transaction(pool, &txn_query(&1, sql, params, opts), timeout)
      else
        deadline = deadline(timeout)

        retrying(
          fn remaining ->
            execute(pool, statement, bound, Keyword.put(opts, :timeout, remaining))
          end,
          1,
          deadline
        )
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
    attempt_transaction(pool, fun, 1, deadline(timeout!(timeout)))
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

    with {:ok, statement, bound, identity} <- prepare(sql, params, opts, :transaction) do
      case execute(conn, statement, bound, [timeout: max(remaining, @min_attempt)] ++ mode) do
        {:ok, result} ->
          with :ok <- advance_identity(txn, identity, max(remaining(deadline), @min_attempt)) do
            {:ok, result}
          end

        {:error, error} ->
          if Errors.retryable?(error), do: :atomics.put(doomed, 1, 1)
          {:error, Errors.message(error)}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Statements
  # ---------------------------------------------------------------------------

  defp prepare(sql, params, opts, scope) do
    case Keyword.get(opts, :dialect, :sqlite) do
      :postgres ->
        {:ok, sql, params, nil}

      :sqlite ->
        with :ok <- refuse_control(sql, scope),
             {:ok, statement, requirements} <- Dialect.translate(sql),
             bound = bound(params, requirements.params),
             :ok <- check_text_params(requirements.text_params, bound) do
          {:ok, statement, bound, identity_insert(statement)}
        end
    end
  end

  # The schema comes from the migrations, and transactions from
  # `transaction/3`; either one written as a statement is refused. Inside a
  # transaction a savepoint of the caller's own works as on SQLite.
  defp refuse_control(sql, scope) do
    statement = sql |> String.replace(~r/\A(\s|--[^\n]*\n)*/, "")

    cond do
      Regex.match?(@schema_change, statement) ->
        {:error, {:unsupported, "schema change outside the migrations"}}

      scope == :transaction and Regex.match?(@savepoint, statement) ->
        :ok

      Regex.match?(@transaction_control, statement) ->
        {:error, {:unsupported, "transaction statement outside the store's transaction"}}

      true ->
        :ok
    end
  end

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

  defp retrying(run, attempt, deadline) do
    case run.(max(remaining(deadline), @min_attempt)) do
      {:ok, result} ->
        {:ok, result}

      {:error, error} ->
        cond do
          not Errors.retryable?(error) ->
            {:error, Errors.message(error)}

          attempt < @max_attempts and retry_after_backoff?(attempt, deadline) ->
            retried(:statement, error.postgres.code, attempt)
            retrying(run, attempt + 1, deadline)

          true ->
            {:error,
             {:serialization_failure, "#{error.postgres.code}; gave up after #{attempt} attempts"}}
        end
    end
  end

  defp timeout!(timeout) when is_integer(timeout) and timeout > 0, do: timeout

  defp timeout!(timeout) do
    raise ArgumentError,
          "the PostgreSQL store needs a finite timeout in milliseconds, got: #{inspect(timeout)}"
  end

  defp deadline(timeout), do: System.monotonic_time(:millisecond) + timeout

  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  # Full jitter over an exponential window capped at 200 ms; true when enough
  # of the call's time is left after it for another attempt.
  defp retry_after_backoff?(attempt, deadline) do
    pause = :rand.uniform(min(200, 2 ** min(attempt + 1, 8)))

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
  defp advance_identity({__MODULE__, conn, doomed, _deadline}, {table, column}, timeout) do
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
        if Errors.retryable?(error), do: :atomics.put(doomed, 1, 1)
        {:error, Errors.message(error)}
    end
  end

  # ---------------------------------------------------------------------------
  # Transactions
  # ---------------------------------------------------------------------------

  defp attempt_transaction(pool, fun, attempt, deadline) do
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

      {:commit, error} ->
        if Errors.retryable?(error) do
          retry_transaction(pool, fun, {attempt, deadline}, error.postgres.code)
        else
          {:error, {:commit_failed, commit_reason(error)}}
        end

      {:begin, error} ->
        {:error, {:begin_failed, Errors.message(error)}}
    end
  end

  defp commit_reason({:rolled_back, _command}), do: :rollback
  defp commit_reason(error), do: Errors.message(error)

  defp retry_transaction(pool, fun, {attempt, deadline}, reason) do
    if attempt < @max_attempts and retry_after_backoff?(attempt, deadline) do
      retried(:transaction, reason, attempt)
      attempt_transaction(pool, fun, attempt + 1, deadline)
    else
      {:error, {:serialization_failure, "#{reason}; gave up after #{attempt} attempts"}}
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
        returned =
          try do
            {:returned, fun.({__MODULE__, conn, doomed, deadline})}
          catch
            kind, reason -> {:raised, kind, reason, __STACKTRACE__}
          end

        conclude(conn, :atomics.get(doomed, 1) == 1, returned, deadline)

      {:error, error} ->
        {:begin, error}
    end
  end

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
