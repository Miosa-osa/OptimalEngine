defmodule OptimalEngine.Store.DerivedDataIndexesMigrationTest do
  @moduledoc """
  The derived data delete indexes exist after the migrations, the statements are safe to
  run again, and the deletes and cascades they were added for read by an index instead of
  scanning the table.
  """

  use ExUnit.Case, async: false

  alias OptimalEngine.Store
  alias OptimalEngine.Store.Migrations

  # table, column the delete or cascade selects by
  @read_by [
    {"chunks", "signal_id"},
    {"cluster_members", "chunk_id"},
    {"citations", "chunk_id"},
    {"decisions", "context_id"},
    {"claims", "signal_id"},
    {"entity_mentions", "context_id"},
    {"entity_mentions", "source_package_id"},
    {"resolution_decisions", "mention_id"},
    {"decomposition_runs", "source_package_id"},
    {"assets", "storage_path"},
    {"asset_adapter_runs", "asset_id"},
    {"asset_extractions", "asset_id"},
    {"asset_transcripts", "asset_id"},
    {"asset_ocr_spans", "asset_id"},
    {"asset_visual_observations", "asset_id"},
    {"asset_embedding_refs", "asset_id"}
  ]

  # Found by its description, not its place: later migrations come after it.
  defp migration do
    Enum.find(Migrations.all(), fn {_version, description, _statements} ->
      description == "derived data: indexes the delete paths read by"
    end)
  end

  test "is a recorded migration, and only creates indexes" do
    assert {version, _description, statements} = migration()
    assert version <= OptimalEngine.Version.info().expected_migration
    assert length(statements) == length(@read_by)

    for {_label, sql} <- statements do
      assert sql =~ ~r/\ACREATE INDEX IF NOT EXISTS /
    end
  end

  test "running its statements again changes nothing" do
    {_version, _description, statements} = migration()

    for _run <- 1..2, {_label, sql} <- statements do
      assert {:ok, _} = Store.raw_query(sql, [])
    end
  end

  for {table, column} <- @read_by do
    test "#{table} is read by #{column} through an index" do
      {:ok, plan} =
        Store.raw_query(
          "EXPLAIN QUERY PLAN SELECT 1 FROM #{unquote(table)} WHERE #{unquote(column)} = ?1",
          ["x"]
        )

      details = plan |> Enum.map(&List.last/1) |> Enum.join(" | ")
      index = "idx_#{unquote(table)}_#{unquote(column)}"

      assert details =~ "USING INDEX #{index}" or details =~ "USING COVERING INDEX #{index}",
             details

      refute details =~ "SCAN #{unquote(table)}", details
    end
  end
end
