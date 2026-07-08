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
bin/optimal install
bin/optimal bootstrap
bin/optimal dev
bin/optimal doctor
bin/optimal reality-check
```

Agent loop commands:

```bash
bin/optimal boot
bin/optimal find "query" --workspace default:my-workspace
bin/optimal capture "raw signal" --workspace default:my-workspace
bin/optimal aware "important correction" --workspace default:my-workspace
bin/optimal close "what changed and how verified"
```

Runtime data lives in `.optimal/`.
Do not commit `.optimal/index.db`, cache files, connector keys, RocksDB stores, workspace imports, or private user data.
