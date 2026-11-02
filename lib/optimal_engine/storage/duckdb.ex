defmodule OptimalEngine.Storage.DuckDB do
  @moduledoc """
  The DuckDB and Parquet provider: columnar analytical projections of tables
  and time series, isolated from the transactional stores. Analytics never
  become the source of truth; every projection is rebuilt from the canonical
  stores.

  The engine drives the `duckdb` command line executable the guest ships,
  so the provider needs no native dependency of its own. `OPTIMAL_ANALYTICS_PATH`
  is the directory the projections live in; it must exist and be writable.

  Health is `SELECT 1` answered by the executable. The proof writes one Parquet
  file of its own under the analytics path (`optimal-proof-<random>.parquet`),
  reads the row back through `read_parquet` and removes the file, so a healthy
  provider has produced and read a columnar file, not merely found a binary.
  """

  @env "OPTIMAL_ANALYTICS_PATH"
  @executable "duckdb"
  @default_timeout 5_000
  @proof_prefix "optimal-proof-"

  @type health :: :healthy | :unreachable | :not_configured | :not_installed | :invalid_config

  @doc "The environment variable the provider is configured by."
  @spec env_name() :: String.t()
  def env_name, do: @env

  @doc "The executable the provider drives."
  @spec executable() :: String.t()
  def executable, do: @executable

  @doc "Whether the analytics path is set."
  @spec configured?() :: boolean()
  def configured?, do: match?({:ok, _}, config())

  @doc "The analytics path, and whether the executable is on the PATH."
  @spec config(keyword()) :: {:ok, map()} | {:error, atom()}
  def config(opts \\ []) do
    case Keyword.get(opts, :path) || System.get_env(@env) do
      value when is_binary(value) and value != "" ->
        {:ok, %{path: value, executable: System.find_executable(@executable)}}

      _ ->
        {:error, :not_configured}
    end
  end

  @doc """
  `SELECT 1` through the executable. `:not_configured` without a path,
  `:not_installed` without the executable, `:invalid_config` when the path is
  not a writable directory, `:unreachable` when the query did not answer.
  """
  @spec health(keyword()) :: health()
  def health(opts \\ []) do
    with {:ok, config} <- config(opts),
         :ok <- check_executable(config),
         :ok <- check_path(config) do
      case query(config, "SELECT 1 AS one", opts) do
        {:ok, [%{"one" => 1}]} -> :healthy
        _ -> :unreachable
      end
    else
      {:error, :not_configured} -> :not_configured
      {:error, :not_installed} -> :not_installed
      {:error, _reason} -> :invalid_config
    end
  end

  @doc "Writes one Parquet file, reads its row back and removes it. Nothing is left behind."
  @spec round_trip(keyword()) :: {:ok, map()} | {:error, term()}
  def round_trip(opts \\ []) do
    with {:ok, config} <- config(opts),
         :ok <- check_executable(config),
         :ok <- check_path(config) do
      value = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

      file =
        Path.join(
          config.path,
          @proof_prefix <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower) <> ".parquet"
        )

      try do
        with {:ok, _} <-
               query(
                 config,
                 "COPY (SELECT '#{value}' AS value, 1 AS n) TO '#{file}' (FORMAT PARQUET)",
                 opts
               ),
             {:ok, [%{"value" => ^value}]} <-
               query(config, "SELECT value FROM read_parquet('#{file}')", opts) do
          {:ok, %{wrote: 1, read_back: true, format: "parquet", path: config.path}}
        else
          {:ok, other} -> {:error, {:round_trip_mismatch, other}}
          {:error, reason} -> {:error, reason}
        end
      after
        File.rm(file)
      end
    end
  end

  @doc "Runs one SQL statement in an in-memory database and decodes the JSON rows."
  @spec query(map(), String.t(), keyword()) :: {:ok, list()} | {:error, term()}
  def query(%{executable: executable}, sql, opts) when is_binary(executable) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    task =
      Task.async(fn ->
        System.cmd(executable, [":memory:", "-json", "-c", sql], stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {out, 0}} -> decode(out)
      {:ok, {out, status}} -> {:error, {:exit, status, String.slice(out, 0, 120)}}
      nil -> {:error, :timeout}
    end
  catch
    _kind, _reason -> {:error, :unreachable}
  end

  def query(_config, _sql, _opts), do: {:error, :not_installed}

  defp decode(out) do
    case String.trim(out) do
      "" ->
        {:ok, []}

      text ->
        case Jason.decode(text) do
          {:ok, rows} when is_list(rows) -> {:ok, rows}
          _ -> {:error, {:unexpected_output, String.slice(text, 0, 120)}}
        end
    end
  end

  defp check_executable(%{executable: nil}), do: {:error, :not_installed}
  defp check_executable(_config), do: :ok

  defp check_path(%{path: path}) do
    cond do
      not File.dir?(path) -> {:error, :path_missing}
      not writable?(path) -> {:error, :path_not_writable}
      true -> :ok
    end
  end

  defp writable?(path) do
    case File.stat(path) do
      {:ok, %File.Stat{access: access}} -> access in [:write, :read_write]
      _ -> false
    end
  end
end
