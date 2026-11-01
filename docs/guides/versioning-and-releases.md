# Versioning And Releases

Optimal Engine uses one traceable release identity across source, runtime, storage, projections, and benchmarks.

## Release identity

Every build reports:

```text
repository identity and contract schema version
application version
release channel
Git commit SHA
build timestamp
API version
expected database migration
required capability identifiers
retrieval and projection component versions
```

Read it from `GET /api/version`.
The lightweight `GET /api/health` and `GET /api/status` responses include the same identity.

The current tracked contract is application `0.3.12`, API `v1`, contract schema `1`, expected migration `85`.
[engine-contract.json](../../engine-contract.json) supplies repository, schema, and capability metadata to [Version.info/0](../../lib/optimal_engine/version.ex) at compilation.
[test/version_test.exs](../../test/version_test.exs) checks that runtime identity matches the contract.
The runner applies every migration whose version is not yet recorded, but `expected_migration` and the replication gate compare the highest number, so two Engines that both report the same number must have applied the same set.
A migration number is therefore provisional until its change merges: the change that merges next takes the highest number on main plus one.
The number lives in one place in `lib/optimal_engine/store/migrations.ex` (the migration's version attribute) and in these pins: `engine-contract.json`, `README.md`, `OPTIONS.md`, this guide, `test/version_test.exs`, `test/api/router_test.exs`, `test/support/conformance_stub_transport.ex`, and `benchmarks/tests/test_truememory_compat.py`.
Git SHA and timestamp are build-time metadata; changing branches does not prove an already running process changed.
A missing build SHA may be reported as `unknown` and is not an acceptable exact-commit identity for an integration requiring a pin.
The commit and build time are compiled into the release, so a build that reuses an earlier compilation of that module reports the values from that earlier compile rather than the ones it was given.
Compile with the metadata variables set before assembling the release, for example `mix compile --force && mix release optimal`; [deploy/Dockerfile.engine](../../deploy/Dockerfile.engine) does this so a cached build cannot bake a stale commit into a new image.
Touching the module's source is not reliable either: Mix compares modification times at second resolution, and a touch in the same second as the previous compile is not stale.
Deleting the compiled module is worse: Mix does not treat a missing output as stale, and the release then starts without that module while `/api/version` and `/api/health` answer 500.

Canopy's workspace bridge validates a local checkout before running allowlisted Mix tasks.
It checks the source root, canonical origin, clean status, pinned commit, and manifest compatibility.
That preflight does not contact or attest a separately running Engine HTTP service.
An HTTP consumer must separately compare the service response with its approved build/contract and authenticate the endpoint; this repository does not currently supply a universal remote attestation gate.

## Release channels

A running Engine reports which release stream it serves in `release_channel`.

| Channel | Meaning |
| --- | --- |
| `dev` | The default. An unversioned build, a checkout, or a local run. |
| `stable` | A released version an operator expects to keep running. |
| `beta` | A candidate version under observation before it reaches `stable`. |
| `pinned` | A version held deliberately, usually for a single tenant or a compatibility reason. |

Set `OPTIMAL_RELEASE_CHANNEL` to `dev`, `stable`, `beta`, or `pinned`.
The runtime rejects any other value at boot instead of starting with a typo, and an absent value means `dev`.
The channel is deployment state, not build state: one image can serve different channels, so it is read when a request asks for the identity rather than baked into the artifact.
An update controller compares the reported channel with the one it intended to run.
The Engine image records the channel as its `OPTIMAL_RELEASE_CHANNEL` default, which the `deploy/Dockerfile.engine` build takes from the `OPTIMAL_RELEASE_CHANNEL` build argument.

## Conformance as a release gate

`mix optimal.conformance --url <engine url> --key <key>` checks a live Engine against this contract and its operating surface, and prints a JSON report with pass, fail, or skip and the evidence per check.
It covers the release contract, enforced authentication, workspace-scoped keys, a decision and the evidence chain, every store family the Engine lists, the size gauges and profiles, a use-case preset applied and removed, the pre-send draft check, analysis reports and the job queue, replication status, the viability report, and the operating routes.
It exits non-zero on any failure.
A release candidate earns promotion to a channel only when a run against a fresh Engine passes.
When `scripts/store_reality_proof.exs` is present the run also executes it as a separate process against a disposable store under the system temp directory, and reports its per-store verdict as one more check; `--no-store-proof` leaves it out.
That proof answers for the code in the checkout, while the other checks answer for the Engine the caller named.

## Version policy

The application version in `mix.exs` follows Semantic Versioning.

- Increment the major version for incompatible public API or persisted-contract changes.
- Increment the minor version for backward-compatible capabilities, schema migrations, and material retrieval behavior.
- Increment the patch version for backward-compatible fixes and operational hardening.
- Ordinary commits retain their exact Git SHA even when they do not create a release.

Database migrations are append-only and independently ordered.
Never edit a migration that may already be applied.

Retrieval planners, routers, selection policies, projections, and persisted data contracts own explicit component versions.
Change a component version whenever persisted meaning or deterministic behavior changes incompatibly.

## Upgrade notes

Some migrations need one operator step after the upgraded Engine has booted.

| Migration | After upgrading |
| --- | --- |
| 76, graph edges keyed by tenant and workspace | Run one graph backfill over every workspace, see [Graph edges upgrade](#graph-edges-upgrade). |
| 78, indexes for the erasure and retention deletes | No step. The first boot builds 16 indexes before `/api/health` answers, so it takes longer on a large store; time a boot on a copy of the store first, and allow for it in the health-check timeout. |
| 79, indexes on the asset tables' foreign keys | No step. The first boot builds 13 more indexes before `/api/health` answers: about 0.7 s on a 1.75 GiB store, where the 16 of migration 78 took about 5 s. |
| 81, ledger rows that hold the ids and keys of this Engine's changes | No step. The boot log says how many ledger rows were re-id'd, re-keyed and deleted (`[Migrations] 081 data: ...`), and names each ledger row whose mutation id has a colon, never its payload; such a row came from a peer before the id check, so check which peer sent it. |
| 82, the ledger rows migration 81 moved keep a colon in their id | No step. The boot log says how many ledger rows were re-id'd and deleted (`[Migrations] 082 data: ...`). |
| 83, graph edges record who asserted them | No step. The first boot reads every `child_of` and `links_to` edge in `graph_edges` once, with a lookup of each end in `contexts`, to give the Notion importer the edges it wrote before asserters were recorded; on a store with many such edges the boot takes longer before `/api/health` answers, so time it on a copy of the store first. |
| 84, indexes for the maintenance windows | No step. The first boot builds three indexes (`chunks`, `contexts` and `claims` by workspace and id) before `/api/health` answers; take a backup, time a boot on a copy of the store first, and allow for it in the health-check timeout. |
| 85, default grants for the keys minted without any | No step. The first boot gives every live key whose metadata has neither `allowed_security_labels` nor `allowed_partitions` the grants `["public", "internal", "confidential"]` and no partition, and marks it `grants_backfilled`; the boot log says how many (`[Migrations] 085 data: ..., rows changed: <n>`) and names none. It grants, and it does not only restrict: a key without grants read only unlabelled rows on the routes that already followed grants (the exports, the conflict list, the ledger, governed recall) and now reads confidential rows there too, while on the routes that did not (memory, signal, wiki page, search, grep) it read everything and now reads no restricted row, no row with a label of its own and no partitioned row. A key an operator meant to keep at unlabelled rows must be given `allowed_security_labels` and `allowed_partitions` of `[]` before the upgrade, because the migration cannot tell it from a key minted before grants existed. A key that has either field (an empty list included), a revoked key and the root bootstrap key (which holds `"*"`) are left as they are. A key minted through the API after the upgrade carries both fields (empty when the request names none), so a platform that mints keys passes the grants it means, for example `{"allowed_security_labels": ["public", "internal", "confidential"], "allowed_partitions": []}`. |

### Graph edges upgrade

The migration that creates `graph_edges` copies the legacy `edges` table, whose key had kept only the first workspace's copy of an edge two workspaces shared; one graph backfill writes the missing edges again.

Before upgrading:

1. Take a backup (`OptimalEngine.Release.backup/1`, or `POST /api/backup`).
2. Find the rows another tenant's key wrote under a workspace id that has no workspace row.
   Before this migration a context took the tenant of its workspace's row only, so a context of an unregistered id reads `default` whoever wrote it; its source package keeps the tenant of the key that wrote it, so the query reads `source_packages`.
   The migration relabels the contexts of an unregistered `<tenant>:<slug>` id with the tenant its prefix names, and leaves a bare id with the default tenant: after the upgrade the tenant's own key reads it as empty (`GET /api/graph` answers `context_count: 0`).
   From 0.3.9 a write that names its tenant under a bare id lands in that tenant (see "Writes under a bare workspace id" in `scope-and-portability.md`), but a row written before stays with `default`, and the tenant that wrote it cannot rewrite it: the write is refused with `context_id_in_use`.
   `POST /api/workspaces` gives a workspace the id `<tenant>:<slug>`, so a bare id cannot be registered, and `POST /api/data-steward/workspaces/repair` moves only the rows of the caller's tenant: run as `default`, it moves these rows into a `default` workspace, not into the writing tenant's.
   From 0.3.11 the operator gives those rows back with `DataSteward.relabel_bare_scope/2` (see "Rows written before 0.3.8" in `scope-and-portability.md`), once per id and tenant the query lists, then runs the graph backfill for that id.
   It moves only the rows the tenant's own source packages vouch for; a row with no source package stays `default`, and the tenant can send that document again under a workspace of its own.
   For an id with a `<tenant>:` prefix, create the workspace, so the maintenance routes answer for it: they answer `404 workspace not found` for an unregistered id.

```sql
SELECT workspace_id, tenant_id, COUNT(*) AS source_packages
FROM source_packages
WHERE tenant_id <> 'default' AND workspace_id NOT IN (SELECT id FROM workspaces)
GROUP BY workspace_id, tenant_id;
```

After upgrading:

1. Stop the Engine service, then run the backfill once, without a workspace, which covers every workspace: `bin/optimal eval 'OptimalEngine.Release.graph_backfill()'` on a release build, or `mix optimal.graph_backfill` from a checkout. Both boot the Engine application, its HTTP listener and triple store included, so they cannot run beside the service. It only adds missing edges, so it is safe to run again; start the service when it is done.
   It exits non-zero when an edge write failed, and only a run where every write succeeded and the claim pass ran counts as done.
2. Until it has run, search reads fewer graph edges (the graph boost and graph candidates), so results are mildly thinner.
3. `GET /api/maintenance/graph` reports it per workspace in `graph_edges`: `backfill_needed` is true while the legacy table holds the workspace's rows and no backfill has completed for it or for every workspace, and false afterwards; an Engine that never had legacy edges reads false. `legacy_edges` counts the workspace's legacy rows and `edges` its graph edges.
   Right after the upgrade `edges` equals `legacy_edges`, because the migration copies every legacy row.
   The flag stays true even for a workspace the old key dropped nothing from, so it says the backfill has not run, not how many edges are missing.
4. `GET /api/graph` reports `stats.edge_count`, the links it draws between contexts: contexts that mention the same entity (the `entities` table) and `cross_ref` edges.
   It is not the number of `graph_edges` rows, and it is `0` for a workspace whose documents name no entity that a topology node or endpoint carries, before the upgrade as after it.

## Creating a release

1. Choose the next Semantic Version.
2. Update `@version` in `mix.exs` and the matching version in `engine-contract.json`, `OPTIMAL_CLI_VERSION` in `apps/cli/optimal`, `version` in `apps/mcp/package.json`, both `version` fields of `apps/mcp/package-lock.json` (the top one and `packages.""`), `MCP_VERSION` in `apps/mcp/src/version.ts`, and `DEFAULT_VERSION` in `deploy/miosa-template/install-client.sh`; update contract migration/capability fields when their meanings change.
3. Run formatting, tests, release benchmarks, and `mix run --no-start scripts/check_release_version.exs`, which checks SemVer, that every file of step 2 carries the same version, and that the build is not a failing-migration test release.
4. Commit the complete release identity.
5. Create the annotated tag `v<version>` on that exact commit.
6. Push the commit and tag.
7. Build with `OPTIMAL_ENGINE_GIT_SHA` and `OPTIMAL_ENGINE_BUILD_TIMESTAMP` set by CI, and `OPTIMAL_RELEASE_CHANNEL` set to the channel the build serves.
   `docker build -f deploy/Dockerfile.engine --build-arg OPTIMAL_ENGINE_GIT_SHA=<sha> --build-arg OPTIMAL_ENGINE_BUILD_TIMESTAMP=<timestamp> --build-arg OPTIMAL_RELEASE_CHANNEL=stable -t optimal-engine:<version> .` passes the same three values into the image.
8. Verify the deployed `/api/version` response against the tag, the channel, and the expected migration, and run `mix optimal.conformance` against it.
9. Build the client CLI archives (`apps/cli/build.sh`) and the MCP server archive (`apps/mcp/build.sh`) from the tagged source on the release build host, run the installer tests against those files, and stage them with `SHA256SUMS`; both builds refuse a version that differs from `mix.exs`. CI builds and tests the same files on every run but publishes nothing.
   See [Client CLI and MCP server](cli.md) and [client install on MIOSA machines](../../deploy/miosa-template/CLIENT-INSTALL.md).

10. From 0.3.10 on, the release also carries the server build itself, so staging a host is a copy plus a manifest and not a 30 to 60 minute rebuild.
    On the same x86_64 build host, with the tag checked out, run `OPTIMAL_ENGINE_GIT_SHA=<tag sha> OPTIMAL_ENGINE_BUILD_TIMESTAMP=<release timestamp> OPTIMAL_RELEASE_CHANNEL=<channel> deploy/miosa-template/build-release.sh`.
    It writes `optimal-engine-<version>-<sha>.tgz` and `SHA256SUMS` (the name `deploy/miosa-template/stage-release.sh` and the manifest use).
    Attach both to the GitHub release next to the client archives, with the SHA and timestamp used in the release notes, and check that `GET /api/version` of an Engine booted from that file reports exactly those values.
    The bytes that were gated and the bytes a host runs are then the same file; a rebuild from the commit is equal only if the toolchain and timestamp happen to match.
    Hosts take their ext4 root from the `miosa-sandbox` template build (`create-template.sh`), not from a raw Ubuntu image; the release tarball is what is unpacked on top of it.
    A managed host never downloads the tarball from GitHub at runtime: the release captain copies the attached files into the staging root by hand, and staging reads them from there.

CI rejects a release tag that does not exactly match the application version.

The release toolchain is one Elixir and OTP pair, named in two places that move together: `BUILDER_IMAGE` in `deploy/Dockerfile.engine` and the `test-current` job in `.github/workflows/ci.yml` (Elixir 1.19.5 / OTP 28.5.0.5 from 0.3.10).
A build host that sets `BUILDER_IMAGE` to an image it already has must pick one on OTP 28.3 or later.
OTP 28.0 to 28.2 (erts 16.0 and 16.1) can crash the whole VM when a process is killed during a long regular expression match, which is what a classification time limit does to a slow document; OTP 28.3 fixed it.

## Migrations at boot

The Store applies pending migrations when it opens, in order, before the API answers.
Each migration runs in one transaction together with the `schema_migrations` row that records it.
The failed migration leaves no trace: when a statement fails, everything that migration wrote is rolled back, its version stays unrecorded, and `migration <nnn> failed and was rolled back: <cause>` is raised with the number zero-padded, for example `migration 086` in a release whose last real migration is 085.
The Store then does not open and the release exits without answering.
Migrations before the failed one in the same boot stay applied.
A release that adds several migrations can therefore leave a store between releases, and the previous release is not guaranteed to read it.
A managed upgrade must back the store up before the new release boots (an online copy such as `VACUUM INTO` or `POST /api/backup`) and restore that backup when it rolls back.
A migration that another runner on the same database recorded while this one waited for the write lock is skipped.

Every migration must finish well inside the boot window: a managed Engine is declared failed when `/api/health` does not answer within 90 seconds of its start.
The Store logs how long each migration took (`[Migrations] Applied <nnn> in <n> ms`).
A backfill that may run long on a large store belongs in a resumable job (`OptimalEngine.Jobs`), not in a migration.
Inside a transaction SQLite refuses `VACUUM`, `ATTACH` and `DETACH` and ignores some pragmas without an error (`PRAGMA foreign_keys = OFF` is a silent no-op), so no migration may use them; a test checks every statement.

The PostgreSQL store derives its schema from the same migrations (`docs/guides/postgres-provider.md`).
Until a PostgreSQL store is deployed, its baseline is the newest migration and a migration needs nothing for PostgreSQL.
The release that deploys the first PostgreSQL store sets `@frozen_baseline` in `OptimalEngine.Store.Postgres.Steps` to its newest migration version and is never changed after.
From then on a migration that moves or changes data needs a declared PostgreSQL step, and CI fails without one (`test/store/postgres/steps_test.exs`).

## Upgrade rollback drill

An upgrade path has to prove that it rolls back when the new release cannot start.
The failing-migration test releases exist for that drill and for nothing else.
Each is the Engine at a commit plus migrations that fail on purpose (`OptimalEngine.Store.FailingMigration`), and its version says so:

| Build flag | Version | Test migrations | Store after the failed boots |
| --- | --- | --- | --- |
| `OPTIMAL_BUILD_FAILING_MIGRATION=1` | `<version>-failing-migration` | 9000001 fails | as it was: same migration counter, schema and data |
| `OPTIMAL_BUILD_FAILING_MIGRATION=2` | `<version>-passing-then-failing-migration` | 9000001 passes, then 9000002 fails | at migration 9000001; only the pre-boot backup restores it |

The failing migration creates a table, writes a row to it, renames the sentinel tenant `failing-migration-sentinel` (a row the drill seeds; no other row is touched), and then inserts a NULL into a NOT NULL column.
Because it runs in a transaction, none of that survives.
The passing migration creates and fills `passing_migration_probe`, which stays.

The test migrations take numbers above a reserved base, 9000000, that no real migration reaches (a test checks it).
A test migration therefore never takes a real migration's number, and a test release's expected migration (9000001 or 9000002) never looks like the next real release's.
A store the passing migration reached and no backup restored still opens with the previous release: nothing is pending, migration 9000001 and its table stay, and later real migrations still apply, because the runner skips the versions it has recorded rather than those below a counter.
That store's `max(version)` is 9000001, and the `migrations` check of `GET /api/stores/audit` reports it as `migration_drift` until a backup from before the upgrade is restored.

Five guards keep these migrations out of every real release:

- they are compiled in only when `OPTIMAL_BUILD_FAILING_MIGRATION` is `1` or `2` at build time, `mix.exs` then appends the suffix to the version, and any other non-empty value stops the build;
- compiling with the flag stops the build unless the version is exactly `<x.y.z>` and that flag's suffix;
- at run time they are offered only while the running application's version ends in `-failing-migration`;
- `scripts/check_release_version.exs`, which CI runs and step 3 of "Creating a release" requires, refuses a version ending in `-failing-migration` and a set `OPTIMAL_BUILD_FAILING_MIGRATION`;
- `deploy/miosa-template/build-release.sh`, the release build, refuses a set `OPTIMAL_BUILD_FAILING_MIGRATION` and passes it to the image as empty.

The flag is read at compile time, so a build that sets or clears it compiles with `--force`.

### Build it

Build from a clean commit on the release build host, with the same Docker pipeline as any release (`BUILDER_IMAGE` as for `deploy/miosa-template/build-release.sh`):

```bash
scripts/build-failing-migration-release.sh <out-dir>                    # the failing migration alone
scripts/build-failing-migration-release.sh <out-dir> --passing-first    # a passing one first
```

`--mix` builds with the local Mix toolchain instead, in a build directory of its own, for a host without Docker; that archive carries no bundled shared libraries.
The archive's start script is `deploy/miosa-template/start-engine`, the one every release archive carries.
The release channel is always `dev`: a test release serves no channel.
The script writes `optimal-engine-<test version>-<sha>.tgz`, `SHA256SUMS`, and `identity.json`.
`identity.json` is the identity the release itself reports, read with `bin/optimal eval` after its native libraries load, because the release cannot start.
The script refuses a dirty checkout and a release whose reported version, commit, build time, channel, or expected migration (9000001, or 9000002 with `--passing-first`) differ from what it built.

### Stage it

1. Stage it on a QA host only, under a staging root used for the drill alone: point that host's `MIOSA_OPTIMAL_ENGINE_STAGING_ROOT` at it for the drill, never at the fleet's staging root.
   A new managed Engine is created on the newest release staged in its staging root, so a test release must never be staged where a real Engine could be created on it.
2. Put the archive and its manifest in a directory of their own under that root, for example `<sha>-failing-migration/`.
   MIOSA's `engine-release manifest` refuses any version ending in `-failing-migration`, so a test release never gets a release manifest; the drill's manifest carries the fields of `identity.json` (`version`, `git_sha`, `build_timestamp`, `expected_migration`, `release_channel`) and the archive's name and sha256 from `SHA256SUMS`.
   It cannot be verified against a running Engine, because this release never runs.
3. Build the host image for the test version from the archive the same way as for any staged release.
4. On a QA Engine with a completed backup, run the upgrade to the test version, first as a dry run.

Expected result: the new release never answers `/api/health`, and its boot log carries `migration 9000001 failed and was rolled back: migration statement failing_migration_fails failed: NOT NULL constraint failed: failing_migration_probe.note` (`migration 9000002` for the second variant).
The upgrade fails, and the rollback boots the previous release.
With the first variant the store is as it was.
With the second, the passing migration stays applied until the rollback restores the pre-upgrade backup; an upgrade path that does not restore it leaves the store at migration 9000001, which the storage audit reports as drift, and that is what this variant exposes.
Afterwards `/api/version` reports the previous version and expected migration, the record of the upgrade holds the failure reason, and the Engine serves the data it had before.
The start script writes no crash dump (`ERL_CRASH_DUMP_SECONDS=0`): a dump holds ETS tables and process heaps, which is customer data, and the working directory is the data volume.
Never promote a test release to a channel, and remove the drill's staging root and host image after the drill.

### Proof

`scripts/proof-failing-migration.sh` runs the drill end to end with real releases on one data directory, with the start script and environment a managed Engine boots with.
It builds the current release and both test releases (through the build script), starts the current release, records a memory and ingests a document that search finds, stops it, and seeds the sentinel tenant.
Every comparison uses `sqlite3 .dump --preserve-rowids`, because `contexts`, `memories` and `source_packages` have text keys and their full-text rows hang on the hidden rowid, and the schema rows (`SELECT type, name, tbl_name, sql FROM sqlite_schema ORDER BY type, name`), compared exactly, which catch what a line comparison cannot, such as a column moved between tables.
Case A starts the failing-migration release twice and passes only when both boots exit non-zero without ever answering, the migration counter has not moved, the probe table does not exist, the sentinel is unchanged, `integrity_check` is `ok`, and the `.dump` text and the schema rows are the same before and after.
Case B takes a `VACUUM INTO` backup and checks it against the store: the same schema rows, and the same `.dump` lines in another order, because `VACUUM INTO` writes a virtual table's schema row after the ordinary tables.
It then starts the passing-then-failing release twice and passes only when both boots fail the same way and the passing migration stays applied while the failing one left nothing.
The previous release then opens that unrestored store, and its storage audit must report `migration_drift`.
Restoring the backup must give the same schema rows and, line by line, the same `.dump` as before the upgrade, with every full-text row of `contexts` and `memories` joined to its base row and every base row to its full-text row.
The current release then starts again and must serve the record it had, find the document through `/api/search`, and pass the audit's `migrations` check, and no crash dump may be in the data directory.

## Benchmark provenance

Engine-backed TrueMemory runs fetch `/api/version` before execution and persist the complete response as `engine_release`.
This binds every new result to the application version, Git SHA, build time, migration expectation, and component policies that produced it.

Historical benchmark artifacts remain immutable even when older runs lack the newer provenance block.
