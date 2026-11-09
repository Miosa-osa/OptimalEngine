defmodule OptimalEngine.Sync.CrossStoreApplyTest do
  @moduledoc """
  An Engine on one store applies a page of changes an Engine on the other
  store served, and ends with the rows the serving Engine had: a SQLite
  Engine's page on this build's store, and a PostgreSQL Engine's page. The
  pages were recorded on a SQLite build and on a PostgreSQL build
  (`OptimalEngine.Test.SyncPageFixture`); CI runs this file on both.
  """

  use ExUnit.Case, async: false

  alias OptimalEngine.{Store, Sync, Workspace}
  alias OptimalEngine.Test.SyncPageFixture
  alias OptimalEngine.Tenancy.Tenant

  setup do
    n = System.unique_integer([:positive])
    tenant = "xstore-#{n}"
    {:ok, _} = Tenant.create(%{id: tenant, name: "Cross store #{n}"})

    {:ok, _} =
      OptimalEngine.Organization.create(%{
        id: "#{tenant}:org",
        tenant_id: tenant,
        slug: "org",
        name: "Org"
      })

    {:ok, ws} =
      Workspace.create(%{
        tenant_id: tenant,
        organization_id: "#{tenant}:org",
        slug: "notes",
        name: "Notes"
      })

    {:ok, _} = Sync.enable(tenant, ws.id, "user:owner")
    %{tenant: tenant, ws: ws.id, token: "x#{n}"}
  end

  defp load(name, token) do
    "test/fixtures/sync/#{name}_page.json"
    |> File.read!()
    |> String.replace(SyncPageFixture.token(), token)
    |> Jason.decode!()
  end

  defp rows(ws) do
    Map.new(SyncPageFixture.queries(), fn {table, sql} ->
      {:ok, rows} = Store.raw_query(sql, [ws])
      {table, rows}
    end)
  end

  for source <- ~w(sqlite postgres) do
    test "a page a #{source} Engine served applies with the rows it had", ctx do
      page = load(unquote(source), ctx.token)
      assert page["store"] == unquote(source)
      assert length(page["mutations"]) >= 10

      assert {:ok, %{applied: applied}} = Sync.apply_changes(ctx.tenant, ctx.ws, page["mutations"])
      assert applied == length(page["mutations"])

      assert rows(ctx.ws) == page["expected"]

      # Applying again changes nothing, and nothing applied is captured again.
      assert {:ok, %{applied: 0}} = Sync.apply_changes(ctx.tenant, ctx.ws, page["mutations"])

      {:ok, [[captured]]} =
        Store.raw_query("SELECT COUNT(*) FROM sync_capture WHERE workspace_id = ?1", [ctx.ws])

      assert captured == 0
    end
  end
end
