# Optimal Engine Resources

Start here:

- `AGENTS.md` — agent boot, runtime boundaries, store model, and verification rules.
- `docs/guides/getting-started.md` — local setup.
- `docs/guides/installation-and-deployment.md` — install and deploy path.
- `docs/guides/store-and-layer-reality.md` — stores and layer ownership.
- `docs/guides/agent-cli-sop.md` — agent CLI operating procedure.
- `docs/architecture/STORAGE-AND-PROJECTION-MAP.md` — canonical storage/projection map.
- `docs/reference/backend-readiness.md` — backend readiness checks.
- `skills/optimal-engine/README.md` — engine skill docs.

Core local commands:

```bash
make install
make bootstrap
make dev
curl http://localhost:4200/api/health
mix optimal.reality_check
```

When operating from Roberto's private OptimalOS checkout, prefer:

```bash
/Users/rhl/code/OptimalOS/.system/oe boot
/Users/rhl/code/OptimalOS/.system/oe find "query" <workspace>
/Users/rhl/code/OptimalOS/.system/oe capture "raw signal" <workspace> note
/Users/rhl/code/OptimalOS/.system/oe aware "important correction" <workspace>
/Users/rhl/code/OptimalOS/.system/oe close "what changed and how verified" <workspace>
```

Runtime data lives in `.optimal/`.
Do not commit `.optimal/index.db`, cache files, connector keys, RocksDB stores, workspace imports, or private user data.

