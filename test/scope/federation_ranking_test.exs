defmodule OptimalEngine.FederationRankingTest do
  @moduledoc """
  The federated search merges the hits of several sharing workspaces by score,
  and a tie goes by uri, then id, then the workspace the hit came from, so the
  merged list does not depend on which workspace answered first.
  """

  use ExUnit.Case, async: false

  alias OptimalEngine.{Federation, Store, Workspace}
  alias OptimalEngine.Tenancy.Tenant

  @as_of "2026-10-20T12:00:00Z"

  setup do
    n = System.unique_integer([:positive])
    tenant = "fed-rank-#{n}"
    {:ok, _} = Tenant.create(%{id: tenant, name: "Federation rank #{n}"})

    {:ok, _} =
      OptimalEngine.Organization.create(%{
        id: "#{tenant}:org",
        tenant_id: tenant,
        slug: "org",
        name: "Org"
      })

    workspaces =
      for slug <- ["north", "south"] do
        {:ok, workspace} =
          Workspace.create(%{
            tenant_id: tenant,
            organization_id: "#{tenant}:org",
            slug: slug,
            name: slug
          })

        workspace.id
      end

    {:ok, tenant: tenant, token: "rk#{n}", workspaces: workspaces}
  end

  defp context(tenant, workspace, id, uri, token) do
    {:ok, _} =
      Store.raw_query(
        "INSERT INTO contexts (id, tenant_id, workspace_id, title, content, created_at, modified_at, uri) VALUES (?1, ?2, ?3, ?4, ?5, '2026-10-14T10:00:00Z', '2026-10-14T10:00:00Z', ?6)",
        [id, tenant, workspace, "Plan #{token}", "The #{token} plan covers the work.", uri]
      )
  end

  test "hits of equal score from two workspaces merge in uri order", ctx do
    [north, south] = ctx.workspaces
    uris = for n <- 1..6, do: "optimal://nodes/fed/#{ctx.token}/doc-#{n}"

    # The north workspace holds the odd documents, the south the even ones, and
    # each is stored in the reverse of its uri order.
    for {uri, n} <- uris |> Enum.with_index(1) |> Enum.reverse() do
      workspace = if rem(n, 2) == 1, do: north, else: south
      context(ctx.tenant, workspace, "#{ctx.token}-#{n}", uri, ctx.token)
    end

    for allowed <- [nil, ctx.workspaces, Enum.reverse(ctx.workspaces)], _run <- 1..2 do
      result = Federation.search(ctx.tenant, ctx.token, allowed: allowed, limit: 20, as_of: @as_of)
      assert Enum.map(result.results, & &1["uri"]) == uris
    end

    result = Federation.search(ctx.tenant, ctx.token, limit: 4, as_of: @as_of)
    assert Enum.map(result.results, & &1["uri"]) == Enum.take(uris, 4)
  end

  test "the same uri in two workspaces keeps both, ordered by id", ctx do
    [north, south] = ctx.workspaces
    uri = "optimal://nodes/fed/#{ctx.token}/shared"
    context(ctx.tenant, south, "#{ctx.token}-s", uri, ctx.token)
    context(ctx.tenant, north, "#{ctx.token}-n", uri, ctx.token)

    result = Federation.search(ctx.tenant, ctx.token, as_of: @as_of)

    assert Enum.map(result.results, &{&1["id"], &1["source_workspace_id"]}) ==
             [{"#{ctx.token}-n", north}, {"#{ctx.token}-s", south}]
  end

  test "an as_of that is not valid is an error", ctx do
    assert {:error, {:invalid_as_of, "nope"}} =
             Federation.search(ctx.tenant, ctx.token, as_of: "nope")

    assert {:error, {:invalid_as_of, _}} =
             Federation.search(ctx.tenant, ctx.token, as_of: "1900-01-01")
  end
end
