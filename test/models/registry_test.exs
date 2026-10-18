defmodule OptimalEngine.Models.RegistryTest do
  use ExUnit.Case, async: false

  alias OptimalEngine.Models.Registry
  alias OptimalEngine.WorkspaceTopology

  @moduletag :tmp_dir

  setup do
    suffix = System.unique_integer([:positive])

    {:ok, workspace} =
      WorkspaceTopology.create_workspace(%{slug: "models-#{suffix}", name: "Models #{suffix}"})

    %{ws: workspace.id}
  end

  defp example(ws, n, extra \\ %{}) do
    Registry.add_example(
      ws,
      Map.merge(
        %{input: "question #{n}", expected_output: "answer #{n}", purpose: "support"},
        extra
      )
    )
  end

  defp completed_run(ws) do
    {:ok, ex} = example(ws, System.unique_integer([:positive]), %{consent_basis: "contract"})
    {:ok, _} = Registry.approve_example(ws, ex.id)

    {:ok, run} =
      Registry.create_run(ws, %{
        base_model: "base-small",
        trainer: "local",
        method: "lora",
        dataset_query: %{"purpose" => "support"}
      })

    {:ok, _} = Registry.start_run(ws, run.id)
    {:ok, run} = Registry.complete_run(ws, run.id, %{"loss" => 0.12})
    run
  end

  defp artifact(tmp, name, bytes) do
    path = Path.join(tmp, name)
    File.write!(path, bytes)
    {path, :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)}
  end

  test "examples are content-addressed and require consent to approve", %{ws: ws} do
    assert {:ok, ex} = example(ws, 1)
    assert ex.status == "candidate"
    assert ex.organization_id
    assert String.starts_with?(ex.content_hash, "sha256:")

    assert {:ok, same} = example(ws, 1)
    assert same.id == ex.id

    assert {:error, :consent_required} = Registry.approve_example(ws, ex.id)
    assert {:ok, approved} = Registry.approve_example(ws, ex.id, consent_basis: "user opt-in")
    assert approved.status == "approved"
    assert approved.consent_basis == "user opt-in"
    assert is_binary(approved.approved_at)

    assert {:error, {:invalid_transition, "approved", "rejected"}} =
             Registry.reject_example(ws, ex.id)

    assert {:ok, [listed]} = Registry.list_examples(ws, status: "approved")
    assert listed.id == ex.id
    assert {:error, :not_found} = Registry.get_example("another-workspace", ex.id)
  end

  test "runs need approved examples and follow the run lifecycle", %{ws: ws} do
    {:ok, ex} = example(ws, 2)

    run_attrs = %{
      base_model: "base-small",
      trainer: "local",
      method: "lora",
      dataset_query: %{"purpose" => "support"}
    }

    assert {:error, :no_approved_examples} = Registry.create_run(ws, run_attrs)
    {:ok, _} = Registry.approve_example(ws, ex.id, consent_basis: "contract")

    assert {:ok, run} = Registry.create_run(ws, run_attrs)
    assert run.status == "queued"
    assert run.metrics == %{"approved_examples" => 1}

    assert {:error, {:invalid_transition, "queued", "completed"}} =
             Registry.complete_run(ws, run.id, %{})

    assert {:ok, %{status: "running", started_at: started}} = Registry.start_run(ws, run.id)
    assert is_binary(started)
    assert {:ok, done} = Registry.complete_run(ws, run.id, %{"loss" => 0.2})
    assert done.status == "completed"
    assert done.metrics == %{"approved_examples" => 1, "loss" => 0.2}

    assert {:error, {:invalid_transition, "completed", "failed"}} =
             Registry.fail_run(ws, run.id, "x")

    {:ok, failing} = Registry.create_run(ws, run_attrs)

    assert {:ok, %{status: "failed", error: "trainer crashed"}} =
             Registry.fail_run(ws, failing.id, "trainer crashed")
  end

  test "adapters version per kind, verify local artifacts, and activate one at a time", %{
    ws: ws,
    tmp_dir: tmp
  } do
    run = completed_run(ws)
    {path_a, sum_a} = artifact(tmp, "adapter-a.bin", "weights-a")
    {path_b, sum_b} = artifact(tmp, "adapter-b.bin", "weights-b")

    base = %{training_run_id: run.id, adapter_type: "lora"}

    assert {:error, {:checksum_mismatch, _, _}} =
             Registry.register_adapter(
               ws,
               Map.merge(base, %{artifact_uri: path_a, checksum_sha256: sum_b})
             )

    assert {:error, {:artifact_missing, _}} =
             Registry.register_adapter(
               ws,
               Map.merge(base, %{artifact_uri: Path.join(tmp, "gone.bin"), checksum_sha256: sum_a})
             )

    assert {:ok, v1} =
             Registry.register_adapter(
               ws,
               Map.merge(base, %{artifact_uri: path_a, checksum_sha256: sum_a})
             )

    assert {:ok, v2} =
             Registry.register_adapter(
               ws,
               Map.merge(base, %{artifact_uri: "file://" <> path_b, checksum_sha256: sum_b})
             )

    assert {v1.version, v2.version} == {1, 2}
    assert v1.base_model == "base-small"
    assert v1.status == "candidate"

    assert {:ok, %{status: "active"}} = Registry.activate_adapter(ws, v1.id)
    assert {:ok, %{id: active_id}} = Registry.active_adapter(ws, "base-small", "lora")
    assert active_id == v1.id

    assert {:ok, %{status: "active"}} = Registry.activate_adapter(ws, v2.id)
    assert {:ok, %{status: "retired"}} = Registry.get_adapter(ws, v1.id)
    assert {:ok, %{id: current}} = Registry.active_adapter(ws, "base-small", "lora")
    assert current == v2.id
    assert {:error, :already_active} = Registry.activate_adapter(ws, v2.id)

    assert {:ok, [_, _]} = Registry.list_adapters(ws, adapter_type: "lora")
  end

  test "adapters require a completed run in the same workspace", %{ws: ws, tmp_dir: tmp} do
    {path, sum} = artifact(tmp, "early.bin", "early")
    {:ok, ex} = example(ws, 3, %{consent_basis: "contract"})
    {:ok, _} = Registry.approve_example(ws, ex.id)

    {:ok, queued} =
      Registry.create_run(ws, %{base_model: "base-small", trainer: "local", method: "lora"})

    attrs = %{
      training_run_id: queued.id,
      adapter_type: "lora",
      artifact_uri: path,
      checksum_sha256: sum
    }

    assert {:error, {:run_not_completed, "queued"}} = Registry.register_adapter(ws, attrs)
    assert {:error, :not_found} = Registry.register_adapter("another-workspace", attrs)

    run = completed_run(ws)

    assert {:error, :invalid_checksum} =
             Registry.register_adapter(ws, %{
               attrs
               | training_run_id: run.id,
                 checksum_sha256: "nope"
             })
  end

  test "unknown workspaces and missing fields are refused", %{ws: ws} do
    assert {:error, :workspace_not_found} =
             Registry.add_example("missing-workspace", %{
               input: "a",
               expected_output: "b",
               purpose: "c"
             })

    assert {:error, {:missing_field, :purpose}} =
             Registry.add_example(ws, %{input: "a", expected_output: "b"})
  end
end
