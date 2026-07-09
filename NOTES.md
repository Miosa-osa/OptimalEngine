# Optimal Engine Notes

- 2026-07-08: The repo-native `bin/optimal` wrapper is the standard agent-facing command surface for this checkout.
- 2026-07-08: Direct `mix optimal.*` is appropriate for engine development, but product/agent memory operations should use `bin/optimal` when available.
- 2026-07-08: SQLite is the durable local runtime store today.
- 2026-07-08: RocksDB is the default persistent local knowledge graph backend when the NIF is installed.
- 2026-07-08: ETS and Mnesia are fallback or alternate graph backends, not the default source of truth.
- 2026-07-08: BusinessOS must store app state in BusinessOS and knowledge/memory in Optimal Engine.
- 2026-07-08: Every integration must preserve tenant, organization, workspace, Node, and policy scope.
- 2026-07-08: Public defaults must be repo-relative or environment-driven.
- 2026-07-08: Private machine paths, connector keys, runtime stores, and user data do not belong in public commits.
- 2026-07-09: `CLAUDE.md`, `BOOT.md`, `OPTIONS.md`, and `SYSTEM.md` are public entry docs for agents and users.
- 2026-07-09: Claude users should get the same `bin/optimal boot/find/capture/aware/close` memory loop from repo docs without relying on a private checkout.
