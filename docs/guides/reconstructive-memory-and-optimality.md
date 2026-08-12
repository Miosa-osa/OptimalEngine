# Reconstructive Memory And Optimality

## Purpose

Memory Reconstruction assembles task context by traversing authorized associations between governed objects.

It complements direct retrieval without replacing Memory Core truth.

## Interface

All application callers use the same Retrieval Coordinator Interface:

```elixir
OptimalEngine.MemoryCore.retrieve(query,
  tenant_id: "default",
  workspace_id: "default:miosa",
  actor_id: "user:roberto",
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

Outcome feedback requires the original actor or an explicit reconstruction review permission.

## Projection Maintenance

The Associative Projection is rebuilt from accepted Facts, current Memory Objects, recorded Episodes, and current Relationship Edges.

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
