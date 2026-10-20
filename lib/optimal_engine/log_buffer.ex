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
  4,096 bytes, with control characters other than tab replaced by `?`. Before a
  line is stored, these are replaced with `[redacted]`:

    * Engine API keys (`oe_<24 hex id>_<secret>`, plain or URL-encoded; the id is kept);
    * `Bearer` and `Basic` credentials, and the user and password of a URL;
    * the value after a credential-like name (`api_key`, `access_token`,
      `refresh_token`, `token`, `secret`, `password`, `client_secret`,
      `secret_access_key`, `authorization`, `x-optimal-grant`, `bot_token`) in
      `name=value`, `name: value`, `"name" => value` and `{"name", value}` forms;
    * provider tokens with a known prefix (`sk-`, `sk-ant-`, `msk_`, `mki_`,
      `xox?-`, `gh?_`), AWS access key ids (`AKIA...`) and JWTs.

  A secret in any other shape is not recognized, which is why the route is
  limited to the Engine operator. Nothing is written to disk and the ring starts
  empty at boot.
  """

  use GenServer

  require Logger

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

  # Applied in order; the specific shapes first, then any credential-like name.
  @redactions [
    {~r/oe_([0-9a-f]{24})_[A-Za-z0-9_-]+/, "oe_\\1_[redacted]"},
    {~r/(Bearer\s+)[^\s"',;]+/i, "\\1[redacted]"},
    {~r/(Basic\s+)[A-Za-z0-9+\/=]+/i, "\\1[redacted]"},
    {~r/([a-z][a-z0-9+.-]*:\/\/)[^\/\s@:]+:[^\/\s@]+@/i, "\\1[redacted]@"},
    {~r/\b(msk|mki|sk-ant|sk|xox[abpors]|gh[pousr])([_-])[A-Za-z0-9_-]{8,}/, "\\1\\2[redacted]"},
    {~r/AKIA[0-9A-Z]{16}/, "[redacted]"},
    {~r/eyJ[\w-]+\.[\w-]+\.[\w-]+/, "[redacted]"},
    {~r/\b(api[_-]?key|access[_-]?token|refresh[_-]?token|token|secret|password|client[_-]?secret|secret[_-]?access[_-]?key|authorization|x-optimal-grant|bot_token)("?\s*(?:=>|[:=]|",)\s*"?)[^\s"',;&}]+/i,
     "\\1\\2[redacted]"}
  ]
  @control_re ~r/[\x00-\x08\x0b-\x1f\x7f]/

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
    line = String.replace(line, @control_re, "?")

    Enum.reduce(@redactions, line, fn {pattern, replacement}, acc ->
      String.replace(acc, pattern, replacement)
    end)
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

    table_name = Keyword.get(opts, :table, @table)
    handler_id = Keyword.get(opts, :handler_id, @handler_id)

    Process.flag(:trap_exit, true)
    table = :ets.new(table_name, [:named_table, :public, :set, write_concurrency: true])
    :ets.insert(table, [{:seq, 0}, {:capacity, capacity}])

    _ = :logger.remove_handler(handler_id)

    # A bad setting must not stop the Engine: it runs without recent log lines.
    case :logger.add_handler(handler_id, __MODULE__, %{
           level: level,
           config: %{table: table_name, capacity: capacity}
         }) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[LogBuffer] not keeping recent log lines (GET /api/maintenance/log answers none): #{inspect(reason)}"
        )
    end

    {:ok, %{capacity: capacity, handler_id: handler_id}}
  end

  @impl true
  def terminate(_reason, %{handler_id: handler_id}) do
    _ = :logger.remove_handler(handler_id)
    :ok
  end
end
