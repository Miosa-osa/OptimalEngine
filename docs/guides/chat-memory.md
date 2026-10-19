# Chat memory: sessions and org policy

A chat client (a console chat, a voice agent, a CLI agent, a scheduled run) uses the Engine as its memory.
It boots and assembles context from the workspace it was given, and when a chat ends it commits the transcript so later chats, agents and people find it.
Every workspace of an organization also follows the same rules: policy kept in the organization's org section flows down to every workspace, read-only.

| Route | Scope | What it does |
| --- | --- | --- |
| `POST /api/sessions/commit` | `write` | Stores a finished chat as an episode in the workspace; what it learned becomes proposed claims |
| `GET /api/sessions?workspace=&correlation_id=&limit=&offset=` | `read` | The workspace's committed chats, newest first |
| `GET /api/sessions/:id?workspace=&include=transcript` | `read` | One chat, with the live review status of what it learned |
| `GET /api/org-section` | `read` | The tenant's org section |
| `PUT /api/org-section {"workspace_id"}`, `DELETE /api/org-section` | `admin` | Designate or clear the org section |
| `GET /api/org-policy?workspace=` | `read` | The org policy the workspace follows |

`GET /api/boot` and `POST /api/assemble` also carry the org policy as `org_policy`.

## Committing a chat

One call with the whole transcript, at the end of the chat:

```json
POST /api/sessions/commit
{
  "workspace": "<tenant>:sales",
  "correlation_id": "chat_8f2c",
  "title": "Launch planning",
  "source": "console-chat",
  "messages": [
    {"role": "user", "content": "We decided to move the launch review to Thursday.", "at": "2026-10-18T09:00:00Z"},
    {"role": "assistant", "content": "Noted. The vendor wants the signed order form by Friday.", "at": "2026-10-18T09:00:05Z"}
  ],
  "learned": [
    {"category": "task", "content": "Send the vendor the signed order form", "owner": "user:jane", "due": "2026-10-23"}
  ]
}
```

* `correlation_id` (required) is the chat's own id.
* `messages` (required): `role` is `user`, `assistant`, `system`, or `tool`; `content` is non-empty text; `at` is an optional ISO 8601 date-time.
* `title` (up to 200 characters), `source` (default `chat`), and `summary` (the client's own summary, up to 4,000 characters; the Engine writes one when it is absent) are optional.
* `learned` (optional, up to 50) proposes items for review: `content`, `category` (`fact` by default, or `decision`, `task`, `correction`, `preference`, `relationship`, `context`, `skill`), and for tasks `owner` and `due`.
* The actor is the key's principal; a body that names another actor is refused with 403 `actor_identity_mismatch`.

The first commit answers 201:

```json
{
  "session_id": "ses_...",
  "uri": "optimal://<tenant>:sales/sessions/ses_...",
  "workspace_id": "<tenant>:sales",
  "correlation_id": "chat_8f2c",
  "summary": "...",
  "summary_source": "generated",
  "message_count": 2,
  "started_at": "2026-10-18T09:00:00Z",
  "ended_at": "2026-10-18T09:00:05Z",
  "committed_at": "...",
  "actor_id": "agent:console-chat",
  "episode": {"id": "epi_...", "kind": "session", "uri": "optimal://<tenant>:sales/episodes/epi_..."},
  "source_package_id": "sp_...",
  "stored": {"episodes": "epi_...", "sessions": "ses_...", "contexts": "ses_...", "source_packages": "sp_..."},
  "learned": [
    {"claim_id": "cl_...", "uri": "optimal://<tenant>:sales/memory-core/claims/cl_...", "content": "Send the vendor the signed order form",
     "category": "task", "origin": "client", "owner": "user:jane", "due": "2026-10-23", "status": "pending", "review_status": "unreviewed"},
    {"claim_id": "cl_...", "content": "We decided to move the launch review to Thursday.", "category": "decision", "origin": "engine", "status": "pending"}
  ],
  "replayed": false
}
```

### What is stored

The session lifecycle (`../reference/session-lifecycle.md`) holds: a conversation summary is source evidence, never a Fact.

* The transcript is kept first as a Source Package (`source_type: chat_session`).
* The chat becomes an Episode (`kind: "session"`), the Engine's episodic memory record, in the chat's workspace, with provenance to the Source Package, the context, and the claims.
* A context at `optimal://<workspace>/sessions/<id>` holds the summary and the transcript, so `GET /api/search`, `GET /api/read`, and agents find the chat later.
* What the chat learned becomes pending claims in the workspace's review queue: what the client proposed in `learned`, plus what the Engine extracted from the transcript (`origin: "engine"`).
* The session record (`sessions` table) is written last, with a derivation ledger entry linking the Source Package to the episode, the context, and the claims.

Nothing becomes accepted truth without review.

### Reviewing what a chat learned

Each learned item is a claim with a `claim_id`, typed by its category.
A reviewer with the `claims:review` scope accepts it with `POST /api/memory-core/claims/:id/promote` (pass `fact_text` to accept an edited version) or rejects it with `POST /api/memory-core/claims/:id/reject`; rejected claims stay on the data steward's record.
`GET /api/sessions/:id` shows each item's current `status` (`pending`, `promoted`, `rejected`).
A reviewer may not accept a claim they evaluated themselves: items the Engine extracted are evaluated by `system:chat-session`, so the person who chatted can review them; items a client proposes in `learned` are evaluated by the committing key's principal, so give the chat client its own principal and let people review with theirs.

### Retries, conflicts, and limits

The same `correlation_id` in the same workspace with the same transcript returns the stored result with 200 and `"replayed": true`, and writes nothing.
The same `correlation_id` with a different transcript is 409 `{"error": "idempotency_key_conflict", "session_id"}`.
Commits of one chat are serialized, so concurrent retries store it once.
The same chat id in another workspace is another session.

| Limit | Default | Error |
| --- | --- | --- |
| Messages per call | 1,000 | 413 `{"error": "session_too_large", "limit": "messages", "max", "got"}` |
| Text per call (messages, learned, title, summary) | 1,000,000 bytes | 413 with `"limit": "bytes"` |
| Learned items per call | 50 | 413 with `"limit": "learned"` |

A malformed body is 422 `{"error": "invalid_session", "detail"}`.
Deployments set the first two with `config :optimal_engine, :chat_sessions, max_messages: ..., max_bytes: ...`.
The Engine's summary and extraction use the local model when `config :optimal_engine, :session` allows it (`llm_summary`, `llm_extraction`, both on by default) and a model answers; otherwise the summary is the first user messages and extraction is rule based.

### Reading

`GET /api/sessions` and `GET /api/sessions/:id` answer only inside the caller's tenant and the workspace the request names; a session of another workspace or tenant is 404.
`include=transcript` adds the transcript to one session.

## The org section and org policy

An org section is a workspace of the tenant that holds memory spanning workspaces: priorities, policy, people and relationships across the business (`recipes.md`, "Org brain").
A tenant has at most one; it is a tenant setting, designated with the `admin` scope and recorded in the authority evidence chain:

```
PUT /api/org-section {"workspace_id": "<tenant>:org"}
GET /api/org-section          -> {workspace_id, designated_by, designated_at, active, share_up, flows_down}
DELETE /api/org-section
```

A memory in the org section is org policy when its `metadata.kind` is `"policy"`; only its latest version counts, and a forgotten one does not.
Policy is written with the ordinary memory routes and a key that can write the org section:

```
POST /api/memory {"workspace": "<tenant>:org", "content": "Every outbound quote needs a second reviewer.", "metadata": {"kind": "policy"}}
POST /api/memory/<id>/update {"workspace": "<tenant>:org", "content": "..."}
POST /api/memory/<id>/forget {"workspace": "<tenant>:org"}
```

A memory marked `policy` in any other workspace stays local to that workspace.

### Reading policy from a workspace

A key scoped to one workspace reads the org policy, never anything else of the org section:

* `GET /api/boot?workspace=W` and `POST /api/assemble {"workspace": "W", ...}` carry `org_policy`.
* `GET /api/org-policy?workspace=W` lists it.
* `GET /api/memory/<policy id>?workspace=W` reads one policy memory, labeled `inherited: true` and `source_workspace_id`.

```json
"org_policy": {
  "org_workspace_id": "<tenant>:org",
  "inherited": true,
  "count": 1,
  "memories": [
    {"id": "...", "uri": "optimal://<tenant>:org/memory/...", "content": "Every outbound quote needs a second reviewer.",
     "version": 1, "source_workspace_id": "<tenant>:org", "inherited": true}
  ],
  "withheld": 0,
  "withheld_reason": null
}
```

In the org section itself the same memories are its own (`inherited: false`).
Clients place them in the agent's instructions, so every agent of the organization follows the same rules.

Writing policy from a workspace is refused: naming the org section in a body or query is 403 `workspace_scope_denied`, and every write route on a policy memory read from a workspace (update, extend, derive, forget, promote, delete) is 403 `workspace_scope_denied`.
Other content of the org section is not there for a workspace key: by id it is 404 `memory not found`, and naming the org section is 403.

### Deny wins

* An org section whose share-up policy is `none` (`scope-and-portability.md`) keeps its policy inside; readers see `withheld_reason: "org_section_not_shared"`.
* An Engine that does not serve the org section (workspace scope) has no org policy.
* When Optimal Authority governs the tenant (`observe` or `enforce`), each inherited read is decided as `read` on `optimal://<org>/memory/<id>` in the org section, and a local deny that names the reading workspace applies too.
  Under `enforce` a refused memory is withheld and counted in `withheld`; under `observe` it is shown.
  Either way the refusal is recorded once per read as `decision.denied` or `decision.observed` evidence.
  Under `enforce`, a policy pack must allow `read` on the org section's memory for policy to flow.

## Record and list scoping

Routes that address a record by id answer only inside the caller's tenant and key workspace scope:

* `GET /api/memory/:id`, `/versions`, `/relations`, `POST /api/memory/:id/{forget, update, extend, derive, promote}`, and `DELETE /api/memory/:id` act on a memory only when the key covers the memory's workspace and the workspace the request names (if any) is the memory's own.
  Otherwise the answer is 404 `memory not found`, the same as for another tenant's memory.
  Org policy read from a workspace is the one exception, described above.
* `GET /api/signals/:id` reads only a context of the caller's tenant in the named workspace.
* `GET /api/workspaces` lists only the workspaces in the key's `workspace_scope`, unless the key holds `*`.
* `GET /api/health` answers any valid key without a workspace; `?full=true` reads one workspace's diagnostics, so a key limited to named workspaces passes `workspace=<id>` (400 `workspace_required` otherwise).

## CLI and MCP

| CLI | MCP tool | Route |
| --- | --- | --- |
| `optimal session commit <messages.json\|-> [ws] --correlation-id <id> [--title --summary]` | `session_commit` | `POST /api/sessions/commit` |
| `optimal session [list] [ws] [--correlation-id]` | `sessions_list` | `GET /api/sessions` |
| `optimal session show <id> [ws] [--transcript]` | `session_get` | `GET /api/sessions/:id` |
| `optimal policy [ws]` | `org_policy` | `GET /api/org-policy` |
| `optimal org-section [show \| set <workspace> \| clear]` | | `GET/PUT/DELETE /api/org-section` |

The CLI's messages file is a JSON array of `{role, content, at?}`; `learned` items go through the MCP tool or the HTTP route.
