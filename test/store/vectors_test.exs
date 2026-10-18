defmodule OptimalEngine.Store.VectorsTest do
  use ExUnit.Case, async: false

  alias OptimalEngine.Context
  alias OptimalEngine.Store
  alias OptimalEngine.Store.Vectors

  setup do
    %{ws: "vectors-#{System.unique_integer([:positive])}"}
  end

  defp context!(ws, suffix) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    id = "vectors-#{suffix}-#{System.unique_integer([:positive])}"

    :ok =
      Store.insert_context(%Context{
        id: id,
        uri: "optimal://inbox/#{id}.md",
        type: :signal,
        path: "/store-reality/#{id}.md",
        title: id,
        content: id,
        l0_abstract: id,
        l1_overview: id,
        node: "inbox",
        created_at: now,
        modified_at: now,
        workspace_id: ws
      })

    id
  end

  test "stores, reads back, and ranks by cosine similarity", %{ws: ws} do
    near = context!(ws, "near")
    far = context!(ws, "far")
    :ok = Vectors.store(near, [1.0, 0.0, 0.0])
    :ok = Vectors.store(far, [0.0, 1.0, 0.0])

    assert {:ok, [1.0, +0.0, +0.0]} = Vectors.get(near)
    assert {:ok, [{^near, top}, {^far, low}]} = Vectors.search([0.9, 0.1, 0.0], workspace_id: ws)
    assert top > low
  end

  test "rejects empty and non-numeric embeddings without writing", %{ws: ws} do
    id = context!(ws, "invalid")
    assert {:error, :invalid_embedding} = Vectors.store(id, [])
    assert {:error, :invalid_embedding} = Vectors.store(id, [1.0, "x"])
    assert {:error, :not_found} = Vectors.get(id)
  end

  test "search never scores vectors of a different dimension", %{ws: ws} do
    same = context!(ws, "same-dim")
    other = context!(ws, "other-dim")
    :ok = Vectors.store(same, [1.0, 0.0, 0.0])
    :ok = Vectors.store(other, [1.0, 0.0])

    assert {:ok, [{^same, _score}]} = Vectors.search([1.0, 0.0, 0.0], workspace_id: ws)
  end
end
