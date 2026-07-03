defmodule OptimalEngine.Store.VectorWorkspaceIsolationTest do
  use ExUnit.Case, async: false

  alias OptimalEngine.Context
  alias OptimalEngine.Store
  alias OptimalEngine.Store.Vectors

  defp insert_context!(id, workspace_id, title) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    ctx = %Context{
      id: id,
      uri: "optimal://inbox/#{id}.md",
      type: :signal,
      path: "/tmp/#{id}.md",
      title: title,
      content: title,
      l0_abstract: "SIGNAL | note | #{title}",
      l1_overview: title,
      signal: nil,
      node: "inbox",
      sn_ratio: 0.7,
      entities: [],
      created_at: now,
      modified_at: now,
      routed_to: [],
      workspace_id: workspace_id,
      metadata: %{}
    }

    :ok = Store.insert_context(ctx)
    ctx
  end

  test "vector search only scores candidates from the requested workspace" do
    suffix = System.unique_integer([:positive])
    ws_a = "vector-iso-a-#{suffix}"
    ws_b = "vector-iso-b-#{suffix}"

    a = insert_context!("vectorisoa#{suffix}", ws_a, "Workspace A private platform note")
    b = insert_context!("vectorisob#{suffix}", ws_b, "Workspace B private platform note")

    :ok = Vectors.store(a.id, [1.0, 0.0, 0.0])
    :ok = Vectors.store(b.id, [1.0, 0.0, 0.0])

    assert {:ok, hits_a} = Vectors.search([1.0, 0.0, 0.0], workspace_id: ws_a, limit: 10)
    assert Enum.map(hits_a, &elem(&1, 0)) == [a.id]

    assert {:ok, hits_b} = Vectors.search([1.0, 0.0, 0.0], workspace_id: ws_b, limit: 10)
    assert Enum.map(hits_b, &elem(&1, 0)) == [b.id]
  end
end
