# Optimal Engine as a MIOSA sandbox template

A workspace's Memory is the Engine running as an always-on MIOSA sandbox.
The image path uses only MIOSA's own infrastructure: no registry, no GitHub, no public package.

## How it gets there

1. **Build the release** on an x86_64 MIOSA build host (Docker, no registry login):

   ```bash
   deploy/miosa-template/build-release.sh out/
   ```

   This runs `docker build --target release` and writes `out/optimal-engine.tgz`: the OTP release (it carries its own ERTS), the four shared libraries a base sandbox lacks (snappy, zstd, lz4, bzip2), and `start-engine`.
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

## Environment a Memory needs

| Variable | Value |
| --- | --- |
| `OPTIMAL_AUTH_REQUIRED` | `true` |
| `OPTIMAL_BOOTSTRAP_KEY` | `oe_<24 hex>_<secret of 32+ chars>`, chosen by the operator (Optimal derives it per workspace) |
| `OPTIMAL_BOOTSTRAP_SCOPES` | `read,write` |
| `OPTIMAL_BOOTSTRAP_WORKSPACES` | the Engine workspace slug the instance serves |

## Open items

- Embeddings are local or bring-your-own; the Engine's default `OLLAMA_HOST` points at nothing in a sandbox.
- A template belongs to one organization.
  Other organizations need it created in theirs until the platform ships it as a built-in template.
