defmodule OptimalEngine.MemoryCore.ReconstructionTest do
  use ExUnit.Case, async: false

  alias OptimalEngine.MemoryCore

  alias OptimalEngine.MemoryCore.{
    AssociativeProjection,
    Episode,
    ReconstructionLearning,
    ScopeEnvelope
  }

  alias OptimalEngine.MemoryCore.Store, as: MemoryCoreStore
  alias OptimalEngine.Store

  setup do
    suffix = System.unique_integer([:positive])
    workspace = "reconstruction-#{suffix}"
    actor = "user:test-#{suffix}"

    facts = [
      {"fact_northwind_#{suffix}",
       "Northwind commitment requires customer feedback before the next working session", "[]",
       "[]"},
      {"fact_feedback_#{suffix}",
       "Customer feedback changed the Northwind onboarding and commercial plan", "[]", "[]"},
      {"fact_session_#{suffix}",
       "The next Northwind working session decides commitment ownership and timing", "[]", "[]"}
    ]

    Enum.each(facts, fn {id, text, labels, partitions} ->
      insert_fact(id, workspace, text, labels, partitions)
    end)

    on_exit(fn ->
      Store.raw_execute("DELETE FROM memory_consolidation_proposals WHERE workspace_id = ?1", [
        workspace
      ])

      Store.raw_execute("DELETE FROM memory_path_priors WHERE workspace_id = ?1", [workspace])

      Store.raw_execute("DELETE FROM memory_reconstruction_outcomes WHERE workspace_id = ?1", [
        workspace
      ])

      Store.raw_execute("DELETE FROM memory_reconstruction_runs WHERE workspace_id = ?1", [
        workspace
      ])

      Store.raw_execute("DELETE FROM memory_associations WHERE workspace_id = ?1", [workspace])
      Store.raw_execute("DELETE FROM facts WHERE workspace_id = ?1", [workspace])
    end)

    %{workspace: workspace, actor: actor, facts: facts}
  end

  test "returns one governed Context Package and atomically persists its trace", %{
    workspace: workspace,
    actor: actor
  } do
    assert {:ok, package} =
             MemoryCore.retrieve("Northwind commitment customer feedback",
               tenant_id: "default",
               workspace_id: workspace,
               actor_id: actor,
               strategy: :reconstructive,
               reconstruction_steps: 3,
               reconstruction_tokens: 2_000
             )

    run_id = package.metadata.reconstruction_run_id
    assert package.workspace_id == workspace
    assert package.authorization_envelope.actor_id == actor
    assert package.returned_object_links != []
    assert package.retrieval_plan.strategy == "reconstructive"
    assert package.retrieval_plan.reconstruction.paths != []
    assert package.retrieval_plan.reconstruction.required_evidence_roles == ["primary"]
    assert package.retrieval_plan.reconstruction.missing_evidence_roles == []
    assert package.retrieval_plan.reconstruction.stop_reason == "coverage_satisfied"
    assert package.sections.reconstruction =~ "Northwind"

    assert {:ok, [["completed", package_id, steps, paths]]} =
             Store.raw_query(
               "SELECT r.status, r.context_package_id, COUNT(DISTINCT s.id), COUNT(DISTINCT p.id) FROM memory_reconstruction_runs r JOIN memory_reconstruction_steps s ON s.run_id = r.id JOIN memory_association_paths p ON p.run_id = r.id WHERE r.id = ?1 GROUP BY r.id",
               [run_id]
             )

    assert package_id == package.id
    assert steps > 0
    assert paths > 0
  end

  test "refresh preserves reconstructive strategy and evidence requirements", %{
    workspace: workspace,
    actor: actor
  } do
    assert {:ok, original} = reconstruct(workspace, actor)

    assert {:ok, refreshed} =
             MemoryCore.refresh_context_package(original.id,
               tenant_id: "default",
               workspace_id: workspace,
               actor_id: actor,
               force: true
             )

    assert refreshed.metadata.retrieval_strategy == "reconstructive"
    assert refreshed.retrieval_plan.strategy == "reconstructive"

    assert refreshed.retrieval_plan.reconstruction.required_evidence_roles ==
             original.retrieval_plan.reconstruction.required_evidence_roles
  end

  test "authorization is fail-closed during association expansion", %{
    workspace: workspace,
    actor: actor
  } do
    restricted_id = "fact_restricted_#{System.unique_integer([:positive])}"

    insert_fact(
      restricted_id,
      workspace,
      "Northwind restricted acquisition secret",
      ~s(["executive"]),
      ~s(["board"])
    )

    assert {:ok, package} =
             MemoryCore.retrieve("Northwind restricted acquisition secret",
               tenant_id: "default",
               workspace_id: workspace,
               actor_id: actor,
               strategy: :reconstructive
             )

    refute Enum.any?(package.returned_object_links, &(&1.id == restricted_id))
    refute package.sections.reconstruction =~ "acquisition secret"

    assert {:ok, allowed} =
             MemoryCore.retrieve("Northwind restricted acquisition secret",
               tenant_id: "default",
               workspace_id: workspace,
               actor_id: actor,
               allowed_security_labels: ["executive"],
               allowed_partitions: ["board"],
               strategy: :reconstructive
             )

    assert Enum.any?(allowed.returned_object_links, &(&1.id == restricted_id))
  end

  test "outcomes credit intent-specific paths without creating Facts", %{
    workspace: workspace,
    actor: actor
  } do
    assert {:ok, package} = reconstruct(workspace, actor)
    run_id = package.metadata.reconstruction_run_id
    scope = scope(workspace, actor)

    assert {:ok, [[before_facts]]} =
             Store.raw_query("SELECT COUNT(*) FROM facts WHERE workspace_id = ?1", [workspace])

    assert {:ok, result} = ReconstructionLearning.record_outcome(run_id, "success", scope)
    assert result.learning_scope == "intent_path"

    assert {:ok, [[after_facts]]} =
             Store.raw_query("SELECT COUNT(*) FROM facts WHERE workspace_id = ?1", [workspace])

    assert before_facts == after_facts

    assert {:ok, [[priors]]} =
             Store.raw_query("SELECT COUNT(*) FROM memory_path_priors WHERE workspace_id = ?1", [
               workspace
             ])

    assert priors > 0
  end

  test "consolidation groups recurring connected paths and remains review-only", %{
    workspace: workspace,
    actor: actor
  } do
    scope = scope(workspace, actor)

    for _ <- 1..2 do
      assert {:ok, package} = reconstruct(workspace, actor)

      assert {:ok, _} =
               ReconstructionLearning.record_outcome(
                 package.metadata.reconstruction_run_id,
                 "success",
                 scope
               )
    end

    assert {:ok, proposals} =
             ReconstructionLearning.propose_consolidation(scope, minimum_observations: 2)

    assert proposals != []
    assert Enum.all?(proposals, &(&1.status == "proposed" and &1.metadata.review_required))
    assert {:ok, quality} = ReconstructionLearning.measure(scope)
    assert quality.runs == 2
    assert quality.association_paths > 0
  end

  test "associative projection is rebuildable and workspace scoped", %{
    workspace: workspace,
    actor: actor
  } do
    scope = scope(workspace, actor)
    assert {:ok, first} = AssociativeProjection.rebuild(scope)
    assert first.associations > 0
    assert {:ok, paths} = AssociativeProjection.expand(["northwind"], scope)
    assert paths != []
    assert {:ok, second} = AssociativeProjection.rebuild(scope)
    assert second.associations == first.associations
  end

  test "reconstructs governed durable memories without promoting them to facts", %{
    workspace: workspace,
    actor: actor
  } do
    memory_id = "mem_durable_#{System.unique_integer([:positive])}"

    assert :ok =
             Store.raw_execute(
               "INSERT INTO memories (id, tenant_id, workspace_id, content, root_memory_id, audience, metadata) VALUES (?1, 'default', ?2, ?3, ?1, 'default', ?4)",
               [
                 memory_id,
                 workspace,
                 "The retrieval portfolio release improved evidence recall without changing canonical facts",
                 Jason.encode!(%{
                   "memory_core_source_package_id" => "sp_durable_test",
                   "projection_kind" => "versioned_memory_staging"
                 })
               ]
             )

    assert {:ok, package} =
             MemoryCore.retrieve("retrieval portfolio evidence recall",
               tenant_id: "default",
               workspace_id: workspace,
               actor_id: actor,
               strategy: :reconstructive
             )

    assert package.sections.reconstruction =~ "improved evidence recall"
    assert package.retrieval_plan.reconstruction.paths != []

    assert Enum.any?(package.evidence_links, fn link ->
             (Map.get(link, :id) || Map.get(link, "id")) == memory_id
           end)

    assert {:ok, [[fact_count]]} =
             Store.raw_query("SELECT COUNT(*) FROM facts WHERE id = ?1", [memory_id])

    assert fact_count == 0

    Store.raw_execute("DELETE FROM memories WHERE id = ?1", [memory_id])
  end

  test "reconstructs an episode with the sources its provenance names as evidence links", %{
    workspace: workspace,
    actor: actor
  } do
    cue = "episodecue#{System.unique_integer([:positive])}"

    {:ok, episode} =
      Episode.new(%{
        tenant_id: "default",
        workspace_id: workspace,
        kind: "transcript",
        summary: "The weekly sync #{cue} settled the storage plan",
        provenance: %{
          "source_package_id" => "sp_#{cue}",
          "signal_id" => "sig_#{cue}",
          "claim_id" => "cl_#{cue}"
        }
      })

    assert :ok = MemoryCoreStore.insert_episode(episode)
    on_exit(fn -> Store.raw_execute("DELETE FROM episodes WHERE id = ?1", [episode.id]) end)

    links = [
      %{"type" => "episode", "id" => episode.id},
      %{"type" => "source_package", "id" => "sp_#{cue}"},
      %{"type" => "signal", "id" => "sig_#{cue}"},
      %{"type" => "claim", "id" => "cl_#{cue}"}
    ]

    # The Context Package is stored as /api/assemble stores it, links and all.
    assert {:ok, package} =
             MemoryCore.retrieve("#{cue} storage plan",
               tenant_id: "default",
               workspace_id: workspace,
               actor_id: actor,
               strategy: :hybrid
             )

    assert Enum.all?(links, &(&1 in package.evidence_links))

    scope = scope(workspace, actor)
    assert {:ok, [association]} = AssociativeProjection.expand([cue], scope)
    assert association.evidence_links == links

    # An association projected before episodes carried links holds the
    # provenance map itself, and reads as the same links.
    assert :ok =
             Store.raw_execute(
               "UPDATE memory_associations SET evidence_links = ?2 WHERE workspace_id = ?1 AND from_object_type = 'episode'",
               [workspace, Jason.encode!(episode.provenance)]
             )

    assert {:ok, [projected_before]} = AssociativeProjection.expand([cue], scope)
    assert projected_before.evidence_links == links
  end

  defp reconstruct(workspace, actor) do
    MemoryCore.retrieve("Northwind commitment customer feedback",
      tenant_id: "default",
      workspace_id: workspace,
      actor_id: actor,
      strategy: :reconstructive
    )
  end

  defp scope(workspace, actor) do
    ScopeEnvelope.resolve(%{tenant_id: "default", workspace_id: workspace, actor_id: actor})
  end

  defp insert_fact(id, workspace, text, labels, partitions) do
    assert :ok =
             Store.raw_execute(
               "INSERT INTO facts (id, tenant_id, workspace_id, fact_text, lifecycle_state, verification_status, aggregate_confidence, aggregate_precision, security_labels, partition_ids) VALUES (?1, 'default', ?2, ?3, 'accepted', 'verified', 0.9, 0.9, ?4, ?5)",
               [id, workspace, text, labels, partitions]
             )
  end
end
