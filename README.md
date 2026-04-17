# Optimal Engine

Signal-native context storage for AI agents. A single Elixir application that treats
every piece of content as a classified **Signal** — routed, indexed, reasoned over,
and recallable at bounded cost.

- **SQLite + FTS5** for full-text search, with a tiered L0/L1/L2 loading model so
  agents never blow past their context window.
- **OWL 2 RL reasoning** in pure Elixir — no Java, no SPARQL endpoint — for
  graph-backed retrieval that goes beyond keyword match.
- **Episodic memory + SICA learning** — the engine remembers not just what was
  said, but what worked, what broke, and what patterns repeat.
- **Signal Theory classification** — every input resolved on `S=(Mode, Genre, Type,
  Format, Structure)` so routing and retrieval honor the shape of the signal, not
  just its tokens.

Built by [Roberto Luna](https://github.com/robertohluna). Private.

---

## Why this exists

Context windows are finite. Signal gets lost in noise. Agents forget what they
learned five turns ago. The Optimal Engine is a storage layer designed against
exactly those failure modes: it ranks, compacts, and tiers context so the agent
loads the minimum information needed for the maximum decision quality.

The theory driving it is **Signal Theory**: every output is a Signal, modeled as
`S = (Mode, Genre, Type, Format, Structure)`. The engine's job is to maintain the
highest Signal-to-Noise ratio achievable for a given retrieval. See
[`docs/concepts/signal-theory.md`](docs/concepts/signal-theory.md).

---

## Architecture

```
                          ┌───────────────────────────────┐
      user input ──────▶  │  Intake  →  Classifier  →  … │
                          └──────┬────────────────────────┘
                                 │
                                 ▼
                          ┌──────────────────────────────┐
                          │         Router               │  signals routed to nodes
                          └──────┬───────────────────────┘
                                 │
              ┌──────────────────┼────────────────────────┐
              ▼                  ▼                        ▼
       ┌───────────┐      ┌────────────┐          ┌──────────────┐
       │  Store    │      │ Knowledge  │          │    Memory    │
       │ SQLite +  │      │  triples + │          │  episodic +  │
       │   FTS5    │      │   OWL 2 RL │          │  cortex +    │
       │           │      │  reasoner  │          │  learning    │
       └────┬──────┘      └─────┬──────┘          └──────┬───────┘
            └────────────┬──────┴────────────────────────┘
                         ▼
                ┌──────────────────┐
                │  SearchEngine    │  hybrid BM25 + graph boost + temporal
                └─────────┬────────┘
                          ▼
                ┌────────────────────┐
                │ ContextAssembler   │  L0 → L1 → L2 tiered loading
                └────────┬───────────┘
                         ▼
                    agent prompt
```

Full walkthrough: [`docs/architecture/FULL-SYSTEM-ARCHITECTURE.md`](docs/architecture/FULL-SYSTEM-ARCHITECTURE.md).
Layer specs: [`docs/architecture/00-overview.md`](docs/architecture/00-overview.md)
through `07-governance.md`.

---

## Quick start

Requires Elixir `~> 1.17`, Erlang/OTP 26+, a C toolchain (for the exqlite NIF).

```bash
git clone git@github.com:robertohluna/OptimalEngine.git
cd OptimalEngine
mix deps.get
mix compile
```

First ingest:

```bash
mix optimal.ingest "Ed called about pricing, wants $2K per seat" --genre note
mix optimal.search "pricing"
mix optimal.l0
```

---

## Mix tasks

All commands are prefixed `mix optimal.*`. Full reference:
[`docs/guides/mix-tasks.md`](docs/guides/mix-tasks.md).

| Task                       | Purpose                                                       |
|---------------------------|---------------------------------------------------------------|
| `mix optimal.ingest`      | Classify, route, persist, and index a signal                  |
| `mix optimal.search`      | Hybrid BM25 + temporal + graph-boosted search                 |
| `mix optimal.read`        | Read a context by `optimal://` URI at a given tier            |
| `mix optimal.assemble`    | Build a tiered (L0/L1/L2) context bundle for a topic          |
| `mix optimal.l0`          | Print the always-loaded L0 context (~100 tokens per node)     |
| `mix optimal.ls`          | List contexts under an `optimal://` URI                       |
| `mix optimal.index`       | Full reindex of all markdown files under the root             |
| `mix optimal.intake`      | Interactive multi-line intake from stdin                      |
| `mix optimal.graph`       | Knowledge graph stats, triangles, clusters, hubs              |
| `mix optimal.reflect`     | Find missing edges from entity co-occurrences                 |
| `mix optimal.reweave`     | Find stale contexts on a topic + suggest updates              |
| `mix optimal.simulate`    | Run a "what if" scenario through the graph                    |
| `mix optimal.impact`      | Impact analysis for an entity or node                         |
| `mix optimal.remember`    | Store observations; mine friction patterns                    |
| `mix optimal.rethink`     | Synthesize observations into actionable knowledge             |
| `mix optimal.knowledge`   | Knowledge graph + SICA learning operations                    |
| `mix optimal.health`      | Diagnostics — orphans, drift, duplicates, fidelity            |
| `mix optimal.verify`      | Cold-read test of L0 abstract fidelity                        |
| `mix optimal.stats`       | Store statistics (counts, sizes, token budgets)               |
| `mix optimal.api`         | Start the HTTP API on port 4200                               |
| `mix optimal.graph_ui`    | Launch the graph visualizer against a running API             |
| `mix optimal.spec.*`      | Spec coverage, drift detection, reporting                     |

---

## Subsystems

Four cohesive subsystems live inside a single `:optimal_engine` app, one
supervision tree, one naming convention.

- **Core engine** (`lib/optimal_engine/`) — Intake, Router, Indexer, SearchEngine,
  ContextAssembler, Store (SQLite + FTS5 + ETS hot cache), L0Cache.
- **Knowledge** (`lib/optimal_engine/knowledge/`) — RDF triple store with pluggable
  backends (ETS, Mnesia, RocksDB), native SPARQL 1.1 execution, OWL 2 RL
  materialization.
- **Memory** (`lib/optimal_engine/memory/`) — episodic records, Cortex synthesis,
  SICA-style learning loop, session persistence, context injection.
- **Signal** (`lib/optimal_engine/signal/`) — CloudEvents v1.0.2 envelopes, Signal
  Theory classification, failure-mode detection, ETS-backed pub/sub + journal.

---

## Docs map

```
docs/
├── architecture/   ← the 7 layers + system overview + ADRs
├── concepts/       ← Signal Theory, three-spaces, methodology, kernel primitives
├── reference/      ← data model, search architecture, session lifecycle, hooks
├── guides/         ← getting started, mix tasks, writing guide
└── research/       ← exploratory work that informed the design
```

Start with [`docs/README.md`](docs/README.md) for the index.

---

## Development

```bash
mix test                  # full suite (689 tests, ~3s)
mix credo                 # lints
mix dialyzer              # optional — slow the first run
mix format                # after edits
```

Optional: the `:rocksdb` knowledge backend is gated behind a test tag and is
skipped unless the NIF is installed. The default ETS backend covers every
feature the default mix tasks exercise.

---

## Status

Private. Active development. Single-operator project. Not yet a published Hex
package; not yet accepting external contributions.
