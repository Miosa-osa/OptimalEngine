# Connectors

A connector is a one-way pipe from an outside system into the Engine: it pulls on a cursor, hands the Engine a stream of Signals, and does nothing else.
Classification, routing, storage and memory all run downstream of it, in the intake pipeline, so a connector never holds business logic of its own.
This guide covers the adapter list, the config fields, where credentials come from, and what happens to a Signal after a connector emits it.

## The adapter list

Twenty adapters ship with the Engine.
`OptimalEngine.Connectors.Registry.summary/0` returns them as `{kind, display_name, auth_scheme}` triples.

| Kind | Source | Auth | What it pulls |
| --- | --- | --- | --- |
| `:gmail` | Gmail | OAuth2 | messages, bounded by a lookback window, then the change history |
| `:drive` | Google Drive | OAuth2 | files, with the text of the document types that have any |
| `:notion` | Notion | token | pages in the configured databases, with their blocks |
| `:slack` | Slack | OAuth2 | channel history and its messages |
| `:teams` | Microsoft Teams | token | channel messages |
| `:zoom` | Zoom | token | recorded meetings |
| `:hubspot` | HubSpot | token or OAuth2 | CRM objects |
| `:salesforce` | Salesforce | OAuth2 | CRM objects |
| `:github` | GitHub | token or GitHub App | issues and pull requests |
| `:linear` | Linear | token | issues |
| `:jira` | Jira | basic | issues |
| `:confluence` | Confluence | basic | pages |
| `:dropbox` | Dropbox | OAuth2 | files |
| `:onedrive` | OneDrive | token | files |
| `:go_high_level` | GoHighLevel | token | contacts, conversations with messages, opportunities |
| `:stripe` | Stripe | token | customers, invoices, charges |
| `:beehiiv` | beehiiv | token | posts and subscribers (`families: ["posts"]` reads posts only) |
| `:jot_form` | JotForm | token | form submissions |
| `:fathom` | Fathom | token | recorded meetings with summary, transcript and action items |
| `:sources_folder` | a local folder | none | markdown files on disk |

`:zoom`, `:teams` and `:fathom` are meeting connectors: the `meeting_archive` analysis pulls every enabled connector of those kinds in a workspace.

## The adapter contract

Every adapter implements `OptimalEngine.Connectors.Behaviour` and is usually built with `OptimalEngine.Connectors.Adapters.Base`.

| Callback | Purpose |
| --- | --- |
| `kind/0` | a stable atom, the adapter's identity in the `connectors.kind` column |
| `display_name/0` | a human label for CLIs and logs |
| `auth_scheme/0` | `:oauth2`, `:token`, `:basic`, `:webhook` or `:service_account` |
| `required_config_keys/0` | keys that must exist in the connector's `config` before `init/1` runs |
| `init/1` | validates the config and hydrates the runtime state |
| `sync/2` | fetches the next batch of Signals for a cursor and returns the next cursor |
| `transform/1` | maps one external record to a `%Signal{}` |

`sync/2` must return `{:ok, signals, cursor}`, `{:ok, %{signals: ..., cursor: ...}}`, or `{:error, reason}`, and must never raise.
The reason atoms the Runner honors are `:rate_limited`, `:auth_expired`, `:transient` and `:fatal`.
Anything else is reported to the operator as-is.

## Config fields

A connector row holds a `config` JSON object.
Every adapter also reads an optional `"max_pages"` where its listing is paginated, which bounds how much one sync fetches.

| Field | Meaning |
| --- | --- |
| `"credential_source"` | `"stored"` (default) or `"broker"` |
| `"broker_url"`, `"broker_reference"`, `"broker_scopes"`, `"broker_timeout_ms"` | the outside broker that holds the account, see below |
| `"routing_labels"`, `"routing_channel"` | what the routing rules match a Signal's `label` and `channel` against |
| `"review_workspace_id"` | where a low-confidence route waits for a person |
| `"routing_walled_workspaces"` | workspaces only an identity rule may open |
| `"outward_topic"` | tags every Signal from this connector as outward evidence |

An adapter's own keys, such as `user_email` for Gmail or `location_ids` for GoHighLevel, are listed in its moduledoc.

## Credential sources

One connection, one place: the account is connected once and the Engine asks for a short-lived, scoped credential when it syncs, rather than keeping a copy per Engine.

| Source | When | Where credentials live |
| --- | --- | --- |
| `"stored"` (the default) | a self-hosted Engine outside MIOSA | the Engine, envelope-encrypted with `CONNECTOR_KEY` in `config.credentials_ciphertext` |
| `"broker"` | a managed Engine on MIOSA | the outside broker (MIOSA Connect), fetched at sync time |

With `credential_source: "broker"` the Engine `POST`s to `broker_url`:

```json
{
  "reference": "conn_0000000000",
  "connector": {"id": "pull:default:gmail", "kind": "gmail"},
  "tenant_id": "default",
  "workspace_id": "default",
  "scopes": ["mail.read"]
}
```

The broker answers with the credential map, which the adapter receives exactly as if it had been decrypted from the Engine's store:

```json
{"credentials": {"oauth_refresh_token": "..."}, "expires_at": "2026-10-18T12:05:00Z"}
```

The Engine presents no Engine-side secret in that call: the broker authenticates the Engine out of band, with a broker-issued Engine token, mTLS, or a private network.
Fetched credentials are held in memory for one sync cycle and are never written to the connectors table, the run log, or an error message.
A connector on the broker source that also carries credentials is refused at registration, so a second copy of the account can never be stored.

Three failures are possible, and each names the broker rather than the adapter:

| Error | When |
| --- | --- |
| `:broker_not_configured` | the source is `"broker"` but the URL or the reference is missing, or the source name is not one of the two known values |
| `:broker_refused` | the broker answered without usable credentials: 401, 403, 404, an error body, or an empty credential map |
| `:broker_unreachable` | no usable answer: a network error, a timeout, or a 5xx |

## Routing

A connector's Signals are routed to a workspace, in this order.

1. The connector's own workspace.
   A connector row is registered against one workspace, which is the explicit mapping: a Gmail label, a Slack channel, a GoHighLevel location or a Stripe account is pinned when the connector is created.
   Everything no rule claims stays here.
2. The stored routing rules, in `OptimalEngine.Routing.RuleStore`.
   A rule matches a Signal's sender, domain, label, channel or keywords.
   A high-confidence route wins, so a person or company the operator has already mapped claims their mail wherever it arrives.
   A low-confidence route goes to `review_workspace_id` when the connector names one, and otherwise stays put.
3. Walled workspaces.
   A workspace named in `routing_walled_workspaces` is only reached by an identity rule, on sender, domain, label or channel.
   A keyword is a guess, and a guess never opens a private view.

`OptimalEngine.Connectors.Routing.material/2` reads what a Signal can honestly say about itself: the sender is the first email-shaped entity, the title and text come from the Signal, and the labels and channel come from the connector's config, because a per-message label is not part of a Signal.

## Open loops

After a Signal is stored, the Engine reads it for what someone owes: a reply that is expected, a commitment made, money due, or a decision someone is waiting on.
Detection is deterministic and shared with the operating layer, so a connector-ingested message and a workspace context produce the same loops from the same words.
Each loop records the workspace, the counterparty, the due date resolved from phrases such as "by Friday" or an ISO date, and the uri of the context the Signal was stored as, so the loop links back to its evidence.
A message with nothing owed creates no loop.

## Outward evidence

A connector may name an `outward_topic`, one of `market`, `customers`, `competitors`, `technology`, `risk`, `regulation` or `partners`.
When it does, every Signal it produces is recorded as an `outward` event on its workspace, which is what System 4 reads to see the outside world.
A topic the Engine does not know is refused when the connector is registered, not silently ignored on every sync.

## Registering a connector

A connector is a row in the `connectors` table, registered against one workspace.
The workspace must exist, belong to the tenant, and be active; registering into a missing or archived workspace is refused.
Every Signal the connector emits lands in that workspace unless a routing rule claims it.

From the command line:

```bash
mix optimal.connector register gmail-ops --kind gmail --config gmail.json --workspace default:ops
mix optimal.connector register gmail-ops ... --disabled     # register without pulling yet
mix optimal.connector list                                  # rows with workspace, state, last run, last error
mix optimal.connector list --workspace default:ops
mix optimal.connector adapters                              # every adapter the Engine ships
mix optimal.connector run gmail-ops                         # one sync cycle, through intake
mix optimal.pull                                            # every enabled connector, once
```

The config file holds the adapter's config, with its credentials under `"credentials"`.
`register` replaces the tenant's own row of the same id.

Over HTTP:

| Route | Scope | What it does |
| --- | --- | --- |
| `GET /api/connectors?workspace=` | `read` | the connectors of every workspace the key covers, or of the named one |
| `GET /api/connectors/:id` | `read` | one connector |
| `POST /api/connectors` | `connectors:write` or `admin` | register: `id`, `kind`, `workspace`, `config`, `credentials`, `enabled` |
| `PATCH /api/connectors/:id` | `connectors:write` or `admin` | change `enabled`, `cadence`, `interval_ms`, `config`, `credentials`, or move it with `workspace` |
| `DELETE /api/connectors/:id` | `connectors:write` or `admin` | delete the connector and its run history |
| `POST /api/connectors/:id/run` | `write` | run it now and answer with the result; `{"wait": false}` starts it and answers `202` |

```bash
curl http://localhost:4200/api/connectors \
  -H "Authorization: Bearer $OPTIMAL_ENGINE_KEY" \
  -H 'Content-Type: application/json' \
  --data '{"id":"gmail-ops","kind":"gmail","workspace":"default:ops",
           "config":{"user_email":"ops@example.com","credential_source":"broker",
                     "broker_url":"https://connect.example.com/api/credentials",
                     "broker_reference":"conn_0000000000"}}'
```

Credentials are write-only.
They arrive only under `credentials`, which the Engine seals with `CONNECTOR_KEY`, or from the broker with `credential_source: "broker"`.
A secret-shaped key anywhere else in `config` (a token, secret, password or API key) is refused with `credentials_outside_envelope`.
No response, list or log ever carries credentials or their ciphertext: a connector reports only `"credentials": "stored"`, `"broker"` or `"none"`.
`PATCH` with `credentials` replaces them, and `"credentials": null` removes them; switching a connector to the broker requires removing stored credentials in the same change.

A key restricted to named workspaces lists only its workspaces' connectors, and every `:id` route answers `404` for a connector outside them, exactly as for one that does not exist.
Naming a workspace the key does not cover in `?workspace=` or in a registration body is `403 workspace_scope_denied`.
Each registration, change and deletion, and each run asked for over HTTP, is appended to the authority evidence chain as `connector.registered`, `connector.changed`, `connector.deleted` or `connector.run`, naming the acting principal.

## Scheduling

`OptimalEngine.Connectors.PullScheduler` runs the connectors table.
Every tick (`tick_ms`, one minute by default) it reads the enabled connector rows of its tenant and starts the ones that are due.

- **What runs.**
  Every enabled row of the tenant, however it was registered: the CLI, the HTTP API, or a config spec.
  A disabled row never runs, and nothing re-enables it.
- **Config specs only provision.**
  A spec in `config :optimal_engine, :connectors, enabled: [...]` inserts its row once, when the row does not exist.
  An existing row is never changed by a spec, so an operator's workspace, config and enabled state always win.
  A spec without a workspace is provisioned into the tenant's intake workspace: the Engine's own workspace when it is workspace-scoped, then the configured intake workspace (`corpus_source_workspace`, `default:knowledge-intake` by default), then the legacy `default` workspace, whichever is first active and owned by the tenant.
  An archived workspace is skipped; with no active candidate the spec is reported as a failed pull with `no_intake_workspace` and nothing is inserted.
  Deleting a row a spec provisions brings it back on the next tick, so disable it instead.
- **Cadence.**
  A row's `config` may set `"interval_ms"` (at least 60000) or `"cadence"` (`"hourly"`, `"daily"`, `"weekly"`, or `"15m"`, `"6h"`, `"2d"`); `interval_ms` wins when both are set.
  Without either, message and meeting sources (`gmail`, `slack`, `teams`, `zoom`, `fathom`, `go_high_level`) pull hourly, file and document sources (`sources_folder`, `drive`, `dropbox`, `onedrive`, `notion`, `confluence`) pull daily, and every other kind pulls on the scheduler's `interval_ms`, daily by default.
  A connector is due when its cadence has passed since its last run started, or when it has never run.
- **No starvation.**
  Due connectors start oldest first, at most `max_concurrency` (3) at a time, each in its own task, so one slow connector never holds up the others.
- **No overlap.**
  A connector still running is never started again, and the Runner allows one run per connector at a time across the scheduler, the API, the CLI and analyses; a second request is refused with `already_running`.

The Runner writes one `connector_runs` row for every sync it attempts, including one whose adapter could not be initialised, advances the cursor only on success, disables a connector on a fatal error, and retries rate limits and transient failures with backoff.
A connector whose workspace was archived fails its run with `workspace_archived` instead of pulling into a retired workspace.
The produced Signals are driven through `OptimalEngine.Pipeline.Intake`, which is where routing, loops and outward tagging happen.

| Setting (`config :optimal_engine, :pull_scheduler`) | Default | Meaning |
| --- | --- | --- |
| `enabled` | `true` | start the loop |
| `boot_delay_ms` | 2 minutes | delay before the first tick |
| `tick_ms` | 1 minute | how often due connectors are checked |
| `interval_ms` | 24 hours | cadence for kinds without one of their own |
| `max_concurrency` | 3 | connectors pulling at once |
| `tenant_id` | `default` | the tenant whose connectors the loop runs |

## Status

Every connector view, in `GET /api/connectors` and `mix optimal.connector list`, carries its run status: `running`, `last_run` (start, end, status, signals, error), `last_error`, `runs`, `signals_total`, its `cadence` and where it came from, and `next_run_at`.
A run that was cut off by a restart shows as `interrupted`.
`GET /api/metrics` adds a `connectors` summary for the workspaces the key covers: totals, how many are running and failing, and each failing connector with its reason.
A failed pull is never silent: the scheduler logs a warning naming the connector and the reason, `last_run` shows the failure until a later run succeeds, and `last_error` keeps the most recent failure after that.
