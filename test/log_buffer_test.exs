defmodule OptimalEngine.LogBufferTest do
  @moduledoc """
  The in-memory log ring behind `GET /api/maintenance/log`: bounded, oldest
  first, one line per event, and never holding a key.
  """

  use ExUnit.Case, async: true

  alias OptimalEngine.LogBuffer

  require Logger

  defp ring(capacity) do
    table = :ets.new(:log_buffer_test, [:public, :set])
    :ets.insert(table, [{:seq, 0}, {:capacity, capacity}])
    {table, %{config: %{table: table, capacity: capacity}}}
  end

  defp event(message, level \\ :warning) do
    %{level: level, msg: {:string, message}, meta: %{time: :logger.timestamp()}}
  end

  test "keeps the newest `capacity` lines, oldest first" do
    {table, config} = ring(3)
    for n <- 1..5, do: assert(LogBuffer.log(event("line #{n}"), config) == :ok)

    assert %{lines: lines, capacity: 3} = LogBuffer.recent(10, table)
    assert length(lines) == 3
    assert Enum.at(lines, 0) =~ "line 3"
    assert List.last(lines) =~ "line 5"

    assert %{lines: [last]} = LogBuffer.recent(1, table)
    assert last =~ "line 5"
  end

  test "formats one line with a UTC timestamp and the level" do
    {table, config} = ring(5)
    LogBuffer.log(event("first\nsecond", :error), config)

    assert %{lines: [line]} = LogBuffer.recent(5, table)
    refute line =~ "\n"
    assert line =~ ~r/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d[.\d]*Z \[error\] first/
  end

  # One line written through the handler and read back.
  defp stored(message) do
    {table, config} = ring(5)
    assert LogBuffer.log(event(message), config) == :ok
    %{lines: [line]} = LogBuffer.recent(5, table)
    line
  end

  @key_id "0123456789abcdef01234567"

  describe "redaction before a line is stored" do
    test "Engine API keys, plain and URL-encoded" do
      line =
        stored(
          "key oe_#{@key_id}_abc-DEF_123 and ?h=Bearer%20oe_#{@key_id}_ghi456&k=%3Doe_#{@key_id}_jkl789"
        )

      assert line =~ "oe_[redacted]"
      for secret <- ["abc-DEF_123", "ghi456", "jkl789"], do: refute(line =~ secret)
    end

    test "Engine API keys an operator chose, base64 secrets included" do
      line = stored("bootstrap oe_my-own-key_s3cr3t, oe_ops_dGhpcyBpcyBhIHNlY3JldA== (set)")

      for secret <- ["my-own-key_s3cr3t", "s3cr3t", "dGhpcyBpcyBhIHNlY3JldA"],
          do: refute(line =~ secret)

      assert line =~ "(set)"
    end

    test "bearer tokens" do
      line = stored("sent Bearer xyz.789-tok")
      assert line =~ "Bearer [redacted]"
      refute line =~ "xyz.789-tok"
    end

    test "basic credentials" do
      line = stored("sent Basic dXNlcjpwYXNzd29yZA== and Basic dXNlcjpwYXNz")
      assert line =~ "Basic [redacted]"
      refute line =~ "dXNlcjpwYXNzd29yZA"
      refute line =~ "dXNlcjpwYXNz"
    end

    test "basic credentials in any case" do
      line = stored("sent basic dXNlcjpwYXNzd29yZA== and BASIC dXNlcjpwYXNz")
      assert line =~ "basic [redacted]"
      assert line =~ "BASIC [redacted]"
      refute line =~ "dXNlcjpwYXNzd29yZA"
      refute line =~ "dXNlcjpwYXNz"
    end

    test "basic as a word, not an auth scheme, is kept" do
      line = stored("running in basic mode with Basic Configuration")
      assert line =~ "basic mode with Basic Configuration"
    end

    test "URL userinfo" do
      line = stored("fetching https://deploy:hunter2@objects.example.com/bucket")
      assert line =~ "https://[redacted]@objects.example.com/bucket"
      refute line =~ "hunter2"
    end

    test "URL userinfo without a password, and a password holding an @" do
      line =
        stored("https://tok3n-only@a.example/x and https://user:p@ss-w0rd@b.example/y?q=1")

      assert line =~ "https://[redacted]@a.example/x"
      assert line =~ "https://[redacted]@b.example/y?q=1"
      for secret <- ["tok3n-only", "p@ss", "ss-w0rd"], do: refute(line =~ secret)
    end

    test "key and value pairs in an inspected map, a keyword list, a header tuple and a query" do
      line =
        stored(
          inspect(%{secret_access_key: "AbCdEf123456", region: "eu-west-1"}) <>
            " " <>
            inspect(password: "hunter22", client_secret: "cs-0099") <>
            " " <>
            inspect([{"authorization", "Bearer tok123456"}, {"x-api-key", "k3y-v4lue"}]) <>
            " " <>
            inspect(%{"refresh_token" => "rt-777"}) <>
            " token=qq111&next=2 x-optimal-grant: grant-abc bot_token=bt-1"
        )

      for secret <-
            ~w(AbCdEf123456 hunter22 cs-0099 tok123456 k3y-v4lue rt-777 qq111 grant-abc bt-1) do
        refute line =~ secret, "#{secret} survived: #{line}"
      end

      assert line =~ "eu-west-1"
      assert line =~ ~s(secret_access_key: "[redacted]")
      # An unquoted value ends at whitespace or at the next query parameter.
      assert line =~ "token=[redacted]&next=2 x-optimal-grant"
    end

    test "credential names at the end of longer names" do
      line =
        stored(
          "AWS_SECRET_ACCESS_KEY=wJal1 db_password=dbpw1 " <>
            inspect(%{"notion_token" => "nt-tok1"}) <> " slack_bot_token=sbt-1"
        )

      for secret <- ~w(wJal1 dbpw1 nt-tok1 sbt-1), do: refute(line =~ secret, "#{secret}: #{line}")
    end

    test "JSON inside an inspected string" do
      line = stored(inspect(~s({"password":"jpw-1","api_key":"jak-1"})))
      for secret <- ~w(jpw-1 jak-1), do: refute(line =~ secret, "#{secret}: #{line}")
    end

    test "charlist values" do
      line = stored(inspect(password: ~c"clpw-1") <> " secret: 'sqsec-1'")
      for secret <- ~w(clpw-1 sqsec-1), do: refute(line =~ secret, "#{secret}: #{line}")
    end

    test "a value is redacted to its end, not to its first separator" do
      line =
        stored(
          "password=tail1&tail2 authorization: Token tok-tail3 " <>
            inspect(%{password: "has space&more"})
        )

      for secret <- ["tail1", "tail2", "tok-tail3", "has space", "more"] do
        refute line =~ secret, "#{secret}: #{line}"
      end
    end

    # The token fixtures are assembled here, so none in the repository is key-shaped.
    test "provider tokens with a known prefix" do
      line =
        stored(
          Enum.join(
            [
              "sk" <> "-ant-api03-AbCdEfGh12345678",
              "sk" <> "_live_AbCdEfGh1234",
              "gh" <> "p_AbCdEfGh12345678",
              "xo" <> "xb-1234567890-abcdefgh",
              "ms" <> "k_AbCdEfGh1234",
              "mk" <> "i-AbCdEfGh1234"
            ],
            " "
          )
        )

      for secret <- ~w(AbCdEfGh12345678 AbCdEfGh1234 1234567890-abcdefgh) do
        refute line =~ secret, "#{secret} survived: #{line}"
      end
    end

    test "more provider prefixes" do
      line =
        stored(
          Enum.join(
            [
              "github" <> "_pat_11ABCDEFG0abcdefghijkl",
              "nt" <> "n_1234567890abcdefgh",
              "secret" <> "_AbCdEfGhIjKlMnOp",
              "ya" <> "29.a0AfH6SMBxyzxyzxyz",
              "rk" <> "_live_1234567890abcd",
              "wh" <> "sec_1234567890abcdef"
            ],
            " "
          )
        )

      for secret <-
            ~w(11ABCDEFG0abcdefghijkl 1234567890abcdef AbCdEfGhIjKlMnOp a0AfH6SMBxyzxyzxyz live_1234567890abcd) do
        refute line =~ secret, "#{secret}: #{line}"
      end
    end

    test "cloud access key ids and JWTs" do
      # Assembled here so the public audit never sees a key-shaped literal.
      access_key_id = "AKIA" <> String.duplicate("Q7", 8)

      jwt =
        Enum.join(["ey" <> "JhbGciOiJIUzI1NiJ9", "ey" <> "JzdWIiOiIxIn0", "c2lnbmF0dXJl-x_y"], ".")

      line = stored("#{access_key_id} #{jwt}")

      refute line =~ access_key_id
      refute line =~ "hbGciOiJIUzI1NiJ9"
    end

    test "ordinary text is kept" do
      line = stored("token count 512, tokens: 3, risk-assessment-v2, task_runner_12345678")
      refute line =~ "[redacted]"
    end
  end

  # Every secret of the later tests starts with "Zq", which nothing else in
  # their lines holds.
  defp zq(n), do: "Zq" <> String.duplicate("w8", 6) <> "n#{n}"

  defp marker, do: "drill-#{System.unique_integer([:positive])}"

  # A PEM boundary line, assembled so no fixture in the repository is one.
  defp pem(edge, kind), do: "-----" <> edge <> " " <> kind <> "PRIVATE" <> " KEY-----"

  defp ring_lines_with(marker) do
    %{lines: lines} = LogBuffer.recent(1_000)
    Enum.filter(lines, &String.contains?(&1, marker))
  end

  defmodule Holder do
    @moduledoc false
    use GenServer

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_cast(:crash, state), do: raise("crash for the log drill #{state.marker}")
  end

  describe "the second redaction pass" do
    test "authorization values in every form, scheme words included" do
      line =
        stored(
          inspect([{"authorization", String.to_charlist("Token #{zq(1)}")}]) <>
            " authorization: ApiKey #{zq(2)} " <>
            inspect({"authorization", ~s(Digest username="bob", response="#{zq(3)}")}) <>
            " Authorization: AWS4-HMAC-SHA256 Credential=#{zq(4)}/20261020/us-east-1/s3/aws4_request," <>
            " SignedHeaders=host, Signature=#{zq(5)}"
        )

      refute line =~ "Zq", line
      assert line =~ "SignedHeaders=host"
    end

    test "quoted values with escaped quotes, single quotes and backticks" do
      line =
        stored(
          inspect(%{password: ~s(a"#{zq(1)}"b)}) <>
            " secret: 'it\\'s #{zq(2)}' password=`#{zq(3)} x` done"
        )

      refute line =~ "Zq", line
      assert line =~ "done"
    end

    test "a query value stops at the next parameter" do
      line = stored("GET /cb?token=#{zq(1)}&next=2&state=ok")
      assert line =~ "token=[redacted]&next=2&state=ok"
      refute line =~ "Zq"
    end

    test "Erlang binaries and atom-named tuples" do
      line =
        stored(
          "#" <>
            "{password => <<\"#{zq(1)}\">>} {password,<<\"#{zq(2)}\">>} " <>
            inspect({:password, zq(3)}) <>
            " " <>
            inspect({:db_password, String.to_charlist(zq(4) <> " x")}) <>
            " {:api_key, #{zq(5)}}"
        )

      refute line =~ "Zq", line
    end

    test "short Basic credentials and a lowercase scheme" do
      line = stored("sent Basic YTpi and basic #{Base.encode64("u:" <> zq(1))}")
      refute line =~ "YTpi"
      refute line =~ Base.encode64("u:" <> zq(1))
      assert line =~ "Basic [redacted]"
    end

    test "more credential names, camelCase names and env-style keys" do
      line =
        stored(
          "private_key=#{zq(1)} secret-key: #{zq(2)} passwd=#{zq(3)} passphrase: #{zq(4)} " <>
            "signature=#{zq(5)} CONNECTOR_KEY=#{zq(6)} OPTIMAL_AUTHORITY_KEY=#{zq(7)} " <>
            ~s(apiKey: "#{zq(8)}" accessToken=#{zq(9)} clientSecret: #{zq(10)} dbPassword=#{zq(11)})
        )

      refute line =~ "Zq", line
      assert line =~ "apiKey: \"[redacted]\""
    end

    test "PEM private key blocks, closed or cut" do
      body = zq(1) <> String.duplicate("AB", 20)

      line =
        stored(
          "key #{pem("BEGIN", "RSA ")} #{body} #{pem("END", "RSA ")} then " <>
            "#{pem("BEGIN", "")} #{zq(2)}"
        )

      refute line =~ "Zq", line
      assert line =~ "key [redacted private key] then"
    end

    test "more provider prefixes, built here so no fixture is key-shaped" do
      keys = [
        "AI" <> "za" <> zq(1) <> String.duplicate("x9", 10) <> "y",
        "xa" <> "pp-1-" <> zq(2),
        "gl" <> "pat-" <> zq(3) <> "abcdef",
        "np" <> "m_" <> zq(4) <> String.duplicate("q1", 10),
        "h" <> "f_" <> "Zq" <> String.duplicate("abc", 11)
      ]

      for key <- keys do
        assert byte_size(key) > 20
        line = stored("using #{key} now")
        refute line =~ "Zq", line
        assert line =~ "now"
      end

      temporary_key_id = "AS" <> "IA" <> String.duplicate("R4", 8)
      refute stored("id #{temporary_key_id}") =~ temporary_key_id
    end

    test "bidi and invisible controls are replaced" do
      codes = [0x202E, 0x202A, 0x2066, 0x2069, 0x200B, 0x200F, 0xFEFF, 0x2060, 0x061C]
      chars = Enum.map(codes, &<<&1::utf8>>)
      line = stored("a" <> Enum.join(chars, "b") <> "c")
      for char <- chars, do: refute(line =~ char)
      assert line =~ "a?b?b?b?b?b?b?b?b?c"
    end

    test "crafted lines finish in bounded time" do
      for crafted <- [
            String.duplicate("eyJ", 5_000),
            String.duplicate("a", 15_000) <> ":",
            String.duplicate("a://", 3_500),
            String.duplicate("aKey", 3_500),
            String.duplicate("A_", 7_000),
            "password=\"" <> String.duplicate("\\\\", 7_000)
          ] do
        {micros, _line} = :timer.tc(fn -> stored(crafted) end)
        assert micros < 1_000_000, "#{byte_size(crafted)} bytes took #{micros} µs"
      end
    end

    test "redacting a redacted line changes nothing" do
      for message <- [
            "key oe_#{zq(1)} Bearer #{zq(2)} Basic YTpi https://u:#{zq(3)}@h.example/p",
            "token=#{zq(4)}&next=2 " <> inspect(%{"api_key" => zq(6), password: zq(5)}),
            "{:password, #{zq(7)}} #{pem("BEGIN", "")} #{zq(8)} #{pem("END", "")}",
            "sk-" <> zq(9) <> " AK" <> "IA" <> String.duplicate("Q7", 8)
          ] do
        once = LogBuffer.redact(message)
        assert LogBuffer.redact(once) == once
        refute once =~ "Zq", once
      end
    end
  end

  # These go through :logger and the handler the application installed, so
  # each event shape reaches the ring as it would in production.
  describe "secrets logged through the running Engine's logger" do
    test "Logger.error, a format with arguments, and a report" do
      m = marker()

      ExUnit.CaptureLog.capture_log(fn ->
        Logger.error("#{m} elixir password=#{zq(1)}")
        :logger.error(~c"~s erlang password=~s", [m, zq(2)])
        :logger.error(%{drill: m, password: zq(3), api_key: zq(4)})
      end)

      lines = ring_lines_with(m)
      assert length(lines) == 3, inspect(lines)
      for line <- lines, do: refute(line =~ "Zq", line)
    end

    test "a crashed GenServer with a secret in its state" do
      m = marker()

      ExUnit.CaptureLog.capture_log(fn ->
        {:ok, pid} = GenServer.start(__MODULE__.Holder, %{marker: m, password: zq(5)})
        ref = Process.monitor(pid)
        GenServer.cast(pid, :crash)
        assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 5_000
      end)

      lines = ring_lines_with(m)
      assert lines != []
      for line <- lines, do: refute(line =~ "Zq", line)
    end
  end

  test "control characters other than tab are replaced" do
    line = stored("\e[31mred\e[0m bell\a tab\there")
    refute line =~ "\e"
    refute line =~ "\a"
    assert line =~ "?[31mred?[0m bell? tab\there"
  end

  # A stored line is at most 4,096 bytes. Each case slides a secret across
  # that cut one character at a time; no part of it may stay. Every secret
  # starts with "Zq", which nothing else in the line contains.
  defp secret, do: "Zq" <> String.duplicate("9k", 20)

  defp across_the_cut(value) do
    for shift <- 0..130 do
      tail = " " <> String.duplicate("y", 200)
      line = stored(String.duplicate("x", 4_096 - 140 + shift) <> " " <> value <> tail)
      assert byte_size(line) <= 4_096
      assert String.ends_with?(line, "...")
      line
    end
  end

  describe "a line cut to its length" do
    test "a quoted value" do
      for line <- across_the_cut(~s(password="#{secret()}" done)),
          do: refute(line =~ "Zq", line)
    end

    test "the userinfo of a URL" do
      for line <- across_the_cut("https://Zqdrill:#{secret()}@host.example/path"),
          do: refute(line =~ "Zq", line)
    end

    test "an AWS access key id" do
      key = "AKIA" <> String.duplicate("Q7", 8)
      for line <- across_the_cut("key #{key} done"), do: refute(line =~ "AKIA", line)
    end

    test "a Bearer credential" do
      for line <- across_the_cut("Bearer #{secret()} done"), do: refute(line =~ "Zq", line)
    end

    test "a cut inside a multibyte character leaves valid UTF-8" do
      for shift <- 0..3 do
        line = stored(String.duplicate("x", shift) <> String.duplicate("é", 2_100))
        assert byte_size(line) <= 4_096
        assert String.valid?(line)
      end
    end
  end

  test "a quoted value without its closing quote is redacted to the end of the line" do
    for value <- ["password=\"Zq" <> String.duplicate("u", 12), "secret: 'Zq" <> "uuuu"] do
      line = stored("login " <> value)
      refute line =~ "Zq", line
      assert line =~ "[redacted]"
    end
  end

  test "C1 controls and the Unicode line and paragraph separators are replaced" do
    line = stored("a\u0085b\u009bc\u2028d\u2029e café")
    for char <- ["\u0085", "\u009b", "\u2028", "\u2029"], do: refute(line =~ char)
    assert line =~ "a?b?c?d?e café"
  end

  test "a level the logger rejects leaves the Engine running without the handler" do
    handler = :"log_buffer_bad_level_#{System.unique_integer([:positive])}"
    table = :"log_buffer_bad_level_table_#{System.unique_integer([:positive])}"

    ExUnit.CaptureLog.capture_log(fn ->
      assert {:ok, pid} =
               GenServer.start(LogBuffer, level: :loud, handler_id: handler, table: table)

      assert {:error, _not_found} = :logger.get_handler_config(handler)
      assert LogBuffer.recent(5, table) == %{lines: [], capacity: 1_000}
      GenServer.stop(pid)
    end)
  end

  test "never raises from the logger handler, even without a table" do
    assert LogBuffer.log(event("lost"), %{config: %{table: :no_such_table, capacity: 3}}) == :ok
    assert LogBuffer.recent(5, :no_such_table) == %{lines: [], capacity: 0}
  end
end
