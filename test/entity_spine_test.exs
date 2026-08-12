defmodule OptimalEngine.EntitySpineTest do
  use ExUnit.Case, async: false

  alias OptimalEngine.{
    DataContract,
    EntityProjection,
    EntityQuality,
    EntityRegistry,
    EntityResolution,
    RelationshipRegistry,
    Store
  }

  setup do
    workspace = "entity-spine-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      for table <-
            ~w(resolution_decisions entity_lineage entity_mentions entity_identifiers entity_aliases relationship_edges canonical_entities) do
        Store.raw_execute("DELETE FROM #{table} WHERE workspace_id = ?1", [workspace])
      end
    end)

    %{workspace: workspace}
  end

  test "resolves aliases to durable canonical identity and records review", %{workspace: workspace} do
    assert {:ok, roberto} =
             EntityRegistry.register(%{
               workspace_id: workspace,
               entity_kind: "person",
               canonical_name: "Roberto H. Luna",
               created_by: "test",
               aliases: [%{alias: "Roberto Luna"}],
               identifiers: [
                 %{
                   namespace: "email",
                   value: "roberto@miosa.ai",
                   verification_status: "verified"
                 }
               ]
             })

    assert {:ok, mention} =
             EntityResolution.resolve(%{
               workspace_id: workspace,
               proposed_kind: "person",
               surface_text: "Roberto Luna",
               source_span: %{start: 10, end: 23}
             })

    assert [%{id: id, score: 1.0}] = mention.candidates
    assert id == roberto.id

    assert {:ok, decision} =
             EntityResolution.decide(mention.id, :link,
               workspace_id: workspace,
               actor_id: "test:reviewer",
               entity_id: roberto.id,
               reason: "exact reviewed alias"
             )

    assert decision.entity_id == roberto.id
    assert {:ok, []} = EntityResolution.queue(workspace)
    assert {:ok, %{unresolved_mentions: 0, orphan_resolutions: 0}} = EntityQuality.run(workspace)
  end

  test "creates a new identity from a reviewed mention", %{workspace: workspace} do
    assert {:ok, mention} =
             EntityResolution.resolve(%{
               workspace_id: workspace,
               proposed_kind: "organization",
               surface_text: "Commas"
             })

    assert {:ok, %{entity_id: entity_id}} =
             EntityResolution.decide(mention.id, :new_entity,
               workspace_id: workspace,
               actor_id: "test:reviewer",
               reason: "confirmed organization"
             )

    assert {:ok, %{id: ^entity_id, canonical_name: "Commas", entity_kind: "organization"}} =
             EntityRegistry.get(entity_id, workspace)
  end

  test "merges duplicate identities without losing lineage", %{workspace: workspace} do
    assert {:ok, winner} =
             EntityRegistry.register(%{
               workspace_id: workspace,
               entity_kind: "organization",
               canonical_name: "MIOSA",
               created_by: "test"
             })

    assert {:ok, loser} =
             EntityRegistry.register(%{
               workspace_id: workspace,
               entity_kind: "organization",
               canonical_name: "Miosa AI",
               created_by: "test"
             })

    assert {:ok, %{merged: loser_id, into: winner_id}} =
             EntityRegistry.merge(loser.id, winner.id,
               workspace_id: workspace,
               actor_id: "test:reviewer",
               reason: "same legal operating identity"
             )

    assert loser_id == loser.id
    assert winner_id == winner.id

    assert {:ok, %{lifecycle_state: "merged", successor_entity_id: successor}} =
             EntityRegistry.get(loser.id, workspace)

    assert successor == winner.id

    assert {:ok, [%{operation: "merge", successor: successor}]} =
             EntityRegistry.history(loser.id, workspace)

    assert successor == winner.id
  end

  test "validates typed temporal relationships and builds a projection", %{workspace: workspace} do
    assert {:ok, person} =
             EntityRegistry.register(%{
               workspace_id: workspace,
               entity_kind: "person",
               canonical_name: "Roberto Luna"
             })

    assert {:ok, organization} =
             EntityRegistry.register(%{
               workspace_id: workspace,
               entity_kind: "organization",
               canonical_name: "MIOSA"
             })

    assert {:ok, relationship} =
             RelationshipRegistry.relate(%{
               workspace_id: workspace,
               from_entity_id: person.id,
               relationship_type: "member_of",
               to_entity_id: organization.id,
               actor_id: "test:reviewer",
               valid_time_start: "2026-01-01T00:00:00Z",
               evidence_links: [%{source: "test"}]
             })

    assert relationship.relationship_type == "member_of"
    assert {:ok, projection} = EntityProjection.build(person.id, workspace)
    assert projection.entity.id == person.id
    assert [%{to_entity_id: target, relationship_type: "member_of"}] = projection.relationships
    assert target == organization.id

    assert {:error, {:contract_violation, %{missing: missing}}} =
             DataContract.validate(:relationship, %{workspace_id: workspace})

    assert "from_entity_id" in missing
  end
end
