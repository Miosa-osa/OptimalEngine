defmodule OptimalEngine.Storage.Postgres do
  @moduledoc """
  Connection, configuration, and health for the PostgreSQL storage provider.

  This module is the first stage of the provider described in
  `docs/guides/postgres-provider.md`. It is deliberately not registered as a
  provider adapter: the engine cannot yet read or write relational data through
  PostgreSQL, so `OptimalEngine.Storage.Providers` must keep reporting
  `adapter_missing` for `postgres`. Registering this module there would claim a
  capability the engine does not have.

  What it does provide is a truthful health signal. `OPTIMAL_POSTGRES_URL` is
  parsed into connection options and the probe runs a real `SELECT 1`, so a
  configured but wrong host, database, or credential reports `unreachable`
  instead of a bare TCP success.

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
      stage: 1,
      adapter_registered: false,
      env: @env
    }
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

  defp ssl_enabled?(%URI{query: nil}), do: false

  defp ssl_enabled?(%URI{query: query}) do
    query
    |> URI.query_decoder()
    |> Enum.find_value(false, fn
      {"sslmode", mode} -> mode in ["require", "verify-ca", "verify-full"]
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
    parent = self()
    tag = make_ref()

    {pid, monitor} =
      spawn_monitor(fn ->
        send(parent, {tag, connect_and_query(config, timeout)})
      end)

    receive do
      {^tag, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^pid, _reason} ->
        :unreachable
    after
      timeout + 1_000 ->
        Process.exit(pid, :kill)
        :unreachable
    end
  end

  defp connect_and_query(config, timeout) do
    options =
      config
      |> Map.put(:timeout, timeout)
      |> Map.put(:connect_timeout, timeout)
      |> Map.put(:pool_size, 1)
      |> Map.put(:backoff_type, :stop)
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    case Postgrex.start_link(options) do
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
