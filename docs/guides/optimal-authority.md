# Optimal Authority

Optimal Authority decides who or what may read, search, write, share, export, erase, sync, or act, for people, agents, and apps alike.
It covers data and actions with one model.
Authority comes from the institution: policy packs say what is allowed, what needs approval, and what is denied.
Nothing creates authority on its own, and delegation only narrows.

## Pieces

| Piece | Role | Module |
| --- | --- | --- |
| Policy pack | Versioned, hash-identified rules per tenant, workspace, or subject (System 5) | `OptimalEngine.Authority.Policy` |
| Decision point | Allow, ask, or deny for one request; deny wins; default deny | `OptimalEngine.Authority.Decision` |
| Grant | Signed, short-lived, registered statement of exactly who may do exactly what | `OptimalEngine.Authority.Grants` |
| Approval request | How a subject gets what policy asks for; no self-approval | `OptimalEngine.Authority.Requests` |
| Enforcement point | Verifies a grant against the exact request before acting and before releasing a result | `OptimalEngine.Authority.Admission` |
| Local deny | A stop the Engine keeps for itself; no grant overrides it | `OptimalEngine.Authority.LocalDeny` |
| Outside issuers | Pinned keys and revocation feeds for authorities other than this Engine | `OptimalEngine.Authority.Issuers` |
| Evidence | Signed, hash-chained record of every authority event | `OptimalEngine.Authority.Evidence` |
| Integrity scan | Finds changes made outside authority | `OptimalEngine.Authority.Integrity` |
| Route mode | Puts the Engine's own data routes behind authority | `OptimalEngine.API.AuthorityPlug` |

## Policy packs

A pack is published to one scope: the whole tenant, one workspace, or one subject.
Publishing supersedes the previous version in that scope and keeps it for audit.
Every decision names the pack id and hash it used.

```yaml
name: workspace-default
rules:
  - id: members-read
    effect: allow            # allow | ask | deny
    subjects: ["user:*", "agent:*"]
    actions: [read, search]
    resources: ["optimal://default:example/**"]
    data_classes: [public, internal]
    max_ttl_seconds: 900
    ceiling: {records: 500}
    delegable: false
  - id: exports-need-approval
    effect: ask
    actions: [export]
  - id: no-restricted-for-agents
    effect: deny
    subjects: ["agent:*"]
    data_classes: [restricted]
```

An absent matcher matches anything.
`*` matches within one path segment and `**` crosses segments.
Data classes are `public`, `internal`, `confidential`, and `restricted`.
Actions are free strings; the Engine's routes use `read`, `search`, `write`, `erase`, `export`, `sync`, and `admin`, and outside systems use their own (for example `act:sandbox.exec`).

Evaluation: a matching local deny wins; otherwise any matching `deny` denies, else any `ask` asks, else any `allow` allows, else the answer is deny.
Limits combine to the most restrictive value across matching allow and ask rules.

`Authority.default_pack/0` (or `GET /api/authority/policies/default`) is a starting pack by data class.

Publishing a pack that loosens the one it replaces is detected rule by rule: an effect moving toward allow, a removed deny or ask rule, a widened matcher on an allow or ask rule, a narrowed deny, a longer lifetime, a larger or removed ceiling, or delegation turned on.
In `enforce` mode a loosening needs a grant for `authority:loosen` on `optimal://authority/policies/<scope>/<id>`.
Every loosening is recorded as `policy.loosened`.

## Grants

A grant is a compact JWS (RFC 7515) with header `alg: EdDSA` (RFC 8037), `typ: optimal-grant+jws`, and the signing key's `kid` (its RFC 7638 thumbprint).
The payload is the RFC 8785 canonical JSON of the claims:

| Claim | Meaning |
| --- | --- |
| `iss`, `aud`, `sub`, `iat`, `nbf`, `exp`, `jti` | RFC 7519 registered claims |
| `optimal.tenant`, `optimal.workspace` | Where the grant applies |
| `optimal.action`, `optimal.resource`, `optimal.data_class` | Exactly what it permits |
| `optimal.command_sha256` | Binds the grant to one canonical command or query |
| `optimal.ceiling` | Named upper bounds, for example `records` |
| `optimal.max_uses` | Admissions allowed (default 1) |
| `optimal.delegable`, `optimal.parent` | Whether it may be narrowed to another subject, and the grant it came from |
| `optimal.policy_sha256`, `optimal.rule`, `optimal.approval` | Why it was issued |

Issuance is a decision: the policy must allow, or ask with an approved request.
The lifetime and ceilings may not exceed what the matching rules permit, and never exceed `OPTIMAL_AUTHORITY_MAX_TTL_SECONDS` (default 3600).
Every grant is registered, so it can be narrowed, suspended, restored, revoked with everything narrowed from it, and read back.

## Enforcement

`Authority.admit/3` (or `POST /api/authority/admit`) refuses unless every check passes, in this order:

1. Shape: `alg` must be `EdDSA`; `none`, HMAC and every other algorithm are refused before any key is used; no `crit`, no unencoded payload, canonical payload only.
2. Key: the `kid` must be pinned for the claimed issuer in the enforcer's own tenant; revoked keys never verify.
3. Signature.
4. Issuer trusted and audience equal to the enforcer.
5. Time: `nbf`, `exp`, `iat` not in the future, lifetime within the limit.
6. Binding: subject, tenant, workspace, action, resource, data class, and command hash equal the request.
7. Ceilings: requested amounts within the ceiling; a ceiling the enforcer cannot measure refuses with `constraint_not_enforceable` and records `could_not_enforce`.
8. Independent local deny.
9. State: the grant and every grant it was narrowed from are neither revoked nor suspended; for outside issuers the revocation feed must be fresh.
10. Uses: consumed atomically, so a replay, even a concurrent one, is refused.

A refused admission never spends a use.
`checkpoint` re-checks a running grant; `release` re-checks before a result leaves and records `action.completed` or `action.withheld`.

Refusal reasons: `missing_grant`, `malformed`, `algorithm_not_allowed`, `wrong_type`, `missing_kid`, `unsupported_critical_header`, `unexpected_header`, `non_canonical_payload`, `unknown_key`, `key_revoked`, `bad_signature`, `untrusted_issuer`, `wrong_audience`, `issued_in_future`, `not_yet_valid`, `expired`, `lifetime_exceeds_limit`, `wrong_subject`, `wrong_tenant`, `wrong_workspace`, `wrong_action`, `wrong_resource`, `wrong_data_class`, `command_mismatch`, `ceiling_exceeded`, `constraint_not_enforceable`, `local_deny`, `not_registered`, `revoked`, `suspended`, `authority_unavailable`, `replayed`.

## Outside issuers and disconnected behavior

Register an outside authority with its pinned JWK set and a revocation freshness limit (`POST /api/authority/issuers`).
Its grants verify only against those keys and are consumed once in the Engine's own ledger.
Revocations arrive by push (`POST /api/authority/issuers/:issuer/revocations`).
Known revocations and expiry are always honored; when the feed is older than the limit, the issuer's grants are refused with `authority_unavailable` until the next push.
Outside enforcers pull this Engine's revocations from `GET /api/authority/revocations` and its keys from `GET /api/authority/keys`.

## Evidence

Every authority event is one entry: tenant sequence number, previous hash, canonical hash, Ed25519 signature by the tenant's evidence key (separate from the grant key).
`GET /api/authority/evidence/verify` recomputes the chain and detects changed, removed, inserted, or reordered entries.
`POST /api/authority/evidence/checkpoint` signs the head for anchoring outside the Engine.
`GET /api/authority/evidence/export` returns entries, keys, and checkpoints; `Evidence.verify_export/1` verifies a bundle without the database.
It returns at most `limit` entries after `after` (default and most 10,000), with what a verifier needs to tell a whole export from one cut short:

```
{"entries": [...], "complete": true | false, "total": N, "head": {"seq": S, "hash": H, "kid": K, "signature": G}, "next_after": seq | null}
```

`head` is the chain's last entry when the export was read, signed with the evidence key over the statement a checkpoint signs; `total` counts the entries after `after` up to it; `complete` is true only when the last entry exported is the head, and then `next_after` is `null`.
`Evidence.verify_export/1` checks the head's signature and, for a complete bundle, that it holds `total` entries ending at the head; a bundle that is not complete is reported `partial`, never valid.
`mix optimal.authority export` writes the whole chain page by page, ending complete.
Verification, the integrity scan and agent action chains read the chain in pages, so none is cut short however long the chain grows.
Outside enforcers report receipts with `POST /api/authority/evidence` (`outcome: could_not_enforce` for constraints they could not apply).

`GET /api/authority/integrity` compares live packs, grants, local denies, and API keys with the evidence and reports changes made outside authority.

## The Engine's own routes

`PUT /api/authority/settings {"mode": ...}` sets the tenant's mode:

* `off` (default): routes behave as before.
* `observe`: decisions are evaluated and refusals recorded, nothing is blocked.
* `enforce`: a route runs only when the decision allows it or the request carries `x-optimal-grant` with a grant that admits it.

Routes are described as subject (the authenticated principal), action (from method and route), resource `optimal://<workspace>/<route path>`, and data class (the workspace's `metadata.data_class`, default `internal`).
Authority, key, status, version, and metrics routes are never governed by the mode.

## API scopes

| Route | Scope |
| --- | --- |
| `GET /keys`, `GET /revocations`, `GET /settings`, `GET /policies/default`, `POST /decide`, own `GET /effective` | `read` |
| `POST /requests` (for yourself) | `write` |
| other `GET` routes | `authority:read` |
| `POST /grants`, `POST /grants/:jti/{narrow,suspend,restore,revoke}` | `authority:issue` |
| `POST /requests/:id/{approve,deny}` | `authority:approve` |
| `POST /admit`, `/checkpoint`, `/release`, `/evidence` | `authority:enforce` |
| everything else | `authority:admin` |

## Configuration

| Variable | Default | Meaning |
| --- | --- | --- |
| `OPTIMAL_AUTHORITY_KEY` | none | 64 hex characters; wraps signing keys with AES-256-GCM. Required when authentication is required. |
| `OPTIMAL_AUTHORITY_MODE` | `off` | Default route mode for tenants without a setting |
| `OPTIMAL_AUTHORITY_ISSUER` | `optimal-engine` | `iss` this Engine signs as |
| `OPTIMAL_AUTHORITY_AUDIENCE` | `optimal-engine` | `aud` this Engine enforces as |
| `OPTIMAL_AUTHORITY_MAX_TTL_SECONDS` | `3600` | Longest grant lifetime |

## CLI

```bash
mix optimal.authority init
mix optimal.authority publish pack.yaml --scope workspace --id default:example
mix optimal.authority mode observe
mix optimal.authority decide --subject agent:x --action read --resource optimal://default:example/memory
mix optimal.authority issue --subject agent:x --action read --resource optimal://default:example/memory --ttl 300
mix optimal.authority effective agent:x --workspace default:example
mix optimal.authority verify
mix optimal.authority integrity --record
```

## Standards

JWS RFC 7515, JWT claims RFC 7519, EdDSA and OKP keys RFC 8037, JWK thumbprints RFC 7638, JSON canonicalization RFC 8785.
