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
`GET /api/authority/evidence/export?after=&limit=&until=` returns the chain a page at a time, with its keys and checkpoints; `Evidence.verify_export/1` verifies a bundle without the database.
A page holds at most `limit` entries after `after` (default and most 10,000), oldest first, and what a verifier needs to tell a whole export from one cut short:

```
{"entries": [...], "head": {"seq": S, "hash": H} | null, "head_signature": {"kid": K, "signature": G} | null,
 "total": N, "complete": true | false, "next_after": seq | null}
```

Entries keep their `seq`, `hash`, `prev_hash`, `kid` and `signature`.
`head` is the chain's last entry when the page is read, or the entry at `until`; with `until` no page goes past it, so pages read with one `until` share one head while the chain grows.
An `until` beyond the head, below `after`, or not a sequence number answers 400 `until_out_of_range`.
`head_signature` is the evidence key's signature over the statement a checkpoint signs for that head.
`total` counts the whole chain from seq 1 through the head, the same on every page.
`complete` is true only on the page whose last entry is the head, and then `next_after` is `null`.
An empty chain exports no entries, a `null` head, a `total` of 0, and is complete.
With `format=ndjson` a page is one line per entry, the entry object with `"type": "entry"` added, then one last line:

```
{"type": "export_end", "head": {"seq": S, "hash": H} | null, "head_signature": {"kid": K, "signature": G} | null,
 "total": N, "complete": true | false, "next_after": seq | null}
```

The stream has no key or checkpoint lines: a verifier reads each evidence key by its `kid` from `GET /api/authority/evidence/keys/:kid`.
Every character outside ASCII is written as a `\u` escape (U+2028, U+2029 and U+0085 among them), so each line is ASCII and only LF (0x0A) ends a record.
Split the stream on LF only, never on a reader's wider idea of a line break.

To export a chain of any length, read the first page, then the next ones with `after` set to `next_after` and `until` set to the first page's `head.seq`, until a page is complete.
`after` and `until` are sequence numbers no larger than 9,223,372,036,854,775,807, the largest the Store holds; anything else answers 400 (`after_out_of_range` or `until_out_of_range`).

A verified export with `complete: true` and a valid `head_signature` proves one thing: the bundle holds every entry from seq 1 through that `head.seq`, ending with that hash.
It does not prove the head is the chain's current one.
Any key that can read evidence can have the Engine sign a historical seq through `until`, so an old head comes with a fresh signature.
A verifier that needs freshness compares the head with something newer: a later signed checkpoint (`POST /api/authority/evidence/checkpoint`, anchored outside the Engine), or the head of a live `GET /api/authority/evidence/export` read without `until`.
`Evidence.verify_export/1` checks the head's signature and that a bundle is the whole chain: it starts at seq 1, holds `total` entries, ends at the head, and says it is complete.
A page that is not the whole chain is reported `partial`, never valid; join the pages' entries into one bundle with the last page's other fields to verify them.
`mix optimal.authority export [--until <seq>] [--format json|ndjson]` writes the whole chain through the head page by page, ending complete.
Verification, the integrity scan and agent action chains read the chain in pages, so none is cut short however long the chain grows.

### Verifying entries offline

An entry's `hash` is the lowercase hex SHA-256 of the UTF-8 bytes of the RFC 8785 canonical JSON of exactly these twelve fields:

| Field | Value |
| --- | --- |
| `tenant_id` | the tenant |
| `seq` | the entry's number in the tenant's chain, from 1 |
| `id` | `ev_` and a random id |
| `kind` | the evidence kind |
| `jti`, `subject`, `action`, `resource`, `workspace_id` | a string, or `null` |
| `detail` | a JSON object, `{}` when empty |
| `prev_hash` | the previous entry's `hash`; 64 zeros for seq 1 |
| `recorded_at` | the UTC time in ISO 8601 with microseconds, such as `2026-10-21T00:00:00.000000Z` |

In the canonical form an object's members are sorted by their names' UTF-16 code units (for these names, alphabetical order), nested objects included, with no whitespace.
Strings escape only `"`, `\` and control characters; integers are plain decimals; a field that is `null` is written as `null`, never left out.
So the members come in this order: `action`, `detail`, `id`, `jti`, `kind`, `prev_hash`, `recorded_at`, `resource`, `seq`, `subject`, `tenant_id`, `workspace_id`.
`hash`, `kid` and `signature` are not part of it.

`signature` is the Ed25519 (RFC 8032) signature by the tenant's evidence key over the 64 ASCII characters of `hash`, in base64url without padding.
`kid` is that key's RFC 7638 thumbprint.
`GET /api/authority/evidence/keys/:kid` returns that key as a public JWK, `{"kty": "OKP", "crv": "Ed25519", "kid": K, "x": X, "alg": "EdDSA", "optimal_purpose": "evidence"}`, with `"retired_at"` (ISO 8601, UTC) when it has been rotated out; old entries keep verifying with a retired key.
A kid that is unknown, a grant key's, or a revoked key's answers 404: what a revoked key signed no longer verifies.
The route needs the `authority:read` grant, like the export; `GET /api/authority/keys` lists every active and retired key of the tenant.
`head_signature` is the same key's signature over the canonical JSON of `{"hash": H, "seq": S, "tenant_id": T}` for the head, the statement a checkpoint signs.

A worked example, signed with the RFC 8032 test key whose secret is `9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60` (a published test key, never a real one).
The entry's canonical form:

```
{"action":"read","detail":{"by":"user:owner"},"id":"ev_example0000000000","jti":"grt_example","kind":"grant.issued","prev_hash":"0000000000000000000000000000000000000000000000000000000000000000","recorded_at":"2026-10-21T00:00:00.000000Z","resource":"optimal://acme:ops/notes","seq":1,"subject":"agent:analyst","tenant_id":"acme","workspace_id":"acme:ops"}
```

Its `hash`: `b0b34816fa897020ff710bb47d1a235a806b69af9d155e1b273ad60ef6be327d`.
The key's public JWK is `{"crv":"Ed25519","kty":"OKP","x":"11qYAYKxCrfVS_7TyWQHOg7hcvPapiMlrwIaaPcHURo"}`, so its `kid` is `kPrK_qmxVWaYVA9wwBF6Iuo3vVzz7TxHCTwXBygrS4k`.
The entry's `signature`: `I1n5bJG6O_IsBQsvRdEGKxzu2As7Ajo9Ww8CNmoZFhMZQgFJOFmnzpXkPiKPV-sIIqAa22JoRPHVN-eH2ybQDA`.
With that entry as the head, the statement is `{"hash":"b0b34816fa897020ff710bb47d1a235a806b69af9d155e1b273ad60ef6be327d","seq":1,"tenant_id":"acme"}` and `head_signature.signature` is `7wK7vhhnJyDos-w6oJrJPXmtCqVjimy6eCIm1jxvW8mEfaBRn2qaftGvOGDA84i3wS91kNLm_BWE9HVmLs2yDA`.
`test/authority/evidence_recipe_test.exs` checks this example against the Engine and recomputes a live entry's hash by the same recipe.
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
mix optimal.authority export --format ndjson --out evidence.ndjson
```

Over HTTP, the `optimal` client prints a page as the Engine wrote it, so every hash and signature still verifies:

```bash
optimal authority export --until 2500 --after 1000 --limit 1000 --format ndjson
```

## Standards

JWS RFC 7515, JWT claims RFC 7519, EdDSA and OKP keys RFC 8037, JWK thumbprints RFC 7638, JSON canonicalization RFC 8785.
