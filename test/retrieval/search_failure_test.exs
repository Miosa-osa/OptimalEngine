defmodule OptimalEngine.Retrieval.SearchFailureTest do
  @moduledoc """
  A search that raises fails that request, and the caller is told an opaque id,
  never the exception text.

  The search process is given a topology whose half-life is zero, so scoring a
  context divides by zero. The exception and its stack trace are in the log
  under the id, with the workspace and the length of the query; a telemetry
  event counts the failure; and every surface that searches answers an error
  instead of a result that reads as "nothing found".
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import OptimalEngine.TestSupport.RetrievalFixtures

  alias OptimalEngine.Retrieval.{ContextAssembler, RAG, Search}

  @ref ~r/\A[0-9a-f]{12}\z/

  # Telemetry handler: forwards the event to the test process.
  def forward(_event, measurements, meta, pid),
    do: send(pid, {:search_failed_event, measurements, meta})

  setup do
    token = token()
    workspace = "#{token}-w"
    on_exit(fn -> delete_workspaces([workspace]) end)
    insert_context(workspace, "#{token}-1", "optimal://nodes/ranking/#{token}/a", token)
    break_search()
    {:ok, token: token, workspace: workspace, pid: Process.whereis(Search)}
  end

  defp failed_ref(ctx) do
    capture_log(fn ->
      assert {:error, {:search_failed, ref}} = Search.search(ctx.token, workspace_id: ctx.workspace)
      send(self(), {:ref, ref})
    end)

    assert_received {:ref, ref}
    ref
  end

  describe "Search.search/2" do
    test "answers an opaque id, every time a different one, and the process lives on", ctx do
      first = failed_ref(ctx)
      second = failed_ref(ctx)

      assert first =~ @ref
      assert second =~ @ref
      assert first != second
      assert Process.whereis(Search) == ctx.pid
    end

    test "puts the exception, its stack trace, the workspace and the query length in the log",
         ctx do
      log =
        capture_log(fn ->
          result = Search.search(ctx.token, workspace_id: ctx.workspace)
          send(self(), {:result, result})
        end)

      assert_received {:result, {:error, {:search_failed, ref}} = result}

      assert log =~ "ref=#{ref}"
      assert log =~ ctx.workspace
      assert log =~ "query_length=#{byte_size(ctx.token)}"
      assert log =~ "ArithmeticError"
      assert log =~ "lib/optimal_engine/retrieval/search.ex"

      # None of it reaches the caller.
      refute inspect(result) =~ "Arithmetic"
      refute inspect(result) =~ "search.ex"
    end

    test "emits a telemetry event with the same id", ctx do
      handler = "search-failed-#{ctx.token}"

      :ok =
        :telemetry.attach(
          handler,
          [:optimal_engine, :search, :failed],
          &__MODULE__.forward/4,
          self()
        )

      on_exit(fn -> :telemetry.detach(handler) end)

      ref = failed_ref(ctx)

      assert_receive {:search_failed_event, %{count: 1}, meta}
      assert meta.ref == ref
      assert meta.workspace_id == ctx.workspace
      assert meta.query_length == byte_size(ctx.token)
    end
  end

  describe "RAG.ask/2" do
    test "answers the error, not an envelope of no results", ctx do
      capture_log(fn ->
        result =
          RAG.ask(ctx.token, workspace_id: ctx.workspace, skip_intent: true, skip_wiki: true)

        send(self(), {:result, result})
      end)

      assert_received {:result, {:error, {:search_failed, ref}}}
      assert ref =~ @ref
    end

    test "is a 502 with the id on POST /api/rag", ctx do
      capture_log(fn ->
        conn =
          post("/api/rag", %{
            "query" => ctx.token,
            "workspace" => ctx.workspace,
            "skip_intent" => true,
            "skip_wiki" => true
          })

        send(self(), {:conn, conn})
      end)

      assert_received {:conn, conn}
      assert conn.status == 502
      assert %{"error" => "search failed", "ref" => ref} = Jason.decode!(conn.resp_body)
      assert ref =~ @ref
      refute conn.resp_body =~ "Arithmetic"
    end

    test "is a 502 with the id on a recall route, not an empty 200", ctx do
      capture_log(fn ->
        conn = get("/api/recall/who?topic=#{ctx.token}&workspace=#{ctx.workspace}")
        send(self(), {:conn, conn})
      end)

      assert_received {:conn, conn}
      assert conn.status == 502
      assert %{"error" => "search failed", "ref" => ref} = Jason.decode!(conn.resp_body)
      assert ref =~ @ref
    end

    test "is an error event with the id on GET /api/rag/stream", ctx do
      capture_log(fn ->
        conn =
          get("/api/rag/stream?query=#{ctx.token}&workspace=#{ctx.workspace}&skip_intent=true")

        send(self(), {:conn, conn})
      end)

      assert_received {:conn, conn}
      assert conn.resp_body =~ "event: error"
      [_, data] = Regex.run(~r/event: error\ndata: (.*)\n/, conn.resp_body)
      assert %{"error" => "search failed", "ref" => ref} = Jason.decode!(data)
      assert ref =~ @ref
      refute conn.resp_body =~ "Arithmetic"
    end
  end

  describe "ContextAssembler" do
    test "assemble, l1 and fused_search answer the error, not empty tiers", ctx do
      opts = [workspace_id: ctx.workspace]

      capture_log(fn ->
        send(self(), {:assemble, ContextAssembler.assemble(ctx.token, opts)})
        send(self(), {:l1, ContextAssembler.l1(ctx.token, opts)})
        send(self(), {:fused, ContextAssembler.fused_search(ctx.token, opts)})
      end)

      for tag <- [:assemble, :l1, :fused] do
        assert_received {^tag, {:error, {:search_failed, ref}}}
        assert ref =~ @ref
      end
    end
  end

  describe "the search and grep routes" do
    test "answer 500 with the id and no exception text", ctx do
      for path <- ["/api/search", "/api/grep"] do
        capture_log(fn ->
          send(self(), {path, get("#{path}?q=#{ctx.token}&workspace=#{ctx.workspace}")})
        end)

        assert_received {^path, conn}
        assert conn.status == 500
        assert %{"error" => "search failed", "ref" => ref} = Jason.decode!(conn.resp_body)
        assert ref =~ @ref
        refute conn.resp_body =~ "Arithmetic"
        refute conn.resp_body =~ "search.ex"
      end
    end
  end
end
