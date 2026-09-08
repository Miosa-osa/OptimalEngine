# Versioning And Releases

Optimal Engine uses one traceable release identity across source, runtime, storage, projections, and benchmarks.

## Release identity

Every build reports:

```text
repository identity and contract schema version
application version
Git commit SHA
build timestamp
API version
expected database migration
required capability identifiers
retrieval and projection component versions
```

Read it from `GET /api/version`.
The lightweight `GET /api/health` and `GET /api/status` responses include the same identity.

The current tracked contract is application `0.3.1`, API `v1`, contract schema `1`, expected migration `62`.
[engine-contract.json](../../engine-contract.json) supplies repository, schema, and capability metadata to [Version.info/0](../../lib/optimal_engine/version.ex) at compilation.
[test/version_test.exs](../../test/version_test.exs) checks that runtime identity matches the contract.
Git SHA and timestamp are build-time metadata; changing branches does not prove an already running process changed.
A missing build SHA may be reported as `unknown` and is not an acceptable exact-commit identity for an integration requiring a pin.

Canopy's workspace bridge validates a local checkout before running allowlisted Mix tasks.
It checks the source root, canonical origin, clean status, pinned commit, and manifest compatibility.
That preflight does not contact or attest a separately running Engine HTTP service.
An HTTP consumer must separately compare the service response with its approved build/contract and authenticate the endpoint; this repository does not currently supply a universal remote attestation gate.

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
2. Update `@version` in `mix.exs` and the matching version in `engine-contract.json`; update contract migration/capability fields when their meanings change.
3. Run formatting, tests, release benchmarks, and `mix run --no-start scripts/check_release_version.exs`.
4. Commit the complete release identity.
5. Create the annotated tag `v<version>` on that exact commit.
6. Push the commit and tag.
7. Build with `OPTIMAL_ENGINE_GIT_SHA` and `OPTIMAL_ENGINE_BUILD_TIMESTAMP` set by CI.
8. Verify the deployed `/api/version` response against the tag and expected migration.

CI rejects a release tag that does not exactly match the application version.

## Benchmark provenance

Engine-backed TrueMemory runs fetch `/api/version` before execution and persist the complete response as `engine_release`.
This binds every new result to the application version, Git SHA, build time, migration expectation, and component policies that produced it.

Historical benchmark artifacts remain immutable even when older runs lack the newer provenance block.
