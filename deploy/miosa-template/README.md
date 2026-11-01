# Optimal Engine as a MIOSA sandbox template

This directory builds the Optimal Engine into a MIOSA sandbox template.
The image path uses only MIOSA's own infrastructure: no registry, no GitHub, no public package.

## The Model And What This Template Does Today

The model for a managed Engine is one org Engine per organization, with a walled section per workspace.
An agent's key opens only its own workspace section unless the key is scoped to all workspaces.
A customer gets an Engine of their own only when a wall requires it: co-owned data, private views, clients, or white-label end users.
The full model, the five sizes, and the operating model are in [MIOSA-managed Engine](../../docs/guides/miosa-managed-engine.md).

| | Today | Planned |
| --- | --- | --- |
| Instances | The template starts one Engine as an always-on sandbox, and the environment below serves one workspace. | One org Engine per organization (`OPTIMAL_ENGINE_SCOPE=org`, the Engine default) serving every workspace behind scoped keys. |
| Sizes | The Engine reads `OPTIMAL_SIZE_PROFILE` and reports usage against it. | Agent memory, Workspace, Business, Platform, and Scale as platform sizes, with one-command resize and scale to zero. |
| Install | A built, versioned release archive (below). | The same archive, followed through release channels with backup and rollback. |

Nothing here installs from a repo clone.
The build host compiles the release once, and every Engine unpacks that archive.

## How it gets there

1. **Build the release** on an x86_64 MIOSA build host (Docker, no registry login):

   ```bash
   deploy/miosa-template/build-release.sh out/
   ```

   This runs `docker build --target release` and writes `out/optimal-engine.tgz`: the OTP release (it carries its own ERTS), the four shared libraries a base sandbox lacks (snappy, zstd, lz4, bzip2), and `start-engine` (this directory's `start-engine`, which writes no crash dump into the data volume).
   The rocksdb compile takes 30 to 60 minutes.
2. **Stage it in a MIOSA bucket** of the organization that builds the template:

   ```bash
   MIOSA_API_KEY=... BUCKET_ID=<uuid> deploy/miosa-template/stage-release.sh out/optimal-engine.tgz
   ```

   It prints `RELEASE_URL` (presigned, 24 hours) and `RELEASE_SHA256`.
   The bucket's access policy must be `signed`, not `private`.
3. **Create the template** (validate first):

   ```bash
   MIOSA_API_KEY=... RELEASE_URL=... RELEASE_SHA256=... deploy/miosa-template/create-template.sh --dry-run
   MIOSA_API_KEY=... RELEASE_URL=... RELEASE_SHA256=... deploy/miosa-template/create-template.sh
   ```

   The template is the `miosa-sandbox` base plus steps that download the tarball, check its sha256 and unpack it into `/opt/optimal-engine`.
   MIOSA builds it in a Firecracker guest (`from` plus `steps`).
4. Watch the build: `miosa template builds optimal-engine`.
5. Start a Memory from Optimal (`workspace_memory_launch`), or create a sandbox from the template by hand with the environment below.
   The release carries its own runtime, so nothing is compiled on the sandbox.

## The client on every machine

Machines that use a Memory get the `optimal` CLI and the Engine MCP server from `install-client.sh`; see [CLIENT-INSTALL.md](CLIENT-INSTALL.md).

## Environment a Memory needs

| Variable | Value |
| --- | --- |
| `OPTIMAL_AUTH_REQUIRED` | `true` |
| `OPTIMAL_BOOTSTRAP_KEY` | `oe_<24 hex>_<secret of 32+ chars>`, chosen by the operator (Optimal derives it per workspace) |
| `OPTIMAL_BOOTSTRAP_SCOPES` | `read,write` |
| `OPTIMAL_BOOTSTRAP_WORKSPACES` | the Engine workspace slug the instance serves today; `*` (the default) for an org Engine's operator key |
| `OPTIMAL_EMBED_URL` | the shared embedding endpoint, the gateway's `POST /v1/embeddings` as the Engine's network reaches it |
| `OPTIMAL_EMBED_API_KEY` or `OPTIMAL_EMBED_API_KEY_FILE` | the Engine's gateway key, sent as a bearer token |

Also set, for any managed Engine:

| Variable | Value |
| --- | --- |
| `CONNECTOR_KEY`, `OPTIMAL_AUTHORITY_KEY` | 64 hex characters each, generated once and kept outside the sandbox's data volume |
| `OPTIMAL_BACKUP_KEY` | 64 hex characters, with a copy kept away from the machine; seals offsite backups |
| `OPTIMAL_RELEASE_CHANNEL` | `dev`, `stable`, `beta`, or `pinned` |
| `OPTIMAL_SIZE_PROFILE` | `agent`, `workspace`, `business`, `platform`, or `scale` |

`start-engine` does not set `OPTIMAL_KNOWLEDGE_BACKEND`, so the triple-store mirror is ETS and is reloaded from SQLite at each start.
The graph that search reads is the `graph_edges` table in the database on the data volume.
Set `OPTIMAL_KNOWLEDGE_BACKEND=rocksdb` and `OPTIMAL_KNOWLEDGE_ROCKSDB_PATH=/data/.optimal/knowledge-rocksdb` to keep the mirror on disk.

With `OPTIMAL_EMBED_URL` set, a Memory embeds every document and query through the gateway and runs no model of its own (see [text embedding options](../../OPTIONS.md#text-embeddings)).

## Open items

- Without `OPTIMAL_EMBED_URL` a Memory embeds through `OLLAMA_HOST`, which points at nothing in a sandbox, so search is full-text only.
- The template serves one workspace per instance.
  The org Engine with walled workspaces is the model above, and provisioning it from the template is planned.
- Resize, scale to zero, and channel-following upgrades are planned platform operations; the Engine reports the sizes, channel, and identity they would use.
- A template belongs to one organization.
  Other organizations need it created in theirs until the platform ships it as a built-in template.
