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
  C1 controls, DEL, the Unicode line and paragraph separators, and the bidi and
  invisible format characters (U+061C, U+200B, U+200E, U+200F, U+202A to
  U+202E, U+2060, U+2066 to U+2069, U+FEFF). A longer line is redacted first
  and then cut at a character boundary, ending in `...`, so a cut never leaves
  part of a secret. Before a line is stored, these are replaced with
  `[redacted]`:

    * PEM private key blocks, to their END line or the end of the line;
    * Engine API keys, any `oe_` token (generated `oe_<id>_<secret>` keys and
      operator-chosen ones, plain or URL-encoded);
    * `Bearer` credentials, `Basic` credentials (any case, only followed by a
      credential, so "basic mode" stays), and the userinfo of a URL, with or
      without a password, a password holding `@` included;
    * the value after a credential-like name (`api_key`, `access_token`,
      `refresh_token`, `token`, `secret`, `password`, `passwd`, `passphrase`,
      `client_secret`, `secret_access_key`, `secret_key`, `private_key`,
      `signature`, `authorization`, `x-optimal-grant`, `bot_token`), also at the
      end of a longer name (`AWS_SECRET_ACCESS_KEY`, `db_password`,
      `notion_token`), as the last word of a camelCase name (`apiKey`,
      `accessToken`, `clientSecret`, `dbPassword`), and after an upper-case
      environment name ending in `_KEY` (`CONNECTOR_KEY`). It counts in
      `name=value`, `name: value`, `"name" => value`, `{"name", value}`,
      `{:name, value}`, Erlang `{name,<<"value">>}` and escaped-JSON forms. A
      quoted value (`"..."` with its escapes, `~c"..."`, `<<"...">>`, `'...'`,
      `` `...` ``) is redacted to its closing quote, or to the end of the line
      without one; an unquoted one to whitespace, a quote, or the `&` of the
      next query parameter, an auth scheme word included (any word after
      `authorization`; `Token`, `ApiKey`, `Digest`, `AWS4-HMAC-SHA256` and the
      like after the other names). A bare name in prose ("the
      password: was reset") loses the word after it: the rule fails closed;
    * provider tokens with a known prefix (`sk-`, `sk-ant-`, `rk_`, `whsec_`,
      `msk_`, `mki_`, `xox?-`, `xapp-`, `gh?_`, `github_pat_`, `glpat-`,
      `ntn_`, `secret_`, `npm_`, `hf_`, `ya29.`, `AIza`), AWS access key ids
      (`AKIA...`, `ASIA...`) and JWTs.

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
  # A line is formatted in a window four times as long, redacted, and only then
  # cut to @max_line bytes: a cut made before redaction can split a secret so
  # that no rule recognizes the part that stays.
  @window 4 * @max_line

  @formatter %{
    template: [:time, " [", :level, "] ", :msg],
    single_line: true,
    legacy_header: false,
    time_offset: ~c"Z",
    chars_limit: @window,
    max_size: @window
  }

  # Applied in order: whole blocks and specific shapes first, then the
  # credential-like names, then the prefixed tokens (after the names, so
  # secret_access_key is a name). Every pattern is linear on a crafted line: a
  # repeatable start (a URL scheme, a JWT) only counts at the start of a word,
  # and a repeated part is possessive or ends where the next start begins (URL
  # userinfo stops at the "/" of the next "://").
  #
  # A credential-like name counts at the start of a word or after any
  # non-alphanumeric, so AWS_SECRET_ACCESS_KEY and db_password do, and as the
  # last word of a camelCase name (apiKey, accessToken); an upper-case
  # environment name ending in _KEY counts too. Its separator is an optional
  # (escaped) quote, then =>, : or =, or the "," of a tuple. The value is:
  #
  #   * a double-quoted string, escapes included, also as a charlist ~c"..." or
  #     an Erlang binary <<"...">>, or an escaped \"...\" inside an inspected
  #     string, redacted to its closing quote, or to the end of the line without
  #     one;
  #   * a '...' or `...` string, the same way;
  #   * otherwise everything up to whitespace, a quote, or the & that starts the
  #     next query parameter, after an optional auth scheme word: any word for
  #     authorization (its own rule), a known one (Bearer, Token, ApiKey,
  #     Digest, AWS4-HMAC-SHA256 and the like) for the other names.
  #
  # The name list and the atom-named tuple rule repeat the names, because a
  # pattern built by interpolation is compiled at run time.
  @redactions [
    {~r/-----BEGIN [A-Z ]*PRIVATE KEY-----.*?(?:-----END [A-Z ]*PRIVATE KEY-----|\z)/s,
     "[redacted private key]"},
    {~r/oe_[^\s"'&,;)}\[\]]+/, "oe_[redacted]"},
    {~r/(Bearer\s+)[^\s"',;]+/i, "\\1[redacted]"},
    # Only as an auth scheme: a credential that is not a plain lowercase or
    # capitalized word.
    {~r/((?i:Basic)\s+)(?![a-z]+(?![A-Za-z0-9+\/=]))(?![A-Z][a-z]+(?![A-Za-z0-9+\/=]))[A-Za-z0-9+\/]++=*/,
     "\\1[redacted]"},
    {~r/(?<![a-z0-9+.-])([a-z][a-z0-9+.-]*+:\/\/)[^\/\s?#]*@/i, "\\1[redacted]@"},
    # authorization: any scheme word may come before an unquoted credential.
    {~r/(?<![A-Za-z0-9])(authorization)(\\?"?\s*(?:=>|[:=]|\\?",)\s*)(?|((?:~c|<<)?")(?:[^"\\]|\\.)*+\\?("(?:>>)?|\z)|(\\")[^"]*?(\\"|\z)|(')(?:[^'\\]|\\.)*+\\?('|\z)|(`)[^`]*+(`|\z)|()(?:[A-Za-z][\w-]*+\s+)?(?:[^\s"'`&]|&(?![\w.-]++=))+())/i,
     :value},
    {~r/(?|(?<![A-Za-z0-9])(api[_-]?key|access[_-]?token|refresh[_-]?token|token|client[_-]?secret|secret[_-]?access[_-]?key|secret[_-]?key|private[_-]?key|secret|passw(?:or)?d|passphrase|signature|x-optimal-grant|bot_token)|(?<![A-Za-z0-9_])((?-i:(?:[A-Z][A-Z0-9]*+_)++KEY))|(?<=(?-i:[a-z]))((?-i:Token|Secret|Password|Key)))(\\?"?\s*(?:=>|[:=]|\\?",)\s*)(?|((?:~c|<<)?")(?:[^"\\]|\\.)*+\\?("(?:>>)?|\z)|(\\")[^"]*?(\\"|\z)|(')(?:[^'\\]|\\.)*+\\?('|\z)|(`)[^`]*+(`|\z)|()(?:(?:bearer|basic|token|apikey|api-key|digest|negotiate|ntlm|hoba|mutual|oauth|dpop|aws4-hmac-sha256)\s+)?(?:[^\s"'`&]|&(?![\w.-]++=))+())/i,
     :value},
    {~r/(\{:?(?:[a-z0-9_]*_)?(?:api[_-]?key|access[_-]?token|refresh[_-]?token|token|client[_-]?secret|secret[_-]?access[_-]?key|secret[_-]?key|private[_-]?key|secret|passw(?:or)?d|passphrase|signature|authorization|bot_token),\s*)(?:(?:~c|<<)?"(?:[^"\\]|\\.)*+\\?(?:"(?:>>)?|\z)|'(?:[^'\\]|\\.)*+\\?(?:'|\z)|[^\s,}]+)/i,
     "\\1[redacted]"},
    {~r/(?<![A-Za-z0-9])(github_pat|ntn|ya29|whsec|rk|msk|mki|sk-ant|sk|xox[abpors]|xapp|glpat|gh[pousr])([_.-])[A-Za-z0-9_.-]{8,}/,
     "\\1\\2[redacted]"},
    # Letters and digits only, so a name such as secret_access_key, npm_config
    # or hf_cache stays.
    {~r/(?<![A-Za-z0-9])secret_[A-Za-z0-9]{16,}/, "secret_[redacted]"},
    {~r/(?<![A-Za-z0-9])npm_[A-Za-z0-9]{36}(?![A-Za-z0-9])/, "npm_[redacted]"},
    {~r/(?<![A-Za-z0-9])hf_[A-Za-z]{30,}/, "hf_[redacted]"},
    {~r/AIza[0-9A-Za-z_-]{35}/, "[redacted]"},
    {~r/(?:AKIA|ASIA)[0-9A-Z]{16}/, "[redacted]"},
    {~r/(?<![\w-])eyJ[\w-]++\.[\w-]++\.[\w-]++/, "[redacted]"}
  ]
  # C0 and C1 controls but tab, DEL, the line and paragraph separators, and the
  # bidi and invisible format characters a line could hide text with.
  @control_re ~r/[\x00-\x08\x0b-\x1f\x7f\x{80}-\x{9f}\x{2028}\x{2029}\x{061c}\x{200b}\x{200e}\x{200f}\x{202a}-\x{202e}\x{2060}\x{2066}-\x{2069}\x{feff}]/u

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
    line =
      event
      |> :logger_formatter.format(@formatter)
      |> IO.chardata_to_string()
      |> redact()
      |> cap()

    seq = :ets.update_counter(table, :seq, 1)
    :ets.insert(table, {seq, line})
    :ets.delete(table, seq - capacity)
    :ok
  catch
    _kind, _reason -> :ok
  end

  @doc false
  # The rules, on any text: control characters first, then the patterns.
  @spec redact(String.t()) :: String.t()
  def redact(line) do
    line = String.replace(line, @control_re, "?")

    Enum.reduce(@redactions, line, fn
      {pattern, :value}, acc -> Regex.replace(pattern, acc, &redact_value/5)
      {pattern, replacement}, acc -> Regex.replace(pattern, acc, replacement)
    end)
  end

  # At most @max_line bytes, cut at a character boundary and marked with "...".
  defp cap(line) when byte_size(line) <= @max_line, do: line

  defp cap(line) do
    head = binary_part(line, 0, @max_line - 3)

    case :unicode.characters_to_binary(head) do
      {:incomplete, whole, _split_character} -> whole <> "..."
      _valid_or_not -> head <> "..."
    end
  end

  # The name and its separator stay; a quoted value keeps its quotes (its
  # closing one only when the line has it); an auth scheme word goes with the
  # credential.
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
