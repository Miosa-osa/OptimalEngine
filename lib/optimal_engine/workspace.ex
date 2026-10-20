defmodule OptimalEngine.Workspace do
  @moduledoc """
  A **workspace** is a knowledge base owned by an organization inside a tenant.

  An organization can hold many workspaces — e.g. "Engineering Brain",
  "Sales Brain", "M&A Brain", "Personal". Each workspace has its own
  curated wiki, its own connectors, its own audiences, and its own
  set of typed hierarchical nodes scoped by `node.workspace_id`.

  Multiplicity rules:

  - Every signal-bearing row carries a `workspace_id`.
  - Default deployments use the singleton workspace `"default"`
    seeded by migration 026.
  - A principal in a tenant can belong to multiple workspaces via
    `workspace_members` with role ∈ `:owner | :member | :viewer`.

  Tenant isolation is the absolute boundary; workspace is a soft scope
  inside it. There's no cross-workspace leakage by default — every
  query that scopes by workspace must pass `workspace_id`.

  This module is the facade over the `workspaces` and `workspace_members`
  tables created in migration 026.
  """

  alias OptimalEngine.Store
  alias OptimalEngine.Organization
  alias OptimalEngine.Tenancy.Tenant
  alias OptimalEngine.Workspace.Config
  alias OptimalEngine.Workspace.Filesystem

  require Logger

  @default_id "default"
  @allowed_statuses [:active, :archived]
  # The same rule portable topology documents use for workspace slugs.
  @slug_format ~r/\A[a-z0-9][a-z0-9-]{0,127}\z/
  # Tables whose rows a workspace record owns rather than names; the check
  # for rows under an unregistered id skips them.
  @own_tables ~w(workspaces workspace_handles)
  @allowed_roles [:owner, :member, :viewer]

  @type status :: :active | :archived
  @type role :: :owner | :member | :viewer

  @type t :: %__MODULE__{
          id: String.t(),
          tenant_id: String.t(),
          organization_id: String.t(),
          slug: String.t(),
          name: String.t(),
          description: String.t() | nil,
          status: status(),
          created_at: String.t() | nil,
          archived_at: String.t() | nil,
          metadata: map()
        }

  defstruct id: nil,
            tenant_id: Tenant.default_id(),
            organization_id: Organization.default_id(),
            slug: nil,
            name: nil,
            description: nil,
            status: :active,
            created_at: nil,
            archived_at: nil,
            metadata: %{}

  # ── Defaults ────────────────────────────────────────────────────────────

  @doc "Returns the reserved default workspace id."
  @spec default_id() :: String.t()
  def default_id, do: @default_id

  # ── Lookup ──────────────────────────────────────────────────────────────

  @doc "Returns the workspace with the given id, or `{:error, :not_found}`."
  @spec get(String.t()) :: {:ok, t()} | {:error, :not_found}
  def get(id) when is_binary(id) do
    case Store.raw_query(
           select_sql() <> " WHERE id = ?1",
           [id]
         ) do
      {:ok, [row]} -> {:ok, row_to_struct(row)}
      {:ok, []} -> {:error, :not_found}
      other -> other
    end
  end

  @doc "Returns the workspace identified by `(tenant_id, slug)`."
  @spec get_by_slug(String.t(), String.t()) :: {:ok, t()} | {:error, :not_found}
  def get_by_slug(slug, tenant_id) when is_binary(slug) and is_binary(tenant_id) do
    case Store.raw_query(
           select_sql() <> " WHERE tenant_id = ?1 AND slug = ?2",
           [tenant_id, slug]
         ) do
      {:ok, [row]} -> {:ok, row_to_struct(row)}
      {:ok, []} -> {:error, :not_found}
      other -> other
    end
  end

  @doc """
  Returns the workspace a slug names in `tenant_id`: the one whose current
  slug it is, else the one that held it before a rename (its row in
  `workspace_handles`). Ids never change on a rename, so this is how a link
  or a document written with an older slug finds its workspace.
  """
  @spec get_by_handle(String.t(), String.t()) :: {:ok, t()} | {:error, :not_found}
  def get_by_handle(slug, tenant_id) when is_binary(slug) and is_binary(tenant_id) do
    case get_by_slug(slug, tenant_id) do
      {:error, :not_found} ->
        case Store.raw_query(
               select_sql() <>
                 " WHERE id = (SELECT workspace_id FROM workspace_handles WHERE tenant_id = ?1 AND slug = ?2)",
               [tenant_id, slug]
             ) do
          {:ok, [row]} -> {:ok, row_to_struct(row)}
          {:ok, []} -> {:error, :not_found}
          other -> other
        end

      found ->
        found
    end
  end

  @doc """
  Every slug the workspace holds: the current one and those it had before a
  rename. No other workspace of the tenant can take any of them.
  """
  @spec handles(String.t()) :: [String.t()]
  def handles(workspace_id) when is_binary(workspace_id) do
    case Store.raw_query(
           "SELECT slug FROM workspace_handles WHERE workspace_id = ?1 ORDER BY created_at, slug",
           [workspace_id]
         ) do
      {:ok, rows} -> List.flatten(rows)
      _ -> []
    end
  end

  @doc """
  Lists workspaces in a tenant. Options:
    * `:status`    — `:active` (default) | `:archived` | `:all`
    * `:tenant_id` — defaults to the default tenant
    * `:limit`     — max rows (default 50)
    * `:offset`    — row offset for pagination (default 0)
  """
  @spec list(keyword()) :: {:ok, [t()]} | {:error, term()}
  def list(opts \\ []) do
    tenant_id = Keyword.get(opts, :tenant_id, Tenant.default_id())
    organization_id = Keyword.get(opts, :organization_id)
    status = Keyword.get(opts, :status, :active)
    limit = Keyword.get(opts, :limit, 50)
    offset = Keyword.get(opts, :offset, 0)

    {where, params} = list_scope(tenant_id, organization_id, status)

    sql =
      select_sql() <>
        where <> " ORDER BY name LIMIT ?#{length(params) + 1} OFFSET ?#{length(params) + 2}"

    params = params ++ [limit, offset]

    case Store.raw_query(sql, params) do
      {:ok, rows} -> {:ok, Enum.map(rows, &row_to_struct/1)}
      other -> other
    end
  catch
    {:invalid_status, s} -> {:error, {:invalid_status, s}}
  end

  @doc """
  Counts workspaces in a tenant. Accepts the same `:tenant_id` and `:status` opts as `list/1`.
  """
  @spec count(keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def count(opts \\ []) do
    tenant_id = Keyword.get(opts, :tenant_id, Tenant.default_id())
    organization_id = Keyword.get(opts, :organization_id)
    status = Keyword.get(opts, :status, :active)

    {where, params} = list_scope(tenant_id, organization_id, status)
    sql = "SELECT COUNT(*) FROM workspaces" <> where

    case Store.raw_query(sql, params) do
      {:ok, [[n]]} -> {:ok, n}
      {:ok, []} -> {:ok, 0}
      other -> other
    end
  catch
    {:invalid_status, s} -> {:error, {:invalid_status, s}}
  end

  # ── Mutations ───────────────────────────────────────────────────────────

  @doc """
  Creates a workspace. Required: `slug`, `name`. Optional: `tenant_id`
  (defaults to default tenant), `description`, `metadata`. Slug becomes
  part of the id (`tenant_id:slug` for non-default tenants, plain
  `default` for the singleton default-tenant default-workspace case).
  Errors: `:slug_taken`, `:slug_reserved`.
  """
  @spec create(map()) :: {:ok, t()} | {:error, term()}
  def create(%{slug: slug, name: name} = attrs) when is_binary(slug) and is_binary(name) do
    tenant_id = Map.get(attrs, :tenant_id, Tenant.default_id())
    organization_id = Map.get(attrs, :organization_id, Organization.default_id())
    description = Map.get(attrs, :description)
    metadata = Map.get(attrs, :metadata, %{})
    id = Map.get(attrs, :id) || derive_id(tenant_id, slug)

    sql = """
    INSERT INTO workspaces (id, tenant_id, organization_id, slug, name, description, status, metadata)
    VALUES (?1, ?2, ?3, ?4, ?5, ?6, 'active', ?7)
    """

    params = [id, tenant_id, organization_id, slug, name, description, Jason.encode!(metadata)]

    with {:ok, organization} <- Organization.get(organization_id),
         true <- organization.tenant_id == tenant_id || {:error, :organization_tenant_mismatch},
         :ok <- not_reserved(slug),
         {:ok, _} <- insert_unless_taken(tenant_id, slug, id, sql, params) do
      root = Application.get_env(:optimal_engine, :root_path, File.cwd!())

      case Filesystem.provision(id, root: root) do
        {:ok, _path} ->
          case Config.put(id, Config.defaults(), root) do
            :ok ->
              :ok

            {:error, reason} ->
              require Logger

              Logger.warning(
                "[Workspace.create] config write failed for #{slug}: #{inspect(reason)}"
              )
          end

        {:error, reason} ->
          require Logger
          Logger.warning("[Workspace.create] FS provision failed for #{slug}: #{inspect(reason)}")
      end

      {:ok,
       %__MODULE__{
         id: id,
         tenant_id: tenant_id,
         organization_id: organization_id,
         slug: slug,
         name: name,
         description: description,
         status: :active,
         metadata: metadata
       }}
    else
      false -> {:error, :organization_tenant_mismatch}
      other -> other
    end
  end

  def create(_), do: {:error, :missing_required_fields}

  @doc """
  Updates a workspace's mutable fields: `:name`, `:description`,
  `:metadata`, and `:slug`. Tenant and id are immutable.

  A new slug renames the workspace without moving it: the id stays, so every
  row, file, key, and `optimal://` link that names the id keeps working. The
  slug it replaces stays this workspace's handle (`workspace_handles`,
  `get_by_handle/2`), so no other workspace can take it. A slug whose
  derived id already holds rows (written to that id before it was
  registered) is refused, so a rename never adopts them. Every rename is
  recorded in the authority evidence chain (`workspace.renamed`) with the
  actor given as `opts[:actor]`.
  Errors: `:invalid_slug`, `:slug_reserved`, `:slug_taken`, `:slug_has_data`,
  `:default_workspace_slug`.
  """
  @spec update(String.t(), map(), keyword()) :: {:ok, t()} | {:error, term()}
  def update(id, attrs, opts \\ []) when is_binary(id) and is_map(attrs) do
    with {:ok, current} <- get(id),
         {:ok, slug} <- next_slug(current, Map.get(attrs, :slug)) do
      updated = %{
        current
        | name: Map.get(attrs, :name, current.name),
          description: Map.get(attrs, :description, current.description),
          metadata: Map.get(attrs, :metadata, current.metadata),
          slug: slug
      }

      with {:ok, _} <- write_unless_taken(current, updated) do
        if slug != current.slug, do: record_rename(current, slug, opts[:actor])
        {:ok, updated}
      end
    end
  end

  defp next_slug(current, nil), do: {:ok, current.slug}
  defp next_slug(%{slug: slug}, slug), do: {:ok, slug}

  defp next_slug(current, slug) do
    cond do
      current.id == @default_id -> {:error, :default_workspace_slug}
      not (is_binary(slug) and Regex.match?(@slug_format, slug)) -> {:error, :invalid_slug}
      true -> with :ok <- not_reserved(slug), do: {:ok, slug}
    end
  end

  # A default-tenant workspace lives in `<root>/<slug>` beside the root's own
  # directories, so a slug may never name one of them.
  defp not_reserved(slug) do
    if slug in Filesystem.reserved_names(), do: {:error, :slug_reserved}, else: :ok
  end

  # Each conflict check runs in one Store transaction with its write, so two
  # requests can never both take one slug.
  defp insert_unless_taken(tenant_id, slug, id, sql, params) do
    Store.transaction(fn txn ->
      if handle_taken?(txn, tenant_id, slug, id, nil) do
        {:error, :slug_taken}
      else
        with {:ok, _} <- Store.txn_execute(txn, sql, params),
             do: add_handle(txn, tenant_id, slug, id)
      end
    end)
  end

  defp write_unless_taken(current, updated) do
    tenant_id = current.tenant_id
    derived_id = derive_id(tenant_id, updated.slug)
    renamed? = updated.slug != current.slug

    Store.transaction(fn txn ->
      cond do
        renamed? and handle_taken?(txn, tenant_id, updated.slug, derived_id, current.id) ->
          {:error, :slug_taken}

        renamed? and derived_id != current.id and rows_under?(txn, derived_id) ->
          {:error, :slug_has_data}

        true ->
          with {:ok, _} <-
                 Store.txn_execute(
                   txn,
                   "UPDATE workspaces SET name = ?1, description = ?2, metadata = ?3, slug = ?4 WHERE id = ?5",
                   [
                     updated.name,
                     updated.description,
                     Jason.encode!(updated.metadata),
                     updated.slug,
                     current.id
                   ]
                 ),
               do: add_handle(txn, tenant_id, updated.slug, current.id)
      end
    end)
  end

  defp add_handle(txn, tenant_id, slug, id) do
    Store.txn_execute(
      txn,
      "INSERT OR IGNORE INTO workspace_handles (tenant_id, slug, workspace_id) VALUES (?1, ?2, ?3)",
      [tenant_id, slug, id]
    )
  end

  # A slug is taken when another workspace of the tenant uses it now or held
  # it before a rename, or when the id it would derive already exists.
  defp handle_taken?(txn, tenant_id, slug, id, except_id) do
    {:ok, rows} =
      Store.txn_query(
        txn,
        """
        SELECT 1 FROM workspaces WHERE id != ?4 AND (id = ?3 OR (tenant_id = ?1 AND slug = ?2))
        UNION ALL
        SELECT 1 FROM workspace_handles WHERE tenant_id = ?1 AND slug = ?2 AND workspace_id != ?4
        LIMIT 1
        """,
        [tenant_id, slug, id, except_id || ""]
      )

    rows != []
  end

  # Writes to an unregistered "<tenant>:<slug>" id are allowed, so an id can
  # hold rows before any workspace has it. A rename onto that slug would
  # strand them behind the renamed workspace's handle.
  defp rows_under?(txn, workspace_id) do
    {:ok, tables} =
      Store.txn_query(
        txn,
        """
        SELECT m.name FROM sqlite_master m
        WHERE m.type = 'table' AND m.sql NOT LIKE 'CREATE VIRTUAL TABLE%'
          AND EXISTS (SELECT 1 FROM pragma_table_info(m.name) c WHERE c.name = 'workspace_id')
        """,
        []
      )

    tables
    |> List.flatten()
    |> Enum.reject(&(&1 in @own_tables))
    |> Enum.any?(fn table ->
      match?(
        {:ok, [_ | _]},
        Store.txn_query(
          txn,
          ~s(SELECT 1 FROM "#{table}" WHERE workspace_id = ?1 LIMIT 1),
          [workspace_id]
        )
      )
    end)
  end

  defp record_rename(current, slug, actor) do
    actor = actor || "system:engine"

    case OptimalEngine.Authority.Evidence.append(current.tenant_id, "workspace.renamed", %{
           subject: actor,
           action: "admin",
           resource: "optimal://#{current.id}",
           workspace_id: current.id,
           detail: %{"from" => current.slug, "to" => slug, "by" => actor}
         }) do
      {:ok, _entry} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[Workspace] rename of #{current.id} not recorded as evidence: #{inspect(reason)}"
        )
    end
  rescue
    error ->
      Logger.warning(
        "[Workspace] rename of #{current.id} not recorded as evidence: #{Exception.message(error)}"
      )
  end

  @doc "Moves a workspace to another organization in the same tenant."
  @spec assign_organization(String.t(), String.t()) :: {:ok, t()} | {:error, term()}
  def assign_organization(id, organization_id) when is_binary(id) and is_binary(organization_id) do
    with {:ok, workspace} <- get(id),
         {:ok, organization} <- Organization.get(organization_id),
         true <-
           organization.tenant_id == workspace.tenant_id || {:error, :organization_tenant_mismatch},
         {:ok, _} <-
           Store.raw_query("UPDATE workspaces SET organization_id = ?1 WHERE id = ?2", [
             organization_id,
             id
           ]) do
      get(id)
    else
      false -> {:error, :organization_tenant_mismatch}
      other -> other
    end
  end

  @doc "Soft-deletes a workspace by setting `status = 'archived'`."
  @spec archive(String.t()) :: :ok | {:error, term()}
  def archive(id) when is_binary(id) do
    case Store.raw_query(
           "UPDATE workspaces SET status = 'archived', archived_at = datetime('now') WHERE id = ?1",
           [id]
         ) do
      {:ok, _} -> :ok
      other -> other
    end
  end

  # ── Membership ──────────────────────────────────────────────────────────

  @doc """
  Grants a principal access to a workspace at a role. Role defaults to
  `:member`.
  """
  @spec add_member(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def add_member(workspace_id, principal_id, opts \\ []) do
    role = Keyword.get(opts, :role, :member)
    tenant_id = Keyword.get(opts, :tenant_id, Tenant.default_id())

    if role not in @allowed_roles do
      {:error, {:invalid_role, role}}
    else
      sql = """
      INSERT INTO workspace_members (tenant_id, workspace_id, principal_id, role)
      VALUES (?1, ?2, ?3, ?4)
      ON CONFLICT(workspace_id, principal_id) DO UPDATE SET
        role = excluded.role,
        ended_at = NULL
      """

      case Store.raw_query(sql, [tenant_id, workspace_id, principal_id, Atom.to_string(role)]) do
        {:ok, _} ->
          {:ok,
           %{
             tenant_id: tenant_id,
             workspace_id: workspace_id,
             principal_id: principal_id,
             role: role
           }}

        other ->
          other
      end
    end
  end

  @doc "Removes a principal from a workspace (sets ended_at)."
  @spec remove_member(String.t(), String.t()) :: :ok | {:error, term()}
  def remove_member(workspace_id, principal_id) do
    case Store.raw_query(
           "UPDATE workspace_members SET ended_at = datetime('now') WHERE workspace_id = ?1 AND principal_id = ?2",
           [workspace_id, principal_id]
         ) do
      {:ok, _} -> :ok
      other -> other
    end
  end

  @doc "Lists active members of a workspace as `{principal_id, role}` tuples."
  @spec members_of(String.t()) :: {:ok, [{String.t(), atom()}]} | {:error, term()}
  def members_of(workspace_id) when is_binary(workspace_id) do
    case Store.raw_query(
           "SELECT principal_id, role FROM workspace_members WHERE workspace_id = ?1 AND ended_at IS NULL ORDER BY role, principal_id",
           [workspace_id]
         ) do
      {:ok, rows} ->
        {:ok, Enum.map(rows, fn [pid, role] -> {pid, String.to_atom(role)} end)}

      other ->
        other
    end
  end

  @doc """
  Lists the workspaces a principal can access (active, not-ended) as
  `{workspace, role}` tuples, ordered by name.
  """
  @spec workspaces_of(String.t()) :: {:ok, [{t(), atom()}]} | {:error, term()}
  def workspaces_of(principal_id) when is_binary(principal_id) do
    sql = """
    SELECT w.id, w.tenant_id, w.organization_id, w.slug, w.name, w.description, w.status,
           w.created_at, w.archived_at, w.metadata, m.role
    FROM workspaces w
    INNER JOIN workspace_members m ON m.workspace_id = w.id
    WHERE m.principal_id = ?1 AND m.ended_at IS NULL AND w.status = 'active'
    ORDER BY w.name
    """

    case Store.raw_query(sql, [principal_id]) do
      {:ok, rows} ->
        {:ok,
         Enum.map(rows, fn row ->
           {ws_row, [role]} = Enum.split(row, 10)
           {row_to_struct(ws_row), String.to_atom(role)}
         end)}

      other ->
        other
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────────

  # The default-tenant default-workspace gets the bare id "default" for
  # backwards compat with rows backfilled in migration 026. Everything
  # else gets `<tenant_id>:<slug>`.
  @doc """
  The id a new workspace with `slug` gets in `tenant_id`. A renamed
  workspace keeps the id it was created with, so its id can differ.
  """
  @spec derive_id(String.t(), String.t()) :: String.t()
  def derive_id(tenant_id, slug) do
    if tenant_id == Tenant.default_id() and slug == @default_id,
      do: @default_id,
      else: "#{tenant_id}:#{slug}"
  end

  defp select_sql do
    "SELECT id, tenant_id, organization_id, slug, name, description, status, created_at, archived_at, metadata FROM workspaces"
  end

  defp list_scope(tenant_id, organization_id, status) do
    {clauses, params} =
      if organization_id,
        do: {["tenant_id = ?1", "organization_id = ?2"], [tenant_id, organization_id]},
        else: {["tenant_id = ?1"], [tenant_id]}

    case status do
      :all ->
        {" WHERE " <> Enum.join(clauses, " AND "), params}

      s when s in @allowed_statuses ->
        position = length(params) + 1

        {" WHERE " <> Enum.join(clauses ++ ["status = ?#{position}"], " AND "),
         params ++ [Atom.to_string(s)]}

      other ->
        throw({:invalid_status, other})
    end
  end

  defp row_to_struct([
         id,
         tenant_id,
         organization_id,
         slug,
         name,
         description,
         status,
         created_at,
         archived_at,
         meta_json
       ]) do
    %__MODULE__{
      id: id,
      tenant_id: tenant_id,
      organization_id: organization_id,
      slug: slug,
      name: name,
      description: description,
      status: String.to_atom(status),
      created_at: created_at,
      archived_at: archived_at,
      metadata: decode_json(meta_json)
    }
  end

  defp decode_json(nil), do: %{}
  defp decode_json(""), do: %{}

  defp decode_json(s) when is_binary(s) do
    case Jason.decode(s) do
      {:ok, m} when is_map(m) -> m
      _ -> %{}
    end
  end
end
