# Erasure And Retention

What the Engine removes when a workspace is archived or moved, a principal is erased, a memory is forgotten or deleted, or a retention policy deletes or redacts a context, and what it leaves: in its own tables, in the replication ledger, on its peers and on the NATS ledger stream.
The embedding cache's own rules are in [`OPTIONS.md`](../../OPTIONS.md), Text Embeddings.

## What each path removes

| Path | Rows | Files | Cache |
| --- | --- | --- | --- |
| Archive a workspace (`POST /api/workspaces/:id/archive`) | None: the workspace is marked archived and its rows stay; on NATS, the Signals its connectors queued and intake has not taken, and their dead letters | None | Embedding entries, decomposition checkpoints and local copies of object-store assets |
| Finalize a move (`POST /api/workspaces/:id/finalize-move`) | Every row of the workspace | The workspace's directory, local assets included | As archive |
| Erase a principal (`Compliance.Erasure`) | The principal's contexts and everything derived from them, then the principal | Signal files with their sidecars and cross-reference copies, asset files, decomposition checkpoints and the objects of the deleted assets in the configured object store | Embedding entries of each workspace that held one of the contexts (also when a batch fails, for the contexts already gone) |
| Retention `delete` | The context and everything derived from it | As erase | Embedding entries of the workspace |
| Retention `redact` | The text, abstract and overview are rewritten; everything derived from the original is deleted and built again from the redacted text | The signal file and its sidecars are rewritten through the same redaction, in place; asset files and checkpoints of the deleted derived rows are removed | None |
| Retention `archive` | None: `archived_at` is set | None | None |
| Forget a memory (`POST /api/memory/:id/forget`, `Memory.forget/2`) | Every version of the memory (its `root_memory_id` chain, earlier and later, and for a chain an older build wrote without `root_memory_id`, the versions its `parent_memory_id` links reach); an update of the memory waits for the forget and is then refused (`forgotten`). Each row stays, flagged forgotten with its reason, with its text emptied, its `content_hash`, `citation_uri` and `source_chunk_id` cleared and its metadata cut to `security_labels` and `partition_ids`; its full-text entry, its embedding row, its source chunk (unless the chunk's context still exists or another live memory names it), and the source package its creation staged the text in, with the claims made from it (pending or reviewed), the facts that accepted them and the package's episodes and decomposition runs. A package another live memory or a context of the workspace holds the same text in stays, and so does a memory that extends or derives from it. On PostgreSQL the posting lists are rewritten after the commit from a queue the forget's own transaction wrote, so a failed rewrite is retried by the store's background refresh and before any search. Their changes leave the replication ledger too (see [below](#the-replication-ledger-peers-and-nats)) | None | The embedding entries cached from the versions' text |
| Delete a memory (`DELETE /api/memory/:id`, `Memory.delete/1`) | What a forget erases, for every version of the memory, then the versions' rows (their relations cascade) | None | As forget |
| A replica applies a peer's delete of a context | The context; the rows derived from it arrive as deletes of their own. The decomposition runs, assets and extraction text this Engine made itself are not replicated and are deleted with the package (see below) | The checkpoints and local asset files of a source package, once the package row is gone: the package the peer deleted with the context, or that it deleted on its own | Embedding entries of the workspace |

"Everything derived from a context" is, in `Compliance.DerivedData`: the document vector, chunks and chunk vectors (and the intents, classifications, cluster members and citations that cascade from a chunk), entity mentions and their resolution decisions, entities, claims, the facts that accepted a deleted claim, the context's source packages (and `source_packages_fts` where an older database has it), decomposition runs, assets with their extractions, transcripts and OCR spans, wiki pages that cite a deleted chunk, episodes, processor runs, decisions, and graph edges (`graph_edges`) that name the context.
The triples the knowledge store (ETS or RocksDB) mirrors from those edges go with them: triggers on `graph_edges` record every deleted edge, and the erasure returns once the running store has dropped their triples.
An Engine whose store is not running drops them when it next starts.
Whenever a Qdrant URL is configured (`OPTIMAL_QDRANT_URL`, [Storage Providers](storage-providers.md#qdrant-projection)), serving or not, an erasure, a retention delete and a redaction also delete the points of the context's document vector and of its chunks' vectors from Qdrant, before the rows, in the request and within its timeout; when Qdrant cannot delete them, or does not answer in time, the erasure stops with `qdrant_delete_failed` and the rows stay, so it can be run again. Once the rows are gone the removal is recorded again (`qdrant_pending_removals`) and retried until Qdrant takes it.
Archiving or moving a workspace removes its points from Qdrant too, and deleting, forgetting or superseding a memory removes the memory's points (a forget or hard delete those of every version of the chain, after the erasure commits); these removals are recorded and retried until Qdrant takes them (`Projection.remove_memories/2` for memories). Only the Engine's own points are removed: every delete is filtered on its `engine_id`.
A signal file is the file intake wrote for the context (`contexts.path`, in a `signals` directory of the workspace), its `.abstract.md` and `.overview.md` sidecars, and the cross-reference copies written to the other nodes the signal was routed to, with the contexts that index them: they are the same text, and an index of the directory would bring the context back from any of them.
A row names its file, and a bundle import writes rows verbatim, so a file goes only when it is the context's own: a markdown file that holds the text intake wrote for the context (the part after the frontmatter, byte for byte) or is named for the context's id (the suffix intake gives a name another context held).
A copy is found at the names intake gives it in each node the signal was routed to (the primary file's name, or that name with the suffix of the context's id when another context already held it there) and goes only when it is markdown and holds the text of the context it was copied from.
A context goes with a copy only if its row says it is the copy of that context (`metadata.cross_ref_of`); another context that holds the plain name in the node, or whose row merely names the same path, is never erased with it.
Erasing a copy does not erase the context it was copied from, which is a context of its own.
A file that a context outside the erasure also names (the index of `contexts.path` is not unique) is kept, whatever way its row spells the path (`a/./b` is `a/b`), and the row of the erased context goes.
The check is made when the files are planned and again just before they are removed or rewritten.
What is left is counted in the log, never named.
The markdown file of each wiki page that cites an erased chunk (`<workspace>/.wiki/<slug>.md`) goes with the page row; the wiki scheduler writes the page again from what is left.
A chunk counts only when it is in the workspace of its context: a chunk row that names another workspace (a bundle import writes it verbatim) does not reach that workspace's page files.
A file to be redacted is read through one handle, and only if that handle is the regular file that was looked at (same device and inode), so a link put in its place in between is not read.
A redacted file is written to a new file created exclusively under a random name and then renamed over the old one, so no link left at a guessable name is written through.
A signal file that has another hard link loses (or is rewritten at) the name the Engine knows, and the log counts such files, never naming them: the text stays under the other name.
A file in a node's folder that a person put there is theirs and stays, as does a file that is not markdown or holds other text than the context's, any file outside the workspace's own directory, in a hidden directory, in `assets`, `architectures` or `tenants`, a link, and the files of another workspace even when a row names them.
A file of the context that a person edited by hand under the plain name is theirs too, and stays; one named for the context's id is removed whatever it holds.
A source package that a remaining context refers to is kept, and so is an asset file that a remaining asset shares.
Erasure and retention work in batches of 200 contexts, each batch one transaction with its derived rows; a failure stops with the earlier batches done, and running it again finishes the rest.
The dry run (`Erasure.preview/2`) counts every table by running the delete and rolling it back.

A single memory that is deleted or forgotten, and an app data record that is deleted or whose indexed text is rewritten, removes the embedding cached from its text.
A memory embedded with a custom `document_prefix`, a collection dropped whole, and search queries stay in the cache until `cache_max_age_days` removes them.

## The replication ledger, peers and NATS

Change capture records every write of a replicated row with the whole row (`sync_capture`, then `sync_mutations` when sealed), so an erasure that only appended its own change would leave the erased text in the earlier changes, serve it to every peer that had not caught up, and publish it to NATS.
`OptimalEngine.Sync.Redaction` takes it out, in the transaction of the erasure.

| Path | `sync_mutations` and `sync_capture` here | Peers | NATS ledger stream |
| --- | --- | --- | --- |
| Erase a principal, retention `delete`, retention `redact` (the derived rows) | Every row the batch deleted, explicitly or by a foreign-key cascade (chunks, embeddings, claims, facts, packages, episodes, wiki pages): its earlier changes are redacted and its unsealed captures dropped. The append-only rows made from a deleted chunk, context or memory (intents, citations, classifications, cluster members, decisions, entities, graph edges, memory relations) are found by that link and redacted too | The deletes replicate as deletes; a peer that applies a delete redacts its own copies of the row's changes up to the delete, deletes the append-only rows the origin deletes with a context (decisions, entities, graph edges; a chunk's and a memory's go by foreign key) and redacts their changes | Each delete purges its row's subject before its tombstone goes out; the erasure flushes the publisher (`flush/1`) |
| Retention `redact` (the context) | The context's earlier changes are redacted before it is rewritten, so the rewrite is the only change that holds its text, and that text is the redacted one | A redaction request (`ledger_redactions`) goes first: a peer redacts its copies, then applies the rewrite | The request purges the context's subject; the sweep flushes the publisher |
| Forget a memory (`POST /api/memory/:id/forget`) | Every change of every version of the memory's chain and of their embeddings, the forget included, is redacted; the source package, claims, facts, episodes, decomposition runs and source chunk the forget deletes are redacted as deletes (above), with the chunk's append-only rows | A redaction request: a peer erases by its own rule for memories, redacting its copies up to the version erased, deleting its embeddings of the memory and setting `is_forgotten = 1` and `content = ''`. A replica that never had the memory never gets it | The request purges the memory's subject; the forget flushes the publisher |
| Delete a memory (`DELETE /api/memory/:id`) | What a forget redacts, then the earlier changes of every version's row and of their relations and embeddings (cascades) | Deletes, as above | Deletes, as above; the delete flushes the publisher |
| Finalize a move | Every row of the workspace, as for an erasure | Deletes, as above | The workspace's whole subject tree is purged (`forget_workspace/4`), as for an archive |
| Archive a workspace | Nothing: the rows stay | Nothing | The workspace's whole subject tree is purged |
| Any other delete of a replicated row (a graph rebuild, a re-curated wiki page, a bundle import discarded) | The row's earlier changes are redacted when the delete is sealed | Deletes, as above | Deletes, as above, on the publisher's next pass |
| A workspace whose sync was turned off before the erasure | Its deletes are not captured: after the commit, the changes the ledger still holds of rows that no longer exist are redacted | Nothing is sent: the workspace no longer replicates | No delete goes out to purge them, so the erasure asks the publisher to purge each such row's subject (`forget_rows/5`), now or when NATS is back |

A redacted ledger row keeps its id, sequence, device, operation, idempotency key and times, so cursors, conflict clocks and the history page still read it.
Its payload becomes `{"row": {...}, "blobs": {}, "redacted": true}`, its `payload_hash` is the SHA-256 of that payload as the ledger computes every hash, and `redacted_at` records when.
The tombstone's row keeps what the data-class gate and the readers' grant checks classify the row by, reduced to class ranks and ids: labels that are class names or id-shaped (a label that cannot be read becomes `restricted`, the rank the gate gives it), id-shaped partitions, the labels and id keys of its metadata, a class column's class, and link columns as ids only (of a text column, only its `optimal://` addresses).
The gate decides whether a delete may go to a peer from the row's earlier versions, so a tombstone still ranks as the version did.
A key that is an id is kept; a natural text key (an alias, a name) is kept as a keyed hash.
The row's `entity_id` and its delete keep the key as it is: a peer can only delete a row it can name, and the gate finds a deleted row's versions by it.
The ledger is not hash chained: each hash covers its own row's payload, and a peer recomputes the hash of every change it stores instead of trusting the sender's, so a rewritten row verifies like any other.
A redacted row is never served, pushed or published again (`Sync.changes/3` and the push read only `redacted_at IS NULL`), so a new replica or a stream filled again from the ledger never sees the text.
The `local_payload` and `remote_payload` of the row's `sync_conflicts` become the same tombstone.
A delete already carries only the row's key and is not rewritten.

A redaction request carries the type of the row (`memory` or `context`), its id, a reason code and the version erased (the time of the erasure, as change capture writes `occurred_at`), and nothing else.
It is as classified as the row it names: the gate holds it from a peer not cleared for that row, so the peer does not learn the row existed.
A peer erases by its own rule for the table (`Sync.Redaction.erasure_rule/1`), never by values the sender chose: a memory is marked forgotten with no text and its embeddings go; a context's ledger copies go and its redacted text arrives as the rewrite that follows.
It refuses a request that carries any other column, names another type, or has a reason or version it does not know, and one for a row it holds above the class the sender is cleared for.
It redacts only the changes that occurred at or before the version, and does not touch the row when a change of it here is newer (that change wins, as any newer change does, and is still pushed); a delete applied from a peer is bounded by the time the delete occurred the same way.
A peer that applies it does so in the apply's transaction, with capture off, so nothing is echoed.
A request's version may be at most 10 minutes ahead of the receiving Engine's clock (the drift allowed between devices); one further ahead is refused.
A change of an erased row that occurred at or before the version erased (a peer that had not caught up, or a hub relaying one) is skipped (`skipped.erased`) by every Engine that holds the request, in a later batch or in the same one, so it cannot bring the text back; nor is it kept in `sync_conflicts`.
When a peer's delete is applied over a local change, the conflict keeps the local change as its tombstone.
An apply writes its ledger rows at the end of its transaction: a change of the batch that an erasure of the same batch takes out is written as its tombstone.
A seal that wrote a change of a row an erasure had already asked to redact (it read the capture before the forget took the change out) redacts it right after; each row a seal redacts is redacted on its own, and one that fails is logged and left for the backfill.
On the peer the erasure then reaches what the peer made from the row, as a local erasure does: the full-text index follows the emptied row (the FTS5 triggers in the apply's transaction on SQLite; on PostgreSQL the posting lists of the tables a batch deleted from or redacted are refreshed once it commits), the embeddings this Engine cached from the workspace's text are purged, and the derived rows the origin deleted (embeddings, source packages, claims, facts) arrive as deletes of their own, with the decomposition runs and assets this Engine made from a deleted package removed after them.

### Backfill for an Engine that erased before

An Engine on v0.3.7 to v0.3.14 with a workspace that replicates still holds the text of what it erased since in `sync_mutations`.
`mix optimal.ledger.redact` (or `bin/optimal eval 'OptimalEngine.Release.redact_ledger()'` on a release) redacts it once: the earlier changes of every row whose delete is in the ledger, of every row of a single-keyed table that no longer exists (deleted while the workspace did not replicate, or by a peer's delete), of every append-only row whose chunk, context or memory no longer exists (a graph edge's endpoint is not a foreign key: there the context's delete must be in the ledger; `edges` and `observations` are never redacted by a parent), and of every forgotten memory (its request erases up to the forget's own change, not up to the time of the backfill), plus the `sync_capture` and `sync_conflicts` rows of workspaces that no longer exist.
The rows that no longer exist have their NATS subjects purged.
A forgotten memory of a workspace that replicates gets a redaction request, so peers on this release redact theirs; a peer runs the backfill itself for its own deletes.
The NATS publisher is flushed for the workspaces it touched.
`--dry-run` (`redact_ledger(dry_run: true)`) changes nothing (it does not even seal the capture) and prints counts only: the workspaces that replicate, the registered peers, per table the rows still exposed and their ledger changes, and the captured changes not sealed yet; never an id or a word of content.
A second run finds nothing.
It does not run by itself at boot: an operator measures with the dry run first, then runs it.

## What an erasure does not reach

These keep erased data until they are pruned, replaced or removed by an operator.

| Where | Holds | For how long |
| --- | --- | --- |
| Scheduled backups in `OPTIMAL_BACKUP_DIR` | The whole database, every workspace, in plaintext | The newest `OPTIMAL_OFFSITE_BACKUP_KEEP_LOCAL` (3) files: that many intervals of `OPTIMAL_OFFSITE_BACKUP_INTERVAL_MS`, so 3 days at a daily interval |
| Scheduled offsite copies | The whole database, encrypted with `OPTIMAL_BACKUP_KEY` | The newest `OPTIMAL_OFFSITE_BACKUP_KEEP` (14): 14 days at a daily interval |
| Manual backups (`POST /api/backup`), `restores/` under the backup directory, and `<database>.pre-restore-<epoch>` copies | The whole database | Until an operator removes them; the schedule never prunes them |
| Workspace bundles in `<backup dir>/bundles/` | Every row and file of the workspace, in plaintext | Until an operator removes them |
| SQLite free pages and the write-ahead log | Deleted rows, until the pages are reused or checkpointed | Until overwritten; `secure_delete` is not enabled |
| Files in the workspace directory that an erasure does not remove: a file a person put in a node's folder and the indexer read (or edited under the plain name of a signal file), a file that another context also names, a node's `context.md` (it collects facts from many signals), and the cross-reference copies of a signal that retention redacted | Their text | Until the files are removed; a reindex reads them back as contexts |
| Other hard links to a signal file (a backup tool that links files makes them) | The text of the file | Until an operator removes the other names; the Engine removes or rewrites its own name and counts the file in the log |
| Objects in an object store, when an erasure or a retention delete does not reach them | The bytes of assets stored there | Until the objects are deleted: an archive and a move delete none (the workspace's assets on the Engine it moved to still point at them), and neither does an erasure when no object store is configured, when the asset's URI names another bucket or a key outside the asset's workspace prefix, or when another asset still uses the object |
| A peer that runs a release before the ledger redaction (v0.3.14 or older) | Its copies of the erased rows' earlier changes | Until the peer is upgraded and runs the backfill. Replication between the two pauses meanwhile: an Engine syncs only with a peer on the same schema version, so nothing is exchanged with it, and nothing stalls (see [The replication ledger](#the-replication-ledger-peers-and-nats)) |
| Append-only rows deleted on their own at the origin (a re-curated page's citations, a rebuilt graph's edges, reclustered members), on a peer | The rows: append-only tables replicate inserts only, their ids differ per Engine, and only the deletes that go with a deleted chunk, context or memory reach a peer | Until the peer rebuilds them, or an operator removes them; these are rebuilds, not erasures, and the origin's ledger keeps their earlier versions until their chunk, context or memory goes |
| The NATS ledger stream (`OPTIMAL_NATS_FLOWS=ledger`), while NATS is down | The erased rows' earlier messages | Until NATS is back: the erasure's deletes then purge each row's subject, and the report's `nats_ledger` says `pending: true` meanwhile (see [Storage Providers](storage-providers.md#what-the-engine-forgets-leaves-the-stream)) |
| What a NATS subscriber already read | Whatever it kept | The subscriber's own retention |
| NATS intake dead letters of a workspace that was not archived, moved or had its connector deleted | The connector content of a Signal intake gave up on | Until requeued, or `OPTIMAL_NATS_DEAD_LETTER_MAX_AGE_HOURS` (720) after it was dead-lettered |
| Shared canonical entities and aliases | Names that more than one context mention | Until a steward removes them |
| The legacy `edges` table, kept unread for one release after `graph_edges` replaced it | Context and entity ids, no text | Until the table is dropped; no path reads or writes it |

The backup retention is the erasure's window: the data is gone from the Engine at once and from its backups when the last copy that held it is pruned.
Scheduled backups are off unless `OPTIMAL_OFFSITE_BACKUP_INTERVAL_MS` is set.
A restore from a backup brings back what the backup held, so run the erasure again after one.
An operator who has to shorten the window removes the manual copies, the bundles and the pre-restore copies by hand, and lowers `OPTIMAL_OFFSITE_BACKUP_KEEP` and `OPTIMAL_OFFSITE_BACKUP_KEEP_LOCAL`.

On a replica the rows of `decomposition_runs`, `assets` and the asset extractions, transcripts and OCR spans are this Engine's own and are not replicated, so a peer's delete does not delete them, and the package an asset names is cleared when the package row is deleted.
The replica does what the origin does, no more.
At the origin `DerivedData` deletes a source package, with its runs, assets, extraction, transcript and OCR rows and their files, in the transaction that deletes the last context or claim that refers to it (`exclusive_packages` and the package steps of `delete_in/3`), and it keeps all of them while one refers to it.
The package row is the signal: the replica reads, before it applies a batch, the source packages of the contexts and the source packages the batch deletes, and once the batch has committed it removes the files and deletes those rows (with the text in them) of each package whose row is gone and which no context or claim refers to.
A package that is still here is one the origin kept, or one whose delete has not been applied yet, and keeps everything until the delete of the package arrives and sweeps it.
It decides against what is committed then, in one transaction with the removal: a delete that was not applied (held for its label, or kept because a newer local change won) leaves the context and its package, and so does a context or a claim that refers to the package, whether it was written by the same batch or after the plan was read.
If the delete of a package is applied in an earlier batch than the delete of its last context, the context still refers to it and keeps the rows, and the link of the assets to the package is cleared by that delete: they stay until an operator removes them.
An asset file that an asset outside the plan names, spelled the same way or another, stays.

## Files are removed only when they are the Engine's

A path in a row is data, and a bundle import writes these rows too, so a row is a claim and the Engine checks it against the file it would have written.
A file is removed for a workspace only when all of these hold:

- A decomposition checkpoint is `<cache path>/decomposition/<run id>.json`, the run id is letters, digits, `_` and `-`, the path is the one built from the run id (the row's has to be the same), and the file says it is that run's and that workspace's (`run_id` and `workspace_id`). A checkpoint written to another directory by a caller that named one, or one that cannot be read back, is left; one over 256 MiB is an error rather than a silent leftover.
- A local asset is `assets/<xx>/<file>` in the directory of the workspace being erased (`Workspace.Filesystem.path`), never in another workspace's directory or any other file of the root.
- A copy of an object-store asset is under `<cache path>/assets/<prefix>/<tenant>/<workspace>` of the workspace being erased, never under another workspace's.
- A row whose workspace is not one of the erased contexts' workspaces has its row deleted and its file left.
- No directory between the Engine root (or the cache path) and the file is a link, and the file is a regular file: a link is not followed, in the last component or above it. An operator who keeps a workspace directory behind a link keeps those files too.
- A file that a remaining asset also names, spelled the same way or another (`a/./b`, `a/c/../b`), is kept.

- An object of an erased asset is deleted only in the configured bucket, as one key under `<prefix>/<tenant>/<workspace>/assets/` of the workspace being erased with no empty, `.` or `..` segment, and not when another asset still uses it. The objects go before the transaction that deletes their rows, never inside it, so a request to the bucket never holds the store; an object that cannot be deleted leaves the rows in place and the next run finishes. An object the store no longer has (a 404 to the delete) counts as deleted. When no object store is configured the objects stay and the rows go; when one is configured but its settings cannot be read (an unreadable credentials file, an endpoint that is not valid) the erasure stops with `{:artifact_not_removed, :asset_object, reason}`, the rows stay, and the next run finishes once the settings are fixed. An object left alone (another bucket than the configured one, a key outside the workspace's prefix, no store configured) is counted by reason and logged as a warning with the counts and no key.

A bucket and a prefix are the Engine's own.
An object is named by its key alone (`<prefix>/<tenant>/<workspace>/assets/<xx>/<hash>`), and the check that another asset still uses it reads only this Engine's rows.
Two Engines, or an Engine and another application, that write under the same bucket and prefix can therefore share an object (the same tenant id, workspace id and content hash on both, as when a workspace was restored on a second Engine or a move has not yet been finalized), and an erasure on one deletes the object the other's asset still names.
Give each Engine its own `OPTIMAL_S3_PREFIX` or bucket; a bucket that other applications write to is never safe to delete from.

It never removes a directory other than the object copies of one workspace, the copies' tenant directory, `<cache path>/assets`, or the Engine root.
A file a row names that is not the Engine's to remove is left alone and counted: `Artifacts.remove/1` answers with `skipped` (by kind and reason, `not_ours` or `link`) and logs a warning with the counts, never a path.
Archiving, moving, renaming and repairing a workspace remove the checkpoints and copies of the whole workspace by the same rules; an erasure or a retention delete removes those of the rows it deletes and leaves the rest of the workspace's.
