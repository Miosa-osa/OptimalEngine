defmodule OptimalEngine.MemoryCore.WildcardGrantsTest do
  @moduledoc """
  A grant of `"*"` (every label, or every partition) is read the same way by
  the exports (`OptimalEngine.ReadScope`) and by governed recall
  (`RetrievalCoordinator`, `AssociativeProjection`): a key that may mint any
  grant, such as the bootstrap key, is not turned away from unpartitioned or
  unlabelled memory by a literal `*`.
  """

  use ExUnit.Case, async: false

  alias OptimalEngine.MemoryCore.{AssociativeProjection, ID, RetrievalCoordinator, ScopeEnvelope}
  alias OptimalEngine.MemoryCore.Store, as: MemoryCoreStore
  alias OptimalEngine.Store

  defp workspace, do: "wildcard-#{System.unique_integer([:positive])}"

  defp fact!(workspace_id, text, labels, partitions) do
    fact = %{
      id: ID.random_id("fact"),
      tenant_id: "default",
      workspace_id: workspace_id,
      fact_text: text,
      subject_anchor: "alice",
      action_class: "relaxes",
      lifecycle_state: "accepted",
      contradiction_status: "none",
      aggregate_confidence: 0.8,
      aggregate_precision: 0.8,
      security_labels: labels,
      partition_ids: partitions,
      supporting_evidence_links: []
    }

    :ok = MemoryCoreStore.insert_fact(fact)
    fact
  end

  defp recall(workspace_id, labels, partitions) do
    {:ok, package} =
      RetrievalCoordinator.retrieve_package("How does Alice relax?",
        workspace_id: workspace_id,
        actor_id: "agent:test",
        allowed_security_labels: labels,
        allowed_partitions: partitions,
        limit: 4
      )

    MapSet.new(Enum.map(package.facts, & &1.id))
  end

  describe "governed recall" do
    test "a key granted * for both kinds recalls unlabelled and labelled facts" do
      ws = workspace()
      plain = fact!(ws, "Alice relaxes by painting.", [], [])
      held = fact!(ws, "Alice relaxes with the restricted launch plan.", ["restricted"], ["team-a"])

      assert recall(ws, ["*"], ["*"]) == MapSet.new([plain.id, held.id])
    end

    test "each kind is read on its own" do
      ws = workspace()
      plain = fact!(ws, "Alice relaxes by painting.", [], [])
      labelled = fact!(ws, "Alice relaxes with a restricted note.", ["restricted"], [])
      partitioned = fact!(ws, "Alice relaxes in the team-a room.", [], ["team-a"])

      assert recall(ws, ["*"], []) == MapSet.new([plain.id, labelled.id])
      assert recall(ws, [], ["*"]) == MapSet.new([plain.id, partitioned.id])
      assert recall(ws, [], []) == MapSet.new([plain.id])
    end
  end

  describe "the associative projection" do
    test "a key granted * reads the associations that carry labels and partitions" do
      ws = workspace()

      for {id, labels, partitions} <- [
            {"plain", "[]", "[]"},
            {"held", ~s(["restricted"]), ~s(["team-a"])}
          ] do
        {:ok, _} =
          Store.raw_query(
            """
            INSERT INTO memory_associations
              (id, tenant_id, workspace_id, cue, normalized_cue, tag, from_object_type, from_object_id,
               to_object_type, to_object_id, relationship_type, security_labels, partition_ids)
            VALUES (?1, 'default', ?2, 'alice', 'alice', 't', 'fact', ?3, 'fact', ?4, 'related', ?5, ?6)
            """,
            ["assoc-#{id}-#{ws}", ws, "from-#{id}", "to-#{id}", labels, partitions]
          )
      end

      scope = %ScopeEnvelope{tenant_id: "default", workspace_id: ws}

      expand = fn labels, partitions ->
        {:ok, found} =
          AssociativeProjection.expand(["alice"], scope,
            allowed_security_labels: labels,
            allowed_partitions: partitions
          )

        found |> Enum.map(& &1.id) |> Enum.sort()
      end

      assert expand.(["*"], ["*"]) == ["assoc-held-#{ws}", "assoc-plain-#{ws}"]
      assert expand.([], []) == ["assoc-plain-#{ws}"]
      assert expand.(["*"], []) == ["assoc-plain-#{ws}"]
    end
  end
end
