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

  test "redacts API keys and bearer tokens before a line is stored" do
    {table, config} = ring(5)
    LogBuffer.log(event("key oe_9f8e7d_abc-DEF_123 and Authorization: Bearer xyz.789"), config)

    assert %{lines: [line]} = LogBuffer.recent(5, table)
    assert line =~ "oe_9f8e7d_[redacted]"
    assert line =~ "Bearer [redacted]"
    refute line =~ "abc-DEF_123"
    refute line =~ "xyz.789"
  end

  test "never raises from the logger handler, even without a table" do
    assert LogBuffer.log(event("lost"), %{config: %{table: :no_such_table, capacity: 3}}) == :ok
    assert LogBuffer.recent(5, :no_such_table) == %{lines: [], capacity: 0}
  end
end
