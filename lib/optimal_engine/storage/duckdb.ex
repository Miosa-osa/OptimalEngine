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
                 "COPY (SELECT '#{value}' AS value, 1 AS n) TO #{literal(file)} (FORMAT PARQUET)",
                 opts
               ),
             {:ok, [%{"value" => ^value}]} <-
               query(config, "SELECT value FROM read_parquet(#{literal(file)})", opts) do
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

  @doc """
  Runs one SQL statement in an in-memory database and decodes the JSON rows.

  The executable runs as a port of the calling process, read until it exits.
  At the timeout the process is killed by its own OS pid: closing a port does
  not stop the program behind it, so a hung query used to keep running (and a
  late `COPY` could write its file after the proof removed it). Only standard
  output is read; standard error goes to the Engine's log, so a warning cannot
  break the JSON.
  """
  @spec query(map(), String.t(), keyword()) :: {:ok, list()} | {:error, term()}
  def query(%{executable: executable}, sql, opts) when is_binary(executable) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        args: [":memory:", "-json", "-c", sql]
      ])

    # nil once a program that exited at once has closed its port; its output
    # and exit status are still in the mailbox.
    os_pid =
      case Port.info(port, :os_pid) do
        {:os_pid, pid} -> pid
        nil -> nil
      end

    collect(port, os_pid, System.monotonic_time(:millisecond) + timeout, [])
  rescue
    error in ErlangError ->
      if error.original == :enoent, do: {:error, :not_installed}, else: {:error, :unreachable}
  catch
    _kind, _reason -> {:error, :unreachable}
  end

  def query(_config, _sql, _opts), do: {:error, :not_installed}

  defp collect(port, os_pid, deadline, output) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        collect(port, os_pid, deadline, [output, data])

      {^port, {:exit_status, 0}} ->
        decode(IO.iodata_to_binary(output))

      {^port, {:exit_status, status}} ->
        {:error, {:exit, status, output |> IO.iodata_to_binary() |> String.slice(0, 120)}}
    after
      remaining ->
        stop(port, os_pid)
        {:error, :timeout}
    end
  end

  # Kills exactly the process this query started, then drops what the port
  # still sends, so nothing of it is left in the caller's mailbox.
  defp stop(port, os_pid) do
    if is_integer(os_pid),
      do: System.cmd("kill", ["-KILL", Integer.to_string(os_pid)], stderr_to_stdout: true)

    if Port.info(port) != nil, do: Port.close(port)
    flush(port)
  catch
    _kind, _reason -> flush(port)
  end

  defp flush(port) do
    receive do
      {^port, _message} -> flush(port)
    after
      0 -> :ok
    end
  end

  # A SQL string literal: a quote in the path is doubled, so a path such as
  # /data/o'brien works and cannot end the statement.
  defp literal(text), do: "'" <> String.replace(text, "'", "''") <> "'"

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
