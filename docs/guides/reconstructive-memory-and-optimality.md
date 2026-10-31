# Reconstructive Memory And Optimality

## Purpose

Memory Reconstruction assembles task context by traversing authorized associations between governed objects.

It complements direct retrieval without replacing Memory Core truth.

## Interface

All application callers use the same Retrieval Coordinator Interface:

```elixir
OptimalEngine.MemoryCore.retrieve(query,
  tenant_id: "default",
  workspace_id: "default:example",
  actor_id: "user:example",
  allowed_security_labels: [],
  allowed_partitions: [],
  time_mode: "current_valid",
  strategy: :reconstructive,
  token_budget: 8_000,
  reconstruction_steps: 4
)
```

The result is always a governed Context Package.

## Security

Missing label and partition grants fail closed.

Authorization predicates run while candidates are expanded.

Unauthorized objects never enter the ranking window, traversal state, trace, or rendered Context Package.

A durable versioned memory carries the `security_labels` it was remembered with in its `metadata`, and its associations carry them too, so a labelled memory is recalled only for a caller granted its labels.

Outcome feedback requires the original actor or an explicit reconstruction review permission.

## Projection Maintenance

The Associative Projection is rebuilt from accepted Facts, current Memory Objects, durable versioned memories, recorded Episodes, and current Relationship Edges.
A workspace's first reconstructive recall builds it.
A later recall that finds one of those sources written or ended since the projection was built answers from the projection as it is and queues a `maintenance.association_projection` job, which rebuilds it in the background ([maintenance jobs](operating-layer.md#maintenance-jobs)).
An Episode's provenance becomes the episode's own link plus one link per source package, signal and claim it names.

```bash
.system/oe memory_project miosa
```

Deleting the projection loses no canonical knowledge.

## Evaluation

Governed evaluation cases can require terms, forbid leakage terms, require canonical object links, require abstention, and enforce token limits.

The evaluator records completeness, citation precision, canonical recall, policy safety, abstention, and token efficiency in the existing evaluation tables.

## Optimality Classification

The classifier has two scopes.

`architecture` requires storage integrity, migration parity, evaluation pass rate, authorization regressions, zero full-suite failures, and current documentation.

`system` requires all architecture gates plus live context health at or above the configured threshold.

```bash
.system/oe optimality architecture miosa --verified
.system/oe optimality system miosa --verified
```

The `--verified` flag is intentionally explicit.

It should only be used after the referenced release checks have actually passed.

An assessment is a time-stamped evidence record, not a permanent claim about future system state.

## Governed data remediation

Use `oe data_review <workspace>` to inspect clustered actionable claims, memory candidates, routing proposals, unresolved entity mentions, and orphan workspace scopes in one read-only dashboard.

Use `oe claim_batch` and `oe route_batch` only with explicit reviewed identifiers.
The commands do not infer approval, and invalid decisions fail instead of defaulting to rejection.

Use `oe data_recheck <workspace>` after reviewed changes settle.
It rebuilds the associative projection and returns the updated dashboard without promoting additional claims.

The Data Quality Scheduler records a daily read-only snapshot for every active workspace and records score regressions.
