defmodule OptimalEngine.Connectors.DefaultIntakeTest do
  @moduledoc """
  A connector registered without a workspace lands in its own tenant's intake
  workspace (`OptimalEngine.CorpusOrganizer.source_workspace/1`), never in
  another tenant's.
  """

  use ExUnit.Case, async: false

  alias OptimalEngine.Connectors.Rows
  alias OptimalEngine.{Organization, Store, Workspace}
  alias OptimalEngine.Tenancy.Tenant

  setup do
    n = System.unique_integer([:positive])
    original = Application.get_env(:optimal_engine, :corpus_source_workspace)

    on_exit(fn ->
      if is_nil(original),
        do: Application.delete_env(:optimal_engine, :corpus_source_workspace),
        else: Application.put_env(:optimal_engine, :corpus_source_workspace, original)
    end)

    [a, b, bare] = for name <- ~w(a b c), do: "intake-#{name}-#{n}"

    for tenant <- [a, b, bare] do
      {:ok, _} = Tenant.create(%{id: tenant, name: tenant})
    end

    intake = fn tenant ->
      {:ok, workspace} =
        Workspace.create(%{
          tenant_id: tenant,
          organization_id: Organization.default_for(tenant),
          slug: "knowledge-intake",
          name: "Intake"
        })

      workspace.id
    end

    {:ok, n: n, a: a, b: b, bare: bare, a_intake: intake.(a), b_intake: intake.(b)}
  end

  test "a tenant's connector lands in the tenant's own intake", ctx do
    assert {:ok, ctx.a_intake} == Rows.default_workspace(ctx.a)
    assert {:ok, ctx.b_intake} == Rows.default_workspace(ctx.b)
  end

  test "a tenant with no intake workspace has no default", ctx do
    assert {:error, :no_intake_workspace} = Rows.default_workspace(ctx.bare)
  end

  test "a configured intake of another tenant is not this tenant's", ctx do
    Application.put_env(:optimal_engine, :corpus_source_workspace, ctx.b_intake)

    assert {:ok, ctx.a_intake} == Rows.default_workspace(ctx.a)
    assert {:ok, ctx.b_intake} == Rows.default_workspace(ctx.b)
  end

  test "an archived intake is skipped", ctx do
    :ok = Workspace.archive(ctx.a_intake)

    assert {:error, :no_intake_workspace} = Rows.default_workspace(ctx.a)
    assert {:ok, ctx.b_intake} == Rows.default_workspace(ctx.b)
  end

  test "a spec without a workspace is provisioned into the tenant's intake", ctx do
    id = "pull:#{ctx.a}:sources_folder"

    assert {:ok, :created} =
             Rows.provision(%{id: id, kind: :sources_folder, tenant_id: ctx.a, config: %{}})

    assert {:ok, [[workspace]]} =
             Store.raw_query("SELECT workspace_id FROM connectors WHERE id = ?1", [id])

    assert workspace == ctx.a_intake
  end
end
