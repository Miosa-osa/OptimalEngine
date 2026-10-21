defmodule OptimalEngine.Store.AssetForeignKeyIndexesMigrationTest do
  @moduledoc """
  The foreign keys the asset tables cascade by lead an index, so deleting one extraction,
  one adapter run or one source package does not scan each child table.
  """

  use ExUnit.Case, async: false

  alias OptimalEngine.Store
  alias OptimalEngine.Store.Migrations

  @children ~w(asset_transcripts asset_ocr_spans asset_visual_observations asset_embedding_refs)

  # table, column
  @indexed Enum.flat_map(@children, fn table ->
             for column <- ~w(extraction_id adapter_run_id source_package_id), do: {table, column}
           end) ++ [{"asset_extractions", "source_package_id"}]

  test "only creates indexes, one per foreign key, named idx_<table>_<column>" do
    {_version, _description, statements} = migration()

    assert Enum.sort(Enum.map(statements, &elem(&1, 0))) ==
             Enum.sort(for {table, column} <- @indexed, do: "idx_#{table}_#{column}")

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

  for {table, column} <- @indexed do
    test "#{table} is read by #{column} through idx_#{table}_#{column}" do
      {:ok, plan} =
        Store.raw_query(
          "EXPLAIN QUERY PLAN SELECT 1 FROM #{unquote(table)} WHERE #{unquote(column)} = ?1",
          ["x"]
        )

      details = plan |> Enum.map(&List.last/1) |> Enum.join(" | ")
      assert details =~ "idx_#{unquote(table)}_#{unquote(column)}", details
    end
  end

  test "the cascades the indexes are for still work" do
    n = System.unique_integer([:positive])
    asset = "fk-asset-#{n}"
    run = "fk-run-#{n}"
    extraction = "fk-extraction-#{n}"

    sql!(
      "INSERT INTO assets (id, tenant_id, content_type, size_bytes, storage_path) VALUES (?1, 'default', 'text/plain', 1, 'x')",
      [asset]
    )

    sql!(
      "INSERT INTO asset_adapter_runs (id, tenant_id, workspace_id, asset_id, adapter_id, adapter_role, modality, status, started_at) VALUES (?1, 'default', 'default', ?2, 'a', 'ocr', 'text', 'ok', datetime('now'))",
      [run, asset]
    )

    sql!(
      "INSERT INTO asset_extractions (id, tenant_id, workspace_id, asset_id, adapter_run_id, extraction_type, modality) VALUES (?1, 'default', 'default', ?2, ?3, 'text', 'text')",
      [extraction, asset, run]
    )

    sql!(
      "INSERT INTO asset_transcripts (id, tenant_id, workspace_id, asset_id, adapter_run_id, extraction_id, transcript_text) VALUES (?1, 'default', 'default', ?2, ?3, ?4, 'said')",
      ["fk-transcript-#{n}", asset, run, extraction]
    )

    sql!("DELETE FROM asset_extractions WHERE id = ?1", [extraction])

    assert {:ok, [[0]]} =
             Store.raw_query("SELECT COUNT(*) FROM asset_transcripts WHERE extraction_id = ?1", [
               extraction
             ])

    sql!("DELETE FROM assets WHERE id = ?1", [asset])
  end

  defp migration, do: Enum.find(Migrations.all(), &(elem(&1, 1) =~ "asset tables"))

  defp sql!(sql, params) do
    {:ok, _} = Store.raw_query(sql, params)
    :ok
  end
end
