defmodule OptimalEngine.LogBuffer do
  @moduledoc """
  The Engine's most recent log lines, kept in memory for `GET /api/maintenance/log`.

  An operator of a managed Engine cannot tail a log file on the machine that runs
  it, so the client CLI's `optimal log` reads these lines through the API instead.
  This process owns an ETS ring and installs a `:logger` handler that writes one
  formatted line per event into it; the ring keeps the newest `capacity` lines
  (`:log_buffer_capacity`, default 1,000) at `:log_buffer_level` (default `:info`)
  and above.

  A line is `<UTC ISO 8601 time> [<level>] <message>` on a single line, at most
  4,096 bytes. API keys (`oe_<id>_<secret>`) and bearer tokens are redacted before
  a line is stored, so the route never serves a secret even when code logged one.
  Nothing is written to disk and the ring starts empty at boot.
  """

  use GenServer

  @handler_id :optimal_engine_log_buffer
  @table __MODULE__
  @default_capacity 1_000
  @max_line 4_096

  @formatter %{
    template: [:time, " [", :level, "] ", :msg],
    single_line: true,
    legacy_header: false,
    time_offset: ~c"Z",
    chars_limit: @max_line,
    max_size: @max_line
  }

  @key_re ~r/\boe_([0-9A-Za-z]+)_[A-Za-z0-9_\-]+/
  @bearer_re ~r/(Bearer\s+)[^\s"',;]+/i

  @doc false
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  The newest `limit` lines, oldest first, and the ring's capacity.

  Returns no lines and capacity 0 when the ring is not running.
  """
  @spec recent(pos_integer(), :ets.table()) :: %{lines: [String.t()], capacity: non_neg_integer()}
  def recent(limit, table \\ @table) when is_integer(limit) and limit > 0 do
    with [{:seq, last}] <- lookup(table, :seq),
         [{:capacity, capacity}] <- lookup(table, :capacity) do
      first = max(1, last - min(limit, capacity) + 1)

      lines =
        for seq <- first..last//1, [{^seq, line}] <- [lookup(table, seq)], do: line

      %{lines: lines, capacity: capacity}
    else
      _ -> %{lines: [], capacity: 0}
    end
  end

  # ---------------------------------------------------------------------------
  # :logger handler callback. It runs in the process that logged, so it must be
  # cheap and must never raise: a handler that raises is removed by :logger.
  # ---------------------------------------------------------------------------

  @doc false
  def log(event, %{config: %{table: table, capacity: capacity}}) do
    line = event |> :logger_formatter.format(@formatter) |> IO.chardata_to_string() |> redact()
    seq = :ets.update_counter(table, :seq, 1)
    :ets.insert(table, {seq, line})
    :ets.delete(table, seq - capacity)
    :ok
  catch
    _kind, _reason -> :ok
  end

  defp redact(line) do
    line
    |> String.replace(@key_re, "oe_\\1_[redacted]")
    |> String.replace(@bearer_re, "\\1[redacted]")
  end

  defp lookup(table, key) do
    :ets.lookup(table, key)
  rescue
    ArgumentError -> []
  end

  # ---------------------------------------------------------------------------
  # GenServer: owns the table and the handler for the life of the application
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    capacity =
      Keyword.get_lazy(opts, :capacity, fn ->
        Application.get_env(:optimal_engine, :log_buffer_capacity, @default_capacity)
      end)

    level =
      Keyword.get_lazy(opts, :level, fn ->
        Application.get_env(:optimal_engine, :log_buffer_level, :info)
      end)

    Process.flag(:trap_exit, true)
    table = :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    :ets.insert(table, [{:seq, 0}, {:capacity, capacity}])

    _ = :logger.remove_handler(@handler_id)

    :ok =
      :logger.add_handler(@handler_id, __MODULE__, %{
        level: level,
        config: %{table: @table, capacity: capacity}
      })

    {:ok, %{capacity: capacity}}
  end

  @impl true
  def terminate(_reason, _state) do
    _ = :logger.remove_handler(@handler_id)
    :ok
  end
end
