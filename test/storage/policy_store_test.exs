defmodule OptimalEngine.Storage.PolicyStoreTest do
  use ExUnit.Case, async: false

  alias OptimalEngine.Storage.PolicyStore
  alias OptimalEngine.WorkspaceTopology

  setup do
    suffix = System.unique_integer([:positive])

    {:ok, workspace} =
      WorkspaceTopology.create_workspace(%{
        slug: "storage-policy-#{suffix}",
        name: "Storage Policy #{suffix}"
      })

    %{workspace: workspace}
  end

  test "persists versioned workspace storage policy", %{workspace: workspace} do
    assert {:ok, initial} = PolicyStore.get_policy(workspace.id)
    assert initial.policy_version == 1
    assert initial.use_cases == ["desktop_local"]

    assert {:ok, first} =
             PolicyStore.put_policy(workspace.id, ["desktop_local"], actor_id: "test")

    assert first.policy_version == 2
    assert first.use_cases == ["desktop_local"]

    assert {:ok, second} =
             PolicyStore.put_policy(workspace.id, ["desktop_local", "analytics"], actor_id: "test")

    assert second.policy_version == 3
    assert second.use_cases == ["desktop_local", "analytics"]
  end

  test "rejects unknown provider overrides", %{workspace: workspace} do
    assert {:error, {:unknown_providers, [:imaginary]}} =
             PolicyStore.put_policy(workspace.id, ["desktop_local"],
               provider_overrides: %{imaginary: "enabled"}
             )
  end

  test "append-only mutations are idempotent and workspace scoped", %{workspace: workspace} do
    attrs = %{
      workspace_id: workspace.id,
      device_id: "device-a",
      entity_type: "memory_object",
      entity_id: "memory-1",
      operation: :update,
      payload: %{"title" => "Updated"},
      idempotency_key: "mutation-#{workspace.id}"
    }

    assert {:ok, first} = PolicyStore.append_mutation(attrs)
    assert {:ok, second} = PolicyStore.append_mutation(attrs)
    assert first.sequence == second.sequence

    assert {:ok, [mutation]} = PolicyStore.mutations_after(workspace.id, 0)
    assert mutation.workspace_id == workspace.id
    assert mutation.payload == %{"title" => "Updated"}

    assert :ok = PolicyStore.advance_cursor(workspace.id, "replica-b", mutation.sequence)
    assert :ok = PolicyStore.advance_cursor(workspace.id, "replica-b", 0)
  end

  test "reusing a key for a different mutation in the same workspace is a conflict", %{
    workspace: workspace
  } do
    attrs = %{
      workspace_id: workspace.id,
      device_id: "device-a",
      entity_type: "memory_object",
      entity_id: "memory-1",
      operation: :update,
      payload: %{"title" => "First"},
      idempotency_key: "reuse-#{workspace.id}"
    }

    assert {:ok, original} = PolicyStore.append_mutation(attrs)

    for changed <- [
          %{attrs | payload: %{"title" => "Second"}},
          %{attrs | entity_id: "memory-2"},
          %{attrs | entity_type: "claim"},
          %{attrs | operation: :delete}
        ] do
      assert {:error, :idempotency_key_conflict} = PolicyStore.append_mutation(changed)
    end

    assert {:ok, replay} = PolicyStore.append_mutation(%{attrs | device_id: "device-b"})
    assert replay.sequence == original.sequence
    assert {:ok, [_only]} = PolicyStore.mutations_after(workspace.id, 0)
  end

  test "a colliding idempotency key never returns another workspace's mutation", %{
    workspace: workspace
  } do
    suffix = System.unique_integer([:positive])

    {:ok, other} =
      WorkspaceTopology.create_workspace(%{
        slug: "storage-policy-other-#{suffix}",
        name: "Storage Policy Other #{suffix}"
      })

    shared_key = "shared-key-#{suffix}"

    owner_attrs = %{
      workspace_id: workspace.id,
      device_id: "device-a",
      entity_type: "memory_object",
      entity_id: "memory-owner",
      operation: :create,
      payload: %{"secret" => "owner-only"},
      idempotency_key: shared_key
    }

    assert {:ok, owned} = PolicyStore.append_mutation(owner_attrs)
    assert owned.workspace_id == workspace.id

    intruder_attrs = %{
      owner_attrs
      | workspace_id: other.id,
        entity_id: "memory-intruder",
        payload: %{"secret" => "intruder"}
    }

    assert {:error, :idempotency_key_conflict} = PolicyStore.append_mutation(intruder_attrs)
    assert {:ok, []} = PolicyStore.mutations_after(other.id, 0)

    assert {:ok, replay} = PolicyStore.append_mutation(owner_attrs)
    assert replay.sequence == owned.sequence
    assert replay.payload == %{"secret" => "owner-only"}
  end
end
