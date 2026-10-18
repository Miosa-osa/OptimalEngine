# Connectors

A connector is a one-way pipe from an outside system into the Engine: it pulls on a cursor, hands the Engine a stream of Signals, and does nothing else.
Classification, routing, storage and memory all run downstream of it, in the intake pipeline, so a connector never holds business logic of its own.
This guide covers the adapter list, the config fields, where credentials come from, and what happens to a Signal after a connector emits it.

## The adapter list

Twenty adapters ship with the Engine.
`OptimalEngine.Connectors.Registry.summary/0` returns them as `{kind, display_name, auth_scheme}` triples.

| Kind | Source | Auth | What it pulls |
| --- | --- | --- | --- |
| `:gmail` | Gmail | OAuth2 | messages and threads, bounded by a lookback window |
| `:drive` | Google Drive | OAuth2 | files and documents |
| `:notion` | Notion | token | pages and databases |
| `:slack` | Slack | OAuth2 | channels, threads and messages |
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
| `:beehiiv` | beehiiv | token | posts and subscribers |
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

## Running a connector

```bash
mix optimal.connector list                    # every registered adapter
mix optimal.connector register <id> --kind gmail --config config.json
mix optimal.connector run <id>                # one sync cycle
mix optimal.pull                              # every enabled connector, once
```

The Runner writes one `connector_runs` row per invocation, advances the cursor only on success, disables a connector on a fatal error, and retries rate limits and transient failures with backoff.
`OptimalEngine.Connectors.PullScheduler` is the driver: on an interval it runs each enabled connector once and drives the produced Signals through `OptimalEngine.Pipeline.Intake`, which is where routing, loops and outward tagging happen.
