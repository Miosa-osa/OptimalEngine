# Notion Import

A Notion workspace export (Settings, Export, Markdown and CSV) can be imported into one Engine workspace in a single request.
The import runs as a durable job, so it survives a restart, retries a failed attempt, and reports what it did.
Every page becomes a context you can search, read, and cite, and the export's page hierarchy and links become edges in the graph.

## What lands in the workspace

Each page, each database, and each database row that has no page of its own becomes one context.
A context is written through the intake pipeline into the database only, without markdown files on disk.
Its URI is `optimal://<workspace>/notion/<id>`, where `<id>` is the 32 hex id Notion puts in every file name.
Search results and RAG citations carry that URI, and `GET /api/read?uri=<uri>&workspace=<workspace>&tier=full` serves the page.
A file without a Notion id gets a stable id derived from its path (`path-<hex>`).

The context id is derived from the workspace and the Notion id, so importing the same export again updates each context in place.
A page whose title and text are unchanged is skipped, not ingested again, and is counted as `unchanged`.

Two kinds of edges are written:

| Edge | From | To |
| --- | --- | --- |
| `child_of` | a page, a database, or a row | its parent page, or the database the row belongs to |
| `links_to` | a page | every exported page or database it links to |

A link in the stored text that points at another exported page or database (a relative path, or a `notion.so` link carrying the target's id) is rewritten to the target's `optimal://` URI.
A link to a page the export does not hold is left as written and counted as unresolved.
Images, attachments, and other web links are left alone.
A re-import replaces the `child_of` and `links_to` edges of the contexts it writes, so a page that moved has one parent.

A database CSV becomes a context with a Markdown table of its first 200 rows, each row linked to the row's own context.
When Notion exported both `Tasks <id>.csv` and `Tasks <id>_all.csv`, the `_all` view (every property) is read.
A row whose page Notion exported (`Tasks <id>/Row <id>.md`) is that page; a row without one becomes a context of its own with its properties as text.

Attachments (images, PDFs, other files) are counted and not imported.
Notion splits a large export into part zips inside the zip it hands out; part zips at the archive root are read as one export, one level deep.

Writes go only into the workspace named in the request.

## Import over HTTP

Post the zip itself, streamed to the Engine:

```bash
curl -X POST "http://localhost:4200/api/import/notion?workspace=default:docs" \
  -H "Authorization: Bearer $OPTIMAL_KEY" \
  -H "Content-Type: application/zip" \
  -H "Idempotency-Key: notion-2026-10-20" \
  --data-binary @export.zip
```

Or name a URL the Engine downloads itself, such as a presigned object URL:

```bash
curl -X POST http://localhost:4200/api/import/notion \
  -H "Authorization: Bearer $OPTIMAL_KEY" \
  -H "Content-Type: application/json" \
  -d '{"workspace": "default:docs", "source_url": "https://storage.example.com/export.zip?X-Signature=..."}'
```

The key needs the `write` scope and the workspace in its workspace scope.
Both forms answer `202` with the job:

```json
{
  "job_id": "job_4f1c...",
  "kind": "import.notion",
  "workspace_id": "default:docs",
  "status": "queued",
  "duplicate": false,
  "status_url": "/api/import/notion/job_4f1c...?workspace=default%3Adocs"
}
```

The upload is written to disk as it arrives and is never held whole in memory.
A repeated `Idempotency-Key` (or `idempotency_key` in the query or body) returns the first job with `"duplicate": true` and imports nothing twice.
A presigned URL carries its signature in the query string, so the Engine never logs, stores or returns the full URL: the job row, the status, errors and logs show only `scheme://host/path`.

## Follow the job

```bash
curl "http://localhost:4200/api/import/notion/job_4f1c...?workspace=default:docs" \
  -H "Authorization: Bearer $OPTIMAL_KEY"
```

The status needs the `read` scope and answers:

| Field | Meaning |
| --- | --- |
| `status` | `queued`, `running`, `retrying` (a failed attempt waits for its retry), `completed`, or `failed` |
| `attempts`, `max_attempts` | attempts so far, of at most 3 |
| `counts` | `entries`, `parts`, `pages`, `databases`, `rows`, `assets`, `skipped`, `contexts` (written), `unchanged`, `edges_child_of`, `edges_links_to`, `links_unresolved`, `errors` |
| `progress` | `done` and `total` contexts, updated while the job runs |
| `errors` | the first 200 problems, each with `path`, `reason`, and `detail`; `errors_truncated` says whether there were more |
| `root_uris` | the top-level pages |
| `failure`, `last_error` | the code and detail of a failed attempt |
| `source` | `upload` with its `bytes`, or `url` with the URL as `scheme://host/path` |
| `created_at`, `started_at`, `finished_at`, `completed_at` | timestamps |

A queued import starts within about two seconds.
`completed` means every page was processed; a problem with one page is listed in `errors` and the job still completes.
`failed` means the archive or URL was refused, or every attempt failed.

## Check the hierarchy

```bash
curl "http://localhost:4200/api/import/notion/tree?workspace=default:docs" -H "Authorization: Bearer $OPTIMAL_KEY"
curl "http://localhost:4200/api/import/notion/tree?workspace=default:docs&parent=<id>" -H "Authorization: Bearer $OPTIMAL_KEY"
```

Without `parent` the answer lists the imported pages that have no parent; with it, the pages under that page.
Each entry carries `page_id`, `uri`, `title`, and `children`, the number of pages under it.
`limit` (default 500, at most 1,000) and `offset` page through a long level.

## Import from the command line

On the Engine host:

```bash
mix optimal.import_notion export.zip --workspace default:docs
```

The task copies the zip into the imports folder, enqueues the same job, runs it to the end, and prints the counts.
`--key` sets an idempotency key and `--json` prints the final status as JSON.

## Limits and refusals

| Limit | Default | Setting |
| --- | --- | --- |
| Upload or download size | 1 GiB | `OPTIMAL_IMPORT_MAX_BYTES` |
| Entries in the archive, part zips included | 50,000 | `config :optimal_engine, :import_limits, %{max_entries: n}` |
| Uncompressed bytes declared in total | 4 GiB | `:import_limits` `max_total_bytes` |
| One Markdown or CSV entry | 64 MiB | `:import_limits` `max_entry_bytes` |
| One page's text | 2 MiB, the rest is cut and reported | `:import_limits` `max_page_bytes` |

The archive is read by `OptimalEngine.Imports.Zip`, which parses the zip directory itself and never trusts it.
An entry is never inflated past the size its header declares, so a zip bomb is refused instead of filling memory or disk.
Entry names never become paths on disk.

These answers come back from the request itself:

| Status | Error | Cause |
| --- | --- | --- |
| 400 | `source_required` | neither a zip body nor a `source_url` |
| 400 | `empty_upload` | a zip body with no bytes |
| 400 | `invalid_source_url` | not an absolute `https` URL (or `http` to an allowed host) |
| 400 | `invalid_source_url` | the URL carries a user name or password |
| 400 | `source_url_refused` | the host is not on the allowed list (when one is set), does not resolve, or resolves to a loopback, private, link-local, or reserved address |
| 413 | `import_too_large` | over the size limit, with `max_bytes` |
| 403 | `permission_scope_denied`, `workspace_scope_denied` | the key lacks `write` or the workspace |
| 404 | `workspace not found` | another tenant's workspace, or one that is not active |

A job fails at once, without a retry, with one of these codes in `failure.code` and `last_error`:
`invalid_zip`, `zip64_unsupported`, `unsafe_path` (an absolute path, a drive letter, a `..`, `.` or empty segment, a backslash, or a NUL in a name), `too_many_entries`, `archive_too_large`, `entry_size_mismatch` (an entry inflates past its declared size), `empty_export` (no Markdown or CSV), `invalid_source_url`, `source_url_refused`, `redirect_refused` (a redirect to anything but an allowed `https` host), `too_many_redirects` (more than five), `download_too_large`, and `source_missing`.
A download that fails (`download_failed`) or an attempt that crashes is retried with backoff.

These are listed in `errors` while the import continues:
`invalid_name` (a name that is not UTF-8; the entry is skipped), `invalid_utf8` (the text is repaired), `page_truncated`, `duplicate_page` (a second page with the same id), `csv_unreadable`, `entry_too_large`, `crc_mismatch`, `corrupt_entry`, `encrypted_entry`, `unsupported_compression`, and `intake_failed`.

## Source URLs

The Engine downloads a `source_url` inside the job and checks the URL before every request:

- `https` only, with the server's certificate and host name verified; plain `http` only to an allowed host.
- When allowed hosts are set, only those hosts are fetched.
- The host must resolve only to public addresses; a loopback, private, link-local, shared, or reserved address is refused unless the host is allowed explicitly.
- The connection goes to the address that was checked, so a second DNS answer cannot move it elsewhere.
- A redirect is followed only to an allowed `https` host, checked the same way, at most five times.

Allowed hosts come from `OPTIMAL_IMPORT_URL_HOSTS` (comma-separated); an entry is a host name or `*.` followed by a domain, such as `*.storage.example.com`.
`OPTIMAL_IMPORT_CA_FILE` names a PEM file of extra certificate authorities to trust, for object storage behind a private CA.

The body of a `200` answer is written to a file as it arrives, never held whole in memory, and the transfer stops the moment it passes the size limit; `Content-Length` only lets an oversized answer fail early.
The body of any other answer is never read.
The full URL is written only to the import's `source.url` file, readable by the Engine's user alone, and that file is deleted as soon as the download completes.

## Where imports are staged

An import is staged in `imports/<import id>/` next to the Engine database, or in `OPTIMAL_IMPORTS_DIR`.
The folder holds the source (`source.zip`, and `source.url` until a URL source is downloaded) and `report.json`, the counts and error report the status route serves.
The source is deleted when the job completes or fails for good; the report is kept.
`OPTIMAL_IMPORTS_INTERVAL_MS` sets how often the worker looks for queued imports (default 2,000; 0 disables the worker).
