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
| `"broker_url"`, `"broker_reference"`, `"broker_scopes"`, `"broker_timeout_ms"` | the outside broker that holds the account; the reference is sealed on write, see below |
| `"routing_labels"`, `"routing_channel"` | what the routing rules match a Signal's `label` and `channel` against |
| `"review_workspace_id"` | where a low-confidence route waits for a person; a workspace of the connector's tenant, else registering the connector answers `invalid_review_workspace` |
| `"routing_walled_workspaces"` | workspaces only an identity rule may open |
| `"outward_topic"` | tags every Signal from this connector as outward evidence |
| `"write_files"` | `true` also writes a markdown file per pulled item into the workspace folder; default `false` |

An adapter's own keys, such as `user_email` for Gmail or `location_ids` for GoHighLevel, are listed in its moduledoc.
Gmail also reads `"exclude_categories"`: the inbox tabs it leaves out, `["promotions", "social", "updates", "forums"]` by default, `[]` for every tab.
Spam, trash and drafts are never read, and each message is stored with its sender, recipients, date, subject and text body.

## Where pulled items are stored

A pulled item is stored in the database only: one row per source item and workspace, keyed by the item's id in its source, so a later pull of the same item replaces its row instead of adding another.
The row's uri is the item's source uri (for example `optimal://connectors/gmail/<message id>`), it has no file path, and it is dated when the item happened, not when it was pulled.
Search, retrieval and routing read the row like any other context.
A mailbox, a form or a newsletter therefore never becomes thousands of markdown files; set `"write_files": true` on a connector that should also project its items to disk.

## Credential sources

One connection, one place: the account is connected once and the Engine asks for a short-lived, scoped credential when it syncs, rather than keeping a copy per Engine.

| Source | When | Where credentials live |
| --- | --- | --- |
| `"stored"` (the default) | a self-hosted Engine outside MIOSA | the Engine, envelope-encrypted with `CONNECTOR_KEY` in `config.credentials_ciphertext` |
| `"broker"` | a managed Engine on MIOSA | the outside broker (MIOSA Connect), fetched at sync time |

### The broker credential shape

A connector on the broker names the broker and its reference to the connection, and carries no credentials:

```json
{
  "user_email": "ops@example.com",
  "credential_source": "broker",
  "broker_url": "https://api.miosa.ai/api/v1/connect/broker/credentials",
  "broker_reference": "conn_0000000000.<hmac>",
  "broker_scopes": ["mail.read"],
  "broker_timeout_ms": 5000
}
```

`broker_scopes` and `broker_timeout_ms` are optional; the timeout is 5 seconds by default and at most 30.
The reference is opaque to the Engine, and a broker may sign it, so it is treated as a secret: the Engine seals it with `CONNECTOR_KEY` into `config.broker_reference_ciphertext` when the row is written, opens it only for the broker call, and every read API shows it as `"[redacted]"`.
Writing a broker connector therefore needs `CONNECTOR_KEY`, exactly as stored credentials do.
The seal is bound to the connector's id, so a copy of it on another row does not open.
It is not bound to the workspace, which a move or a rename changes while the connector stays the same.
The reference is read from its seal alone: a plaintext `broker_reference` in a stored row is not read (no released Engine stored one), and a seal made without a connector id does not exist.
A connector on the broker source that also carries credentials is refused at registration, so a second copy of the account can never be stored.

### The request

At the start of each sync the Engine `POST`s to `broker_url`:

```json
{
  "reference": "conn_0000000000.<hmac>",
  "connector": {"id": "miosa:conn_0000000000:gmail", "kind": "gmail"},
  "tenant_id": "default",
  "workspace_id": "default:ops",
  "scopes": ["mail.read"]
}
```

`reference` is the configured `broker_reference`, sent verbatim.
MIOSA Connect issues it as `<connection_id>.<base64url hmac>`, and that signature is what the broker authenticates the call by; the Engine never parses it.
`connector.id` is the connector's own id, and `workspace_id` is the connector's own workspace, never one its signals are routed to: the signature covers the workspace, so any other value is answered with a `401`.
The Engine sends no secret and no header of its own beyond `accept` and `content-type`, and never holds the platform's internal secret.
The call does not follow redirects, verifies the broker's certificate and host name, is made once on a connection of its own, reads at most 256 KiB of the answer, and gives up after `broker_timeout_ms`.
"Once" is the Engine's own guarantee, whatever the Erlang/OTP release: the call is made by `Connectors.HTTP.SingleAttempt`, not by `:httpc`, which before OTP 28.4 sends a request again after an answer that names a `Retry-After`, until its timeout.
A `503` with a `Retry-After` from the broker is read as `broker_unreachable` and is not sent again within the call.
The route is whatever `broker_url` names, per connector, so a broker can move its route without an Engine change.

`broker_url` is checked as written, not as a parser might read it.
It must be `https://` in lower case, on port 443 (or none), with an ASCII host listed in `OPTIMAL_CREDENTIAL_BROKER_HOSTS` (comma-separated, compared without case, no trailing dot; `config :optimal_engine, :credential_broker_hosts` in code), no user or password, no query or fragment, and a path under one of `OPTIMAL_CREDENTIAL_BROKER_PATHS` (comma-separated; default `/api/v1/connect/broker/`) with no `.`, `..`, empty, `;` or percent-encoded segment.
An empty or blank entry in `OPTIMAL_CREDENTIAL_BROKER_PATHS`, a bare `/`, a `;` or a `..` stops the Engine at boot, since each would allow more than was meant.
A managed Engine on MIOSA sets it to `api.miosa.ai`, and the MIOSA platform puts `https://api.miosa.ai/api/v1/connect/broker/credentials` in each connector's `broker_url` when it registers the connector.
With no hosts listed, no broker is called and the run fails with `broker_url_not_allowed`, so a connector config can never point the Engine at an address of its choosing.
A URL outside the list is also refused when the connector is registered or changed.

### The response

An OAuth connection (Gmail, Drive, Notion, Slack and the other OAuth adapters) is answered with a short-lived access token:

```json
{"credentials": {"access_token": "...", "expires_at": "2026-10-18T12:05:00Z"}}
```

`expires_at` may also sit beside `credentials` instead of inside it, the same fields at the top level are accepted as a fallback, and `"expires_in"` (seconds) is read when `"expires_at"` is absent.
The adapter calls its API with that token through `OptimalEngine.Connectors.AccessToken`, the one helper every OAuth adapter shares:

- **Early renewal.**
  Before a call, a token that expires within 60 seconds is replaced by asking the broker again.
- **One re-fetch on refusal.**
  When the API refuses the token (a `401`, or Slack's `invalid_auth`, `token_expired` and the like), the Engine asks the broker once for a new token and retries that call.
- **Never a loop.**
  A second refusal anywhere in the same sync fails the run with `broker_token_rejected`, and a broker that cannot answer the re-fetch fails it with `broker_unreachable`, `broker_unauthorized` or `broker_refused`.
  After a failure the sync makes no further calls, the run is recorded as failed, the cursor stays where it was, and the connector stays enabled for its next run.
- **One budget per run.**
  The Runner may attempt a sync again (after a throttled or transient answer); the renewed token and the spent re-fetch carry over, so a run asks the broker for a new token once however many attempts it takes.
- **The token goes only where the adapter sent it.**
  Calls are https only, verify TLS, and follow no redirect by themselves: a redirect comes back as the answer it was.
  Drive's file downloads follow up to two redirects that stay on the same origin; no other redirect is followed with a token.
  Salesforce's `instance_url` must be an org's own API host (`<org>.my.salesforce.com`, with at most one sandbox or develop label before `my`, or a legacy pod such as `na1.salesforce.com`) and OneDrive follows only links on Microsoft Graph's hosts.
  Jira's and Confluence's `site_url` must be https, and when the broker issued the key it must be `<site>.atlassian.net`; a connector with its own credentials may name a self-hosted site.
  Apart from Drive's same-origin downloads, no adapter follows a redirect with a credential: `Connectors.HTTP` hands a redirect back unless the caller asks for it.

A stored API key is answered the same way, and the credential map reaches the adapter exactly as if it had been decrypted from the Engine's store:

```json
{"credentials": {"api_key": "..."}, "expires_at": "2026-10-18T12:05:00Z"}
```

Each adapter has one key its secret lives under, and the broker's secret is put there:

| Adapter | Access token from the broker | API key from the broker |
| --- | --- | --- |
| Gmail, Drive, Dropbox, OneDrive, Salesforce, Teams, Zoom, HubSpot | `access_token`, renewable | kept as sent |
| Notion | `access_token`, renewable | `integration_token` |
| Slack | `access_token`, renewable | `bot_token` |
| Stripe, Fathom, Linear, JotForm, beehiiv | `api_key` | `api_key` |
| GitHub | `pat` | `pat` |
| GoHighLevel, Jira, Confluence | `api_token` | `api_token` |

A key the broker names itself (for example `bot_token`) is passed on as it is and wins.

Fetched tokens and credentials are held in memory for one sync cycle: they are never written to the connectors table, a run record, the evidence chain, a log, or an error message.
The secrets a broker issues (the access token, an API key, the key an adapter names for its secret) and an `access_token` given directly are held in the adapter's state as opaque values, so `inspect/1` of the state, a token or an error, and a crash report that prints the state, show only where a token came from and when it expires.
A held secret has no text conversion: `"#{secret}"` and `to_string/1` raise, and an adapter reveals one by name (`AccessToken.reveal/1`) where it builds a header.
Other credentials in the state, such as the client secret and refresh token of a connector on the Engine's own store, are plain strings for the length of a sync.

### A token given directly

An OAuth adapter also accepts an `access_token` in its credentials, for tests and simple setups.
It is sent as it is and never renewed: a refusal is reported as the adapter always reports one, usually `auth_expired`.
The refresh-token flow is unchanged: given `oauth_refresh_token`, `client_id` and `client_secret` (or the adapter's own equivalents), the adapter exchanges them for a token once per sync, as before.
A connector that carries a complete set of those (every key of the adapter's own grant) uses the grant, and an `access_token` left beside it is ignored; a broker-issued token comes before both.
The exchanges post a form (`application/x-www-form-urlencoded`), once (by `Connectors.HTTP.SingleAttempt`), on a connection of their own with TLS verified and no redirect.
Gmail's and Drive's refresh posts JSON, as before, and reads the answer the same way.
A `401`, or a `400` naming `invalid_grant`, `invalid_client` or `unauthorized_client`, is `auth_expired`; any other `400` is `{:token_error, error_code}`, carrying only the provider's `error` field and only when it is 1 to 64 lower-case letters and underscores (else `"unknown"`); a `429` is `rate_limited`, with the `Retry-After` the provider named (at most 30 s) for the Runner to wait; a `5xx` is `transient`.

### Errors

Each failure names the broker rather than the adapter:

| Error | When |
| --- | --- |
| `broker_not_configured` | the source is `"broker"` but the URL or the reference is missing |
| `broker_url_not_allowed` | the URL is not `https`, carries credentials, or its host is not in `OPTIMAL_CREDENTIAL_BROKER_HOSTS` |
| `broker_reference_unreadable` | the sealed reference cannot be opened with this Engine's `CONNECTOR_KEY` |
| `broker_unauthorized` | the broker answered 401: it did not accept the reference as proof |
| `broker_refused` | the broker answered without usable credentials: 403, 404, an error body, an empty credential map, or a renewal without an access token |
| `broker_unreachable` | no usable answer: a network error, a timeout, or a 5xx |
| `broker_token_rejected` | the API refused a brokered token again after one re-fetch |
| `invalid_credential_source` | the source is not `"stored"` or `"broker"` |

A failure to fetch fails the run before the adapter is initialised; the run row names the reason, and the connector is not disabled.

## Routing

A connector's Signals are routed to a workspace, in this order.

1. The connector's own workspace.
   A connector row is registered against one workspace, which is the explicit mapping: a Gmail label, a Slack channel, a GoHighLevel location or a Stripe account is pinned when the connector is created.
   Everything no rule claims stays here.
2. The stored routing rules, in `OptimalEngine.Routing.RuleStore`.
   A rule matches a Signal's sender, domain, label, channel or keywords.
   A high-confidence route wins, so a person or company the operator has already mapped claims their mail wherever it arrives.
   A low-confidence route goes to `review_workspace_id` when the connector names one, and otherwise stays put.
   A route, whether from a rule or from `review_workspace_id`, that names a workspace of another tenant (or an archived one) is not taken, and the Engine logs it: the Signal stays in the connector's own workspace.
   A workspace nobody registered is routable by the default tenant only.
   A connector registered before this check can still be disabled or changed in what it does not touch.
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
  --data '{"id":"miosa:conn_0000000000:gmail","kind":"gmail","workspace":"default:ops",
           "config":{"user_email":"ops@example.com","credential_source":"broker",
                     "broker_url":"https://api.miosa.ai/api/v1/connect/broker/credentials",
                     "broker_reference":"conn_0000000000.<hmac>",
                     "broker_scopes":["gmail.readonly"],"interval_ms":900000}}'
```

Credentials are write-only.
They arrive only under `credentials`, which the Engine seals with `CONNECTOR_KEY`, or from the broker with `credential_source: "broker"`.
A secret-shaped key anywhere else in `config` (a token, secret, password or API key) is refused with `credentials_outside_envelope`.
No response, list or log ever carries credentials or their ciphertext: a connector reports only `"credentials": "stored"`, `"broker"` or `"none"`, and a broker reference only as `"[redacted]"`.
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
  A spec without a workspace is provisioned into the tenant's intake workspace: the Engine's own workspace when it is workspace-scoped, then the tenant's own intake workspace (`<tenant>:knowledge-intake`, which is `default:knowledge-intake` for the default tenant; `corpus_source_workspace` names the intake of the tenant that owns it), then the legacy `default` workspace, whichever is first active and owned by the tenant.
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
