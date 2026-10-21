# App Data API

The app data API lets an app use Optimal Engine as its database.
An app defines collections in a workspace, then creates, updates, deletes, upserts and queries records, runs multi-write transactions, attaches files, follows a durable change feed, and ships versioned schema migrations with its code.
App collections live beside the workspace's knowledge.
Knowledge APIs (memory, search, graph, RAG, wiki) are unchanged.

Routes are under `/api/data` (`OptimalEngine.API.AppDataRouter`).
The Elixir entry point is `OptimalEngine.AppData`.
Typed clients: `engine.data(workspace)` in `sdks/typescript`, `client.data` in `sdks/python`.
`sdks/typescript/examples/todo-app.ts` is a complete reference app.

## Model

| Concept | Meaning |
| --- | --- |
| Workspace | Every collection belongs to one workspace of one tenant. Collections are isolated per workspace and per tenant. |
| Collection | A named schema (`^[a-z][a-z0-9_]{0,62}$`): typed fields, indexes, an optional owner field, optional search fields. |
| Record | One row: an `id`, a `version`, timestamps, actors, and `data` holding the declared fields. |
| Change | One committed create, update, delete, or schema change, with a durable sequence number. |
| Data key | An API key limited to one workspace's app data, optionally bound to one owner (an end user). |

A record as the API returns it:

```json
{
  "id": "5f0c9e1a2b3c4d5e6f7a8b9c",
  "version": 3,
  "created_at": "2026-11-01T09:00:00.000Z",
  "updated_at": "2026-11-02T10:30:00.000Z",
  "created_by": "api_key:k1",
  "updated_by": "api_key:k1",
  "data": {"title": "write the report", "done": false, "due": "2026-11-05T17:00:00.000Z", "owner": "user-a"}
}
```

Record ids are client supplied (`^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$`) or generated.
Field names `id`, `version`, `created_at`, `updated_at`, `created_by`, `updated_by`, `and`, `or`, and `not` are reserved.
`id`, `version`, `created_at`, `updated_at`, `created_by` and `updated_by` are system fields: they can be filtered and sorted, never written.

### Field types

| Type | Stored as | JSON value | Notes |
| --- | --- | --- | --- |
| `string` | TEXT | string | `max_length` default 4,096; optional `enum` |
| `text` | TEXT | string | `max_length` default 1,000,000; not indexable |
| `integer` | INTEGER | 64-bit integer | |
| `float` | REAL | number | |
| `boolean` | INTEGER 0/1 | true or false | |
| `datetime` | TEXT | ISO 8601 string | normalized to UTC with milliseconds (`2026-11-01T09:00:00.000Z`), so string order is time order; a date means midnight UTC; default `"now"` allowed |
| `json` | TEXT | any JSON | filterable with `contains` (array membership) and `is_null` only |
| `reference` | TEXT, foreign key | record id | `references` names a collection in the same workspace (itself allowed); `on_delete` is `restrict` (default), `set_null`, or `cascade` |

Field options: `required`, `unique`, `index`, `default`, `max_length`, `enum`, `references`, `on_delete`.
A required field is checked after defaults and owner assignment.
Defaults apply when a create omits the field.

### Collection definition

```json
{
  "name": "tasks",
  "fields": [
    {"name": "title", "type": "string", "required": true, "max_length": 200},
    {"name": "done", "type": "boolean", "default": false},
    {"name": "due", "type": "datetime"},
    {"name": "owner", "type": "string"},
    {"name": "project", "type": "reference", "references": "projects", "on_delete": "cascade"}
  ],
  "indexes": [{"fields": ["owner", "done", "due"]}, {"fields": ["title"], "unique": true, "name": "by_title"}],
  "owner_field": "owner",
  "search": {"text": ["title"], "semantic": ["title"]}
}
```

`fields` may also be an object of name to definition.
Unique fields, indexed fields, reference fields and the owner field get indexes automatically.
Limits: 200 fields, 32 indexes of up to 8 fields, 16 search fields, 1,000 collections per workspace.

## Storage model

Each collection is one STRICT SQLite table in the Engine's store, named `appdata_<id>` with an Engine-generated id.
The table has system columns (`_rowid INTEGER PRIMARY KEY`, `id TEXT UNIQUE`, `_version`, `_created_at`, `_updated_at`, `_created_by`, `_updated_by`) and one `f_<field>` column per declared field.
Declared indexes are SQLite indexes on that table, created inside the transaction that declares them.
Full-text search fields are an FTS5 external-content table over the collection (`unicode61`, diacritics removed), kept in sync by insert, update and delete triggers.
Reference fields are SQLite foreign keys to the referenced collection's `id`.
A registry row in `data_collections` holds the schema; the change feed, the app migration ledger, record files, and embeddings have their own tables (migration 66).

Why one table per collection rather than one generic table of JSON documents with expression indexes:

- Typed columns let SQLite check types (STRICT) and let the planner use ordinary B-tree indexes with bound parameters.
  Partial expression indexes on a shared JSON table are only usable when the query repeats the exact expression and the collection literal, which pushes collection ids into SQL text.
- Uniqueness and references are database constraints, not application checks that a bug could skip.
- Each collection's FTS5 index covers only its own rows, so a search never scans other collections' matches.
- Dropping a collection drops its table instead of deleting rows from a shared table.

The cost is runtime DDL.
It is made safe by construction: every identifier in generated SQL is either Engine generated (table names) or a validated name (`^[a-z][a-z0-9_]{0,62}$`) behind a fixed prefix and double quotes.
No request value is ever interpolated into SQL; every value is a bound parameter.
Field names, operators, and sort keys are checked against the schema before they become SQL.

## Security

The API follows the Engine's security model.

- The caller authenticates with an API key (`Authorization: Bearer oe_...`); the tenant is the key's tenant.
- Every request names its workspace with `workspace` in the query string or JSON body.
  `WorkspaceAuthPlug` enforces tenant ownership (404 for another tenant's workspace) and the key's workspace scope (403 `workspace_scope_denied`).
  A request without a workspace is refused with 400 `workspace_required`; naming two different workspaces is 400 `workspace_mismatch`.
- The acting principal comes from the key (`OptimalEngine.API.Actor`).
  A body naming a different `actor_id` is refused with 403 `actor_identity_mismatch`.
- Without authentication required (trusted local development), callers act as the local operator and are admins.

### Operation scopes

| Routes | Scope |
| --- | --- |
| every `GET`, `POST /collections/:name/query` | `read` |
| record writes, bulk, upsert, transactions, files, `POST /collections/:name/embeddings/rebuild` | `write` |
| `POST /collections`, `PATCH /collections/:name`, `DELETE /collections/:name`, `POST /migrations`, every `/keys` route | `data:admin` |

`*` covers every scope.
Schema changes use their own `data:admin` scope rather than `topology:write`, because an app's tables are not workspace topology and an app server should not need topology rights to deploy its schema.
With Optimal Authority enabled, data queries are classified as `search`, schema and key routes as `admin`, record deletes as `erase`, and other writes as `write`.

### Owner field and row filters

A collection with an `owner_field` has per-row owners.

| Caller | Reads, updates, deletes | Creates | Setting the owner to someone else |
| --- | --- | --- | --- |
| Owner-bound data key | only rows it owns; other rows are 404 | owned by the key's owner | refused, 403 `owner_mismatch` |
| Key without an owner, without `data:admin` | every row | owned by the key's principal when omitted | refused, 403 `owner_mismatch` |
| Key with `data:admin` or `*` (the app's server) | every row | owned by the key's principal when omitted | allowed |
| Trusted local caller | every row | owned by the local operator when omitted | allowed |

The owner is never taken on trust from a keyed caller's request body.
Owner filters also apply to full-text and semantic search, counts, includes, filters through references, references written by the caller (an owner-bound caller cannot reference a row it cannot read), cascades (an owner-bound delete may not cascade into rows of other owners), files, and the change feed.

### Data keys

An app's server mints a data key for an end user or a component:

```http
POST /api/data/keys
{"workspace": "default:todo", "name": "user-a session", "owner": "user-a",
 "collections": ["tasks"], "operations": ["read", "create", "update"], "expires_in": 3600}
```

The response holds the key once: `{"id", "key", "expires_at", "data_access"}`.
A data key is an ordinary Engine API key whose metadata carries `data_access`:

- its workspace scope is exactly that workspace;
- its scopes are `read`, plus `write` when it may create, update or delete; it never holds `data:admin`;
- it is confined to `/api/data` (every other Engine route returns 403 `data_key_confined`);
- `collections` (default all) and `operations` (default `read`) limit it further (403 `collection_not_allowed`, `operation_not_allowed`);
- with an `owner`, it is owner-bound as above.

Delegation only narrows: a minter cannot grant scopes, a workspace, or a lifetime beyond its own (403 `scope_exceeds_minter`, `workspace_scope_exceeds_minter`, `expiry_exceeds_minter`).
`expires_in` defaults to 3,600 seconds, at most 30 days.
`GET /api/data/keys` lists the workspace's data keys without secrets; `DELETE /api/data/keys/:id` revokes one immediately.
Minting is recorded as Authority evidence (`key.minted`).
General `/api/auth/keys` minting cannot set `data_access`.

## Routes

All paths are under `/api/data`.
Bodies are JSON; record fields are always nested under `data`, so they never collide with control fields such as `workspace`.

### Collections

| Method and path | Body or query | Success |
| --- | --- | --- |
| `GET /collections` | `workspace` | 200 `{"collections": [...]}` (only collections the caller may read) |
| `POST /collections` | a collection definition | 201 collection |
| `GET /collections/:name` | `workspace` | 200 collection with `record_count` |
| `PATCH /collections/:name` | `{"operations": [...]}` | 200 collection (new `schema_version`) |
| `DELETE /collections/:name` | `confirm=<name>` | 200 `{"dropped": name}` |

Alter operations run together in one transaction; any failure leaves the collection unchanged and reports `operation_index`:

| Operation | Effect |
| --- | --- |
| `{"op": "add_field", "field": {...}}` | Adds a column. A required field needs a `default` when the collection has records; the default backfills existing rows. |
| `{"op": "drop_field", "name": f, "confirm": true}` | Destructive. Drops the column, its single-field indexes, and its search entries. Refused for the owner field, reference fields, and fields in composite indexes. |
| `{"op": "set_default", "name": f, "default": v}` | `null` clears the default. Defaults are applied by the Engine, so no rebuild is needed. |
| `{"op": "set_required", "name": f, "required": bool}` | Refused while rows have no value. |
| `{"op": "add_index", "fields": [...], "unique": bool, "name": n}` | Creates the index now. A unique index over duplicate values is refused (409 `unique_index_duplicates`). |
| `{"op": "drop_index", "name": n}` | Owner-field and reference indexes cannot be dropped. |
| `{"op": "set_search", "text": [...], "semantic": [...]}` | Rebuilds the FTS5 index; changing semantic fields clears stored embeddings. |
| `{"op": "set_owner_field", "name": f}` | Setting needs no confirmation; clearing (`null`) needs `"confirm": true`. |

Changing a field's type, renaming, and dropping reference fields are not supported; add a new field or collection and migrate the data.
Dropping a collection needs `confirm` equal to its name and is refused while another collection references it (409 `collection_referenced`).
Its files' asset bytes stay in the asset store as preserved evidence.

### Records

| Method and path | Body or query | Success |
| --- | --- | --- |
| `POST /collections/:name/records` | `{"data": {...}, "id"?}` | 201 record |
| `POST /collections/:name/records/bulk` | `{"records": [{"data": {...}, "id"?} or {...}]}` | 201 `{"count", "records": [{id, version}], "txn_id", "last_seq"}`; all or nothing, up to 5,000 |
| `POST /collections/:name/upsert` | `{"key": field, [fields], or "id", "data": {...}, "id"?, "version"?}` | 201 when created, 200 when updated (`op` says which) |
| `GET /collections/:name/records/:id` | `fields`, `include` (comma separated) | 200 record, `ETag: "<version>"` |
| `PATCH /collections/:name/records/:id` | `{"data": {...}, "version"?}` or `If-Match: "<version>"` | 200 record with the next version |
| `DELETE /collections/:name/records/:id` | `version` or `If-Match` | 200 `{"id", "version", "deleted": true}` |
| `GET /collections/:name/records` | `where` (JSON), `sort`, `fields`, `include` (comma separated), `limit`, `cursor`, `count`, `search`, `semantic` | 200 page |
| `POST /collections/:name/query` | a query (below) | 200 page |
| `POST /collections/:name/embeddings/rebuild` | | 200 counts |

Updates are partial: only the named fields change.
Optimistic concurrency: every write increments `version`.
An update or delete that names a version (body, `?version=`, or `If-Match`) is rejected with 409 `version_conflict` and `current_version` when the record has moved on; without a version the write is unconditional.
Upsert keys must be `id` or the fields of a unique index.

### Queries

```json
{
  "where": {"owner": "user-a", "done": false, "due": {"lt": "2026-12-01"}, "project.status": "active"},
  "sort": ["due", "-created_at"],
  "limit": 50,
  "cursor": "eyJoIjoi...",
  "fields": ["title", "due"],
  "count": true,
  "include": ["project"]
}
```

- `where` maps a field to a value (equality; `null` means is null) or to operators: `eq`, `ne` (null safe), `gt`, `gte`, `lt`, `lte`, `in`, `nin` (up to 1,000 values), `contains` (substring for `string` and `text`; array membership for `json`), `is_null`.
- `and` and `or` take lists, `not` takes an object; nesting is limited to 8 levels and 200 conditions.
- A dotted path (`project.status`) filters through a reference field: the referenced row must exist, be visible to the caller, and match.
- `sort` takes up to 4 keys; `-field` or `{"field": f, "dir": "desc"}` sorts descending.
  SQLite order applies: nulls first ascending, last descending.
  `json` fields cannot be sorted.
- Pages are keyset pages ordered by the sort keys and then the row: `next_cursor` encodes the last row's sort values, so pages stay correct while other rows are written.
  A cursor is bound to the collection, sort, filter and search it was issued for (422 otherwise).
- `limit` defaults to 50, at most 1,000; `limit: 0` with `count: true` only counts.
- `fields` selects data fields; system fields are always returned.
- `include` attaches referenced records under `included` (up to 8 reference fields), filtered by the caller's visibility.

The response is `{"records": [...], "next_cursor": string or null, "has_more": bool, "count"?: n}`.

### Search

Full-text search over the collection's `search.text` fields:

```json
{"search": {"text": "quarterly report", "match": "all", "prefix": false}, "where": {"done": false}, "limit": 20}
```

Free text is split into terms and each term is quoted, so request text never reaches FTS5 query syntax.
`match: "any"` ORs the terms; `prefix: true` makes the last term a prefix.
Results are ranked by BM25 unless `sort` is given; each record carries `score` (higher is better).
FTS5 matches are computed once and joined to the collection by primary key, so extra filters do not make SQLite probe FTS5 per candidate row.

Semantic search over the `search.semantic` fields:

```json
{"semantic": {"text": "paying bills", "min_score": 0.3}, "where": {"owner": "user-a"}, "limit": 10}
```

Embeddings are a rebuildable projection (`data_embeddings`): one vector per record from its semantic field values, written after the record's transaction commits (asynchronously by default).
`POST /collections/:name/embeddings/rebuild` re-embeds every record now and removes stale vectors.
A query embeds its text with the same embedder and ranks the records matching `where` by cosine similarity, in process; `score` is the similarity.
When no embedder answers, the query returns 503 `semantic_unavailable` with the reason.
It never falls back silently to another kind of search.
`GET /api/data/capabilities` reports whether semantic search is available right now.
The default embedder is the Engine's text embedder, so `OPTIMAL_EMBED_URL` moves app data embeddings to a shared endpoint too (see [text embedding options](../../OPTIONS.md#text-embeddings)).

```elixir
config :optimal_engine, :app_data,
  embedder: OptimalEngine.Embed.Text,     # any module with embed(text, opts)
  embed_model: "nomic-embed-text",
  semantic_indexing: :async               # :async | :sync | :off
```

### Transactions

```http
POST /api/data/transactions
{"workspace": "default:todo", "operations": [
  {"op": "create", "collection": "projects", "id": "p-1", "data": {"name": "Launch"}},
  {"op": "create", "collection": "tasks", "data": {"title": "Plan", "project": "p-1"}},
  {"op": "update", "collection": "tasks", "id": "t-9", "data": {"done": true}, "version": 4},
  {"op": "delete", "collection": "tasks", "id": "t-3"},
  {"op": "upsert", "collection": "settings", "key": "key", "data": {"key": "theme", "value": "dark"}}
]}
```

Up to 5,000 operations across collections of the workspace run in one Store transaction: all commit or none do.
On success: 200 `{"committed": true, "results": [...], "txn_id", "last_seq"}`.
On failure: the failing operation's status with `operation_index` and `"committed": false`.
Later operations can reference records created earlier in the same transaction by their client-supplied ids.

### Files

| Method and path | Body or query | Success |
| --- | --- | --- |
| `POST /collections/:name/records/:id/files` | `{"filename", "content_base64", "content_type"?, "metadata"?}` | 201 file |
| `GET /collections/:name/records/:id/files` | `workspace` | 200 `{"files": [...]}` |
| `GET /collections/:name/records/:id/files/:file_id` | `Range: bytes=a-b`, `bytes=a-`, `bytes=-n` | 200 or 206 bytes; 416 when unsatisfiable |
| `DELETE /collections/:name/records/:id/files/:file_id` | `workspace` | 200 |

Bytes are preserved through the Engine's governed asset store: content addressed, recorded as an asset with a Source Package in the record's workspace.
The API accepts JSON only, so uploads are base64 in the body and one file is at most 5,900,000 bytes (its base64 fits the 8 MB JSON request limit); a record holds at most 100 files.
Downloads are `Content-Disposition: attachment` with `X-Content-Type-Options: nosniff` and honor one byte range per request.
Uploading or removing a file does not change the record's version.
Deleting a record removes its file links; the asset bytes stay as preserved evidence.

### Change feed

Every committed record change and schema change appends one row to `data_changes` in the same transaction, so the feed never shows a rolled-back change and never misses a committed one.
`seq` is a strictly increasing integer (SQLite `AUTOINCREMENT`, never reused).
Changes of one transaction share a `txn_id`.

| Method and path | Query | Success |
| --- | --- | --- |
| `GET /changes` | `since` (sequence or `latest`, default 0), `collection`, `limit` (default 100, max 1,000) | 200 `{"changes", "next_since", "latest_seq"}` |
| `GET /changes/stream` | `since` (default `latest`) or `Last-Event-ID`, `collection`, `idle_timeout` seconds | `text/event-stream` |

A change is `{"seq", "collection", "record_id", "op", "version", "owner", "actor", "data", "txn_id", "at"}` where `op` is `create`, `update`, `delete`, `schema` or `drop` and `data` is the record after the change (null for deletes).
A consumer stores the last `seq` it processed and resumes with `since=<seq>` or the SSE `Last-Event-ID` header.
The stream sends `id: <seq>` for every change, is woken by commits, polls every 15 seconds as a safety net, and sends keepalive comments; with `idle_timeout` it closes after that many quiet seconds.
Owner-bound callers see changes of rows they own, rows of collections without an owner field, and schema events; collection-limited keys see only their collections.
The feed is append-only and kept indefinitely; there is no retention pruning yet.
Schema backfills (`add_field` with a default) do not emit per-record changes; the `schema` change records the alteration.
Webhook delivery of data changes is not implemented; consumers poll or stream.

### Migrations

An app sends its full, ordered migration list on every deploy:

```http
POST /api/data/migrations
{"workspace": "default:todo", "app": "todo", "migrations": [
  {"version": 1, "name": "tasks", "operations": [{"op": "create_collection", "collection": {...}}]},
  {"version": 2, "name": "priority", "operations": [
    {"op": "alter_collection", "name": "tasks", "operations": [{"op": "add_field", "field": {"name": "priority", "type": "integer", "default": 3}}]}]}
]}
```

Operations: `create_collection` (`collection`: a definition), `alter_collection` (`name`, `operations`: alter operations), `drop_collection` (`name`, `confirm`: the name).
Each pending version runs in its own transaction together with its ledger row (`data_schema_migrations`), so it applies exactly once, including across crashes and concurrent deploys.
The response is `{"applied": [...], "skipped": [...]}`.
An applied version whose operations changed is refused (409 `migration_checksum_mismatch`; the checksum is SHA-256 of the canonical operations, so renaming a migration is fine).
A new version lower than one already applied is refused (409 `migration_out_of_order`).
Applying stops at the first failing version, which rolls back alone: the error names `failed_version` and the versions `applied` before it.
`GET /migrations?app=<app>` lists applied versions.

### Errors

| Status | `error` | Meaning |
| --- | --- | --- |
| 400 | `workspace_required`, `workspace_mismatch` | Name exactly one workspace. |
| 400, 413, 415 | `invalid_json`, `request_too_large`, `unsupported_media_type` | The body is not valid JSON, is over the request size limit, or has a content type the Engine does not parse; every Engine route answers these the same way. |
| 400 | `invalid_parameter` | An integer parameter (`limit`, `offset`, `since`, `version`, `idle_timeout` and the like) is outside the signed 64-bit range; every Engine route answers it the same way. |
| 401 | `missing_api_key`, `invalid_api_key`, `api_key_revoked`, `api_key_expired` | Authentication. |
| 403 | `permission_scope_denied`, `workspace_scope_denied`, `data_key_confined`, `collection_not_allowed`, `operation_not_allowed`, `owner_mismatch`, `owner_scope_cascade`, `data_admin_required` | Authorization. |
| 404 | `collection_not_found`, `record_not_found`, `file_not_found`, `index_not_found`, `field_not_found`, `key_not_found` | Absent, or not visible to the caller. |
| 409 | `version_conflict`, `record_exists`, `unique_violation` (`fields`), `reference_restrict`, `collection_exists`, `collection_referenced`, `field_exists`, `unique_index_duplicates`, `migration_checksum_mismatch`, `migration_out_of_order` | Conflicts. |
| 422 | `validation_failed` (`details`: messages) | Invalid definitions, data, filters, cursors, or references to missing records. |
| 503 | `semantic_unavailable` (`reason`) | No embedding provider answered. |

Batch errors add `operation_index` and `"committed": false`.

## Example

```bash
B=http://127.0.0.1:4200; K="Authorization: Bearer $OPTIMAL_API_KEY"; W=default:todo
curl -s -X POST $B/api/data/collections -H "$K" -H 'content-type: application/json' -d '{
  "workspace": "'$W'", "name": "tasks", "owner_field": "owner",
  "fields": [{"name": "title", "type": "string", "required": true},
             {"name": "done", "type": "boolean", "default": false},
             {"name": "due", "type": "datetime"}, {"name": "owner", "type": "string"}],
  "indexes": [{"fields": ["owner", "done", "due"]}], "search": {"text": ["title"]}}'
curl -s -X POST $B/api/data/collections/tasks/records -H "$K" -H 'content-type: application/json' \
  -d '{"workspace": "'$W'", "data": {"title": "write the report", "due": "2026-11-05", "owner": "user-a"}}'
curl -s -X POST $B/api/data/collections/tasks/query -H "$K" -H 'content-type: application/json' \
  -d '{"workspace": "'$W'", "where": {"owner": "user-a", "done": false}, "sort": ["due"], "limit": 50}'
curl -s "$B/api/data/changes?workspace=$W&since=0" -H "$K"
```

## Limits and measured performance

The embedded store is SQLite behind one Store process: one connection, one writer, every statement serialized.
Reads and writes from all routes of the Engine share that connection.
This is the single-writer embedded limit; many concurrent writers need the Postgres provider path planned for managed deployments, which this API does not implement yet.

Measured with `benchmarks/scripts/app_data_bench.exs` (calls `OptimalEngine.AppData` in process, the same functions the routes call; excludes HTTP, JSON, and key verification), on one Apple M3 Ultra (28 cores, 96 GiB), macOS 26, SQLite 3.51.3 in WAL mode with `synchronous=NORMAL`, while the machine ran other workloads (load average 26 to 34).
The `tasks` collection had a title with FTS5, an owner field, a `(owner, done, due)` index, 100 owners, and grew to 102,000 records (94 MiB database and WAL).

| Writes | Result |
| --- | --- |
| Single creates, each its own transaction (first 2,000) | 3,504 writes/s; p50 0.23 ms, p95 0.48 ms, p99 1.75 ms |
| Bulk creates, 1,000 per transaction, growing to 100,000 | 5,333 records/s |
| Versioned updates (one transaction each) | p50 0.18 ms, p95 0.48 ms, p99 1.57 ms |
| 8 concurrent writers, 250 creates each | 2,480 writes/s aggregate (serialized; no gain over one writer) |
| Add an index online at 102,000 records | 64 ms (blocks other Store calls for that time) |

| Query at 102,000 records (500 runs each) | p50 | p95 | p99 |
| --- | --- | --- | --- |
| Open tasks for one owner, sorted by due, limit 50 | 0.49 ms | 0.90 ms | 1.26 ms |
| Next page by cursor | 0.43 ms | 0.84 ms | 1.02 ms |
| Same query with a count | 0.52 ms | 0.98 ms | 1.30 ms |
| Get by id | 0.05 ms | 0.15 ms | 0.21 ms |
| Full-text, one common term (about 13% of rows match), limit 20 | 11.71 ms | 13.64 ms | 14.56 ms |
| Full-text, two terms plus an owner filter, limit 20 | 3.13 ms | 4.63 ms | 6.30 ms |
| Filter on an unindexed field, limit 50 (table scan) | 12.66 ms | 16.49 ms | 25.66 ms |
| Change feed page of 100 | 0.80 ms | 1.37 ms | 1.77 ms |

What the numbers mean for an app:

- Indexed reads and single-record writes are sub-millisecond; give every hot filter an index.
- A full-text term matching a large share of rows costs milliseconds, because BM25 is computed for every match before the top results are chosen.
- Unindexed filters scan the table; their cost grows linearly with the collection.
- Semantic search scores every matching record's embedding in process (no approximate index): fine for thousands to tens of thousands of embedded records per query scope, slow beyond that.
- Bulk inserts and transactions amortize commit cost; prefer them for imports.
- Concurrency does not raise write throughput: writes are serialized.

Over HTTP a keyed request verifies its API key with bcrypt (cost 12 unless configured lower) the first time the Engine sees that key and secret.
On the same machine that verification is about 220 ms; before verified keys were cached it dominated every request: measured sequentially over keep-alive against a live Engine with 1,000 tasks, a get by id was p50 223.5 ms and p95 235.5 ms, the owner query p50 217.9 ms and p95 237.1 ms, and a create p50 221.5 ms and p95 238.4 ms.
`OptimalEngine.Auth.KeyCache` now remembers a verified key and secret for `:key_cache_ttl_seconds` (default 600), so later requests skip bcrypt.
Every request still reads the key row, so revocation, expiry and a rotated secret take effect at once.
Measured with curl against a temporary Engine, the first request with a key took 0.50 s and the next two 17 ms and 11 ms end to end.
The data path behind it is under a millisecond (above).
Use one data key per session rather than per request, so a session pays bcrypt once; bulk inserts and transactions still amortize commit cost.
Trusted local mode (no key) skips verification.

Hard limits: 5,000 operations per bulk insert or transaction; 1,000 records per page; 1,000 values per `in`; 4 sort keys; 8 includes; 5,900,000 bytes per file upload (JSON request limit); 8 levels of `where` nesting and 200 conditions; 100 files per record.

## Durability

Each write's transaction commits or rolls back as a whole: the record rows, their index and FTS5 entries, and their change-feed rows.
SQLite WAL recovery discards uncommitted frames after a crash, so a killed Engine restarts with no partial transaction visible.
With `synchronous=NORMAL` a power loss (not a process crash) can lose the most recent committed transactions; it cannot corrupt the database or expose a partial one.

Measured on a live Engine: a 5,000-record bulk insert (7.4 MiB of JSON, 150 full-text terms per record) was sent and the Engine was killed with `kill -9` while the request ran.
In the three trials where the kill landed during the transaction, the WAL had grown by 2.7 to 3.3 MB of uncommitted frames and the client got no response.
After each restart the collection held 0 of those records and the change feed held 0 of their changes.
A kill before the transaction began also committed nothing.

A request can commit and still lose its response (the Engine dies after the commit, before the reply).
Make retries safe: create with client-supplied ids (a retry gets 409 `record_exists`), or use upserts, or check the change feed for the transaction's records before retrying.
