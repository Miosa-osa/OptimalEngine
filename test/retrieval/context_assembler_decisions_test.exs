defmodule OptimalEngine.Retrieval.ContextAssemblerDecisionsTest do
  @moduledoc """
  The "Related Decisions" section of the assembled L2 lists the decisions
  recorded against the contexts it selected.

  The query behind it once named a `topic` column that the `decisions` table
  does not have, so it failed on every call and the section was always empty.
  """

  use ExUnit.Case, async: false

  import OptimalEngine.TestSupport.RetrievalFixtures

  alias OptimalEngine.Retrieval.ContextAssembler
  alias OptimalEngine.Store

  setup do
    token = token()
    workspace = "#{token}-w"
    on_exit(fn -> delete_workspaces([workspace]) end)
    insert_context(workspace, "#{token}-1", "optimal://nodes/ranking/#{token}/a", token)
    {:ok, token: token, workspace: workspace}
  end

  defp record_decision(ctx, title, decision, rationale, decided_at) do
    {:ok, _} =
      Store.raw_query(
        "INSERT INTO decisions (context_id, title, decision, rationale, decided_at, workspace_id) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
        ["#{ctx.token}-1", title, decision, rationale, decided_at, ctx.workspace]
      )
  end

  test "lists the decisions of the selected contexts, newest first", ctx do
    record_decision(
      ctx,
      "Pricing tier",
      "Keep two tiers",
      "Simpler to explain",
      "2026-10-01 09:00:00"
    )

    record_decision(
      ctx,
      "Launch date",
      "Ship in November",
      "The pilot is ready",
      "2026-10-05 09:00:00"
    )

    assert {:ok, %{l2: l2}} = ContextAssembler.assemble(ctx.token, workspace_id: ctx.workspace)

    assert l2 =~ "## Related Decisions"
    assert l2 =~ "**Launch date** (2026-10-05 09:00:00): Ship in November"
    assert l2 =~ "_Rationale: The pilot is ready_"
    assert l2 =~ "**Pricing tier** (2026-10-01 09:00:00): Keep two tiers"

    {launch, _} = :binary.match(l2, "Launch date")
    {pricing, _} = :binary.match(l2, "Pricing tier")
    assert launch < pricing
  end

  test "a decision without a rationale has no empty rationale line", ctx do
    record_decision(ctx, "Naming", "Call it the portal", nil, "2026-10-02 09:00:00")

    assert {:ok, %{l2: l2}} = ContextAssembler.assemble(ctx.token, workspace_id: ctx.workspace)

    assert l2 =~ "**Naming** (2026-10-02 09:00:00): Call it the portal"
    refute l2 =~ "_Rationale:"
  end

  test "there is no section when no decision is recorded", ctx do
    assert {:ok, %{l2: l2}} = ContextAssembler.assemble(ctx.token, workspace_id: ctx.workspace)

    assert l2 =~ ctx.token
    refute l2 =~ "Related Decisions"
  end
end
