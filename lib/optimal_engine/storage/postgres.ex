defmodule OptimalEngine.Storage.Postgres do
  @moduledoc """
  Connection, configuration, and health for the PostgreSQL storage provider.

  The canonical store on PostgreSQL is `OptimalEngine.Store.Postgres`
  (`docs/guides/postgres-provider.md`); this module is the operator's view of
  the connection. `OPTIMAL_POSTGRES_URL` is parsed into connection options and
  the probe runs a real `SELECT 1`, so a configured but wrong host, database,
  or credential reports `unreachable` instead of a bare TCP success.
  `round_trip/1` writes a row and reads it back.

  The URL is never returned by this module's public functions, logged, or
  written to disk; `safe_config/1` carries only non-secret fields.
  """

  @env "OPTIMAL_POSTGRES_URL"
  @default_port 5432
  @default_timeout 2_000
  @application_name "optimal_engine"

  @type health :: :healthy | :unreachable | :not_configured | :invalid_config

  @doc "The environment variable that configures this provider."
  @spec env_name() :: String.t()
  def env_name, do: @env

  @doc "Non-secret description of the provider and its current stage."
  @spec describe() :: map()
  def describe do
    %{
      id: "postgres",
      name: "PostgreSQL",
      kind: "service",
      role: "canonical",
      capabilities: ~w(relational temporal document geospatial time_series),
      stage: 3,
      adapter_registered: true,
      adapter: "OptimalEngine.Store.Postgres",
      selected: OptimalEngine.Store.selected?(OptimalEngine.Store.Postgres),
      env: @env,
      unavailable: unavailable()
    }
  end

  @doc """
  What the PostgreSQL store does not do yet. Each feature is refused by name
  when it is used, never answered as if it worked; `refused_as` are the
  reasons it is refused with, and every reason the dialect refuses a statement
  with is under one of them. A store that finds one of the first two in use in
  its database does not start (`OptimalEngine.Store.Postgres`).
  """
  @spec unavailable() :: [%{feature: String.t(), reason: String.t(), refused_as: [String.t()]}]
  def unavailable do
    [
      %{
        feature: "replication",
        reason:
          "change capture is SQLite triggers and applying reads SQLite's catalog; " <>
            "enabling, serving and applying sync are refused",
        refused_as: ["replication is not available on the PostgreSQL store"]
      },
      %{
        feature: "app_data_collections",
        reason:
          "a collection creates a table, a full-text index and triggers at runtime; " <>
            "creating one is refused",
        refused_as: [
          "app data collections are not available on the PostgreSQL store",
          "schema change outside the migrations"
        ]
      },
      %{
        feature: "full_text_search",
        reason:
          "FTS5 tables are not created on PostgreSQL; search and MATCH are refused " <>
            "until a tsvector slice",
        refused_as: ["full-text search is not available on the PostgreSQL store", "FTS5 MATCH"]
      },
      %{
        feature: "sqlite_json_functions",
        reason:
          "json_set, json_each, json(), json_array_length and SQLite's other JSON functions, " <>
            "and the json_extract forms PostgreSQL cannot compare as SQLite does (an ordered " <>
            "comparison, ORDER BY on it, a comparison to an expression or a non-text value), " <>
            "are refused at their call sites (routing placement, memory partition and " <>
            "security label filters, reconstruction learning)",
        refused_as:
          refused_by("a SQLite JSON function with no translation") ++
            [
              "json_extract form",
              "json_extract path",
              "json_extract on the right of a comparison",
              "json_extract ordered comparison",
              "json_extract compared to an expression",
              "json_extract compared to a non-text value",
              "json_extract in ORDER BY",
              "json_extract IN with an expression",
              "json_extract IN with a subquery",
              "json_valid of an expression"
            ]
      },
      %{
        feature: "date_time_arithmetic",
        reason:
          "datetime and strftime with a computed modifier or another format, julianday, " <>
            "unixepoch, date() and time() are refused (viability metrics, retention windows)",
        refused_as: [
          "unmapped date/time function",
          "datetime() modifier",
          "strftime call",
          "strftime format",
          "julianday",
          "unixepoch",
          "date",
          "time"
        ]
      },
      %{
        feature: "sqlite_catalog",
        reason:
          "PRAGMA, sqlite_master and the pragma_* functions are refused (workspace bundles, " <>
            "the data steward's table list, a workspace slug change, replication)",
        refused_as: ["PRAGMA", "sqlite_master", "SQLite catalog function"]
      },
      %{
        feature: "rowid",
        reason:
          "a statement that orders or filters by rowid, or reads last_insert_rowid(), is " <>
            "refused (backup schedules, the storage audit, graph edge listings, model call " <>
            "history, a workspace slug change)",
        refused_as: ["rowid", "last_insert_rowid"]
      },
      %{
        feature: "sqlite_functions",
        reason:
          "group_concat, typeof, instr, printf and SQLite's other functions without a " <>
            "translation, GLOB, SQLite's collations and a LIKE with a computed pattern are " <>
            "refused at their call sites (action chain lists, clusters, insight health)",
        refused_as:
          refused_by("a SQLite function with no translation") ++
            ["GLOB", "SQLite collation", "LIKE with a computed pattern"]
      },
      %{
        feature: "replace_writes",
        reason:
          "SQLite's delete-and-insert writes (INSERT OR REPLACE, REPLACE INTO) and an " <>
            "INSERT OR IGNORE with its own ON CONFLICT are refused at their call sites; the " <>
            "store's context and chunk writes replace rows as SQLite does",
        refused_as: [
          "INSERT OR REPLACE",
          "REPLACE INTO",
          "INSERT OR IGNORE with an explicit ON CONFLICT clause"
        ]
      },
      %{
        feature: "runtime_schema_and_transactions",
        reason:
          "the schema comes from the migrations and transactions from the store, so a " <>
            "schema change, a transaction statement sent as a statement, and SQLite-only " <>
            "table options are refused",
        refused_as: [
          "schema change outside the migrations",
          "transaction statement outside the store's transaction",
          "AUTOINCREMENT",
          "WITHOUT ROWID"
        ]
      }
    ]
  end

  defp refused_by(reason) do
    for {name, ^reason} <- OptimalEngine.Store.Dialect.refusals(), do: name
  end

  @doc """
  Reports whether a syntactically valid connection URL is present.

  Presence is not health: call `health/1` for that.
  """
  @spec configured?() :: boolean()
  def configured?, do: match?({:ok, _}, config())

  @doc """
  Parses `OPTIMAL_POSTGRES_URL` into Postgrex connection options.

  The returned map includes the password because the driver needs it.
  Do not log it or return it from an API route; use `safe_config/1` for that.
  """
  @spec config(keyword()) :: {:ok, map()} | {:error, atom() | tuple()}
  def config(opts \\ []) do
    case Keyword.get(opts, :url) || System.get_env(@env) do
      value when is_binary(value) and value != "" -> parse_url(value)
      _ -> {:error, :not_configured}
    end
  end

  @doc "The connection options without the password."
  @spec safe_config(keyword()) :: {:ok, map()} | {:error, atom() | tuple()}
  def safe_config(opts \\ []) do
    with {:ok, config} <- config(opts) do
      {:ok, Map.drop(config, [:password])}
    end
  end

  @doc """
  Checks the configured database with one `SELECT 1`.

  Returns `:not_configured` without a URL, `:invalid_config` for a URL that
  cannot be parsed, and `:unreachable` for any connection or query failure.
  A probe never raises and never logs the credential.
  """
  @spec health(keyword()) :: health()
  def health(opts \\ []) do
    with {:ok, config} <- config(opts) do
      run_probe(config, Keyword.get(opts, :timeout, @default_timeout))
    else
      {:error, :not_configured} -> :not_configured
      {:error, _reason} -> :invalid_config
    end
  end

  @doc "True only when the database answered a real query."
  @spec healthy?(keyword()) :: boolean()
  def healthy?(opts \\ []), do: health(opts) == :healthy

  @doc """
  Writes one row to a temporary table and reads it back, on a connection of
  its own that is closed afterwards. The table disappears with the
  transaction, so nothing is left in the database.
  """
  @spec round_trip(keyword()) :: {:ok, map()} | {:error, term()}
  def round_trip(opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    with {:ok, config} <- config(opts) do
      run_isolated(fn -> write_and_read(config, timeout) end, timeout, {:error, :unreachable})
    end
  end

  defp write_and_read(config, timeout) do
    {:ok, conn} = Postgrex.start_link(connect_options(config, timeout))
    value = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

    try do
      Postgrex.transaction(conn, fn conn ->
        Postgrex.query!(conn, "CREATE TEMP TABLE optimal_proof (value TEXT) ON COMMIT DROP", [])
        Postgrex.query!(conn, "INSERT INTO optimal_proof (value) VALUES ($1)", [value])
        %{rows: [[read]]} = Postgrex.query!(conn, "SELECT value FROM optimal_proof", [])
        read
      end)
      |> case do
        {:ok, ^value} -> {:ok, %{wrote: 1, read_back: true}}
        other -> {:error, {:round_trip_mismatch, other}}
      end
    after
      GenServer.stop(conn, :normal, timeout)
    end
  catch
    _kind, _reason -> {:error, :unreachable}
  end

  # ---------------------------------------------------------------------------
  # URL parsing
  # ---------------------------------------------------------------------------

  defp parse_url(value) do
    uri = URI.parse(value)

    with :ok <- check_scheme(uri),
         {:ok, host} <- check_host(uri),
         {:ok, database} <- check_database(uri),
         {:ok, username} <- check_username(uri) do
      {:ok,
       %{
         hostname: host,
         port: uri.port || @default_port,
         database: database,
         username: username,
         password: uri_password(uri),
         ssl: ssl_enabled?(uri),
         sslmode: sslmode(uri),
         application_name: @application_name
       }}
    end
  end

  defp check_scheme(%URI{scheme: scheme}) when scheme in ["postgres", "postgresql"], do: :ok
  defp check_scheme(_uri), do: {:error, :invalid_scheme}

  defp check_host(%URI{host: host}) when is_binary(host) and host != "", do: {:ok, host}
  defp check_host(_uri), do: {:error, :missing_host}

  defp check_database(%URI{path: path}) when is_binary(path) do
    case String.trim_leading(path, "/") do
      "" -> {:error, :missing_database}
      database -> {:ok, URI.decode_www_form(database)}
    end
  end

  defp check_database(_uri), do: {:error, :missing_database}

  defp check_username(%URI{userinfo: userinfo}) when is_binary(userinfo) and userinfo != "" do
    case String.split(userinfo, ":", parts: 2) do
      [username | _] when username != "" -> {:ok, URI.decode_www_form(username)}
      _ -> {:error, :missing_username}
    end
  end

  defp check_username(_uri), do: {:error, :missing_username}

  defp uri_password(%URI{userinfo: userinfo}) when is_binary(userinfo) do
    case String.split(userinfo, ":", parts: 2) do
      [_username, password] -> URI.decode_www_form(password)
      _ -> nil
    end
  end

  defp uri_password(_uri), do: nil

  defp ssl_enabled?(uri), do: sslmode(uri) in ["require", "verify-ca", "verify-full"]

  defp sslmode(%URI{query: nil}), do: nil

  defp sslmode(%URI{query: query}) do
    query
    |> URI.query_decoder()
    |> Enum.find_value(fn
      {"sslmode", mode} -> mode
      _ -> nil
    end)
  end

  # ---------------------------------------------------------------------------
  # Probe
  # ---------------------------------------------------------------------------

  # A failed connection must not take the caller down with it, and a hung TCP
  # connect must not outlive the probe. The connection is opened in a spawned,
  # unlinked process that is monitored and hard-stopped at the deadline.
  defp run_probe(config, timeout) do
    run_isolated(fn -> connect_and_query(config, timeout) end, timeout, :unreachable)
  end

  defp run_isolated(fun, timeout, unreachable) do
    parent = self()
    tag = make_ref()

    {pid, monitor} = spawn_monitor(fn -> send(parent, {tag, fun.()}) end)

    receive do
      {^tag, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^pid, _reason} ->
        unreachable
    after
      timeout + 1_000 ->
        Process.exit(pid, :kill)
        unreachable
    end
  end

  defp connect_options(config, timeout) do
    config
    |> Map.delete(:sslmode)
    |> Map.put(:timeout, timeout)
    |> Map.put(:connect_timeout, timeout)
    |> Map.put(:pool_size, 1)
    |> Map.put(:backoff_type, :stop)
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp connect_and_query(config, timeout) do
    case Postgrex.start_link(connect_options(config, timeout)) do
      {:ok, conn} ->
        try do
          case Postgrex.query(conn, "SELECT 1", [], timeout: timeout) do
            {:ok, %Postgrex.Result{rows: [[1]]}} -> :healthy
            _ -> :unreachable
          end
        after
          GenServer.stop(conn, :normal, timeout)
        end

      _ ->
        :unreachable
    end
  catch
    _kind, _reason -> :unreachable
  end
end
