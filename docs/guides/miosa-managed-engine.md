# MIOSA-Managed Engine

This guide is for operators and platform integrators who run the Optimal Engine as a managed service on MIOSA, and for anyone deciding whether to.
It is deployment mode 4 of [Installation and deployment](installation-and-deployment.md).

In this mode the Engine is offered as MIOSA's managed `optimal` database engine.
The platform provides the durable volume, the credentials, and the backups, and you use the Engine over HTTP.
The Engine itself is the same one every other mode runs: one instance that holds every store inside it.

## What Exists Today And What Is Planned

This repository is the Engine side.
The platform side is operated outside it, so each row below says where it lives.
"Planned" means it is the intended operating model and is not claimed to exist yet.

| Capability | Status | Where |
| --- | --- | --- |
| Engine release build with its own runtime and shared libraries | Exists | `deploy/miosa-template/build-release.sh` |
| Release identity, versions, and channels reported by the running Engine | Exists | `GET /api/version`, `OPTIMAL_RELEASE_CHANNEL` |
| Stage a release in a MIOSA bucket and create a template from it | Exists | `deploy/miosa-template/stage-release.sh`, `create-template.sh` |
| Unattended first key, walled workspaces, scoped agent keys | Exists | `OPTIMAL_BOOTSTRAP_*`, `workspace_scope` on keys |
| Verified online backups and sealed offsite backups to a MIOSA bucket | Exists | `POST /api/backup`, [Storage providers](storage-providers.md#offsite-backups) |
| Sync between a local Engine and a managed Engine through the MIOSA relay | Exists | [Replication](replication.md#syncing-through-a-relay) |
| Usage gauges and a resize recommendation | Exists | `GET /api/storage` |
| Durable volume, credentials, and platform backups for a managed Engine | Platform | Operated by MIOSA |
| One org Engine per organization, provisioned from the template | Planned | The template today starts one workspace Engine |
| One-command resize between sizes | Planned | The Engine reports the recommendation; the platform does the move |
| Scale to zero and wake on request | Planned | Two sizes are flagged for it in the Engine's size profiles |
| Channel-following upgrades with automatic backup and rollback | Planned | The Engine reports its channel; an update controller compares it |

## One Org Engine, A Walled Section Per Workspace

A managed Engine serves an organization.
Each workspace in it is a walled section.

```text
Organization
  one org Engine (OPTIMAL_ENGINE_SCOPE=org, the default)
    workspace "sales"        walled section
    workspace "support"      walled section
    workspace "research"     walled section
```

The wall is enforced on every request, not by convention:

- A key carries a `workspace_scope`.
  A key scoped to one workspace opens only that workspace's section and is refused (403 `workspace_scope_denied`) on any other.
- A key opens every workspace only when its scope is `*`.
  Only the operator holds such a key.
- Each workspace has its own directory, its own rows, and its own search results.
  A workspace owned by another tenant answers as not found.
- A workspace's share-up policy decides whether its results appear in org-wide views (`read`) or stay inside (`none`).
  Workspaces marked `private` or `client` default to `none`.

An agent therefore gets a key scoped to its workspace and nothing more:

```bash
curl -s "$ENGINE_URL/api/auth/keys" \
  -H "Authorization: Bearer $OPERATOR_KEY" \
  -H 'content-type: application/json' \
  --data '{"name":"sales agent","scopes":["read","write"],"workspace_scope":["default:sales"]}'
```

`GET /api/scope` reports the Engine's scope, and [Scope, sharing, and moving workspaces](scope-and-portability.md) has the rest.

### When A Customer Gets An Engine Of Their Own

Use the org Engine by default.
Give a customer their own Engine only when a wall inside one Engine is not enough:

| Reason | Why a wall is not enough |
| --- | --- |
| Co-owned data | Two organizations each own part of the data, so neither can be the operator of the other's rows. |
| Private views | A party must see a view the org operator cannot, so the operator must not hold the data. |
| Clients | A client of the organization needs an Engine they control, shared with the organization by explicit policy. |
| White-label end users | A product built on the Engine gives each of its end users a separate memory. |

Separate Engines are connected by federation (`GET /api/federation/search`, peers that share upward) and by replication, so the customer's Engine can stay in step with the org Engine without sharing a disk.
A workspace-scope Engine (`OPTIMAL_ENGINE_SCOPE=workspace` and `OPTIMAL_ENGINE_WORKSPACE=<id>`) serves only that workspace and answers every other as not found.

## Sizes

The Engine has five size profiles.
The managed service presents them as five sizes.

| Size | Profile (`OPTIMAL_SIZE_PROFILE`) | Machine size name | vCPU / RAM | Disk | Scale to zero | Embedded limits (rule of thumb) |
| --- | --- | --- | --- | --- | --- | --- |
| Agent memory | `agent` | `tiny` | 1 / 1 GiB | 2 GiB | flagged | 50k vectors, 100k memories |
| Workspace | `workspace` | `xs` | 1 / 2 GiB | 10 GiB | flagged | 250k vectors, 500k memories |
| Business | `business` | `small` | 2 / 4 GiB | 25 GiB | no | 1M vectors, 2M memories |
| Platform | `platform` | `medium` | 4 / 8 GiB | 100 GiB | no | 5M vectors, 10M memories |
| Scale | `scale` | `large` | 8 / 16 GiB | 250 GiB | no | beyond embedded limits |

These come from `OptimalEngine.Sizing`.
The default profile is `business`.
Each profile sets the SQLite page cache and memory map, the hot context cache, and the API rate limit per key, and [Sizes and presets](sizing-and-presets.md) lists those values.

Scale is where providers are added.
At 70 percent of a limit on the largest embedded profile, `GET /api/storage` recommends `enable_providers` and names them by the gauge that is full:

| Gauge | Provider named | Status |
| --- | --- | --- |
| `disk_bytes` | S3-compatible object storage | Wired. Assets and offsite backups move to a MIOSA bucket. |
| `writes_per_minute` | Postgres and NATS JetStream | Postgres is wired but partial (no full-text search, replication, or app data collections). NATS JetStream has no adapter yet. |
| `vectors` | Qdrant | No adapter yet. Embedded vectors keep serving. |
| anything else | Postgres | Wired but partial, as above. |

Managed Qdrant and NATS cannot be used yet; managed Valkey is reached through `OPTIMAL_VALKEY_URL`.
Until their adapters ship, the Scale size is the biggest single Engine, with S3 for assets and backups.

## Operating Model

### Resize

The Engine measures vectors, memories, contexts, disk, memory, and the recent write rate against the active profile.
At 70 percent of any limit `GET /api/storage` answers a recommendation with the next size, its machine, and its disk:

```bash
curl -s "$ENGINE_URL/api/storage" -H "Authorization: Bearer $KEY" | jq '{profile: .profile.id, worst, recommendation}'
```

One-command resize is planned: the platform reads that recommendation, moves the Engine to the next machine and disk, and sets `OPTIMAL_SIZE_PROFILE`.
The Engine's data is one SQLite file and its directories on one durable disk, so a resize is a disk and machine move with a backup first.
This repository does not implement the move; the Engine only reports the recommendation.

### Scale To Zero

The two smallest profiles, `agent` and `workspace`, are flagged `scale_to_zero` in the Engine's size profiles.
Scale to zero is planned as the platform stopping an idle Engine and starting it on the next request, with the disk kept.
What the Engine side guarantees for it:

- State is on the durable volume, so a stop loses nothing that was committed.
- The Engine records how long its last boot took (`boot_ms` in `GET /api/storage`), so a wake time can be measured.
- A scheduled offsite backup whose slot fell in a stopped period runs when the Engine comes back, and sync resumes on its next cycle.
- A managed Engine is declared failed when `/api/health` does not answer within 90 seconds of its start, so a wake must fit in that window.

### Backups

Backups come from the platform, and the Engine provides the mechanism they use:

- `POST /api/backup` takes a verified online copy while the Engine serves.
  It needs the `admin` scope.
- `{"offsite": true}`, or a schedule through `OPTIMAL_OFFSITE_BACKUP_INTERVAL_MS`, seals the copy with `OPTIMAL_BACKUP_KEY` and stores it in the MIOSA bucket the Engine is configured with.
  The bucket only ever holds ciphertext.
- A restore checks the checksum and the database's integrity before it replaces anything, and archives the previous database.

The database backup does not carry asset bytes kept on the filesystem.
Keep assets in the bucket with `OPTIMAL_ASSET_STORAGE=s3` so a restore brings them back.

## Installing: Built Images, Never A Repo Clone

A managed Engine runs from a built, versioned release.
No machine clones this repository, compiles it, or runs Mix.

What exists today:

1. `deploy/miosa-template/build-release.sh` builds the release on an x86_64 build host and writes `optimal-engine-<version>-<sha>.tgz` and `SHA256SUMS`.
   The archive holds the OTP release with its own runtime, the shared libraries a base sandbox lacks, and `start-engine`.
2. `stage-release.sh` stages the archive in a MIOSA bucket.
3. `create-template.sh` creates the template: the `miosa-sandbox` base plus steps that download the archive, check its sha256, and unpack it.
4. A managed host never downloads the archive from a public source at runtime.
   The release captain copies the release files into the staging root.

Every build reports its identity through `GET /api/version`: version, release channel, commit, build time, API version, and expected migration.
The channel is `OPTIMAL_RELEASE_CHANNEL`, one of `dev`, `stable`, `beta`, or `pinned`, and an update controller compares the reported channel with the one it intended.
A release earns promotion to a channel only when `mix optimal.conformance` passes against a fresh Engine ([Versioning and releases](versioning-and-releases.md)).

### Upgrade And Rollback

Migrations run when the new version boots, and the previous version is not guaranteed to read a store the new one migrated.
An upgrade therefore takes a backup first, boots the new release, and restores the backup if the new release cannot start.
The upgrade rollback drill in [Versioning and releases](versioning-and-releases.md#upgrade-rollback-drill) proves that path with a release whose migration fails on purpose.
Channel-following upgrades that do this unattended are planned.

## Environment For An Org Engine

The template documents the variables a managed Engine needs.
For an org Engine they are:

| Variable | Value |
| --- | --- |
| `OPTIMAL_AUTH_REQUIRED` | `true` |
| `OPTIMAL_BOOTSTRAP_KEY` | `oe_<24 hex>_<secret of 32+ chars>`, generated by the operator |
| `OPTIMAL_BOOTSTRAP_SCOPES` | `read,write` for a service key, or `admin` for the operator's root key |
| `OPTIMAL_BOOTSTRAP_WORKSPACES` | `*` for an org-wide operator key, or the slugs the key may open (default `*`) |
| `OPTIMAL_ENGINE_SCOPE` | `org` (the default) for an org Engine, `workspace` with `OPTIMAL_ENGINE_WORKSPACE` for a single-workspace Engine |
| `OPTIMAL_SIZE_PROFILE` | `agent`, `workspace`, `business`, `platform`, or `scale` |
| `OPTIMAL_RELEASE_CHANNEL` | `dev`, `stable`, `beta`, or `pinned` |
| `CONNECTOR_KEY`, `OPTIMAL_AUTHORITY_KEY` | 64 hex characters each, supplied by the platform and kept outside the volume |
| `OPTIMAL_BACKUP_KEY` | 64 hex characters, with a copy kept away from the machine |
| `OPTIMAL_S3_ENDPOINT`, `OPTIMAL_S3_BUCKET`, `OPTIMAL_S3_ACCESS_KEY_ID`, `OPTIMAL_S3_SECRET_ACCESS_KEY` | The MIOSA bucket for assets and offsite backups |
| `OPTIMAL_ASSET_STORAGE` | `s3` to keep asset bytes in that bucket |
| `OPTIMAL_EMBED_URL`, `OPTIMAL_EMBED_API_KEY` or `OPTIMAL_EMBED_API_KEY_FILE` | The shared embedding endpoint, so the Engine runs no model of its own |
| `OPTIMAL_CREDENTIAL_BROKER_HOSTS` | `api.miosa.ai`, so connectors can take short-lived credentials from the broker |

The start script runs the Engine with the API on `0.0.0.0:4200`, the data under `/data`, and no crash dump.
It does not set `OPTIMAL_KNOWLEDGE_BACKEND`, so a managed Engine runs the triple-store mirror on ETS.
The graph that search and assembly read is the `graph_edges` table in the SQLite database on the data volume, and the mirror is reloaded from it at each start; no retrieval path reads the mirror.

The embedding variables and the template steps are in [`deploy/miosa-template/README.md`](../../deploy/miosa-template/README.md).

## Verify

```bash
curl -s "$ENGINE_URL/api/health" -H "Authorization: Bearer $KEY"
curl -s "$ENGINE_URL/api/version" -H "Authorization: Bearer $KEY"
curl -s "$ENGINE_URL/api/stores/audit" -H "Authorization: Bearer $KEY"
curl -s "$ENGINE_URL/api/scope" -H "Authorization: Bearer $KEY"
```

- `GET /api/health` answers 200 when the Engine is up.
  A request to a protected route without a key must answer 401.
- `GET /api/version` reports the version, channel, and expected migration you intended to run.
- `GET /api/stores/audit` answers 503 when any check fails.
  It covers SQLite integrity, migrations, full-text parity, workspace isolation, vector validity, asset files, the latest verified backup, and the offsite schedule.
- `GET /api/scope` reports `org` or `workspace`.
- A key scoped to one workspace must be refused on another: request a second workspace with it and expect 403.

## Related

- [Installation and deployment](installation-and-deployment.md) for the other three modes.
- [Sizes and presets](sizing-and-presets.md) for every size's limits and tuning.
- [Storage providers](storage-providers.md) for S3, offsite backups, and what has no adapter.
- [Replication](replication.md) for syncing a local Engine with a managed one through the relay.
- [Client install on MIOSA machines](../../deploy/miosa-template/CLIENT-INSTALL.md) for the CLI and MCP server.
