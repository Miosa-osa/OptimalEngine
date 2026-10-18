# Optimal Engine as a MIOSA sandbox template

This is how a workspace's Memory is built: the Engine image runs as an always-on MIOSA sandbox.

## Steps

1. Build `deploy/Dockerfile.engine` and push it to a registry MIOSA can pull from.
   Note the digest (`repo@sha256:<64 hex>`).
   A tag is refused: it can move under a running Memory.
2. Create the template in the organization:

   ```bash
   MIOSA_API_KEY=... ENGINE_IMAGE=repo@sha256:... deploy/miosa-template/create-template.sh --dry-run
   MIOSA_API_KEY=... ENGINE_IMAGE=repo@sha256:... deploy/miosa-template/create-template.sh
   ```

   `--dry-run` validates the BuildSpec with the platform and creates nothing.
3. Wait for the build: `miosa template builds optimal-engine`.
4. Start a Memory from Optimal (`workspace_memory_launch`) or create the sandbox by hand with the environment below.

## Environment a Memory needs

| Variable | Value |
| --- | --- |
| `OPTIMAL_AUTH_REQUIRED` | `true` |
| `OPTIMAL_BOOTSTRAP_KEY` | `oe_<24 hex>_<secret of 32+ chars>`, chosen by the operator (Optimal derives it per workspace) |
| `OPTIMAL_BOOTSTRAP_SCOPES` | `read,write` |
| `OPTIMAL_BOOTSTRAP_WORKSPACES` | the Engine workspace slug the instance serves |

## Open items

- The image defaults `OLLAMA_HOST` to a Docker host address that does not exist in a sandbox.
  Embeddings are local or bring-your-own; point `OLLAMA_HOST` at the user's own model, or leave retrieval to full-text search.
- A template belongs to one organization.
  Other organizations need it created in theirs until the platform ships it as a built-in template.
