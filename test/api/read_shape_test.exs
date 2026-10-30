defmodule OptimalEngine.API.ReadShapeTest do
  @moduledoc """
  The size and scope of what the read routes return:

    * `GET /api/search` carries the whole text of each hit unless
      `content=snippet` asks for the start of it, and shows a document once,
      however many cross-reference copies of it match
    * `GET /api/graph` and `GET /api/batch/export/*` return everything unless
      `limit` is given, then window by `limit` and `offset`
    * `GET /api/stats` counts the workspace it is asked about
    * a search in a workspace nothing was written to is an empty list
  """

  use ExUnit.Case, async: false

  import Plug.Test

  alias OptimalEngine.API.RateLimiter
  alias OptimalEngine.API.Router
  alias OptimalEngine.Context
  alias OptimalEngine.Store

  @opts Router.init([])

  defp get(path), do: conn(:get, path) |> Router.call(@opts)

  defp body(conn) do
    assert conn.status == 200
    Jason.decode!(conn.resp_body)
  end

  defp insert_context(id, workspace_id, attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    ctx = %Context{
      id: id,
      uri: attrs[:uri] || "optimal://nodes/#{attrs[:node]}/#{id}.md",
      type: :signal,
      path: "/tmp/#{id}.md",
      title: attrs[:title],
      content: attrs[:content] || "content for #{id}",
      l0_abstract: "SIGNAL | note | #{attrs[:title]}",
      l1_overview: "overview for #{id}",
      signal: nil,
      node: attrs[:node],
      sn_ratio: 0.7,
      entities: attrs[:entities] || [],
      created_at: now,
      modified_at: now,
      routed_to: [],
      workspace_id: workspace_id,
      metadata: attrs[:metadata] || %{}
    }

    :ok = Store.insert_context(ctx)
    ctx
  end

  setup do
    RateLimiter.reset()
    suffix = System.unique_integer([:positive])
    {:ok, suffix: suffix, ws: "shape-ws-#{suffix}", other: "shape-other-#{suffix}"}
  end

  describe "GET /api/search text" do
    test "a hit carries its whole text by default; content=snippet cuts it", ctx do
      token = "snippettoken#{ctx.suffix}"
      long = token <> " " <> String.duplicate("filler words ", 400)
      insert_context("shape-long-#{ctx.suffix}", ctx.ws, %{title: "Long", node: "n", content: long})

      [full] = body(get("/api/search?q=#{token}&workspace=#{ctx.ws}"))["results"]
      assert full["content_truncated"] == false
      assert full["content"] == long
      assert full["l0_abstract"] =~ "Long"

      [explicit] = body(get("/api/search?q=#{token}&workspace=#{ctx.ws}&content=full"))["results"]
      assert explicit["content"] == long

      [hit] = body(get("/api/search?q=#{token}&workspace=#{ctx.ws}&content=snippet"))["results"]
      assert hit["content_truncated"] == true
      assert byte_size(hit["content"]) <= 600
      assert String.starts_with?(long, hit["content"])
      assert hit["l0_abstract"] =~ "Long"
    end

    test "a short text is returned whole", ctx do
      token = "shorttoken#{ctx.suffix}"

      insert_context("shape-short-#{ctx.suffix}", ctx.ws, %{
        title: "Short",
        node: "n",
        content: token
      })

      for suffix <- ["", "&content=snippet"] do
        [hit] = body(get("/api/search?q=#{token}&workspace=#{ctx.ws}#{suffix}"))["results"]
        assert hit["content"] == token
        assert hit["content_truncated"] == false
      end
    end
  end

  describe "GET /api/search duplicates" do
    test "a signal and its cross-reference copy are one result", ctx do
      token = "dupetoken#{ctx.suffix}"
      parent_id = "shape-parent-#{ctx.suffix}"

      insert_context(parent_id, ctx.ws, %{title: "Dupe #{token}", node: "a", content: token})

      insert_context("shape-copy-#{ctx.suffix}", ctx.ws, %{
        title: "Dupe #{token}",
        node: "b",
        content: token,
        metadata: %{"cross_ref_of" => parent_id}
      })

      insert_context("shape-other-#{ctx.suffix}", ctx.ws, %{
        title: "Another #{token}",
        node: "c",
        content: "#{token} but a different document"
      })

      results = body(get("/api/search?q=#{token}&workspace=#{ctx.ws}"))["results"]
      ids = Enum.map(results, & &1["id"])

      assert length(results) == 2
      assert length(Enum.uniq(Enum.map(results, & &1["uri"]))) == 2
      assert "shape-other-#{ctx.suffix}" in ids
      assert length(Enum.filter(ids, &(&1 in [parent_id, "shape-copy-#{ctx.suffix}"]))) == 1
    end
  end

  describe "GET /api/search in a workspace with nothing in it" do
    test "answers an empty list", ctx do
      body = body(get("/api/search?q=anything&workspace=#{ctx.other}"))
      assert body["results"] == []
      assert body["pagination"]["total"] == 0
    end
  end

  describe "GET /api/graph limit" do
    setup ctx do
      for n <- 1..55 do
        insert_context("shape-g#{n}-#{ctx.suffix}", ctx.ws, %{
          title: "G#{n}",
          node: "gnode",
          entities: ["SharedEntity#{ctx.suffix}"]
        })
      end

      :ok
    end

    test "returns a page of contexts and counts the whole workspace", ctx do
      page = body(get("/api/graph?workspace=#{ctx.ws}&limit=2"))

      assert length(page["contexts"]) == 2
      assert page["stats"]["context_count"] == 55
      assert page["pagination"]["total"] == 55
      assert page["pagination"]["limit"] == 2
      assert page["pagination"]["has_more"] == true

      ids = MapSet.new(page["contexts"], & &1["id"])
      assert Enum.all?(page["edges"], &(&1["source"] in ids and &1["target"] in ids))
      assert page["stats"]["edge_count"] >= length(page["edges"])
    end

    test "offset moves the window; without a limit the whole workspace comes back", ctx do
      first = body(get("/api/graph?workspace=#{ctx.ws}&limit=2"))
      second = body(get("/api/graph?workspace=#{ctx.ws}&limit=2&offset=2"))

      assert Enum.map(first["contexts"], & &1["id"]) !=
               Enum.map(second["contexts"], & &1["id"])

      all = body(get("/api/graph?workspace=#{ctx.ws}"))
      assert length(all["contexts"]) == 55
      assert all["stats"]["context_count"] == 55
      assert all["pagination"]["limit"] == nil
      assert all["pagination"]["total"] == 55
      assert all["pagination"]["has_more"] == false
      assert length(all["edges"]) == all["stats"]["edge_count"]
    end

    test "an offset without a limit windows the edges the way a limit does", ctx do
      rest = body(get("/api/graph?workspace=#{ctx.ws}&offset=50"))

      assert length(rest["contexts"]) == 5
      assert rest["pagination"]["limit"] == nil
      assert rest["pagination"]["offset"] == 50
      assert rest["pagination"]["has_more"] == false
      assert rest["stats"]["context_count"] == 55

      ids = MapSet.new(rest["contexts"], & &1["id"])
      assert rest["edges"] != []
      assert Enum.all?(rest["edges"], &(&1["source"] in ids and &1["target"] in ids))
      assert length(rest["edges"]) < rest["stats"]["edge_count"]

      # No limit, so no cap on the entities.
      assert length(rest["entities"]) == rest["stats"]["entity_count"]
    end
  end

  describe "GET /api/batch/export limit" do
    setup ctx do
      for n <- 1..55 do
        insert_context("shape-e#{n}-#{ctx.suffix}", ctx.ws, %{title: "E#{n}", node: "enode"})
      end

      :ok
    end

    test "signals are windowed and the export says it is not complete", ctx do
      page = body(get("/api/batch/export/signals?workspace=#{ctx.ws}&limit=2"))

      assert length(page["signals"]) == 2
      assert page["pagination"]["total"] == 55
      assert page["pagination"]["has_more"] == true
      assert page["complete"] == false

      rest = body(get("/api/batch/export/signals?workspace=#{ctx.ws}&limit=2&offset=54"))
      assert length(rest["signals"]) == 1
      assert rest["complete"] == true
    end

    test "without a limit the export comes whole, past the largest page", ctx do
      all = body(get("/api/batch/export/signals?workspace=#{ctx.ws}"))
      assert length(all["signals"]) == 55
      assert all["complete"] == true
      assert all["pagination"]["limit"] == nil
      assert all["pagination"]["total"] == 55
      assert all["pagination"]["has_more"] == false

      assert length(body(get("/api/batch/export/workspace?workspace=#{ctx.ws}"))["signals"]) == 55
    end

    test "the workspace snapshot windows its signals and memories", ctx do
      snapshot = body(get("/api/batch/export/workspace?workspace=#{ctx.ws}&limit=3"))

      assert length(snapshot["signals"]) == 3
      assert snapshot["pagination"]["signals"]["total"] == 55
      assert snapshot["complete"] == false
    end
  end

  describe "GET /api/stats" do
    test "counts the workspace it is asked about", ctx do
      for n <- 1..3 do
        insert_context("shape-s#{n}-#{ctx.suffix}", ctx.ws, %{
          title: "S#{n}",
          node: "snode",
          entities: ["StatEntity#{n}-#{ctx.suffix}"]
        })
      end

      insert_context("shape-o1-#{ctx.suffix}", ctx.other, %{title: "O1", node: "snode"})

      mine = body(get("/api/stats?workspace=#{ctx.ws}"))
      theirs = body(get("/api/stats?workspace=#{ctx.other}"))
      empty = body(get("/api/stats?workspace=shape-empty-#{ctx.suffix}"))

      assert mine["workspace_id"] == ctx.ws
      assert mine["cache_size"] == 0
      assert mine["total_contexts"] == 3
      assert mine["total_signals"] == 3
      assert mine["total_entities"] == 3
      assert theirs["total_contexts"] == 1
      assert theirs["total_entities"] == 0
      assert empty["total_contexts"] == 0
    end
  end
end
