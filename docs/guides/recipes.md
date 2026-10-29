# Recipes

Each recipe sets an Engine up for one use and shows the calls that use it.
Examples use the `optimal` CLI (alias `oe`, `docs/guides/cli.md`) and the HTTP API; every call carries `Authorization: Bearer <key>`.
`test/recipes/recipes_test.exs` runs the API side of each recipe.

## Agent memory

One agent, or one end user's agent, with memory of its own.

```
optimal init --for agent --slug mailer --name "Mailer agent"
POST /api/principals {"id": "agent:mailer", "kind": "agent"}
POST /api/auth/keys {"name": "mailer", "principal_id": "agent:mailer", "scopes": ["read", "write"], "workspace_scope": ["<tenant>:mailer"]}
```

The agent then works only with its own key:

```
POST /api/memory {"workspace": "<tenant>:mailer", "content": "The customer prefers email over calls."}
GET  /api/search?q=prefers&workspace=<tenant>:mailer
POST /api/agent-actions {"workspace": "<tenant>:mailer", "stage": "request", "action": "send_email", "resource": "mailto:customer"}
```

Run it as its own Engine at the `agent` size (scales to zero), or as a workspace inside a larger Engine when many agents share one machine.

## Workspace brain

One client or team: Signals, open loops, the daily rhythm, and its health.

```
optimal init --for workspace --slug client-a --name "Client A"
optimal capture "Can you confirm the pricing before Friday?" client-a
optimal loops extract client-a
optimal boot client-a
optimal brief client-a
optimal viability client-a
```

## Org brain

A whole company in one Engine: a workspace per team or client, shared upward to the org on purpose, read across workspaces with one key.

```
optimal init --for business --slug ops --name Ops
optimal init --for business --slug sales --name Sales
PUT /api/workspaces/<tenant>:sales/share {"share_up": "read"}
GET /api/federation/search?q=renewal
GET /api/brief?workspaces=*
GET /api/viability?workspaces=*
optimal init --for business --slug org --name Org
PUT /api/org-section {"workspace_id": "<tenant>:org"}
POST /api/memory {"workspace": "<tenant>:org", "content": "Every outbound quote needs a second reviewer.", "metadata": {"kind": "policy"}}
GET /api/org-policy?workspace=<tenant>:sales
```

A key scoped to some workspaces sees only those in every org view.
Policy kept in the org section flows down read-only to every workspace's boot and context assembly (`chat-memory.md`).

## One Engine per customer

White label: each customer gets an Engine of its own with its own keys, evidence, and backups.

```
optimal init --for tenant-per-customer --slug main --name "Customer"
POST /api/auth/keys {"name": "customer-app", "scopes": ["read", "write"], "workspace_scope": ["<tenant>:main"]}
GET  /api/authority/evidence/export
POST /api/workspaces/<tenant>:main/bundle
```

The platform keeps the root key in its vault, hands the customer's apps narrowed keys only, and moves a customer by exporting and importing its workspace bundle (`docs/guides/scope-and-portability.md`).

## Search and RAG for an app

An application's retrieval layer: write content in, read answers out, with a read-only key for the app's front end.

```
optimal init --for app --slug docs --name Docs
POST /api/ingest {"workspace": "<tenant>:docs", "title": "Refund policy", "text": "Refunds are issued within 14 days."}
POST /api/auth/keys {"name": "docs-reader", "scopes": ["read"], "workspace_scope": ["<tenant>:docs"]}
GET  /api/search?q=refund&workspace=<tenant>:docs
POST /api/rag {"workspace": "<tenant>:docs", "query": "How long do refunds take?"}
POST /api/assemble {"workspace": "<tenant>:docs", "query": "refunds"}
GET  /api/read?uri=<optimal:// address>&workspace=<tenant>:docs
```

An importer that captures items from another system (chat days, meetings, commits) also sends what intake needs to file them as that system's items:

```
POST /api/ingest {"workspace": "<tenant>:ops", "title": "WhatsApp 2026-10-28: Jordan", "text": "...",
                  "occurred_at": "2026-10-28", "source_id": "whatsapp:15125550100:2026-10-28"}
```

`occurred_at` (an ISO 8601 date or date-time; a bare date means noon UTC) dates the signal when the item happened instead of when it was ingested, `source_id` makes a later ingest of the same item replace its row instead of adding another, and `"write_files": false` stores the signal in the database only, the way connector pulls do.
An `occurred_at` that is not a date is a 400.

## App database and connector hub

The app data API (collections, records, queries, change feed) and the connector hub land with their own guides.
