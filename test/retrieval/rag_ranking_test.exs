defmodule OptimalEngine.Retrieval.RagRankingTest do
  @moduledoc """
  What `RAG.ask/2` delivers under a tight token budget is the best of what it
  retrieved, in the order it was retrieved, on every call.

  The planner that packs the budget orders by exact score, then by URI. A path
  that hands it items of one displayed score has to hand it their order too, or
  the budget drops by URI and not by relevance.
  """

  use ExUnit.Case, async: false

  import OptimalEngine.TestSupport.RetrievalFixtures

  alias OptimalEngine.Retrieval.{RAG, Receiver}
  alias OptimalEngine.Store

  @as_of ~U[2026-10-20 12:00:00Z]

  setup do
    token = token()
    workspace = "#{token}-w"
    on_exit(fn -> delete_workspaces([workspace]) end)
    {:ok, token: token, workspace: workspace}
  end

  # A budget that fits one of the small items below and not two.
  defp tight_receiver, do: Receiver.new(%{format: :plain, token_budget: 100})

  defp insert_memory(workspace, id, content) do
    {:ok, _} =
      Store.raw_query(
        "INSERT INTO memories (id, workspace_id, content, root_memory_id, created_at, updated_at) VALUES (?1, ?2, ?3, ?1, '2026-10-10 12:00:00', '2026-10-10 12:00:00')",
        [id, workspace, content]
      )
  end

  describe "memories" do
    test "survive a tight budget in the order Memory.list gave them, not in id order", ctx do
      # `mem-z` is the better match (shorter text, so the better BM25) and has
      # the later id. Under a budget for one memory, the one kept is the better.
      insert_memory(
        ctx.workspace,
        "mem-a-#{ctx.token}",
        "#{ctx.token} and a good many other words here"
      )

      insert_memory(ctx.workspace, "mem-z-#{ctx.token}", ctx.token)

      listed =
        OptimalEngine.Memory.list(workspace_id: ctx.workspace, q: ctx.token, limit: 5)
        |> Enum.map(& &1.id)

      assert listed == ["mem-z-#{ctx.token}", "mem-a-#{ctx.token}"]

      for _ <- 1..3 do
        assert {:ok, result} =
                 RAG.ask(ctx.token,
                   receiver: tight_receiver(),
                   workspace_id: ctx.workspace,
                   memory_limit: 5,
                   skip_intent: true,
                   skip_wiki: true
                 )

        assert result.source == :memory
        assert result.trace.truncated?
        assert result.envelope.sources == ["optimal://memory/mem-z-#{ctx.token}"]
      end
    end

    test "all fit when the budget is ample, still in the listed order", ctx do
      insert_memory(
        ctx.workspace,
        "mem-a-#{ctx.token}",
        "#{ctx.token} and a good many other words here"
      )

      insert_memory(ctx.workspace, "mem-z-#{ctx.token}", ctx.token)

      assert {:ok, result} =
               RAG.ask(ctx.token,
                 receiver: Receiver.new(%{format: :plain, token_budget: 5_000}),
                 workspace_id: ctx.workspace,
                 memory_limit: 5,
                 skip_intent: true,
                 skip_wiki: true
               )

      assert result.envelope.sources ==
               ["optimal://memory/mem-z-#{ctx.token}", "optimal://memory/mem-a-#{ctx.token}"]
    end
  end

  describe "search hits" do
    setup ctx do
      older = DateTime.add(stored_at(), -1, :second)

      # The older one sorts first by URI and is stored first; only the exact
      # score, which the displayed score cannot show, names the newer one.
      insert_context(
        ctx.workspace,
        "#{ctx.token}-old",
        "optimal://nodes/ranking/#{ctx.token}/a-old",
        ctx.token,
        modified_at: older,
        content: "#{ctx.token} the older of two near ties"
      )

      insert_context(
        ctx.workspace,
        "#{ctx.token}-new",
        "optimal://nodes/ranking/#{ctx.token}/b-new",
        ctx.token,
        modified_at: stored_at(),
        content: "#{ctx.token} the newer of two near ties"
      )

      :ok
    end

    test "reach the planner with their exact scores, so the budget keeps the better", ctx do
      for _ <- 1..3 do
        assert {:ok, result} =
                 RAG.ask(ctx.token,
                   receiver: tight_receiver(),
                   workspace_id: ctx.workspace,
                   skip_intent: true,
                   skip_wiki: true,
                   hybrid_limit: 10,
                   as_of: @as_of
                 )

        assert result.source == :chunks
        assert result.trace.truncated?
        assert result.envelope.sources == ["optimal://nodes/ranking/#{ctx.token}/b-new"]
      end
    end
  end

  describe "as_of" do
    test "that is not valid is an error, never an empty answer", ctx do
      assert {:error, {:invalid_as_of, "nope"}} =
               RAG.ask(ctx.token, workspace_id: ctx.workspace, skip_wiki: true, as_of: "nope")

      assert {:error, {:invalid_as_of, "1900-01-01"}} =
               RAG.ask(ctx.token,
                 workspace_id: ctx.workspace,
                 context_package: true,
                 as_of: "1900-01-01"
               )
    end

    test "is a 400 on the routes that retrieve", ctx do
      assert (conn = post("/api/rag", %{"query" => ctx.token, "as_of" => "nope"})).status == 400
      assert Jason.decode!(conn.resp_body)["error"] =~ "as_of"

      assert get("/api/rag/stream?query=#{ctx.token}&as_of=nope").status == 400
      assert get("/api/recall/who?topic=#{ctx.token}&as_of=nope").status == 400
      assert get("/api/recall/where?thing=#{ctx.token}&as_of=1900-01-01").status == 400

      for path <- ["/api/assemble", "/api/reconstruct"] do
        assert post(path, %{"query" => ctx.token, "as_of" => "nope"}).status == 400
        assert post(path, %{"query" => ctx.token, "as_of" => "1900-01-01"}).status == 400
      end
    end

    test "a valid one is accepted by the same routes", ctx do
      as_of = "2026-10-20T12:00:00Z"
      body = %{"query" => ctx.token, "as_of" => as_of, "skip_wiki" => true, "skip_intent" => true}
      assert post("/api/rag", body).status == 200
      assert get("/api/recall/who?topic=#{ctx.token}&as_of=#{as_of}").status == 200
      assert post("/api/assemble", %{"query" => ctx.token, "as_of" => as_of}).status == 200
    end
  end
end
