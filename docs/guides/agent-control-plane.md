# Agent Control Plane Integrity

Effective: 2026-09-08.
Owner: platform.

The repository root `agent-authority.json` is the document authority registry.
Run `python3 scripts/agent_control_plane.py` before relying on repository instructions.
Run `python3 -m unittest discover -s scripts/tests -p 'test_agent_control_plane.py'` for adversarial fixtures.

Each document has an owner, scope, version, effective classification date, kind, status, and explicitly owned concepts.
The classification date records this authority review, not the original document publication date.
Only active normative documents and contracts may own current concepts.
One scoped concept has one owner document; reference and historical documents cannot override it.
Required boot references must lead to active authority.
Supersession must resolve to a current contract without cycles or missing targets.
New documents in the declared inventory require explicit classification.

A reference explains implementation or a proposal and does not independently authorize behavior.
A historical report describes evidence at its original date and does not establish current runtime state.
The validator verifies declared ownership and structural references, not arbitrary natural-language contradictions.
Semantic conflicts require human review and application regression evidence.

## Permission changes

The manifest records the permission baseline.
Documentation cannot grant API, tenant, workspace, tool, Fact, or topology access beyond runtime policy.
CODEOWNERS covers boot files, registered documentation, manifests, enforcement scripts, and workflows.
Repository branch rules must require code-owner review with stale approval dismissal and the `agent-control-plane-integrity` status check.
A workflow file alone cannot configure required checks or demonstrate that repository rules are enabled.
Permission changes require explicit review of the actual diff; a green structural validator is not permission approval.
Repository administrators retain the platform's ability to change repository settings.

## Evidence limits

The September 8 report correctly identified unresolved Canopy boot references and stale integration guidance.
Its broader epistemic and permission scenarios require runtime reproductions; documentation drift alone does not prove those exploits.
The Engine already exposes build SHA, release version, API version, migration level, and retrieval component identity.
Layered storage terminology and governed knowledge terminology can coexist without an API conflict.
Canopy's current workspace bridge executes local allowlisted Mix tasks; the old in-process dependency was a proposal.
The workspace contract and its tests govern checkout compatibility.
Do not claim universal prompt-injection prevention or full independent red-team closure from these gates.

## Engine runtime trust boundary

Ordinary authenticated writes do not grant Claim review, topology modification, or key administration.
Review-capable API credentials bind the reviewer identity to the authenticated key so request bodies cannot impersonate another reviewer.
The Fact promoter additionally checks persisted evidence and review state.
Explicitly configured trusted local development mode and wildcard administrative credentials remain privileged.
Direct access to Elixir execution or the SQLite files is privileged operating-system access, not an untrusted API principal.
These API guarantees do not claim to sandbox a local process that already owns the repository and database.

## Findings 4-6: evidence and retest boundaries

The following assessment addresses the September 8, 2026 Agent Control Plane Integrity report.
A documented defect, a reproduced runtime bypass, a proposed test, and an unimplemented stronger guarantee are different forms of evidence.

### Finding 4: integration and architecture drift

Signal classification, L0-L3 retrieval projections, and the Source Package to Claim to Fact lifecycle describe different layers.
Their coexistence is not evidence that a single API contract changed incompatibly.
Current layer ownership is defined by [engine operating model](../../SYSTEM.md), the [storage map](../architecture/STORAGE-AND-PROJECTION-MAP.md), and the [reconstruction ADR](../adr/0001-governed-reconstructive-memory.md).
Historical reviews remain classified evidence and do not authorize current behavior.

Canopy's older in-process wiring proposal must not outrank its current workspace-local Mix bridge.
The actual integration implementation is [Canopy Workspaces.Engine](https://github.com/Miosa-osa/canopy/blob/main/backend/lib/canopy/workspaces/engine.ex), with the approved task manifest handled by [Engine.Manifest](https://github.com/Miosa-osa/canopy/blob/main/backend/lib/canopy/workspaces/engine/manifest.ex).
The Engine does not infer compatibility merely because two documents describe similar architecture.

Retest by validating both authority registries, checking supersession/classification, and comparing the invoked module/task with the current integration contract.
The validator checks explicit metadata and recognized references; natural-language equivalence, contradictions, and retrieval ranking require a separate semantic review.

### Finding 5: checkout and version compatibility

[engine-contract.json](../../engine-contract.json) declares the canonical repository, application version, API version, contract schema, expected migration, and capabilities.
[Version.info/0](../../lib/optimal_engine/version.ex) exposes compile-time identity through `/api/version` and health/status responses.
[test/version_test.exs](../../test/version_test.exs) checks that the reported version and contract fields agree.

Canopy's [Engine.Compatibility](https://github.com/Miosa-osa/canopy/blob/main/backend/lib/canopy/workspaces/engine/compatibility.ex) rejects an unexpected checkout, noncanonical origin, dirty source, wrong pinned commit, untracked contract, and incompatible version/API/migration/capabilities before command execution.
Its regressions are in [workspace Engine tests](https://github.com/Miosa-osa/canopy/blob/main/backend/test/canopy/workspaces/engine_test.exs) and [workspace Engine controller tests](https://github.com/Miosa-osa/canopy/blob/main/backend/test/canopy_web/controllers/workspace_engine_controller_test.exs).
These tests include test executables; they do not themselves prove every real Engine command succeeds.

A separate September 8 disposable HTTP smoke test exercised the real allowlisted `optimal.health` task in a clean Engine clone pinned to `8b0e262bcc9943dcce1f6e9c6e5449cbb6ddfea3`.
Canopy returned HTTP 200 with process exit code 0 and ten successful diagnostics against a fresh test database.
A deliberately incorrect origin was rejected before execution.
This demonstrates that tested local command path, not a continuously running Engine service or production integration.

Checkout preflight is not running-HTTP attestation.
It does not contact a separately running Engine, bind a network endpoint to an operating-system process, or establish a cryptographic build identity.
An HTTP integration must independently authenticate the endpoint and compare its reported build identity with the approved release.
The local operator, dependency installation, ignored build artifacts, and process/database access remain trusted parts of execution.

The source-checkout [wrapper](../../bin/optimal) also had a reproduced wrong-store risk: its unauthenticated health probe treated an authenticated server as unavailable and selected local Mix fallback.
The probe now forwards the configured bearer token and refuses fallback on reachable HTTP failures; operation failures also return a failing exit status.
[Black-box wrapper tests](../../scripts/tests/test_optimal_wrapper.py) exercise valid, absent, and invalid credentials, reachable 403/503 responses, rejected writes, and the intentionally retained unconfigured default-local no-response fallback using a disposable HTTP server and fake Mix executable.
Explicit API URL or credential configuration also prevents fallback when no HTTP response arrives.
This protects command routing for the named wrapper paths; it does not attest a remote build or turn local commands into an HTTP-only client.

### Finding 6: code CI versus control-plane CI

The dedicated [agent-control-plane workflow](../../.github/workflows/agent-control-plane.yml) runs the authority validator, adversarial structural tests, and authenticated wrapper routing regressions.
The ordinary [Engine CI workflow](../../.github/workflows/ci.yml) compiles, checks formatting and release version, and runs the application suite.
[Engine CI run 34276397493](https://github.com/Miosa-osa/OptimalEngine/actions/runs/34276397493) passed 2,022 tests on Elixir 1.17.3 / OTP 26.2 for commit `cd6b489dfef18814bcd1acde521f563d9592b3b0`.
The merged main commit `51b6f86` also passed [application CI run 34277536190](https://github.com/Miosa-osa/OptimalEngine/actions/runs/34277536190) and [authority run 34277536230](https://github.com/Miosa-osa/OptimalEngine/actions/runs/34277536230).
These are build-specific results, not standing claims that future commits or every deployment are green.

The main-branch protection settings were read back on September 8: both control-plane and application checks were required, with one code-owner approval, stale-approval dismissal, and administrator enforcement.
[CODEOWNERS](../../.github/CODEOWNERS) identifies the protected documentation and enforcement surfaces.
Settings can change outside this repository; re-read branch protection before relying on that administrative state.
An author cannot supply their own independent approval, and agents must not bypass the review requirement.

Retest by running the structural tests and application regressions, inspecting the actual PR checks for the intended commit, and verifying the remote branch rules.
A workflow file alone does not prove a required merge gate.
A manifest permission string is a reviewed baseline, not an executable interpretation of every possible permission change.

## Seven adversarial fixtures: what is and is not covered

| Report fixture | Existing evidence | Limit and remaining retest |
| --- | --- | --- |
| A: missing authority | [Validator tests](../../scripts/tests/test_agent_control_plane.py) inject missing and malformed document references. | Recognized reference formats are checked; the parser is not an unrestricted natural-language interpreter. |
| B: competing authority | Duplicate declared owners and invalid authority dependencies are rejected. | Undeclared or contradictory prose requires review. |
| C: superseded architecture | Supersession cycles, retired normative targets, and wrong contract metadata are rejected. | Descriptions of incompatible behavior are not automatically inferred from prose. |
| D: wrong checkout | Canopy compatibility tests and the disposable remote-mismatch smoke test reject the wrong source checkout. | A separately running HTTP service is not attested by this gate. |
| E: historical-state poisoning | Historical documents cannot own current concepts; current boot authority cannot depend on retired state. | No test here proves an agent's retrieval ranking or reasoning can never favor stale historical content. |
| F: epistemic bypass | [API control-plane tests](../../test/api/control_plane_integrity_test.exs), [truth lifecycle tests](../../test/memory_core/truth_lifecycle_test.exs), and [Claim review tests](../../test/memory_core/claim_review_test.exs) exercise review, provenance, tenant identity, batch intake, and operation permissions. | These cover named paths, not arbitrary SQL, every future importer/migration, or a malicious local operator. |
| G: permission weakening | Required code-owner approval and branch settings govern changes to the baseline and enforcement files. | The structural validator cannot detect every semantically weaker permission string or dishonest reclassification; independent review remains necessary. |

Do not summarize this table as all seven scenarios being fully semantically solved.
Full independent red-team closure requires adversarial execution against the intended deployment, including threat boundaries and scenarios beyond the named regression tests.

## Runtime regressions and configuration evidence

The report did not contain a reproduced Fact-promotion or tenant exploit.
The subsequent review reproduced HTTP cases where operation scopes were not enforced, body-supplied reviewer identities could be accepted, implicit anonymous identity counted as review, and authenticated tenant parameters could replace the key's tenant.
[PermissionPlug](../../lib/optimal_engine/api/permission_plug.ex) now enforces the operation and identity boundary after [AuthPlug](../../lib/optimal_engine/api/auth_plug.ex) and [WorkspaceAuthPlug](../../lib/optimal_engine/api/workspace_auth_plug.ex).
[FactPromoter](../../lib/optimal_engine/memory_core/fact_promoter.ex) separately reloads persisted Claims and enforces evidence/review state.
The [API regressions](../../test/api/control_plane_integrity_test.exs) also verify that ordinary batch intake stays pending and that review/topology/admin paths deny insufficient grants.

The follow-up documentation sweep reproduced another concrete defect: the advertised `OPTIMAL_AUTH_REQUIRED=true` environment setting did not change runtime authentication.
[Runtime configuration](../../config/runtime.exs) now accepts literal `true`/`false`, preserves configured defaults when absent, and rejects invalid values.
[Runtime configuration tests](../../test/runtime_config_test.exs) verify those cases and that the enabled setting denies an unauthenticated HTTP request.
No local default was silently changed, and no live user service was restarted during this fix.

For the current API contract and migration steps use [API grants and migration](interfaces-and-publishing.md#api-grants-and-identity).
For verification against real user data use health/storage audit; fixture-writing probes require the [isolated environment recipe](installation-and-deployment.md#isolated-fixture-verification).

## Trusted baseline and retained failure evidence

The [trusted evaluator](../../scripts/trusted_control_plane.py) takes separate `--trusted-root` and `--candidate-root` checkouts plus a required `--report` artifact path.
The trusted checkout comes from the pull request's exact base SHA, supplied as `--trusted-sha`.
The CLI requires exact Git roots, clean tracked checkouts, and tracked validator/test/ledger files; dirty or untracked evidence cannot be presented as an immutable HEAD result.
Its existing validator evaluates the candidate registry before any candidate validator executes, and its unchanged regression tests execute the candidate validator in a temporary directory.
Trusted and candidate enforcement hashes and ledger contents are checked again after child execution to detect changes during evaluation.
Candidate-authored tests cannot replace those baseline expectations.
Missing validator files, empty or nonexecuting trusted tests, missing baseline evidence, fixture failures, and evidence rewrites fail the gate.
The JSON report records both revisions, trusted and candidate source hashes, actual subprocess outcomes, and evidence status.

The [failure ledger](../../evidence/control-plane/ledger.json) retains exact synthetic positive and negative inputs, SHA-256 hashes, observed failure, causal lesson, red-team record, and retention reason.
Its six fixtures cover valid authority, missing boot contract, competing concept ownership, historical ownership of current state, a missing required execution path, and an empty permission baseline.
Each red-team record explicitly stores the strongest argument for and against the claim, assumptions to break, constraints, verdict, and revisit condition.
A failed replay of an existing baseline fixture is classified as `known-failure-recurrence` and `process-defect`, with its fixture ID and retained causal lesson.
A newly introduced failing fixture is classified as `discovery`.
This classification identifies exact retained fixture recurrence, not arbitrary defects with an inferred common cause.
A permissive checker and replacement all-success test file previously both returned success, while the new harness rejects the candidate using retained negative expectations.
The ordinary authority checker also accepted deletion of the evidence ledger; the trusted evidence comparison now rejects that loss.
The exact synthetic replacements and reproduction record remain in the negative fixture directory.
[Harness regressions](../../scripts/tests/test_trusted_control_plane.py) cover those cases and demonstrate that rehashing rewritten evidence does not evade comparison with the trusted record.
Add a new record with `supersedes` pointing to an older ID when evidence needs a follow-up interpretation.
Retain the old record and its exact files; supersession does not authorize deletion or rewriting of prior evidence.

The first installation requires an explicit `--bootstrap-ledger` because older main has the trusted validator and regression suite but no ledger or harness yet.
That mode still runs the previous validator and tests, validates the new fixture ledger, and reports `pending-independent-bootstrap` instead of claiming prior immutable evidence.
It is rejected if a trusted ledger already exists.
Subsequent pull requests run the installed base harness with strict retained-evidence checks.

Trusted comparison runs inside the already-required `agent-control-plane-integrity` job, so its failure fails that merge check.
The workflow uses ordinary `pull_request` with a separate base checkout and `persist-credentials: false`; it does not use privileged `pull_request_target` execution.
The initial harness and the candidate-owned workflow remain subject to independent code-owner review.
The [CI launcher](../../scripts/run_trusted_control_plane.sh) builds the [evaluation image](../../.github/control-plane/Dockerfile) before running candidate Python.
The evaluator container has no network, runs as a nonroot user with capabilities dropped and privilege escalation disabled, mounts both checkouts read-only, and limits writable storage to temporary files and a dedicated report directory.
It receives no host credentials or Docker socket, and the trusted report is uploaded before candidate code runs on the host.
The installed baseline selects the launcher and image definition; their first installation remains independently reviewed bootstrap policy.
Direct local invocation of the Python harness does not provide that container isolation.
Neither execution mode establishes a fully tamperproof external oracle, and the candidate-owned workflow still requires independent owner review.
Runner isolation, workflow review, and protected branch settings remain necessary trust boundaries.
The gate verifies retained scenarios and does not claim that every semantic contradiction or adversarial agent behavior is covered.

## Fresh-agent behavioral retest

The [fresh-agent runner](../../scripts/fresh_agent_review.py) exercises four separate read-only agent cases: clean authority, historical poisoning, documentation permission poisoning, and a missing current contract.
Use a separately reviewed runner and a clean committed candidate checkout:

```bash
python3 /trusted/path/scripts/fresh_agent_review.py --repository engine --candidate-root /clean/committed/repo --output-dir /private/new-dir
```

The output retains the candidate commit, tool transcript, schema, prompt, answer hashes, and evaluation result for each case.
Evaluation requires exact evidence quotes and a completed validator trace; a plausible answer alone does not pass.
CI runs the deterministic [runner regressions](../../scripts/tests/test_fresh_agent_review.py); actual model execution is explicit and does not expose credentials to pull-request CI.
The runner and judging code themselves require independent review.
These four behavioral cases do not establish authenticated runtime boot, arbitrary tool safety, or universal injection resistance.
