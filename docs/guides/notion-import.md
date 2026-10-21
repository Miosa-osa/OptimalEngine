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

A page is classified as an ingest is: a page longer than 64 KiB takes its genre and summary from its first 64 KiB of whole lines, its mode from the whole page, and its entities from the whole page within the classification time limit (past it, from the first 64 KiB).
Each page gets one classification budget, so a page of any shape costs a bounded time to classify; all of its text is stored and searchable.

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
Every edge the importer writes records it as its asserter (`asserted_by` is `import.notion`), and a re-import retracts only edges that record it alone.
An edge someone else asserted is never retracted, and neither is an edge the importer wrote that someone else then asserted too.
Edges imported before an Engine recorded asserters are given to the importer by the upgrade when both ends are imported Notion contexts.

A database CSV becomes a context with a Markdown table of its first 200 rows, each row linked to the row's own context.
The CSV is read as a stream, and at most 10,000 rows of one CSV are imported; the rest are left out and reported as `csv_truncated`.
Blank rows are skipped but counted: at most twice the row limit plus 1,000 rows are parsed, so a CSV of blank lines is cut as early as one of real rows.
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

An `Idempotency-Key` header (or `idempotency_key` in the query or JSON body) names one import of a workspace for good.
A request that repeats the key gets the first job back with `"duplicate": true`, whatever state that job is in, and the Engine answers it before reading the body, so nothing is uploaded, downloaded, or imported twice.
To import the export again, use a new key.
A key is 1 to 128 printable ASCII characters with no spaces; anything else is refused with `400 invalid_idempotency_key`.

A workspace holds at most two imports that are queued or running at once (`config :optimal_engine, :import_max_outstanding`).
A request past that is refused with `429 too_many_imports`, before its body is read.
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
| `failure`, `last_error` | the code and detail of a failed attempt, from the fixed lists below |
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
The tree reads only the requesting key's tenant, and so does the idempotency check of `POST /api/import/notion`.
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
| One page's, database's or row's text | 2 MiB, the rest is cut and reported | `:import_limits` `max_page_bytes` |
| The archive's central directory | 64 MiB | `:import_limits` `max_directory_bytes` |
| Rows read from one database CSV | 10,000, the rest reported as `csv_truncated` | `:import_limits` `max_rows_per_csv` |
| Contexts in one import (pages, databases and rows) | 100,000 | `:import_limits` `max_contexts` |
| Imports queued or running in one workspace | 2 | `:import_max_outstanding` |
| Pages classified at once | half the schedulers | `:import_classify_concurrency` |
| One download, end to end | 30 minutes | `:import_fetch_deadline_ms` |
| A download's average rate, after its first minute | at least 16 KiB/s | `:import_min_bytes_per_second`, `:import_min_rate_after_ms` |

The archive is read by `OptimalEngine.Imports.Zip`, which parses the zip directory itself and never trusts it.
An entry is never inflated past the size its header declares, so a zip bomb is refused instead of filling memory or disk.
Entry names never become paths on disk.
A part zip is unpacked to the import's folder, and its bytes count against the total, the same as the entries inside it.

These answers come back from the request itself:

| Status | Error | Cause |
| --- | --- | --- |
| 400 | `source_required` | neither a zip body nor a `source_url` |
| 400 | `empty_upload` | a zip body with no bytes |
| 400 | `upload_failed` | the upload broke off |
| 400 | `invalid_idempotency_key` | a key over 128 bytes, or with a space or a control character |
| 400 | `invalid_source_url` | not an absolute `https` URL (or `http` to an allowed host) |
| 400 | `invalid_source_url` | the URL carries a user name or password, is over 8 KiB, or holds a control character |
| 400 | `source_url_refused` | the host is not on the allowed list (when one is set), does not resolve, or resolves to a loopback, private, link-local, or reserved address |
| 413 | `import_too_large` | over the size limit, with `max_bytes` |
| 403 | `permission_scope_denied`, `workspace_scope_denied` | the key lacks `write` or the workspace |
| 404 | `workspace not found` | another tenant's workspace, or one that is not active |
| 429 | `too_many_imports` | the workspace already has two imports queued or running, with `max_outstanding` |
| 500 | `import_unavailable`, `status_unavailable`, `tree_unavailable` | the store did not answer |

A job fails at once, without a retry, with one of these codes in `failure.code` and `last_error`:
`invalid_zip`, `zip64_unsupported`, `unsafe_path` (an absolute path, a drive letter, a `..`, `.` or empty segment, a backslash, or a NUL in a name), `too_many_entries`, `archive_too_large` (also a central directory over its limit), `entry_size_mismatch` (an entry inflates past its declared size), `too_many_contexts`, `empty_export` (no Markdown or CSV), `invalid_source_url`, `source_url_refused`, `redirect_refused` (a redirect to anything but an allowed `https` host), `too_many_redirects` (more than five), `download_too_large`, and `source_missing`.
The same holds inside a part zip: a traversal or a bomb in a part refuses the whole import.

A refusal found while the archive is read, before any page is written, leaves the workspace as it was.
An entry that inflates past its declared size is found only when it is read, so contexts written before it stay, without their edges, which are written last.
Importing a corrected export updates those contexts in place and writes the edges.

A download that fails or an attempt that crashes is retried with backoff.
A failed download is `download_failed` with one code from a fixed list, and never with anything taken from the request or the URL:
`connect_failed`, `tls_failed`, `timeout`, `too_slow`, `send_failed`, `receive_failed`, `connection_closed`, `malformed_response`, `body_incomplete`, `redirect_without_location`, `unresolvable`, or `http_<status>` such as `http_404`.
A crash is reported by its kind alone, such as `crashed: RuntimeError`.

These are listed in `errors` while the import continues:
`invalid_name` (a name that is not UTF-8; the entry is skipped), `invalid_utf8` (the text is repaired), `page_truncated`, `page_unreadable` (a page that could not be processed or classified), `duplicate_page` (a second page with the same id), `csv_unreadable`, `csv_truncated`, `part_unreadable` (a zip at the archive root that is not a readable archive; it is skipped), `entry_too_large`, `crc_mismatch`, `corrupt_entry`, `encrypted_entry`, `unsupported_compression`, and `intake_failed` (its detail is a code, such as `intake_unavailable`).

## Source URLs

The Engine downloads a `source_url` inside the job and checks the URL before every request:

- `https` only, with the server's certificate and host name verified; plain `http` only to an allowed host.
- When allowed hosts are set, only those hosts are fetched.
- The host must resolve only to public addresses; a loopback, private, link-local, shared, or reserved address is refused unless the host is allowed explicitly.
- The URL and every redirect `Location` are at most 8 KiB with no control character.
- The host is resolved once, and every address it resolves to must be public, so an answer that mixes a public and a private address is refused.
- At most four of its addresses are tried, each within what is left of the download's deadline.
- The connection goes to the address that was checked, with the host name sent as `Host` and as the TLS server name and checked against the certificate, so a second DNS answer cannot move it elsewhere.
- A redirect is followed only to an allowed `https` host, checked the same way, at most five times.

Allowed hosts come from `OPTIMAL_IMPORT_URL_HOSTS` (comma-separated); an entry is a host name or `*.` followed by a domain, such as `*.storage.example.com`.
`OPTIMAL_IMPORT_CA_FILE` names a PEM file of extra certificate authorities to trust, for object storage behind a private CA.

The body of a `200` answer is written to a file as it arrives, never held whole in memory, and the transfer stops the moment it passes the size limit; `Content-Length` only lets an oversized answer fail early.
The body of any other answer is never read.
A download that runs past 30 minutes, or averages under 16 KiB/s after its first minute, is cut off as `timeout` or `too_slow`, and a long one keeps the job's lease alive while it runs.
The full URL is written only to the import's `source.url` file, readable by the Engine's user alone, and that file is deleted as soon as the download completes.

## Where imports are staged

An import is staged in `imports/<import id>/` next to the Engine database, or in `OPTIMAL_IMPORTS_DIR`.
The folder holds the source (`source.zip`, and `source.url` until a URL source is downloaded) and `report.json`, the counts and error report the status route serves.
The source is deleted when the job completes or fails for good; the report is kept.
The folder is readable by the Engine's user alone (0700), and so is every file in it (0600): the source, the URL, unpacked part zips, and CSVs.
When the worker starts, it removes what imports older than a day left behind: the sources of jobs that are no longer queued or running, however they ended, and folders no job refers to.
`OPTIMAL_IMPORTS_INTERVAL_MS` sets how often the worker looks for queued imports (default 2,000; 0 disables the worker).
