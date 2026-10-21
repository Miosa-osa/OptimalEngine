# Scope, sharing, and moving workspaces

## Engine scope

An Engine runs in one of two scopes.

| Scope | Set with | Behavior |
| --- | --- | --- |
| `org` (default) | `OPTIMAL_ENGINE_SCOPE=org` | One Engine for an organization; every workspace is a walled section. A key scoped to one workspace never reads another. |
| `workspace` | `OPTIMAL_ENGINE_SCOPE=workspace` and `OPTIMAL_ENGINE_WORKSPACE=<id>` | Serves only that workspace; every other workspace is answered as not found. |

`GET /api/scope` reports the scope.

A workspace id with no workspace row and no `<tenant>:` prefix (an ad hoc id) can be named by every tenant's keys, and the routes read each row in the caller's tenant.
The contexts and graph edges written under such an id carry tenant `default`, the tenant of a workspace with no row, so another tenant's writes there are not read back as its own: a tenant other than the default writes to registered workspaces (`<tenant>:<slug>` ids).
An unregistered `<tenant>:<slug>` id is accepted for its own tenant's keys, and the contexts and graph edges written under it take the tenant its prefix names, when that tenant exists.
On disk, each workspace has its own directory: the default tenant keeps `<root>/<slug>`, and every other tenant gets `<root>/tenants/<tenant>/<slug>`, so two tenants' workspaces with the same slug never share files.

## Graph edges

Graph edges live in `graph_edges`, unique within a tenant and a workspace: the same entity pair in two workspaces is two edges.
Each edge takes the tenant of its workspace, as a context does: for a workspace that is not registered, the tenant its `<tenant>:` prefix names, else `default`.
Every graph read (`/api/graph`, `/api/graph/hubs`, `/api/graph/triangles`, `/api/graph/clusters`, `/api/graph/reflect`, `/api/node/:id`, `/api/optimal/graph`, the search graph boost, graph candidates, health and simulation) reads one workspace in one tenant, the requester's tenant for API routes, so a workspace of another tenant reads as empty.
The contexts and entities those routes show, and `/api/batch/export/signals` and `/api/batch/export/memories`, are filtered by the requester's tenant the same way.
A search in one tenant ranks the same whether or not another tenant has edges between the same names.

The baseline `edges` table was keyed by endpoints and relation only, so a pair two workspaces shared kept only the first workspace's edge, and its `tenant_id` was never written.
The migration that created `graph_edges` copied it there with each workspace's tenant and left it in the store, unread and unwritten, for one release, so an older Engine still boots on a migrated store.
After upgrading, run one graph backfill over every workspace to recreate the edges the old key dropped (see [Graph edges upgrade](versioning-and-releases.md#graph-edges-upgrade)); `GET /api/maintenance/graph` reports `graph_edges.backfill_needed` until it has run.
The same migration gives the contexts and entities written with tenant `default` under another tenant's workspace (before writes took their workspace's tenant) that workspace's tenant.
A bundle written before that migration carries its edges as `edges`, and a replicated change sealed before it names `edges`: both are written to `graph_edges`.

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

## Graph reads

Two tenants can share a bare workspace id (one nobody registered), so the graph routes are bound to the caller's tenant.
`GET /api/graph`, the node routes and the optimal graph routes show the tenant's contexts only.
The graph analyses (`GET /api/graph/hubs`, `/triangles`, `/clusters` and `/reflect`) read the edge table, which has no tenant of its own, so they answer only for a workspace registered to the caller's tenant: a workspace of another tenant, one that does not exist and an id nobody registered all answer `404 workspace not found`.
`/api/graph/triangles` returns at most 100 triangles per request, whatever its `limit`.

## Repairing a workspace id

A rename keeps the id. An operator can also make the id match the slug, or attach rows written to an unregistered id, with `POST /api/data-steward/workspaces/rename {source_workspace_id, target_workspace_id}` and `POST /api/data-steward/workspaces/repair {source_workspace_id, target_workspace_id}` (`topology:write`).
Both move every row of the caller's tenant that names the workspace to the new id in one transaction, and the answer lists the tables (`tables`, `updated_records` for a repair, `handles_moved` for a rename).
A rename also moves the slugs the workspace holds, and a repair moves rows only (the target must already be a registered workspace).
A rename is refused (`target_workspace_has_rows`, nothing moves) when the new id already holds rows in any workspace table: that is other data written under the id, and a rename is the same workspace under a new id. Merge those rows into the workspace first with `workspaces/repair`, which records the move as a merge, then rename.

Both act inside the caller's tenant.
The route authorizes `source_workspace_id` and `target_workspace_id` like any workspace a request names, so a key restricted to some workspaces must hold both, and a workspace of another tenant answers `404` as if it were absent.
The source of a rename must be a workspace of the tenant.
The target of a repair must be an active workspace of the tenant, and its source must not be registered: a workspace of another tenant, in any state, or an active workspace of this tenant, is refused (`source_workspace_is_registered`); an archived workspace of this tenant can still be repaired from.
Every move is bound to the tenant (`AND tenant_id = ?`), so rows another tenant wrote under an id both use stay where they are.
A table with no tenant column (the entity resolution tables, for example) is moved wholesale by a rename, whose source is registered to one tenant.
A repair, whose source belongs to nobody, traces each row of such a table to a tenant through the rows it points at, and moves it when they are the caller's and in the workspace being repaired: aliases, identifiers and lineage through their canonical entity, a resolution decision through its mention, reconstruction paths and outcomes through their run, a consolidation proposal through the runs behind its paths.
A mention has a tenant column of its own (`entity_mentions.tenant_id`, the tenant that wrote it) and is moved by it.
One written before the column that the migration could not fill (it names no context or source package that exists) records no tenant, and is traced through its context or source package like the tables above.
The tables move first, before the rows they point at, so a row is traced from where its parent still is: a decision before its mention, and a mention before its context.
A row that cannot be traced stays under the old id. So do the tables nothing can be traced from, `memory_path_feedback` and `sync_capture` (a captured change names the old id inside the change itself, and the rows that moved are captured again under the new one): they are listed in `unscoped_tables` with the rows they hold, once the repair has moved something of the caller's.
Rows hanging off the caller's rows do not make a repair: it needs at least one row of a table with a `tenant_id` column to move, or it answers `nothing_to_repair`.
A mention is written with its context and source package: `POST /api/entity-mentions` refuses (`context_not_found`, `source_package_not_found`) one that names a context or package that is not the key's tenant's, in the mention's workspace, and a decision is made only by the tenant the mention belongs to (`mention_not_found` otherwise), so another tenant cannot plant a row that a repair would take.
A mention records the tenant of the key that wrote it, so one that names neither a context nor a source package is still its writer's alone.
Every check (the target, the source, the id a rename gives up and takes) and the move run in one transaction, and a check that cannot be answered stops the repair.
The entity reads and decisions follow the same rule, so two tenants that share a bare workspace id do not see each other's identities: the review queue (`GET /api/entities/review`) and the dashboard's entity clusters list the tenant's mentions only (a mention is its writer's by the tenant it records; one written before that column and not filled by its migration, with neither a context nor a source package or with parents that are gone, belongs to the workspace and is listed to every tenant that shares it), a new mention is matched with the tenant's entities only, and an entity read by id, its history and its projection answer `404`/empty for another tenant's.
A mention is linked (`entity_id`) or an entity merged (`winner_entity_id`) only into an entity of the same tenant and workspace (`entity_not_found`).
The entity quality report (`GET /api/entities/quality`) and the dashboard count the tenant's entities, mentions and lineage only.
A rename is refused when another tenant has rows under the source id (`workspace_id_shared`), because it could not take them along: rows of a table with a different `tenant_id`, or rows of a table with no tenant column that hang off another tenant's rows.
To clear it, find the rows (`SELECT COUNT(*) FROM <table> WHERE workspace_id = '<id>' AND tenant_id <> '<tenant>'` for each table with a `tenant_id` column) and, if they are the tenant's rows with a stray `tenant_id`, correct them (`UPDATE <table> SET tenant_id = '<tenant>' WHERE workspace_id = '<id>' AND tenant_id = '<stray>'`), or if they belong to the other tenant, move them to that tenant's workspace (`UPDATE <table> SET workspace_id = '<their workspace>' WHERE workspace_id = '<id>' AND tenant_id = '<stray>'`). Then rename again.
A repair with nothing of the caller's to move answers `nothing_to_repair`, and says nothing about what other tenants hold under the id.

Signed evidence is not rewritten, because each entry is hashed and signed over the workspace id it names.
`authority_evidence` is left alone, and the repair is appended to it as a signed `workspace.rekeyed` entry (from, to, who, mode) in the same transaction, which the answer reports as `rekey_recorded: true`.
The mode is `rename` for `workspaces/rename` (the same workspace under a new id) and `merge` for `workspaces/repair` (rows of an unregistered id moved into a workspace that already existed).
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

## Repairing node types and the hierarchy

`POST /api/data-steward/nodes/repair-types` gives the active nodes of the caller's tenant the node type their kind names (`org` and `unit` stand for `entity` and `department`), where a node has none or one that is not an active type of its own workspace.
It answers `{"updated_nodes": n}`.

`POST /api/data-steward/hierarchy/repair-deterministic` moves workspaces to another organization and gives nodes another kind, as a mapping the caller supplies in the request.
The Engine knows no names, so there is nothing to run without a mapping (`422 mapping_required`):

```json
{
  "mapping": {
    "organizations": [
      {
        "organization_id": "acme:ventures",
        "from_organization_id": "acme:default",
        "name_contains": "Alpha",
        "description_contains": "Alpha"
      }
    ],
    "node_kinds": [
      {
        "workspace_id": "acme:main",
        "from_kind": "workspace",
        "kinds": {"tasks": "operation", "projects": "project"}
      }
    ]
  }
}
```

An organization rule moves the tenant's active workspaces that are in `from_organization_id` (the tenant's default organization when it is left out) and whose name or description contains the text, compared without regard to case (ASCII letters) and as text, not as a pattern.
It needs `name_contains` or `description_contains`, so a rule never matches every workspace.
A node rule retypes the active nodes of the workspace that have the slug and are of `from_kind` (`workspace` when it is left out): the node takes the kind, and the workspace's active node type of that name.
A node whose workspace has no such type is left as it was.
A mapping has at most 50 rules of each kind and retypes at most 500 node slugs.
The answer counts `workspace_owners_updated` and `nodes_retyped`.

Both repairs change the caller's tenant only.
The target organization and the workspaces a mapping names must be the tenant's (`organization_not_found`, `workspace_not_found`), so the rule that an organization belongs to the tenant of its workspaces holds after a repair as before it.
They act on the whole tenant and name no workspace, so they need a key that holds the whole tenant (`workspace_scope` `["*"]`); a key restricted to some workspaces answers `403 workspace_scope_denied`.
An organization id, a workspace id and a match text are at most 256 bytes.
A repair does not create the tenant's default organization: if a rule leaves out `from_organization_id` and the tenant has none, no workspace is in it and nothing moves.

## Moving a workspace (split, merge, seed)

A bundle is a gzip tar file with `manifest.json`, one JSON-lines file per table, and the workspace's files.
It carries every row of every table with a `workspace_id` column, child rows without one, the principals the workspace's memberships name, and workspace-scoped operating documents.
Embeddings and other binary columns travel as base64, so vectors are copied, not recomputed; full-text indexes fill through the Engine's triggers as rows are inserted.
Graph edges travel as `graph_edges`; the legacy `edges` table is not exported (see [Graph edges](#graph-edges)).
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
