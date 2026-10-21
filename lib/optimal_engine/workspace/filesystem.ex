defmodule OptimalEngine.Workspace.Filesystem do
  @moduledoc """
  Provisions the on-disk directory tree for a workspace.

  Layout (relative to the engine root):

      <root>/<workspace_slug>/
      ├── nodes/                  Tier 1 — raw signals, append-only
      ├── .wiki/                  Tier 3 — curated pages
      │   └── SCHEMA.md           governance rules the curator honors
      ├── assets/                 binary attachments, hash-addressed
      └── architectures/          user-defined data-point schemas

  The default workspace is special — it lives at the root itself
  (no `default/` prefix) for backwards-compat with the existing
  `nodes/`, `.wiki/`, `assets/` layout.

  This module is idempotent: calling `provision/2` on an existing
  workspace skips already-created paths. Safe to invoke on every
  workspace upsert.
  """

  require Logger

  @default_slug "default"

  @doc """
  Returns the absolute on-disk path for a workspace, given the engine root
  and either the workspace id or (for the default tenant) its slug.

  * `"default"` (the default tenant's default workspace) is the root itself.
  * `"default:<slug>"` and a bare `"<slug>"` are `<root>/<slug>`.
  * `"<tenant>:<slug>"` for any other tenant is `<root>/tenants/<tenant>/<slug>`,
    so two tenants' workspaces with the same slug never share a directory.
  """
  @spec path(String.t(), String.t()) :: String.t()
  def path(root, key) when is_binary(root) and is_binary(key) do
    case String.split(key, ":", parts: 2) do
      [@default_slug] -> root
      ["default", @default_slug] -> root
      ["default", slug] -> Path.join(root, safe(slug))
      [tenant, slug] -> Path.join([root, "tenants", safe(tenant), safe(slug)])
      [slug] -> Path.join(root, safe(slug))
    end
  end

  # Directory names never climb out of the root.
  defp safe(segment) do
    case segment |> Path.basename() |> String.trim() do
      value when value in ["", ".", ".."] -> "_"
      value -> value
    end
  end

  @doc """
  Directory names the engine root uses for itself. A default-tenant
  workspace lives in `<root>/<slug>`, so no workspace slug may be one of
  them.
  """
  @spec reserved_names() :: [String.t()]
  def reserved_names, do: ~w(nodes assets architectures tenants cache)

  @doc """
  The directory key of an id that names no workspace and whose own name cannot
  be its directory (it sanitizes to a name the root uses, or to nothing):
  `ws-` and twelve hex digits of the id's hash. The same id always gets the
  same key, and ids that sanitize alike get different ones.
  """
  @spec hashed_key(String.t()) :: String.t()
  def hashed_key(id) when is_binary(id),
    do: "ws-" <> Base.encode16(binary_part(:crypto.hash(:sha256, id), 0, 6), case: :lower)

  @doc """
  Provisions the directory tree for a workspace. Returns `{:ok, path}` with
  the absolute workspace path on success; `{:error, reason}` on failure.

  Idempotent — re-running on an existing workspace is a no-op.

  Options:
    * `:root` — engine root path. Defaults to `File.cwd!/0`.
    * `:write_schema` — whether to drop a starter `.wiki/SCHEMA.md`.
      Defaults to `true` for new workspaces, ignored for the default
      workspace (which has its own schema).
  """
  @spec provision(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def provision(slug, opts \\ []) when is_binary(slug) do
    root = Keyword.get(opts, :root, File.cwd!())
    write_schema = Keyword.get(opts, :write_schema, true)
    workspace_path = path(root, slug)

    with :ok <- File.mkdir_p(workspace_path),
         :ok <- File.mkdir_p(Path.join(workspace_path, "nodes")),
         :ok <- File.mkdir_p(Path.join(workspace_path, ".wiki")),
         :ok <- File.mkdir_p(Path.join(workspace_path, "assets")),
         :ok <- File.mkdir_p(Path.join(workspace_path, "architectures")) do
      if write_schema and slug != @default_slug do
        maybe_write_schema(workspace_path, slug)
      end

      Logger.info("[Workspace.Filesystem] provisioned #{slug} at #{workspace_path}")
      {:ok, workspace_path}
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────────

  defp maybe_write_schema(workspace_path, slug) do
    schema_path = Path.join([workspace_path, ".wiki", "SCHEMA.md"])

    if File.exists?(schema_path) do
      :ok
    else
      File.write(schema_path, default_schema(slug))
    end
  end

  defp default_schema(slug) do
    """
    # Wiki governance — workspace `#{slug}`

    The Optimal Engine curator reads this file and applies its rules
    when generating pages for this workspace. Edit freely.

    ## Required sections

    Every curated page must contain:

    - `## Summary` — one paragraph, ≤ 100 tokens.
    - `## Key points` — bullets, atomic claims, ≤ 2K tokens total.
    - `## Detail` — full prose; no length cap.

    ## Citation requirements

    - Every factual claim carries a `{{cite: optimal://...}}` directive.
    - Citations must resolve to a Tier-1 signal in this workspace.
    - Cross-workspace citations are rejected by the integrity gate.

    ## Audience policy

    Audiences derive from the workspace's audience registry. Default is
    `default`. Add audiences by writing them to the wiki page frontmatter
    `audience:` field; the curator will produce one variant per audience.

    ## Naming

    - Wiki slugs are lowercase-kebab-case and unique per audience.
    - Slugs should match the dominant entity or theme of the page.
    """
  end
end
