# Sizes and presets

An Engine runs at one of five size profiles and is set up for its use with one preset.
The profile tunes the Engine to its machine and says when to grow; the preset applies the policy, storage, and repertoire defaults for what the Engine is for.

## Size profiles

| Profile | Machine (vCPU / RAM) | Disk | Embedded limits (rule of thumb) | Scales to zero | Use |
| --- | --- | --- | --- | --- | --- |
| `agent` | 1 / 1 GiB | 2 GiB | 50k vectors, 100k memories, 25k contexts | yes | one agent's or one end user's memory |
| `workspace` | 1 / 2 GiB | 10 GiB | 250k vectors, 500k memories, 100k contexts | yes | one client or team workspace |
| `business` | 2 / 4 GiB | 25 GiB | 1M vectors, 2M memories, 500k contexts | no | a whole company in one brain |
| `platform` | 4 / 8 GiB | 100 GiB | 5M vectors, 10M memories, 2M contexts | no | a large customer, a product with many end users |
| `scale` | 8 / 16 GiB or more | 250 GiB or more | beyond embedded limits | no | vectors move to a vector provider, writers to Postgres |

Set the profile with `OPTIMAL_SIZE_PROFILE` (default `business`).
It sets the SQLite page cache and memory map, the hot context cache, and the API rate limit per key.

| Profile | Page cache | Memory map | Hot contexts | Requests per minute per key |
| --- | --- | --- | --- | --- |
| `agent` | 16 MiB | 64 MiB | 200 | 300 |
| `workspace` | 64 MiB | 256 MiB | 500 | 600 |
| `business` | 128 MiB | 1 GiB | 2,000 | 1,200 |
| `platform` | 256 MiB | 4 GiB | 5,000 | 3,000 |
| `scale` | 512 MiB | 8 GiB | 10,000 | 6,000 |

Explicit configuration always wins: `config :optimal_engine, :context_cache_entries`, `:sqlite_cache_mib`, `:sqlite_mmap_mib`, `:api_per_minute`, and `:api_rate_limit`.

## Usage gauges

`GET /api/storage` returns the active profile, one gauge per measure, the worst one, the recommendation, and how long the last boot took (`boot_ms`).
`GET /api/metrics` carries the same under `sizing`.

| Gauge | Measured as | Limit |
| --- | --- | --- |
| `vectors` | rows in the vector, chunk embedding, and memory embedding stores | profile |
| `memories` | memories | profile |
| `contexts` | contexts | profile |
| `disk_bytes` | the database files, the file root, the cache, and the graph store (refreshed every five minutes) | profile disk |
| `memory_bytes` | the Engine's memory in use | profile machine memory |
| `writes_per_minute` | contexts and memories written in the last hour, per minute | profile |

A gauge is `ok` under 70 percent, `watch` from 70 percent, and `over` from 100 percent.
At 70 percent of any limit the recommendation is `resize` to the next profile, with its machine and disk; on `scale` it is `enable_providers` with the providers for the gauge (a vector provider for vectors, object storage for disk, Postgres and a stream for writes).
A platform reads this to show usage and to resize automatically.

`GET /api/storage/profiles` lists every profile.

## Presets

```
optimal init --for agent|workspace|business|app|tenant-per-customer [--slug ops --name Ops]
POST /api/init {"for": "business", "slug": "brain", "name": "Brain"}     (admin scope)
mix optimal.init --for business --slug brain --name Brain
```

| Preset | Profile | Engine scope | Data class | Storage use cases | Repertoire |
| --- | --- | --- | --- | --- | --- |
| `agent` | agent | workspace | internal | desktop_local | note, message, decision-log, plan |
| `workspace` | workspace | workspace | internal | desktop_local | email, message, transcript, brief, status-report, plan, decision-log |
| `business` | business | org | confidential | desktop_local | the workspace set plus proposal, invoice, contract, report, roadmap |
| `app` | platform | workspace | internal | cloud_team | spec, api-doc, changelog, ticket, bug-report, release-notes |
| `tenant-per-customer` | workspace | workspace | confidential | desktop_local | email, message, note, brief |

Applying a preset, each part only when it is not already set:

1. creates the workspace with its data class, or sets the data class on an existing one that has none;
2. sets the workspace storage policy to the preset's use cases;
3. publishes the default policy pack by data class for the tenant;
4. turns authority on in `observe`, so refusals are recorded and nothing is blocked (move to `enforce` after reviewing the evidence);
5. declares the genre repertoire, which System 2 and the variety ratio read (`docs/guides/viability.md`).

The result lists what was applied and what was kept, the size to provision, and the environment to set (`OPTIMAL_SIZE_PROFILE`, `OPTIMAL_ENGINE_SCOPE`, `OPTIMAL_ENGINE_WORKSPACE`, `OPTIMAL_AUTH_REQUIRED`).
Running it again changes nothing that is already set.
`GET /api/init/presets` lists the presets; `docs/guides/recipes.md` walks through each use.
