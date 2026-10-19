defmodule OptimalEngine.Pipeline.IntakeDatabaseOnlyTest do
  @moduledoc """
  `write_files: false` stores a signal in the database only: no markdown file,
  no cross-reference copies, no summary sidecars. With a `:source_id` the row
  id is derived from the source and the workspace, so ingesting the same item
  again replaces its row instead of adding another; `:occurred_at` dates it.
  """

  use ExUnit.Case, async: false

  alias OptimalEngine.Pipeline.Intake
  alias OptimalEngine.Store

  setup do
    root =
      Path.join(System.tmp_dir!(), "optimal_intake_db_only_#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    original_root = Application.get_env(:optimal_engine, :root_path)
    Application.put_env(:optimal_engine, :root_path, root)

    on_exit(fn ->
      Application.put_env(:optimal_engine, :root_path, original_root)
      File.rm_rf!(root)
    end)

    %{root: root, workspace: "db-only-#{System.unique_integer([:positive])}"}
  end

  defp files_under(root), do: Path.wildcard(Path.join(root, "**/*.md"))

  defp rows(workspace) do
    {:ok, rows} =
      Store.raw_query(
        "SELECT id, uri, path, content, created_at FROM contexts WHERE workspace_id = ?1",
        [workspace]
      )

    rows
  end

  test "stores the signal without writing any file", ctx do
    occurred = ~U[2026-10-14 09:30:00Z]

    assert {:ok, result} =
             Intake.process("Pricing review moved to Thursday. Two plans stay.",
               workspace_id: ctx.workspace,
               write_files: false,
               source_id: "example:item-1",
               source_uri: "optimal://connectors/example/item-1",
               occurred_at: occurred
             )

    assert result.files_written == []
    assert result.cross_references == []
    assert result.uri == "optimal://connectors/example/item-1"

    # Summaries are generated asynchronously; give them time to (not) land.
    Process.sleep(300)
    assert files_under(ctx.root) == []

    assert [[id, uri, path, content, created_at]] = rows(ctx.workspace)
    assert id == result.context.id
    assert uri == "optimal://connectors/example/item-1"
    assert path in [nil, ""]
    assert content =~ "Pricing review moved to Thursday."
    assert created_at =~ "2026-10-14"
  end

  test "the same source ingested again replaces its row", ctx do
    opts = [workspace_id: ctx.workspace, write_files: false, source_id: "example:item-2"]

    {:ok, first} = Intake.process("Draft agenda for the kickoff.", opts)
    {:ok, second} = Intake.process("Final agenda for the kickoff, with owners.", opts)

    assert first.context.id == second.context.id
    assert [[_id, _uri, _path, content, _created]] = rows(ctx.workspace)
    assert content =~ "Final agenda"
  end

  test "the same source in two workspaces stays two rows", ctx do
    other = ctx.workspace <> "-b"

    {:ok, a} =
      Intake.process("Shared memo text.",
        workspace_id: ctx.workspace,
        write_files: false,
        source_id: "example:item-3"
      )

    {:ok, b} =
      Intake.process("Shared memo text.",
        workspace_id: other,
        write_files: false,
        source_id: "example:item-3"
      )

    refute a.context.id == b.context.id
    assert length(rows(ctx.workspace)) == 1
    assert length(rows(other)) == 1
  end

  test "without the option intake still writes its file", ctx do
    {:ok, result} = Intake.process("A note that belongs on disk.", workspace_id: ctx.workspace)
    assert [_written] = result.files_written
  end
end
