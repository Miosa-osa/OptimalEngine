# ADR 0001: Governed Reconstructive Memory

- Status: Accepted
- Date: 2026-08-12

## Context

Reconstructive recall needs multi-step cue expansion without creating a second truth system or bypassing tenant, workspace, actor, label, partition, provenance, and temporal policy.

Compatibility search rows are useful projections, but they are not canonical Memory Core truth.

## Decision

Memory Reconstruction is a strategy inside `MemoryCore.RetrievalCoordinator`.

Every strategy returns one governed Context Package through the same Interface.

The Associative Projection is a rebuildable Retrieval projection derived from accepted Facts, current Memory Objects, recorded Episodes, and current Relationship Edges.

Authorization predicates run during association candidate expansion and fail closed.

Reconstruction Runs, ordered steps, Association Paths, and outcomes are audit and learning records.

Outcome learning is conditioned on intent and exact paths.

Consolidation creates review-required proposals and never promotes Facts directly.

## Consequences

- `ContextAssembler` remains a compatibility Module, not the canonical answer surface.
- `MemoryReconstructor` remains only as a deprecated compatibility Adapter.
- Tiered, reconstructive, and hybrid retrieval share Scope Envelope, budget, provenance, persistence, and Context Package contracts.
- The projection can be rebuilt after schema, policy, or model changes.
- An Optimality Assessment must cite verification evidence before using the `optimal` classification.
