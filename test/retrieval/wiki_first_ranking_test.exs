defmodule OptimalEngine.Retrieval.WikiFirstRankingTest do
  @moduledoc """
  Curated pages that match a query equally well come back in slug order, so
  which page a retrieval answers from does not depend on how they were listed.
  """

  use ExUnit.Case, async: false

  alias OptimalEngine.Retrieval.WikiFirst
  alias OptimalEngine.Store
  alias OptimalEngine.Wiki.Page
  alias OptimalEngine.Wiki.Store, as: WikiStore

  setup do
    n = System.unique_integer([:positive])
    workspace = "wiki-rank-#{n}"

    on_exit(fn ->
      Store.raw_query("DELETE FROM wiki_pages WHERE workspace_id = ?1", [workspace])
    end)

    {:ok, workspace: workspace, prefix: "ranking-#{n}"}
  end

  defp put_page(workspace, slug, audience \\ "default") do
    :ok =
      WikiStore.put(%Page{
        tenant_id: "default",
        workspace_id: workspace,
        slug: slug,
        audience: audience,
        version: 1,
        frontmatter: %{},
        body: "Body of #{slug}."
      })
  end

  test "pages that match equally are returned in slug order, whatever order they were stored in",
       ctx do
    slugs = for suffix <- ~w(a b c d e), do: "#{ctx.prefix}-#{suffix}"
    for slug <- Enum.shuffle(slugs), do: put_page(ctx.workspace, slug)

    for _ <- 1..3 do
      pages = WikiFirst.lookup_many(ctx.prefix, "default", workspace_id: ctx.workspace, limit: 10)
      assert Enum.map(pages, & &1.slug) == slugs
    end

    pages = WikiFirst.lookup_many(ctx.prefix, "default", workspace_id: ctx.workspace, limit: 2)
    assert Enum.map(pages, & &1.slug) == Enum.take(slugs, 2)
  end

  test "a page whose slug is the query outranks pages whose slug only starts with it", ctx do
    put_page(ctx.workspace, "#{ctx.prefix}-a")
    put_page(ctx.workspace, ctx.prefix)

    pages = WikiFirst.lookup_many(ctx.prefix, "default", workspace_id: ctx.workspace)
    assert Enum.map(pages, & &1.slug) == [ctx.prefix, "#{ctx.prefix}-a"]
  end
end
