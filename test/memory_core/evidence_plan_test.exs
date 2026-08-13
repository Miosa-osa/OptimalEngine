defmodule OptimalEngine.MemoryCore.EvidencePlanTest do
  use ExUnit.Case, async: true

  alias OptimalEngine.MemoryCore.EvidencePlan

  test "classifies and decomposes multi-clause comparison requests" do
    plan = EvidencePlan.build("How do Alice and Bob relax, and which hobbies do both enjoy?")

    assert plan.intent == "comparison_set"
    assert "primary" in plan.required_roles
    assert Enum.any?(plan.required_roles, &String.starts_with?(&1, "clause_"))
    assert Enum.any?(plan.obligations, &(&1.role == "entity:alice"))
    assert Enum.any?(plan.obligations, &(&1.role == "entity:bob"))
    assert length(plan.probes) <= 8
  end

  test "adds explicit temporal and inference obligations" do
    temporal = EvidencePlan.build("When did Alice last visit the clinic after moving?")
    inference = EvidencePlan.build("What suggests that Bob likely has asthma?")

    assert temporal.intent == "temporal"
    assert "temporal" in temporal.required_roles
    assert inference.intent == "inference"
    assert "inference" in inference.required_roles
  end

  test "simple requests retain one required primary probe" do
    plan = EvidencePlan.build("Alice's favorite color?")

    assert plan.intent == "single_hop"

    assert hd(plan.obligations) == %{
             role: "primary",
             probe: "Alice's favorite color?",
             required: true
           }
  end
end
