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

The current tracked contract is application `0.3.4`, API `v1`, contract schema `1`, expected migration `70`.
[engine-contract.json](../../engine-contract.json) supplies repository, schema, and capability metadata to [Version.info/0](../../lib/optimal_engine/version.ex) at compilation.
[test/version_test.exs](../../test/version_test.exs) checks that runtime identity matches the contract.
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
2. Update `@version` in `mix.exs` and the matching version in `engine-contract.json`, `OPTIMAL_CLI_VERSION` in `apps/cli/optimal`, `version` in `apps/mcp/package.json`, `apps/mcp/package-lock.json` and `apps/mcp/src/server.ts`, and `DEFAULT_VERSION` in `deploy/miosa-template/install-client.sh`; update contract migration/capability fields when their meanings change.
3. Run formatting, tests, release benchmarks, and `mix run --no-start scripts/check_release_version.exs`.
4. Commit the complete release identity.
5. Create the annotated tag `v<version>` on that exact commit.
6. Push the commit and tag.
7. Build with `OPTIMAL_ENGINE_GIT_SHA` and `OPTIMAL_ENGINE_BUILD_TIMESTAMP` set by CI, and `OPTIMAL_RELEASE_CHANNEL` set to the channel the build serves.
   `docker build -f deploy/Dockerfile.engine --build-arg OPTIMAL_ENGINE_GIT_SHA=<sha> --build-arg OPTIMAL_ENGINE_BUILD_TIMESTAMP=<timestamp> --build-arg OPTIMAL_RELEASE_CHANNEL=stable -t optimal-engine:<version> .` passes the same three values into the image.
8. Verify the deployed `/api/version` response against the tag, the channel, and the expected migration, and run `mix optimal.conformance` against it.
9. Build the client CLI archives (`apps/cli/build.sh`) and the MCP server archive (`apps/mcp/build.sh`) from the tagged source on the release build host, run the installer tests against those files, and stage them with `SHA256SUMS`; both builds refuse a version that differs from `mix.exs`. CI builds and tests the same files on every run but publishes nothing.
   See [Client CLI and MCP server](cli.md) and [client install on MIOSA machines](../../deploy/miosa-template/CLIENT-INSTALL.md).

CI rejects a release tag that does not exactly match the application version.

## Benchmark provenance

Engine-backed TrueMemory runs fetch `/api/version` before execution and persist the complete response as `engine_release`.
This binds every new result to the application version, Git SHA, build time, migration expectation, and component policies that produced it.

Historical benchmark artifacts remain immutable even when older runs lack the newer provenance block.
