defmodule OptimalEngine.MemoryCore.KnowledgeLifecycle do
  @moduledoc """
  Deprecated facade for the Truth Lifecycle.

  The Source -> Claim -> Fact -> Memory Object transitions now live in
  domain-verb modules per the Memory Core cleanup rules:

    * `OptimalEngine.MemoryCore.ClaimExtractor.extract_from_source/2`
    * `OptimalEngine.MemoryCore.FactPromoter.promote/2` (and `reject/2`)
    * `OptimalEngine.MemoryCore.MemoryObject.build_from_fact/2`

  This module only delegates. It is NOT behavior-compatible with the legacy
  implementation it replaced:

    * `promote_claim_to_fact/2` now enforces evidence review. Pass
      `:verifier_id` or `:actor_id` (explicit reviewer approval) or opt in
      to auto-promotion with `policy: :auto`, gated by
      `OptimalEngine.MemoryCore.ScoringPolicy.auto_promote_threshold/0`.
      With no review options the call returns `{:error, :approval_required}`
      where the legacy module promoted unconditionally. Self-review (the
      verifier matching the Claim's own `evaluator_id`) is rejected unless
      `allow_self_review: true` is given.
    * `build_memory_object/2` now requires a persisted Fact with
      `lifecycle_state: "accepted"` and non-empty accepted Claim lineage,
      returning `{:error, :fact_not_found}` / `{:error, :fact_not_accepted}`
      otherwise.
    * All three entry points return typed structs (`%Claim{}`, `%Fact{}`,
      `%MemoryObject{}`) instead of plain maps: Access syntax
      (`claim[:id]`) and bare `Jason.encode!/1` on the results no longer
      work.

  Do not add new lifecycle logic here.
  """

  alias OptimalEngine.MemoryCore.{ClaimExtractor, FactPromoter, MemoryObject}

  @deprecated "Use OptimalEngine.MemoryCore.ClaimExtractor.extract_from_source/2 (returns {:ok, %Claim{}})"
  defdelegate extract_claim(source_package, opts \\ []),
    to: ClaimExtractor,
    as: :extract_from_source

  @deprecated "Use OptimalEngine.MemoryCore.FactPromoter.promote/2 (requires :verifier_id/:actor_id or policy: :auto; returns {:ok, %Fact{}})"
  defdelegate promote_claim_to_fact(claim, opts \\ []), to: FactPromoter, as: :promote

  @deprecated "Use OptimalEngine.MemoryCore.MemoryObject.build_from_fact/2 (requires a persisted accepted Fact; returns {:ok, %MemoryObject{}})"
  defdelegate build_memory_object(fact, opts \\ []), to: MemoryObject, as: :build_from_fact
end
