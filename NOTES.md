# Optimal Engine Notes

- 2026-07-08: Roberto's private OptimalOS checkout uses `/Users/rhl/code/OptimalOS/.system/oe` as the agent-facing wrapper.
- 2026-07-08: Direct `mix optimal.*` is appropriate for engine development, but product/agent memory operations should use the wrapper when available.
- 2026-07-08: SQLite is the durable local runtime store today.
- 2026-07-08: RocksDB is the default persistent local knowledge graph backend when the NIF is installed.
- 2026-07-08: ETS and Mnesia are fallback or alternate graph backends, not the default source of truth.
- 2026-07-08: BusinessOS must store app state in BusinessOS and knowledge/memory in Optimal Engine.
- 2026-07-08: Every integration must preserve tenant, organization, workspace, Node, and policy scope.

