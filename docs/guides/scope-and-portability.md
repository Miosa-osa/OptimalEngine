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
The slugs held before a rename are also mirrored in `metadata.previous_slugs`, so an Engine rolled back to an earlier release still finds them.
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

## External ids

A workspace can carry the id another system knows it by, so that system finds it whatever its slug or name becomes.
`POST /api/workspaces {"slug", "name", "external_id": "<id>"}` sets it at creation, and `PATCH /api/workspaces/:id {"external_id"}` (or `"external_id"` inside a metadata replacement) sets it once on a workspace that has none.
It is stored in the `workspaces.external_id` column, mirrored in `metadata.external_id` for one release, and returned as `external_id` by `GET /api/workspaces` and `GET /api/workspaces/:id`.
An external id is 1 to 255 printable ASCII bytes without spaces (`!` to `~`) and is compared exactly, so `ABC` and `abc` are different ids; anything else answers `400 invalid_external_id`, in a create, an update, or a lookup.
At most one active workspace of a tenant holds an external id (`409 external_id_taken`): the tenant is the scope a mirror reads and writes, and one outside id must name one live workspace there.
Once set on a workspace it never changes (`409 external_id_immutable`), because the system that holds it keys its own records on it.
To bind an outside workspace to a different Engine workspace, archive the old workspace, then create or bind another: an archived workspace keeps the value for history and releases it.
`GET /api/workspaces?external_id=<x>` lists every workspace of the tenant that carries the id, archived ones included unless `status` is given, each with its `status`, within what the caller's key covers; the active one is the binding (`Workspace.get_by_external_id/2` returns only that one).
Nothing un-archives a workspace; a route that ever does must check the binding again and answer `409 external_id_taken` when another active workspace holds the id.
A key with `topology:write` that is restricted to some workspaces can still learn from `409 external_id_taken` that an id is held in its tenant, the same way `409 slug_taken` tells it a slug is taken.
A rename keeps it, and so does a metadata replacement.
A workspace bundle carries it; an import into a tenant where an active workspace holds it creates the copy without it, keeps it as `metadata.imported_external_id`, and reports it as `imported_external_id` in the import summary.
Portable topology documents name workspaces by slug (and by id for a renamed one), so they do not carry it.

## Repairing a workspace id

A rename keeps the id. An operator can also make the id match the slug, or attach rows written to an unregistered id, with `POST /api/data-steward/workspaces/rename {source_workspace_id, target_workspace_id}` and `POST /api/data-steward/workspaces/repair {source_workspace_id, target_workspace_id}` (`topology:write`).
Both move every row that names the workspace to the new id in one transaction, and the answer lists the tables (`tables`, `updated_records` for a repair, `handles_moved` for a rename).
A rename also moves the slugs the workspace holds, and a repair moves rows only (the target must already be a registered workspace).
A rename is refused (`target_workspace_has_rows`, nothing moves) when the new id already holds rows in any workspace table: that is other data written under the id, and a rename is the same workspace under a new id. Merge those rows into the workspace first with `workspaces/repair`, which records the move as a merge, then rename.

Signed evidence is not rewritten, because each entry is hashed and signed over the workspace id it names.
`authority_evidence` is left alone, and the repair is appended to it as a signed `workspace.rekeyed` entry (from, to, who, mode) in the same transaction, which the answer reports as `rekey_recorded: true`.
The mode is `rename` for `workspaces/rename` (the same workspace under a new id) and `merge` for `workspaces/repair` (rows of an unregistered id moved into a workspace that already existed).
A repair that moves no rows records nothing (`false`).
An agent action chain recorded under the old id still verifies, and is found under the new id, because a step is checked against the id inside its signed entry followed through the re-keys recorded after it, whatever the mode.
A re-key counts only when it is a signed entry of the tenant's chain, from a key that is not revoked, with a link to the entry before it; a row written into the table by hand explains nothing.
Deleting a re-key does not make anything verify: the steps it explained stop verifying, and the gap shows in `Evidence.verify/1` and the integrity scan.

Grants issued before the repair follow a rename, and only a rename.
A grant is for the workspace under its new id: it admits there, and no longer under the old id, which may name a different workspace by now.
A merge is not followed, because a grant for an unregistered id was never issued for the workspace that already existed, with its own data and policies.
Nor does the grant keep admitting under the unregistered id once a merge moved its rows away: that id may name nothing now, or an unrelated workspace that took it, so a grant for a merged-away id admits nowhere (`wrong_workspace` under either id) and is issued again for the workspace it is meant for.
A grant from an outside issuer is taken as written, and a grant issued after a repair is not changed by it.
Local denies follow both modes, as they are written and as they read after the repairs recorded since they were added: a deny for the old id applies to the new id, and after a merge to the workspace the rows were merged into, so a repair never leaves one matching nothing.
Following can only add denials, so a deny follows a repair on record without checking its signature: a forged repair record cannot lift a deny, it can only make one apply to more, and whoever can write rows into the evidence table could write denies into theirs directly.
Where a deny was added is the first `local_deny.added` entry for it; a later record of the same deny cannot move that position forward.
The deny and its entry are written in one transaction, so a repair cannot fall between them.

An Engine that cannot sign evidence (the key that wraps the evidence key is missing) refuses a repair of a workspace that has agent action steps (`{"error": ":evidence_key_unavailable"}`, 422) and moves nothing, because the steps could never be verified again.
A workspace with no steps is repaired with a warning in the log, and `rekey_recorded` is `false`.
A repair made by a release before this check left no record, so its steps show as unverified.

A repair does not rewrite what names the id inside hashed content.
Workspace policy packs (`authority_policies.scope_id` and the resource patterns in their signed documents) and API keys (`api_keys.workspace_scope`, fingerprinted when minted) are published and minted again for the new id, which leaves evidence, rather than edited in place, which the integrity scan would report.
Open loops move, but their de-duplication key is built from the id, so a loop detected again is not matched with the one that moved.

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

A bundle does not follow the data-class gate of replication (`replication.md`).
It is a whole-workspace move for an admin: it carries every row and file, including those labelled `restricted`, because a move that left them behind would lose them when `finalize-move` deletes the source.
Seeding a replica that is cleared for less than the workspace holds from a bundle therefore copies that data across.
Seed such a replica only from a workspace whose data class it is cleared for.
