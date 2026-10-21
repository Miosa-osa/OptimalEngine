defmodule OptimalEngine.Sync.CaptureExcludedTest do
  @moduledoc """
  Capture never runs on a table the Engine excludes from replication. A
  trigger an older binary put on such a table (it did not yet exclude
  `workspace_handles`) is dropped when the current binary installs capture.
  """

  use ExUnit.Case, async: false

  alias OptimalEngine.Store
  alias OptimalEngine.Sync.Capture

  @stray "sync_capture_ai_workspace_handles"

  defp triggers_on(table) do
    {:ok, rows} =
      Store.raw_query(
        "SELECT name FROM sqlite_master WHERE type = 'trigger' AND tbl_name = ?1 AND name LIKE 'sync_capture_%' ORDER BY name",
        [table]
      )

    List.flatten(rows)
  end

  defp plant_stray_trigger do
    :ok =
      Store.raw_execute(
        "CREATE TRIGGER IF NOT EXISTS #{@stray} AFTER INSERT ON workspace_handles BEGIN SELECT 1; END",
        []
      )

    assert triggers_on("workspace_handles") == [@stray]
  end

  test "install removes capture triggers from an excluded table and keeps the others" do
    plant_stray_trigger()

    assert {:ok, %{tables: tables}} = Capture.install()
    assert tables > 0

    assert triggers_on("workspace_handles") == []
    assert "sync_capture_ai_contexts" in triggers_on("contexts")
  end

  test "installing one excluded table drops its stray triggers too" do
    plant_stray_trigger()

    assert Capture.install("workspace_handles") == {:skipped, :excluded}
    assert triggers_on("workspace_handles") == []
  end

  test "a table that is not replicated is excluded, whether or not it has a workspace_id" do
    # Only the replicated list is captured: a table that merely has no
    # workspace_id column is excluded like any other, not left alone.
    assert Capture.install("schema_migrations") == {:skipped, :excluded}
    assert Capture.install("workspace_members") == {:skipped, :excluded}
  end
end
