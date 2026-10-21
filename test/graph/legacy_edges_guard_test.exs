defmodule OptimalEngine.Graph.LegacyEdgesGuardTest do
  @moduledoc """
  The baseline `edges` table is superseded by `graph_edges`
  and stays in the store unread for one release. Only the Store's baseline
  DDL and the migrations may name it in SQL; anything else that reads or
  writes it would read edges without their tenant, or write edges nothing
  reads.
  """

  use ExUnit.Case, async: true

  @allowed ~w(lib/optimal_engine/store/migrations.ex lib/optimal_engine/store/sqlite.ex)
  @sql ~r/\b(FROM|INTO|JOIN|UPDATE)(\s+OR\s+[A-Z]+)?\s+edges\b/

  test "no lib file outside the Store's DDL and the migrations names the edges table in SQL" do
    root = Path.expand("../..", __DIR__)

    files =
      root
      |> Path.join("lib/**/*.ex")
      |> Path.wildcard()
      |> Enum.map(&Path.relative_to(&1, root))
      |> Enum.reject(&(&1 in @allowed))

    assert length(files) > 100

    offenders =
      for relative <- files,
          {line, number} <-
            root |> Path.join(relative) |> File.read!() |> String.split("\n") |> Enum.with_index(1),
          Regex.match?(@sql, line) do
        "#{relative}:#{number}: #{String.trim(line)}"
      end

    assert offenders == [], "use graph_edges:\n" <> Enum.join(offenders, "\n")
  end
end
