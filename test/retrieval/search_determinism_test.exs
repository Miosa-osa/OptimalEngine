defmodule OptimalEngine.Retrieval.SearchDeterminismTest do
  @moduledoc """
  Two Engines that hold the same data return the same ranked list.

  Each test stores the same contexts twice, in two workspaces and in opposite
  orders. That is the difference between two Engines (their rows have different
  rowids, so the database yields ties in a different order) without starting a
  second Engine. The two workspaces must then answer alike.
  """

  use ExUnit.Case, async: false

  import OptimalEngine.TestSupport.RetrievalFixtures

  alias OptimalEngine.Retrieval.{ContextAssembler, Grep, Search}

  @as_of ~U[2026-10-20 12:00:00Z]
  @stored_at stored_at()

  setup do
    token = token()
    workspaces = ["#{token}-a", "#{token}-b"]
    on_exit(fn -> delete_workspaces(workspaces) end)
    {:ok, token: token, ws_a: Enum.at(workspaces, 0), ws_b: Enum.at(workspaces, 1)}
  end

  # The same contexts in two workspaces: `a` in uri order, `b` in the reverse.
  defp store_twice(token, ws_a, ws_b, count) do
    uris = uris(token, count)

    for {uri, n} <- Enum.with_index(uris, 1) do
      insert_context(ws_a, "#{token}-a-#{n}", uri, token)
    end

    for {uri, n} <- uris |> Enum.with_index(1) |> Enum.reverse() do
      insert_context(ws_b, "#{token}-b-#{n}", uri, token)
    end

    uris
  end

  defp uris_of(results), do: Enum.map(results, & &1.uri)

  defp exact(result), do: Map.get(result, :rank_score, result.score)

  defp scores(results) do
    Enum.map(results, &{&1.uri, &1.score, Map.get(&1, :rank_score)})
  end

  describe "contexts with identical text and timestamps" do
    test "rank in uri order, whatever order they were stored in", ctx do
      uris = store_twice(ctx.token, ctx.ws_a, ctx.ws_b, 12)

      for workspace <- [ctx.ws_a, ctx.ws_b], _run <- 1..3 do
        assert {:ok, results} = Search.search(ctx.token, workspace_id: workspace, limit: 20)
        assert uris_of(results) == uris
      end
    end

    test "a tie at the edge of the candidate window keeps the same contexts", ctx do
      # 12 contexts and limit 3: the database hands the search 9 of the 12, so
      # which 9 it hands over must not depend on the order they were stored in.
      uris = store_twice(ctx.token, ctx.ws_a, ctx.ws_b, 12)

      for workspace <- [ctx.ws_a, ctx.ws_b] do
        assert {:ok, results} = Search.search(ctx.token, workspace_id: workspace, limit: 3)
        assert uris_of(results) == Enum.take(uris, 3)
      end
    end

    test "carry one exact score, however many there are, when no as_of is given", ctx do
      store_twice(ctx.token, ctx.ws_a, ctx.ws_b, 12)

      assert {:ok, results} = Search.search(ctx.token, workspace_id: ctx.ws_a, limit: 20)
      assert length(results) == 12

      assert results |> Enum.map(&exact/1) |> Enum.uniq() |> length() == 1
    end

    test "the score shown is the exact score rounded to four decimals", ctx do
      store_twice(ctx.token, ctx.ws_a, ctx.ws_b, 3)

      assert {:ok, results} = Search.search(ctx.token, workspace_id: ctx.ws_a, as_of: @as_of)

      for result <- results do
        assert is_float(result.rank_score)
        assert result.score == Float.round(result.rank_score, 4)
      end
    end

    test "fused search ranks them in uri order in both workspaces", ctx do
      uris = store_twice(ctx.token, ctx.ws_a, ctx.ws_b, 8)

      for workspace <- [ctx.ws_a, ctx.ws_b] do
        assert {:ok, results} =
                 ContextAssembler.fused_search(ctx.token,
                   workspace_id: workspace,
                   limit: 8,
                   as_of: @as_of
                 )

        assert uris_of(results) == uris
      end
    end
  end

  describe "a near-tie that differs only after the fourth decimal" do
    # Two contexts alike but for the second they were modified in. The newer one
    # decays less, so its exact score is higher, by far less than 0.0001: the two
    # print the same score. The older one is stored first and sorts first by uri,
    # so neither the storage order nor the tie-break can name the newer one first.
    setup ctx do
      older = DateTime.add(@stored_at, -1, :second)

      insert_context(
        ctx.ws_a,
        "#{ctx.token}-old",
        "optimal://nodes/ranking/#{ctx.token}/a-old",
        ctx.token,
        modified_at: older,
        node: "tb-old"
      )

      insert_context(
        ctx.ws_a,
        "#{ctx.token}-new",
        "optimal://nodes/ranking/#{ctx.token}/b-new",
        ctx.token,
        modified_at: @stored_at,
        node: "tb-new"
      )

      # The instant the two scores are measured at moves where the rounding
      # boundaries fall; take one at which they print the same.
      as_of =
        Enum.find_value(0..40, fn hours ->
          as_of = DateTime.add(@as_of, hours * 3600, :second)
          {:ok, results} = Search.search(ctx.token, workspace_id: ctx.ws_a, as_of: as_of)

          if length(results) == 2 and
               results |> Enum.map(& &1.score) |> Enum.uniq() |> length() == 1,
             do: as_of
        end)

      assert as_of, "no instant found at which the two scores print the same"
      {:ok, as_of: as_of}
    end

    test "orders by the true score", ctx do
      assert {:ok, results} = Search.search(ctx.token, workspace_id: ctx.ws_a, as_of: ctx.as_of)

      assert uris_of(results) == [
               "optimal://nodes/ranking/#{ctx.token}/b-new",
               "optimal://nodes/ranking/#{ctx.token}/a-old"
             ]
    end

    test "grep orders its matches the same way", ctx do
      assert {:ok, matches} = Grep.grep(ctx.token, workspace_id: ctx.ws_a, as_of: ctx.as_of)
      assert Enum.map(matches, & &1.slug) == ["tb-new", "tb-old"]
    end
  end

  describe ":as_of" do
    setup ctx do
      older = DateTime.add(@stored_at, -3 * 86_400, :second)

      insert_context(
        ctx.ws_a,
        "#{ctx.token}-1",
        "optimal://nodes/ranking/#{ctx.token}/one",
        ctx.token,
        modified_at: older
      )

      insert_context(
        ctx.ws_a,
        "#{ctx.token}-2",
        "optimal://nodes/ranking/#{ctx.token}/two",
        ctx.token
      )

      :ok
    end

    test "gives identical scores on repeated calls, however much later they are made", ctx do
      assert {:ok, first} = Search.search(ctx.token, workspace_id: ctx.ws_a, as_of: @as_of)
      # Longer than the one second the decay measures age in.
      Process.sleep(1_100)
      assert {:ok, second} = Search.search(ctx.token, workspace_id: ctx.ws_a, as_of: @as_of)

      assert scores(first) == scores(second)
    end

    test "moves the decay: the same context scores lower at a later instant", ctx do
      later = DateTime.add(@as_of, 30 * 86_400, :second)

      assert {:ok, [early | _]} = Search.search(ctx.token, workspace_id: ctx.ws_a, as_of: @as_of)
      assert {:ok, [late | _]} = Search.search(ctx.token, workspace_id: ctx.ws_a, as_of: later)

      assert early.uri == late.uri
      # Compared exact: on a small corpus every score prints as 0.0.
      assert exact(late) < exact(early)
    end

    test "takes a DateTime or an ISO 8601 string, and reads a missing offset as UTC", ctx do
      assert {:ok, from_datetime} = Search.search(ctx.token, workspace_id: ctx.ws_a, as_of: @as_of)

      for text <- ["2026-10-20T12:00:00Z", "2026-10-20T14:00:00+02:00", "2026-10-20T12:00:00"] do
        assert {:ok, from_text} = Search.search(ctx.token, workspace_id: ctx.ws_a, as_of: text)
        assert scores(from_text) == scores(from_datetime)
      end
    end

    test "treats a blank value as absent", ctx do
      assert {:ok, [_ | _]} = Search.search(ctx.token, workspace_id: ctx.ws_a, as_of: "")
    end

    test "refuses a value that is not a timestamp", ctx do
      assert {:error, {:invalid_as_of, "yesterday"}} =
               Search.search(ctx.token, workspace_id: ctx.ws_a, as_of: "yesterday")

      assert {:error, {:invalid_as_of, 42}} =
               Search.search(ctx.token, workspace_id: ctx.ws_a, as_of: 42)
    end
  end

  describe "GET /api/search" do
    test "answers with the same list and scores for the same as_of", ctx do
      uris = store_twice(ctx.token, ctx.ws_a, ctx.ws_b, 6)
      query = "q=#{ctx.token}&as_of=2026-10-20T12:00:00Z&limit=10"

      first = get("/api/search?#{query}&workspace=#{ctx.ws_a}")
      Process.sleep(1_100)
      second = get("/api/search?#{query}&workspace=#{ctx.ws_b}")

      assert first.status == 200 and second.status == 200
      first_results = Jason.decode!(first.resp_body)["results"]
      second_results = Jason.decode!(second.resp_body)["results"]

      assert Enum.map(first_results, & &1["uri"]) == uris
      assert Enum.map(second_results, & &1["uri"]) == uris
      assert Enum.map(first_results, & &1["score"]) == Enum.map(second_results, & &1["score"])
    end

    test "answers 400 when as_of is not a timestamp", ctx do
      insert_context(
        ctx.ws_a,
        "#{ctx.token}-1",
        "optimal://nodes/ranking/#{ctx.token}/one",
        ctx.token
      )

      conn = get("/api/search?q=#{ctx.token}&workspace=#{ctx.ws_a}&as_of=yesterday")
      assert conn.status == 400
      assert %{"error" => error} = Jason.decode!(conn.resp_body)
      assert error =~ "as_of"
    end
  end

  describe "GET /api/grep" do
    test "answers 400 when as_of is not a timestamp", ctx do
      insert_context(
        ctx.ws_a,
        "#{ctx.token}-1",
        "optimal://nodes/ranking/#{ctx.token}/one",
        ctx.token
      )

      conn = get("/api/grep?q=#{ctx.token}&workspace=#{ctx.ws_a}&as_of=yesterday")
      assert conn.status == 400
    end
  end
end
