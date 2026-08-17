# Versioning And Releases

Optimal Engine uses one traceable release identity across source, runtime, storage, projections, and benchmarks.

## Release identity

Every build reports:

```text
application version
Git commit SHA
build timestamp
API version
expected database migration
retrieval and projection component versions
```

Read it from `GET /api/version`.
The lightweight `GET /api/health` and `GET /api/status` responses include the same identity.

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
2. Update `@version` in `mix.exs`.
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
