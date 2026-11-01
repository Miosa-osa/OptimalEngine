defmodule OptimalEngine.Store.SQLiteBusyTimeoutTest do
  @moduledoc """
  Another process can hold the database's write lock for a moment (a capture
  script, the sqlite3 CLI, a backup). The Store's connection waits for it
  instead of answering busy at once, and a statement that still finds it busy
  answers {:error, :busy} rather than crashing the Store.
  """

  use ExUnit.Case, async: false

  alias OptimalEngine.Store

  test "the Store's connection waits up to 3 s for a lock another process holds" do
    assert {:ok, [[3_000]]} = Store.raw_query("PRAGMA busy_timeout", [])
  end
end
