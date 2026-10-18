defmodule OptimalEngine.Pipeline.DecompositionRunsTest do
  use ExUnit.Case, async: false

  alias OptimalEngine.MemoryCore.{SourcePackage, Store}
  alias OptimalEngine.Pipeline.Decomposer.ChunkTree
  alias OptimalEngine.Pipeline.DecompositionRuns
  alias OptimalEngine.WorkspaceTopology

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    suffix = System.unique_integer([:positive])

    {:ok, workspace} =
      WorkspaceTopology.create_workspace(%{slug: "decomp-#{suffix}", name: "Decomp #{suffix}"})

    source =
      SourcePackage.from_text(
        "# Plan\n\nFirst paragraph about the launch.\n\nSecond paragraph about the budget.",
        workspace_id: workspace.id,
        source_type: "test_note"
      )

    :ok = insert(source)
    %{ws: workspace.id, source: source, checkpoints: Path.join(tmp, "checkpoints")}
  end

  defp insert(source) do
    case Store.insert_source_package(source) do
      :ok -> :ok
      {:ok, _} -> :ok
      other -> other
    end
  end

  test "a deterministic run decomposes the source and checkpoints the output", %{
    ws: ws,
    source: source,
    checkpoints: dir
  } do
    assert {:ok, %{run: run, output: %ChunkTree{} = tree, attempts: [run]}} =
             DecompositionRuns.run(ws, source.id, checkpoint_dir: dir)

    assert run.status == "completed"
    assert run.strategy == "deterministic"
    assert run.attempt == 1
    assert run.input_bytes == byte_size(source.raw_text)
    assert run.output_units == length(tree.chunks)
    assert run.output_units > 0
    assert is_binary(run.completed_at)

    assert {:ok, checkpoint} = run.checkpoint_uri |> File.read!() |> Jason.decode()
    assert checkpoint["source_package_id"] == source.id
    assert length(checkpoint["output"]["chunks"]) == run.output_units

    assert {:ok, [listed]} = DecompositionRuns.list(ws, source_package_id: source.id)
    assert listed.id == run.id
  end

  test "an unavailable recursive sidecar falls back and both attempts are recorded", %{
    ws: ws,
    source: source,
    checkpoints: dir
  } do
    assert {:ok, %{run: run, attempts: [failed, run]}} =
             DecompositionRuns.run(ws, source.id,
               strategy: :recursive,
               command: "exit 3",
               script: Path.join(dir, "missing-script.py"),
               checkpoint_dir: dir
             )

    assert failed.strategy == "recursive"
    assert failed.status == "failed"
    assert failed.fallback_strategy == "deterministic"
    assert failed.error =~ "rlm"

    assert run.strategy == "fallback"
    assert run.status == "completed"
    assert run.attempt == 2
    assert File.regular?(run.checkpoint_uri)

    assert {:ok, runs} = DecompositionRuns.list(ws, source_package_id: source.id)
    assert runs |> Enum.map(& &1.status) |> Enum.sort() == ["completed", "failed"]
  end

  test "a recursive sidecar result is recorded with its model usage", %{
    ws: ws,
    source: source,
    checkpoints: dir
  } do
    script = Path.join(dir, "fake_rlm.sh")
    File.mkdir_p!(dir)

    File.write!(script, """
    grep -q "launch" || exit 9
    echo '{"strategy":"rlm","atoms":[{"text":"launch"},{"text":"budget"}],"iterations":3,"sub_model_calls":2}'
    """)

    assert {:ok, %{run: run, output: output}} =
             DecompositionRuns.run(ws, source.id,
               strategy: :recursive,
               command: "sh",
               script: script,
               checkpoint_dir: dir
             )

    assert run.strategy == "recursive"
    assert run.status == "completed"
    assert run.output_units == 2
    assert run.iterations == 3
    assert run.model_calls == 2
    assert length(output["atoms"]) == 2
  end

  test "runs are scoped to the source package's workspace", %{ws: ws, source: source} do
    assert {:error, :source_package_not_found} = DecompositionRuns.run(ws, "missing-source")
    assert {:error, :workspace_not_found} = DecompositionRuns.run("missing-workspace", source.id)

    assert {:error, {:unknown_strategy, :magic}} =
             DecompositionRuns.run(ws, source.id, strategy: :magic)

    assert {:ok, []} = DecompositionRuns.list(ws)
  end
end
