defmodule OptimalEngine.MemoryCore.RecallOrderingTest do
  @moduledoc """
  Governed recall returns candidates in an order the data decides: facts equal
  in confidence and age come back by id, whatever order they were stored in,
  and the associative projection does the same. A request that fixes `:as_of`
  measures the validity windows against that instant.
  """

  use ExUnit.Case, async: false

  alias OptimalEngine.MemoryCore.{AssociativeProjection, ID, RetrievalCoordinator, ScopeEnvelope}
  alias OptimalEngine.MemoryCore.Store, as: MemoryCoreStore
  alias OptimalEngine.Store

  @fixed_at "2026-10-10 12:00:00"

  setup do
    workspace = "recall-order-#{System.unique_integer([:positive])}"
    token = "rk#{System.unique_integer([:positive])}"

    on_exit(fn ->
      Store.raw_query("DELETE FROM memory_associations WHERE workspace_id = ?1", [workspace])
      Store.raw_query("DELETE FROM memories WHERE workspace_id = ?1", [workspace])
      Store.raw_query("DELETE FROM facts WHERE workspace_id = ?1", [workspace])
    end)

    {:ok, workspace: workspace, token: token}
  end

  defp insert_fact!(workspace, attrs) do
    fact =
      Map.merge(
        %{
          id: ID.random_id("fact"),
          tenant_id: "default",
          workspace_id: workspace,
          fact_text: "A fact.",
          subject_anchor: "ordering",
          action_class: "approved",
          lifecycle_state: "accepted",
          contradiction_status: "none",
          aggregate_confidence: 0.5,
          aggregate_precision: 0.5,
          security_labels: ["internal"],
          partition_ids: ["public"],
          supporting_evidence_links: []
        },
        attrs
      )

    :ok = MemoryCoreStore.insert_fact(fact)
    fact
  end

  defp recall(ctx, opts \\ []) do
    defaults = [
      workspace_id: ctx.workspace,
      actor_id: "agent:test",
      allowed_partitions: ["public"],
      allowed_security_labels: ["internal"],
      limit: 20
    ]

    RetrievalCoordinator.retrieve_package(ctx.token, Keyword.merge(defaults, opts))
  end

  # `count` facts of one text, confidence and age, stored in the reverse of
  # their id order.
  defp store_identical_facts(ctx, count) do
    ids =
      for n <- 1..count, do: "fact-#{ctx.token}-#{String.pad_leading(Integer.to_string(n), 2, "0")}"

    for id <- Enum.reverse(ids) do
      insert_fact!(ctx.workspace, %{id: id, fact_text: "#{ctx.token} was approved"})
    end

    {:ok, _} =
      Store.raw_query("UPDATE facts SET updated_at = ?2 WHERE workspace_id = ?1", [
        ctx.workspace,
        @fixed_at
      ])

    ids
  end

  describe "retrieve_package/2" do
    test "returns facts equal in confidence and age in id order, whatever order they were stored in",
         ctx do
      ids = store_identical_facts(ctx, 8)

      for _ <- 1..3 do
        assert {:ok, package} = recall(ctx)
        assert Enum.map(package.facts, & &1.id) == ids
      end

      assert {:ok, package} = recall(ctx, limit: 3)
      assert Enum.map(package.facts, & &1.id) == Enum.take(ids, 3)
    end

    test "measures a fact's validity against as_of, not against the clock", ctx do
      expired =
        insert_fact!(ctx.workspace, %{
          fact_text: "#{ctx.token} held until the start of 2020",
          valid_time_end: "2020-01-01 00:00:00"
        })

      assert {:ok, package} = recall(ctx)
      refute expired.id in Enum.map(package.facts, & &1.id)
      refute Map.has_key?(package.retrieval_plan, :as_of)

      # In 2019 the fact was still valid.
      assert {:ok, package} = recall(ctx, as_of: "2019-06-01T00:00:00Z")
      assert expired.id in Enum.map(package.facts, & &1.id)
      assert package.retrieval_plan.as_of == "2019-06-01 00:00:00"

      assert {:ok, package} = recall(ctx, as_of: ~U[2021-01-01 00:00:00Z])
      refute expired.id in Enum.map(package.facts, & &1.id)
    end

    test "refuses an as_of that is not a timestamp or lies outside the allowed range", ctx do
      for value <- ["nope", "1900-01-01T00:00:00Z", 42] do
        assert {:error, {:invalid_as_of, ^value}} = recall(ctx, as_of: value)
      end

      assert {:ok, _package} = recall(ctx, as_of: "")
    end
  end

  describe "AssociativeProjection" do
    setup ctx do
      ids = for n <- 1..8, do: "mem-#{ctx.token}-#{n}"

      for id <- Enum.reverse(ids) do
        {:ok, _} =
          Store.raw_query(
            "INSERT INTO memories (id, workspace_id, content, root_memory_id, created_at, updated_at) VALUES (?1, ?2, ?3, ?1, ?4, ?4)",
            [id, ctx.workspace, ctx.token, @fixed_at]
          )
      end

      scope =
        ScopeEnvelope.resolve(%{
          tenant_id: "default",
          workspace_id: ctx.workspace,
          actor_id: "agent:test"
        })

      {:ok, _} = AssociativeProjection.rebuild(scope)

      {:ok, _} =
        Store.raw_query("UPDATE memory_associations SET updated_at = ?2 WHERE workspace_id = ?1", [
          ctx.workspace,
          @fixed_at
        ])

      {:ok, scope: scope}
    end

    test "expands a cue into associations equal in confidence and age by id", ctx do
      assert {:ok, first} = AssociativeProjection.expand([ctx.token], ctx.scope, limit: 50)
      assert length(first) == 8
      assert Enum.map(first, & &1.id) == Enum.sort(Enum.map(first, & &1.id))

      for _ <- 1..3 do
        assert {:ok, ^first} = AssociativeProjection.expand([ctx.token], ctx.scope, limit: 50)
      end

      assert {:ok, again} =
               AssociativeProjection.expand([ctx.token], ctx.scope,
                 limit: 50,
                 as_of: ~U[2026-10-20 12:00:00Z]
               )

      assert again == first
    end
  end
end
