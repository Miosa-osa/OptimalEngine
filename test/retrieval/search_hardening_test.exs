defmodule OptimalEngine.Retrieval.SearchHardeningTest do
  @moduledoc """
  One request cannot take down the search process, which serves every tenant,
  and the retrieval path can be pinned.

  A far-past `as_of` used to push the decay exponent past what `exp` accepts;
  the resulting `ArithmeticError` killed the process, and four requests in five
  seconds exhausted its supervisor's restart intensity.
  """

  use ExUnit.Case, async: false

  import OptimalEngine.TestSupport.RetrievalFixtures

  alias OptimalEngine.Retrieval.{Grep, Search}

  setup do
    token = token()
    workspace = "#{token}-w"
    on_exit(fn -> delete_workspaces([workspace]) end)

    for {uri, n} <- Enum.with_index(uris(token, 3), 1) do
      insert_context(workspace, "#{token}-#{n}", uri, token)
    end

    {:ok, token: token, workspace: workspace, pid: Process.whereis(Search)}
  end

  describe "an as_of far in the past" do
    test "is refused, and the search process lives on", ctx do
      for value <- ["1900-01-01T00:00:00Z", "1969-12-31T23:59:59Z", ~U[1900-01-01 00:00:00Z]] do
        assert {:error, {:invalid_as_of, ^value}} =
                 Search.search(ctx.token, workspace_id: ctx.workspace, as_of: value)
      end

      assert Process.whereis(Search) == ctx.pid
      assert {:ok, [_ | _]} = Search.search(ctx.token, workspace_id: ctx.workspace)
    end

    test "many such requests do not exhaust the restart intensity", ctx do
      for _ <- 1..12 do
        assert {:error, {:invalid_as_of, _}} =
                 Search.search(ctx.token, workspace_id: ctx.workspace, as_of: "1900-01-01")
      end

      assert Process.whereis(Search) == ctx.pid
    end

    test "is a 400 on the search and grep routes", ctx do
      for path <- ["/api/search", "/api/grep"] do
        conn = get("#{path}?q=#{ctx.token}&workspace=#{ctx.workspace}&as_of=1900-01-01T00:00:00Z")
        assert conn.status == 400
        assert %{"error" => error} = Jason.decode!(conn.resp_body)
        assert error =~ "as_of"
      end

      assert {:error, {:invalid_as_of, "1900-01-01T00:00:00Z"}} =
               Grep.grep(ctx.token, workspace_id: ctx.workspace, as_of: "1900-01-01T00:00:00Z")

      assert Process.whereis(Search) == ctx.pid
    end

    test "that is allowed leaves contexts dated later with a finite, positive score", ctx do
      # The context is 26 years newer than the instant, so its age is negative
      # and large: the case that overflowed `exp`.
      for as_of <- ["1970-01-01T00:00:00Z", "2000-01-01T00:00:00Z"] do
        assert {:ok, [_ | _] = results} =
                 Search.search(ctx.token, workspace_id: ctx.workspace, as_of: as_of)

        for result <- results do
          assert is_float(result.rank_score)
          assert result.rank_score > 0.0 and result.rank_score < 1.0e100
        end
      end

      assert Process.whereis(Search) == ctx.pid
    end
  end

  describe "a context dated far in the future" do
    test "scores finite and the search process lives on", ctx do
      insert_context(
        ctx.workspace,
        "#{ctx.token}-future",
        "optimal://nodes/ranking/#{ctx.token}/future",
        ctx.token,
        modified_at: ~U[9999-01-01 00:00:00Z]
      )

      assert {:ok, results} = Search.search(ctx.token, workspace_id: ctx.workspace)
      future = Enum.find(results, &String.ends_with?(&1.uri, "/future"))

      assert future
      assert is_float(future.rank_score)
      assert future.rank_score > 0.0 and future.rank_score < 1.0e100
      assert Process.whereis(Search) == ctx.pid
    end
  end

  describe "a request that raises" do
    test "fails that request and not the process", ctx do
      assert {:error, {:search_failed, message}} =
               Search.search(ctx.token, workspace_id: ctx.workspace, limit: "many")

      assert is_binary(message)
      assert Process.whereis(Search) == ctx.pid
      assert {:ok, [_ | _]} = Search.search(ctx.token, workspace_id: ctx.workspace)
    end
  end

  describe "mode" do
    test "lexical is full text only", ctx do
      assert {:ok, results} =
               Search.search(ctx.token, workspace_id: ctx.workspace, mode: :lexical, limit: 10)

      assert length(results) == 3

      assert {:ok, ^results} =
               Search.search(ctx.token, workspace_id: ctx.workspace, mode: "lexical", limit: 10)
    end

    test "hybrid without a healthy embedder is unavailable, not a quiet fall back", ctx do
      # No embedder answers in tests: Ollama at OLLAMA_HOST is a closed port.
      for mode <- [:hybrid, "hybrid"] do
        assert {:error, :hybrid_unavailable} =
                 Search.search(ctx.token, workspace_id: ctx.workspace, mode: mode)
      end

      assert {:ok, [_ | _]} = Search.search(ctx.token, workspace_id: ctx.workspace, mode: :auto)
      assert {:ok, [_ | _]} = Search.search(ctx.token, workspace_id: ctx.workspace)
      assert Process.whereis(Search) == ctx.pid
    end

    test "is pinned per request on GET /api/search", ctx do
      path = "/api/search?q=#{ctx.token}&workspace=#{ctx.workspace}"

      assert (conn = get(path <> "&mode=lexical")).status == 200
      assert length(Jason.decode!(conn.resp_body)["results"]) == 3

      assert get(path <> "&mode=auto").status == 200
      assert get(path).status == 200

      conn = get(path <> "&mode=hybrid")
      assert conn.status == 503
      assert %{"error" => "hybrid_unavailable"} = Jason.decode!(conn.resp_body)

      conn = get(path <> "&mode=bogus")
      assert conn.status == 400
      assert Jason.decode!(conn.resp_body)["error"] =~ "mode"
    end
  end

  describe "min_score" do
    test "compares the exact score, not the one rounded for display", ctx do
      assert {:ok, [top | _]} = Search.search(ctx.token, workspace_id: ctx.workspace)
      exact = top.rank_score

      assert {:ok, kept} =
               Search.search(ctx.token, workspace_id: ctx.workspace, min_score: exact)

      assert top.uri in Enum.map(kept, & &1.uri)

      assert {:ok, []} =
               Search.search(ctx.token, workspace_id: ctx.workspace, min_score: exact * 2 + 1)
    end
  end
end
