# Scope, sharing, and moving workspaces

## Engine scope

An Engine runs in one of two scopes.

| Scope | Set with | Behavior |
| --- | --- | --- |
| `org` (default) | `OPTIMAL_ENGINE_SCOPE=org` | One Engine for an organization; every workspace is a walled section. A key scoped to one workspace never reads another. |
| `workspace` | `OPTIMAL_ENGINE_SCOPE=workspace` and `OPTIMAL_ENGINE_WORKSPACE=<id>` | Serves only that workspace; every other workspace is answered as not found. |

`GET /api/scope` reports the scope.
On disk, each workspace has its own directory: the default tenant keeps `<root>/<slug>`, and every other tenant gets `<root>/tenants/<tenant>/<slug>`, so two tenants' workspaces with the same slug never share files.

## Share-up policy

Each workspace has a share-up policy for org-wide views: `read` shares its results upward, `none` keeps them inside.
The default is `read`, except workspaces whose `visibility` is `private` or `client`, which default to `none`.
`PUT /api/workspaces/:id/share {"share_up": "read|none", "visibility": "private|client|internal"}` changes it (scope `topology:write`) and records the change in the authority evidence chain.
An org section set to `none` also keeps its policy from flowing down to the other workspaces (`chat-memory.md`).

## Federated search

`GET /api/federation/search?q=` searches every sharing workspace section the caller may see, plus registered peer workspace Engines that share upward.
Results carry `source_workspace_id` and `source_engine`; `sources` reports each section and peer, including peers that could not be reached.
Peers are registered with `POST /api/federation/peers {"workspace_id", "url", "api_key", "share_up"}` (admin); the key is encrypted with `CONNECTOR_KEY` and never returned.
Nothing is copied: a workspace Engine's data is only queried.

## Renaming a workspace

`PATCH /api/workspaces/:id {"slug": "<new slug>", "name": "<new name>"}` (`topology:write`) renames a workspace without moving it.
The id never changes, so every row, file, key, and `optimal://` link that names the id keeps working.
Every slug a workspace holds, the current one and those it had before a rename, is a row of `workspace_handles` (tenant, slug, workspace id), so a slug is claimed by a unique key in the same transaction that writes it.
No other workspace of the tenant can take a held slug (`409 slug_taken`), and a topology file written with one still names this workspace.
`GET /api/resolve?uri=optimal://<tenant>:<slug>/...` written with any slug the workspace holds or held answers `local` with the address by its id.
A request that names `<tenant>:<slug>` where a workspace id belongs, and that slug is not the id, answers `409 {"error": "not_a_workspace_id", "workspace_id": "<id>"}` to a key that covers the workspace (`403 workspace_scope_denied` to any other key), so nothing is written beside the real workspace.
A rename onto a slug whose id (`<tenant>:<slug>`) already holds rows, written there before any workspace had that id, is refused (`409 slug_has_data`), so a rename never adopts them.
That check reads the tables indexed by workspace, which hold the documents, chunks, memories, nodes, and wiki, each by one index lookup, so it stays short while it holds the Store's one writer.
A rename also keeps the slug it leaves for a workspace that had no handle row yet.
A slug is lowercase letters, digits, and dashes, at most 128 characters (`400 invalid_slug`, on create as on rename), and never one of the engine root's own directories (`nodes`, `assets`, `architectures`, `tenants`, `cache`; `409 slug_reserved`, on create too); the singleton `default` workspace keeps its slug.
Every rename is recorded in the authority evidence chain as `workspace.renamed`, in the same transaction as the rename, so one never commits without the other.
The entry names the principal that renamed it (`subject`), the grants it acted under (`detail.authority`: the key's scopes, or `["local"]` for an anonymous local caller), the action the Authority plug names for the route (`write`), and the slugs it went from and to.
An Engine that cannot sign evidence (no evidence key) still renames, and logs a warning.
Files a workspace writes (its wiki pages among them) live in its directory, which is keyed by its id, so a rename moves nothing on disk.
A link written with a slug of a workspace that has moved answers `moved`, as a link by its id does.

A bundle or topology document carries a renamed workspace's id, and an import keeps that id when it belongs to the importing tenant and is free there.
A bundle import drops the slugs the workspace held before a rename (`previous_slugs`) and creates the workspace with its current slug only.
The old slugs are therefore held and resolved only on the Engine the workspace came from.
On the importing Engine a link written with one does not resolve, and any other workspace there may take the slug.
A topology document lists a renamed workspace as `{"slug": "<slug>", "id": "<id>"}` where an unrenamed one is just its slug.
An Engine from before workspaces could be renamed rejects a document with that entry (`invalid_document`, `invalid workspace entry`); a document that Engine exported imports here unchanged.
A topology import also refuses, before it writes anything, a document that names a workspace slug the Engine cannot create (invalid or reserved), and it stops at the first workspace that cannot be created and names it.

## Moving a workspace (split, merge, seed)

A bundle is a gzip tar file with `manifest.json`, one JSON-lines file per table, and the workspace's files.
It carries every row of every table with a `workspace_id` column, child rows without one, the principals the workspace's memberships name, and workspace-scoped operating documents.
Embeddings and other binary columns travel as base64, so vectors are copied, not recomputed; full-text indexes fill through the Engine's triggers as rows are inserted.
Authority state (keys, packs, grants, evidence), replica cursors, metric samples, redirects, and federation peers stay with the Engine.
Connectors (their credentials are sealed with the source Engine's `CONNECTOR_KEY`), their run log, queued jobs, and processor runs stay too: register the connectors again on the target.

| Step | Route (admin) |
| --- | --- |
| Export, optionally reserving a move | `POST /api/workspaces/:id/bundle {"for_move": true}` returns the bundle name, `bundle_sha256`, and `ledger_sequence` (the mark a seeded replica pulls from) |
| Download | `GET /api/bundles/:name` |
| Import on the target | `POST /api/bundles/import {"bundle": "<name>", "mode": "create|merge", "workspace_id"?, "organization_id"?}`, or the raw file with `content-type: application/gzip` |
| Finalize on the source | `POST /api/workspaces/:id/finalize-move {"bundle_sha256", "target_url", "target_workspace_id"}` |
| Resolve a citation | `GET /api/resolve?uri=optimal://<workspace>/...` returns `local` or `moved` with the new location |

Import verifies the manifest, every table file, and every file checksum before writing anything.
Rows are then written in short transactions of 1,000 rows, tables in foreign-key order and the rows of a self-referencing table (memories, nodes) parents first, with foreign keys checked at each commit.
A large workspace therefore never holds the Engine's single writer long enough to stall other requests or time out.
A failed `create` removes every row it wrote and the workspace record, so it can simply be retried; a failed `merge` can be run again, because it only adds missing rows.
Registry rows every Engine derives under the same id (principals, model call operations) are kept when the target already has them.
Tenant and workspace ids are rewritten to the target; integer row ids are reassigned.
`create` refuses an existing workspace; `merge` keeps existing rows.
The source deletes nothing until `finalize-move` receives the same `bundle_sha256` the target reported, then removes the workspace's rows and files, archives the workspace, and records a redirect so `optimal://` citations keep resolving.

Split moves a workspace out of an org Engine; merge is the same steps in the other direction; seeding a new Engine is an import of a bundle.
