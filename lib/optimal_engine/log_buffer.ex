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
  4,096 bytes, with control characters other than tab replaced by `?`: C0 and
  C1 controls, DEL, and the Unicode line and paragraph separators. Before a line
  is stored, these are replaced with `[redacted]`:

    * Engine API keys, any `oe_` token (generated `oe_<id>_<secret>` keys and
      operator-chosen ones, plain or URL-encoded);
    * `Bearer` credentials, `Basic` credentials (only `Basic` followed by a
      credential, so "basic mode" stays), and the userinfo of a URL, with or
      without a password, a password holding `@` included;
    * the value after a credential-like name (`api_key`, `access_token`,
      `refresh_token`, `token`, `secret`, `password`, `client_secret`,
      `secret_access_key`, `authorization`, `x-optimal-grant`, `bot_token`),
      also at the end of a longer name (`AWS_SECRET_ACCESS_KEY`, `db_password`,
      `notion_token`), in `name=value`, `name: value`, `"name" => value`,
      `{"name", value}` and escaped-JSON forms. A quoted or charlist value is
      redacted to its closing quote, an unquoted one to the next whitespace,
      and `authorization` takes an auth scheme word before its credential;
    * provider tokens with a known prefix (`sk-`, `sk-ant-`, `rk_`, `whsec_`,
      `msk_`, `mki_`, `xox?-`, `gh?_`, `github_pat_`, `ntn_`, `secret_`,
      `ya29.`), AWS access key ids (`AKIA...`) and JWTs.

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

  # Applied in order: the specific shapes first, then the credential-like names,
  # then the prefixed tokens (after the names, so secret_access_key is a name).
  #
  # A credential-like name counts at the start of a word or after any
  # non-alphanumeric, so AWS_SECRET_ACCESS_KEY and db_password do. Its separator
  # is an optional (escaped) quote, then =>, : or =, or the "," of a tuple. A
  # quoted value (a charlist ~c"..." or '...' too) is redacted to its closing
  # quote, an unquoted one to the next whitespace; `authorization` also takes an
  # auth scheme word before the credential.
  @redactions [
    {~r/oe_[^\s"'&,;)}\]]+/, "oe_[redacted]"},
    {~r/(Bearer\s+)[^\s"',;]+/i, "\\1[redacted]"},
    # Only as an auth scheme: a credential of at least 8 base64 characters that
    # is not a plain lowercase or capitalized word.
    {~r/(Basic\s+)(?=[A-Za-z0-9+\/]{8})(?![a-z]+(?![A-Za-z0-9+\/=]))(?![A-Z][a-z]+(?![A-Za-z0-9+\/=]))[A-Za-z0-9+\/]+=*/,
     "\\1[redacted]"},
    {~r/([a-z][a-z0-9+.-]*:\/\/)[^\/\s?#]*@/i, "\\1[redacted]@"},
    {~r/(?<![A-Za-z0-9])(authorization)(\\?"?\s*(?:=>|[:=]|\\?",)\s*)(?:[A-Za-z][A-Za-z0-9_-]*\s+)?[^\s"']+/i,
     "\\1\\2[redacted]"},
    {~r/(?<![A-Za-z0-9])(api[_-]?key|access[_-]?token|refresh[_-]?token|token|secret|password|client[_-]?secret|secret[_-]?access[_-]?key|authorization|x-optimal-grant|bot_token)(\\?"?\s*(?:=>|[:=]|\\?",)\s*)(?:((?:~c)?\\?")[^"]*?(\\?")|'[^']*'|[^\s"']+)/i,
     :value},
    {~r/(?<![A-Za-z0-9])(github_pat|ntn|ya29|whsec|rk|msk|mki|sk-ant|sk|xox[abpors]|gh[pousr])([_.-])[A-Za-z0-9_.-]{8,}/,
     "\\1\\2[redacted]"},
    # Letters and digits only, so a name such as secret_access_key stays.
    {~r/(?<![A-Za-z0-9])secret_[A-Za-z0-9]{16,}/, "secret_[redacted]"},
    {~r/AKIA[0-9A-Z]{16}/, "[redacted]"},
    {~r/eyJ[\w-]+\.[\w-]+\.[\w-]+/, "[redacted]"}
  ]
  @control_re ~r/[\x00-\x08\x0b-\x1f\x7f\x{80}-\x{9f}\x{2028}\x{2029}]/u

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

    Enum.reduce(@redactions, line, fn
      {pattern, :value}, acc -> Regex.replace(pattern, acc, &redact_value/5)
      {pattern, replacement}, acc -> Regex.replace(pattern, acc, replacement)
    end)
  end

  # The name and its separator stay; a double-quoted value keeps its quotes.
  defp redact_value(_whole, name, separator, "", ""), do: name <> separator <> "[redacted]"

  defp redact_value(_whole, name, separator, open, close),
    do: name <> separator <> open <> "[redacted]" <> close

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
