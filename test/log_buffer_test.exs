defmodule OptimalEngine.LogBufferTest do
  @moduledoc """
  The in-memory log ring behind `GET /api/maintenance/log`: bounded, oldest
  first, one line per event, and never holding a key.
  """

  use ExUnit.Case, async: true

  alias OptimalEngine.LogBuffer

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

      assert line =~ "oe_#{@key_id}_[redacted]"
      for secret <- ["abc-DEF_123", "ghi456", "jkl789"], do: refute(line =~ secret)
    end

    test "bearer tokens" do
      line = stored("sent Bearer xyz.789-tok")
      assert line =~ "Bearer [redacted]"
      refute line =~ "xyz.789-tok"
    end

    test "basic credentials" do
      line = stored("sent Basic dXNlcjpwYXNzd29yZA==")
      assert line =~ "Basic [redacted]"
      refute line =~ "dXNlcjpwYXNzd29yZA"
    end

    test "URL userinfo" do
      line = stored("fetching https://deploy:hunter2@objects.example.com/bucket")
      assert line =~ "https://[redacted]@objects.example.com/bucket"
      refute line =~ "hunter2"
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
      assert line =~ "next=2"
    end

    test "provider tokens with a known prefix" do
      line =
        stored(
          "sk-ant-api03-AbCdEfGh12345678 sk_live_AbCdEfGh1234 ghp_AbCdEfGh12345678 " <>
            "xoxb-1234567890-abcdefgh msk_AbCdEfGh1234 mki-AbCdEfGh1234"
        )

      for secret <- ~w(AbCdEfGh12345678 AbCdEfGh1234 1234567890-abcdefgh) do
        refute line =~ secret, "#{secret} survived: #{line}"
      end
    end

    test "cloud access key ids and JWTs" do
      # Assembled here so the public audit never sees a key-shaped literal.
      access_key_id = "AKIA" <> String.duplicate("Q7", 8)
      line = stored("#{access_key_id} eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.c2lnbmF0dXJl-x_y")

      refute line =~ access_key_id
      refute line =~ "eyJhbGciOiJIUzI1NiJ9"
    end

    test "ordinary text is kept" do
      line = stored("token count 512, tokens: 3, risk-assessment-v2, task_runner_12345678")
      refute line =~ "[redacted]"
    end
  end

  test "control characters other than tab are replaced" do
    line = stored("\e[31mred\e[0m bell\a tab\there")
    refute line =~ "\e"
    refute line =~ "\a"
    assert line =~ "?[31mred?[0m bell? tab\there"
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
