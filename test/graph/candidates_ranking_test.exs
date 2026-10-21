defmodule OptimalEngine.Graph.CandidatesRankingTest do
  @moduledoc """
  `Graph.graph_candidates/3` ranks contexts by how many query entities mention
  them, and contexts with the same count by id. Forty contexts, so the map that
  holds their counts is large enough that its iteration order is the hash's.
  """

  use ExUnit.Case, async: false

  import OptimalEngine.TestSupport.RetrievalFixtures

  alias OptimalEngine.Graph
  alias OptimalEngine.Store

  setup do
    token = token()
    workspace = "#{token}-w"
    on_exit(fn -> delete_workspaces([workspace]) end)
    {:ok, token: token, workspace: workspace}
  end

  defp mention(workspace, entity, context_id) do
    {:ok, _} =
      Store.raw_query(
        "INSERT INTO graph_edges (tenant_id, workspace_id, source_id, target_id, relation) VALUES ('default', ?3, ?1, ?2, 'mentioned_in')",
        [entity, context_id, workspace]
      )
  end

  defp context_ids(token, count) do
    for n <- 1..count, do: "#{token}-c-#{String.pad_leading(Integer.to_string(n), 2, "0")}"
  end

  test "contexts with the same count come back in id order, whatever order they were linked", ctx do
    entity = "entity-#{ctx.token}"
    ids = context_ids(ctx.token, 40)
    for id <- Enum.shuffle(ids), do: mention(ctx.workspace, entity, id)

    for _ <- 1..3 do
      assert {:ok, ranked} =
               Graph.graph_candidates([entity], 1, workspace_id: ctx.workspace, limit: 40)

      assert ranked == ids
    end

    assert {:ok, ranked} =
             Graph.graph_candidates([entity], 1, workspace_id: ctx.workspace, limit: 5)

    assert ranked == Enum.take(ids, 5)
  end

  test "a context several query entities mention comes first, the rest by id", ctx do
    first = "entity-a-#{ctx.token}"
    second = "entity-b-#{ctx.token}"
    ids = context_ids(ctx.token, 40)
    shared = List.last(ids)

    for id <- Enum.shuffle(ids), do: mention(ctx.workspace, first, id)
    mention(ctx.workspace, second, shared)

    assert {:ok, ranked} =
             Graph.graph_candidates([first, second], 1, workspace_id: ctx.workspace, limit: 4)

    assert ranked == [shared | Enum.take(ids, 3)]
  end
end
