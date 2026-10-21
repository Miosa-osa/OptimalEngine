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

The current tracked contract is application `0.3.3`, API `v1`, contract schema `1`, expected migration `73`.
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

## Creating a release

1. Choose the next Semantic Version.
2. Update `@version` in `mix.exs` and the matching version in `engine-contract.json`, `OPTIMAL_CLI_VERSION` in `apps/cli/optimal`, `version` in `apps/mcp/package.json` and `apps/mcp/package-lock.json`, `MCP_VERSION` in `apps/mcp/src/version.ts`, and `DEFAULT_VERSION` in `deploy/miosa-template/install-client.sh`; update contract migration/capability fields when their meanings change.
3. Run formatting, tests, release benchmarks, and `mix run --no-start scripts/check_release_version.exs`, which checks SemVer, that the CLI and MCP server carry the same version, and that the build is not a failing-migration test release.
4. Commit the complete release identity.
5. Create the annotated tag `v<version>` on that exact commit.
6. Push the commit and tag.
7. Build with `OPTIMAL_ENGINE_GIT_SHA` and `OPTIMAL_ENGINE_BUILD_TIMESTAMP` set by CI, and `OPTIMAL_RELEASE_CHANNEL` set to the channel the build serves.
   `docker build -f deploy/Dockerfile.engine --build-arg OPTIMAL_ENGINE_GIT_SHA=<sha> --build-arg OPTIMAL_ENGINE_BUILD_TIMESTAMP=<timestamp> --build-arg OPTIMAL_RELEASE_CHANNEL=stable -t optimal-engine:<version> .` passes the same three values into the image.
8. Verify the deployed `/api/version` response against the tag, the channel, and the expected migration, and run `mix optimal.conformance` against it.
9. Build the client CLI archives (`apps/cli/build.sh`) and the MCP server archive (`apps/mcp/build.sh`) from the tagged source on the release build host, run the installer tests against those files, and stage them with `SHA256SUMS`; both builds refuse a version that differs from `mix.exs`. CI builds and tests the same files on every run but publishes nothing.
   See [Client CLI and MCP server](cli.md) and [client install on MIOSA machines](../../deploy/miosa-template/CLIENT-INSTALL.md).

CI rejects a release tag that does not exactly match the application version.

## Migrations at boot

The Store applies pending migrations when it opens, in order, before the API answers.
Each migration runs in one transaction together with the `schema_migrations` row that records it.
The failed migration leaves no trace: when a statement fails, everything that migration wrote is rolled back, its version stays unrecorded, and `migration <nnn> failed and was rolled back: <cause>` is raised with the number zero-padded, for example `migration 073` in a release whose last real migration is 072.
The Store then does not open and the release exits without answering.
Migrations before the failed one in the same boot stay applied.
A release that adds several migrations can therefore leave a store between releases, and the previous release is not guaranteed to read it.
A managed upgrade must back the store up before the new release boots (an online copy such as `VACUUM INTO` or `POST /api/backup`) and restore that backup when it rolls back.
A migration that another runner on the same database recorded while this one waited for the write lock is skipped.

Every migration must finish well inside the boot window: a managed Engine is declared failed when `/api/health` does not answer within 90 seconds of its start.
The Store logs how long each migration took (`[Migrations] Applied <nnn> in <n> ms`).
A backfill that may run long on a large store belongs in a resumable job (`OptimalEngine.Jobs`), not in a migration.
Inside a transaction SQLite refuses `VACUUM`, `ATTACH` and `DETACH` and ignores some pragmas without an error (`PRAGMA foreign_keys = OFF` is a silent no-op), so no migration may use them; a test checks every statement.

## Upgrade rollback drill

An upgrade path has to prove that it rolls back when the new release cannot start.
The failing-migration test releases exist for that drill and for nothing else.
Each is the Engine at a commit plus migrations that fail on purpose (`OptimalEngine.Store.FailingMigration`), and its version says so:

| Build flag | Version | Migrations after the last real one | Store after the failed boots |
| --- | --- | --- | --- |
| `OPTIMAL_BUILD_FAILING_MIGRATION=1` | `<version>-failing-migration` | one that fails | as it was: same migration counter, schema and data |
| `OPTIMAL_BUILD_FAILING_MIGRATION=2` | `<version>-passing-then-failing-migration` | one that passes, then one that fails | one migration ahead; only the pre-boot backup restores it |

The failing migration creates a table, writes a row to it, renames the sentinel tenant `failing-migration-sentinel` (a row the drill seeds; no other row is touched), and then inserts a NULL into a NOT NULL column.
Because it runs in a transaction, none of that survives.
The passing migration creates and fills `passing_migration_probe`, which stays.

Four guards keep these migrations out of every real release:

- they are compiled in only when `OPTIMAL_BUILD_FAILING_MIGRATION` is `1` or `2` at build time, `mix.exs` then appends the suffix to the version, and any other non-empty value stops the build;
- compiling with the flag and a version without the variant's suffix stops the build;
- at run time they are offered only while the running application's version ends in `-failing-migration`;
- `scripts/check_release_version.exs`, which CI runs and step 3 of "Creating a release" requires, refuses a version ending in `-failing-migration` and a set `OPTIMAL_BUILD_FAILING_MIGRATION`.

The flag is read at compile time, so a build that sets or clears it compiles with `--force`.

### Build it

Build from a clean commit on the release build host, with the same Docker pipeline as any release (`BUILDER_IMAGE` as for `deploy/miosa-template/build-release.sh`):

```bash
scripts/build-failing-migration-release.sh <out-dir> --channel beta                    # the failing migration alone
scripts/build-failing-migration-release.sh <out-dir> --channel beta --passing-first    # a passing one first
```

`--mix` builds with the local Mix toolchain instead, in a build directory of its own, for a host without Docker; that archive carries no bundled shared libraries.
The archive's start script is `deploy/miosa-template/start-engine`, the one every release archive carries.
The script writes `optimal-engine-<test version>-<sha>.tgz`, `SHA256SUMS`, and `identity.json`.
`identity.json` is the identity the release itself reports, read with `bin/optimal eval` after its native libraries load, because the release cannot start.
The script refuses a dirty checkout and a release whose reported version, commit, or build time differ from what it built, and it prints the manifest command for staging.

### Stage it

1. Write the manifest from the printed values: `engine-release manifest --artifact <tgz> --version <test version> --git-sha <sha> --build-timestamp <time> --expected-migration <n> --channel beta --out <dir>/manifest.json`.
   The manifest cannot be verified against a running Engine, because this release never runs.
2. Stage the archive and its manifest in a directory of their own under the release staging root, for example `<sha>-failing-migration/`, so a test release never shares a directory with a real release of the same commit.
3. Build the host image for the test version from the archive the same way as for any staged release.
4. On a QA Engine with a completed backup, run the upgrade to the test version, first as a dry run.

Expected result: the new release never answers `/api/health`, and its boot log carries `migration <nnn> failed and was rolled back: migration statement failing_migration_fails failed: NOT NULL constraint failed: failing_migration_probe.note`.
The upgrade fails, and the rollback boots the previous release.
With the first variant the store is as it was.
With the second, the passing migration stays applied until the rollback restores the pre-upgrade backup; an upgrade path that does not restore it leaves the store one migration ahead, which is what this variant exposes.
Afterwards `/api/version` reports the previous version and expected migration, the record of the upgrade holds the failure reason, and the Engine serves the data it had before.
The start script writes no crash dump (`ERL_CRASH_DUMP_SECONDS=0`): a dump holds ETS tables and process heaps, which is customer data, and the working directory is the data volume.
Never promote a test release to a channel, and remove its staging directory and host image after the drill.

### Proof

`scripts/proof-failing-migration.sh` runs the drill end to end with real releases on one data directory, with the start script and environment a managed Engine boots with.
It builds the current release and both test releases (through the build script), starts the current release, records data, stops it, and seeds the sentinel tenant.
Case A starts the failing-migration release twice and passes only when both boots exit non-zero without ever answering, the migration counter has not moved, the probe table does not exist, the sentinel is unchanged, `integrity_check` is `ok`, and `sqlite3 .dump` gives the same text before and after (a logical comparison, not of the database file's bytes).
Case B takes a `VACUUM INTO` backup, starts the passing-then-failing release twice, and passes only when both boots fail the same way, the passing migration stays applied while the failing one left nothing, and restoring the backup gives the store it had before.
`VACUUM INTO` writes a virtual table's schema row after the ordinary tables, so the backup's `.dump` lists the same statements in another order.
The proof therefore compares the backup and the restored store with the store before the upgrade statement by statement regardless of order, and the restored store with the backup exactly.
The current release then starts again and must serve the record it had, and no crash dump may be in the data directory.

## Benchmark provenance

Engine-backed TrueMemory runs fetch `/api/version` before execution and persist the complete response as `engine_release`.
This binds every new result to the application version, Git SHA, build time, migration expectation, and component policies that produced it.

Historical benchmark artifacts remain immutable even when older runs lack the newer provenance block.
