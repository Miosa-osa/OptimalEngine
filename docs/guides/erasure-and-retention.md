# Erasure And Retention

What the Engine removes when a workspace is archived or moved, a principal is erased, or a retention policy deletes or redacts a context, and what it leaves.
The embedding cache's own rules are in [`OPTIONS.md`](../../OPTIONS.md), Text Embeddings.

## What each path removes

| Path | Rows | Files | Cache |
| --- | --- | --- | --- |
| Archive a workspace (`POST /api/workspaces/:id/archive`) | None: the workspace is marked archived and its rows stay | None | Embedding entries, decomposition checkpoints and local copies of object-store assets |
| Finalize a move (`POST /api/workspaces/:id/finalize-move`) | Every row of the workspace | The workspace's directory, local assets included | As archive |
| Erase a principal (`Compliance.Erasure`) | The principal's contexts and everything derived from them, then the principal | Signal files with their sidecars and cross-reference copies, asset files, decomposition checkpoints and the objects of the deleted assets in the configured object store | Embedding entries of each workspace that held one of the contexts (also when a batch fails, for the contexts already gone) |
| Retention `delete` | The context and everything derived from it | As erase | Embedding entries of the workspace |
| Retention `redact` | The text, abstract and overview are rewritten; everything derived from the original is deleted and built again from the redacted text | The signal file and its sidecars are rewritten through the same redaction, in place; asset files and checkpoints of the deleted derived rows are removed | None |
| Retention `archive` | None: `archived_at` is set | None | None |
| A replica applies a peer's delete of a context | The context; the rows derived from it arrive as deletes of their own. The decomposition runs, assets and extraction text this Engine made itself are not replicated and are deleted with the package (see below) | The checkpoints and local asset files of a source package, once the package row is gone: the package the peer deleted with the context, or that it deleted on its own | Embedding entries of the workspace |

"Everything derived from a context" is, in `Compliance.DerivedData`: the document vector, chunks and chunk vectors (and the intents, classifications, cluster members and citations that cascade from a chunk), entity mentions and their resolution decisions, entities, claims, the facts that accepted a deleted claim, the context's source packages (and `source_packages_fts` where an older database has it), decomposition runs, assets with their extractions, transcripts and OCR spans, wiki pages that cite a deleted chunk, episodes, processor runs, decisions, and graph edges (`graph_edges`) that name the context.
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

## What an erasure does not reach

These keep erased data until they are pruned, replaced or removed by an operator.

| Where | Holds | For how long |
| --- | --- | --- |
| Scheduled backups in `OPTIMAL_BACKUP_DIR` | The whole database, every workspace, in plaintext | The newest `OPTIMAL_OFFSITE_BACKUP_KEEP_LOCAL` (3) files: that many intervals of `OPTIMAL_OFFSITE_BACKUP_INTERVAL_MS`, so 3 days at a daily interval |
| Scheduled offsite copies | The whole database, encrypted with `OPTIMAL_BACKUP_KEY` | The newest `OPTIMAL_OFFSITE_BACKUP_KEEP` (14): 14 days at a daily interval |
| Manual backups (`POST /api/backup`), `restores/` under the backup directory, and `<database>.pre-restore-<epoch>` copies | The whole database | Until an operator removes them; the schedule never prunes them |
| Workspace bundles in `<backup dir>/bundles/` | Every row and file of the workspace, in plaintext | Until an operator removes them |
| SQLite free pages and the write-ahead log | Deleted rows, until the pages are reused or checkpointed | Until overwritten; `secure_delete` is not enabled |
| The RocksDB knowledge store (`.optimal/knowledge-rocksdb`) | Entity names and context ids as quads | Until the store is rebuilt; no delete path retracts them |
| Files in the workspace directory that an erasure does not remove: a file a person put in a node's folder and the indexer read (or edited under the plain name of a signal file), a file that another context also names, a node's `context.md` (it collects facts from many signals), and the cross-reference copies of a signal that retention redacted | Their text | Until the files are removed; a reindex reads them back as contexts |
| Other hard links to a signal file (a backup tool that links files makes them) | The text of the file | Until an operator removes the other names; the Engine removes or rewrites its own name and counts the file in the log |
| Objects in an object store, when an erasure or a retention delete does not reach them | The bytes of assets stored there | Until the objects are deleted: an archive and a move delete none (the workspace's assets on the Engine it moved to still point at them), and neither does an erasure when no object store is configured, when the asset's URI names another bucket or a key outside the asset's workspace prefix, or when another asset still uses the object |
| Replication ledgers (`sync_capture`, `sync_mutations`) | The rows of a change, in the changes' payloads | Append-only |
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
