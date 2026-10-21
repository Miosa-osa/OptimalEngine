defmodule OptimalEngine.Retrieval.GrepRankingTest do
  @moduledoc """
  Grep orders its matches by the exact chunk score. Matches of equal score keep
  the order of the search hits they come from, then the order of the chunks in
  their document, and every match carries the URI of its context.
  """

  use ExUnit.Case, async: false

  import OptimalEngine.TestSupport.RetrievalFixtures

  alias OptimalEngine.Retrieval.Grep
  alias OptimalEngine.Store

  @as_of ~U[2026-10-20 12:00:00Z]

  setup do
    token = token()
    workspace = "#{token}-w"
    on_exit(fn -> delete_workspaces([workspace]) end)
    {:ok, token: token, workspace: workspace}
  end

  defp insert_chunk(workspace, id, context_id, scale, offset, text) do
    {:ok, _} =
      Store.raw_query(
        "INSERT INTO chunks (id, tenant_id, signal_id, scale, offset_bytes, text, workspace_id) VALUES (?1, 'default', ?2, ?3, ?4, ?5, ?6)",
        [id, context_id, scale, offset, text, workspace]
      )
  end

  test "matches of one document tie in document order, not in the order of their ids", ctx do
    [uri] = uris(ctx.token, 1)
    insert_context(ctx.workspace, "#{ctx.token}-doc", uri, ctx.token)

    # Id order is p-10 before p-2; document order is the reverse.
    insert_chunk(
      ctx.workspace,
      "#{ctx.token}-p-10",
      "#{ctx.token}-doc",
      "paragraph",
      900,
      "#{ctx.token} tenth paragraph"
    )

    insert_chunk(
      ctx.workspace,
      "#{ctx.token}-p-2",
      "#{ctx.token}-doc",
      "paragraph",
      100,
      "#{ctx.token} second paragraph"
    )

    insert_chunk(
      ctx.workspace,
      "#{ctx.token}-p-3",
      "#{ctx.token}-doc",
      "paragraph",
      300,
      "#{ctx.token} third paragraph"
    )

    for _ <- 1..3 do
      assert {:ok, matches} = Grep.grep(ctx.token, workspace_id: ctx.workspace, as_of: @as_of)
      assert length(matches) == 3

      assert Enum.map(matches, & &1.snippet) ==
               Enum.map(["second", "third", "tenth"], &"#{ctx.token} #{&1} paragraph")

      assert matches |> Enum.map(& &1.score) |> Enum.uniq() |> length() == 1
    end
  end

  test "matches of equal score from different documents follow the order of the hits", ctx do
    uris = uris(ctx.token, 4)

    for {uri, n} <- uris |> Enum.with_index(1) |> Enum.reverse() do
      id = "#{ctx.token}-#{n}"
      insert_context(ctx.workspace, id, uri, ctx.token)
      insert_chunk(ctx.workspace, "#{id}-c", id, "chunk", 0, "#{ctx.token} chunk of document #{n}")
    end

    for _ <- 1..3 do
      assert {:ok, matches} = Grep.grep(ctx.token, workspace_id: ctx.workspace, as_of: @as_of)
      assert Enum.map(matches, & &1.uri) == uris
    end

    assert {:ok, matches} =
             Grep.grep(ctx.token, workspace_id: ctx.workspace, as_of: @as_of, limit: 2)

    assert Enum.map(matches, & &1.uri) == Enum.take(uris, 2)
  end

  test "every match carries the uri of its context, with or without chunks", ctx do
    [with_chunk, without_chunk] = uris(ctx.token, 2)
    insert_context(ctx.workspace, "#{ctx.token}-with", with_chunk, ctx.token)
    insert_context(ctx.workspace, "#{ctx.token}-without", without_chunk, ctx.token)

    insert_chunk(
      ctx.workspace,
      "#{ctx.token}-c",
      "#{ctx.token}-with",
      "chunk",
      0,
      "#{ctx.token} chunk text"
    )

    assert {:ok, matches} = Grep.grep(ctx.token, workspace_id: ctx.workspace)
    assert matches |> Enum.map(& &1.uri) |> Enum.sort() == [with_chunk, without_chunk]
  end

  test "GET /api/grep returns the uri of each match", ctx do
    [uri] = uris(ctx.token, 1)
    insert_context(ctx.workspace, "#{ctx.token}-doc", uri, ctx.token)

    insert_chunk(
      ctx.workspace,
      "#{ctx.token}-c",
      "#{ctx.token}-doc",
      "chunk",
      0,
      "#{ctx.token} chunk text"
    )

    conn = get("/api/grep?q=#{ctx.token}&workspace=#{ctx.workspace}&as_of=2026-10-20T12:00:00Z")
    assert conn.status == 200
    assert [%{"uri" => ^uri, "snippet" => snippet}] = Jason.decode!(conn.resp_body)["results"]
    assert snippet =~ "chunk text"
  end
end
