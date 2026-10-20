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

  Identity: a workspace's slugs (current and held) are rows of
  `workspace_handles` (migration 71), and the id another system knows it by
  is the `external_id` column (migration 72). An external id names at most
  one active workspace of a tenant (a partial unique index over active rows);
  an archived workspace keeps the value for history and releases it, so the
  outside workspace can be bound to another. Nothing un-archives a workspace
  today: a path that ever does must re-check the binding and answer
  `:external_id_taken` when another active workspace holds the id.
  """

  alias OptimalEngine.Authority.{Evidence, Keys}
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
  # The tables that check reads: those with an index that starts at
  # workspace_id, so asking one for one id is an index lookup, never a scan.
  @indexed_by_workspace """
  SELECT m.name FROM sqlite_master m
  WHERE m.type = 'table' AND m.sql NOT LIKE 'CREATE VIRTUAL TABLE%'
    AND EXISTS (
      SELECT 1 FROM pragma_index_list(m.name) il
      JOIN pragma_index_info(il.name) ii
      WHERE ii.seqno = 0 AND ii.name = 'workspace_id'
    )
  """
  # The id another system knows a workspace by: 1 to 255 printable ASCII
  # bytes without spaces, compared exactly, held by one active workspace of a
  # tenant, set once. The `workspaces.external_id` column holds it.
  @external_id_format ~r/\A[\x21-\x7E]{1,255}\z/
  # Metadata keys that mirror the external id column and the handles, so an
  # Engine rolled back to an earlier release still finds them; a metadata
  # replacement never sets them.
  @identity_keys ~w(previous_slugs external_id)
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
          external_id: String.t() | nil,
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
            external_id: nil,
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
                 " WHERE tenant_id = ?1 AND id = (SELECT workspace_id FROM workspace_handles WHERE tenant_id = ?1 AND slug = ?2)",
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
  Returns the active workspace another system knows by `external_id` in
  `tenant_id` (its binding), or `{:error, :not_found}`. Archived workspaces
  that held the id are listed by `list/1` with `status: :all`.
  """
  @spec get_by_external_id(String.t(), String.t()) :: {:ok, t()} | {:error, :not_found}
  def get_by_external_id(external_id, tenant_id)
      when is_binary(external_id) and is_binary(tenant_id) do
    case Store.raw_query(
           select_sql() <> " WHERE tenant_id = ?1 AND external_id = ?2 AND status = 'active'",
           [tenant_id, external_id]
         ) do
      {:ok, [row]} -> {:ok, row_to_struct(row)}
      {:ok, []} -> {:error, :not_found}
      other -> other
    end
  end

  @doc """
  Lists workspaces in a tenant. Options:
    * `:status`    — `:active` (default) | `:archived` | `:all`
    * `:external_id`: only the workspaces that carry this external id
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

    {where, params} = list_scope(tenant_id, organization_id, status, opts[:external_id])

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
  Counts workspaces in a tenant. Accepts the same `:tenant_id`, `:status`,
  and `:external_id` opts as `list/1`.
  """
  @spec count(keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def count(opts \\ []) do
    tenant_id = Keyword.get(opts, :tenant_id, Tenant.default_id())
    organization_id = Keyword.get(opts, :organization_id)
    status = Keyword.get(opts, :status, :active)

    {where, params} = list_scope(tenant_id, organization_id, status, opts[:external_id])
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
  (defaults to default tenant), `description`, `metadata`, `external_id`
  (or `metadata["external_id"]`). Slug becomes part of the id
  (`tenant_id:slug` for non-default tenants, plain `default` for the
  singleton default-tenant default-workspace case), and becomes the
  workspace's handle.
  A slug is lowercase letters, digits and dashes (`check_slug/1`).
  Errors: `:invalid_slug`, `:slug_reserved`, `:slug_taken`, `:external_id_taken`,
  `:invalid_external_id`.
  """
  @spec create(map()) :: {:ok, t()} | {:error, term()}
  def create(%{slug: slug, name: name} = attrs) when is_binary(slug) and is_binary(name) do
    tenant_id = Map.get(attrs, :tenant_id, Tenant.default_id())
    organization_id = Map.get(attrs, :organization_id, Organization.default_id())
    description = Map.get(attrs, :description)
    metadata = Map.get(attrs, :metadata) || %{}
    id = Map.get(attrs, :id) || derive_id(tenant_id, slug)

    with :ok <- check_slug(slug),
         {:ok, external_id} <- requested_external_id(attrs, metadata),
         {:ok, organization} <- Organization.get(organization_id),
         true <- organization.tenant_id == tenant_id || {:error, :organization_tenant_mismatch},
         workspace = %__MODULE__{
           id: id,
           tenant_id: tenant_id,
           organization_id: organization_id,
           slug: slug,
           name: name,
           description: description,
           external_id: external_id,
           metadata: with_identity(metadata, external_id, [])
         },
         {:ok, _} <- insert_unless_taken(workspace) do
      root = Application.get_env(:optimal_engine, :root_path, File.cwd!())

      case Filesystem.provision(id, root: root) do
        {:ok, _path} ->
          case Config.put(id, Config.defaults(), root) do
            :ok ->
              :ok

            {:error, reason} ->
              Logger.warning(
                "[Workspace.create] config write failed for #{slug}: #{inspect(reason)}"
              )
          end

        {:error, reason} ->
          Logger.warning("[Workspace.create] FS provision failed for #{slug}: #{inspect(reason)}")
      end

      {:ok, workspace}
    else
      false -> {:error, :organization_tenant_mismatch}
      other -> other
    end
  end

  def create(_), do: {:error, :missing_required_fields}

  @doc """
  Updates a workspace's mutable fields: `:name`, `:description`,
  `:metadata`, `:slug`, and `:external_id`. Tenant and id are immutable.

  A new slug renames the workspace without moving it: the id stays, so every
  row, file, key, and `optimal://` link that names the id keeps working. The
  slug it replaces stays this workspace's handle (`workspace_handles`,
  `get_by_handle/2`, mirrored in `metadata.previous_slugs`), so no other
  workspace can take it, even when the workspace had no handle row yet. A
  slug whose derived id already holds rows (written to that id before it was
  registered) is refused, so a rename never adopts them; the check reads the
  tables indexed by workspace, which hold the documents, chunks, memories,
  nodes, and wiki.

  Every rename is recorded in the authority evidence chain
  (`workspace.renamed`) in the same transaction as the rename, so one never
  commits without the other. An Engine that cannot sign evidence (no evidence
  key) still renames and logs a warning. Options for the rename's record:
  `:actor` (who renamed it) and `:authority` (the grants they acted under, a
  list of strings; the API passes the key's scopes, or `["local"]` for an
  anonymous local caller).

  An external id (`:external_id`, or `"external_id"` inside `:metadata`) can
  be set when the workspace has none and no other active workspace of the
  tenant holds it; once set it never changes, because the system that holds
  it finds the workspace by it. Replacing `:metadata` keeps `previous_slugs`
  and `external_id`.

  The row is read, checked, and written in one Store transaction, so
  concurrent updates never undo each other's slug or external id.
  Errors: `:not_found`, `:invalid_slug`, `:slug_reserved`, `:slug_taken`,
  `:slug_has_data`, `:default_workspace_slug`, `:invalid_external_id`,
  `:external_id_taken`, `:external_id_immutable`.
  """
  @spec update(String.t(), map(), keyword()) :: {:ok, t()} | {:error, term()}
  def update(id, attrs, opts \\ []) when is_binary(id) and is_map(attrs) do
    given_metadata = Map.get(attrs, :metadata)

    # Fetched before the transaction opens, because creating a key writes to
    # the Store; a workspace's tenant never changes, so the read is safe.
    evidence_key = if Map.has_key?(attrs, :slug), do: rename_evidence_key(id)

    with {:ok, requested} <- requested_external_id(attrs, given_metadata || %{}),
         {:ok, {_current, updated}} <-
           Store.transaction(
             &write_unless_taken(&1, id, attrs, given_metadata, requested, {evidence_key, opts})
           ) do
      {:ok, updated}
    end
  end

  # The external id a create or update asks for: `:external_id`, else
  # `metadata["external_id"]`; both given must agree.
  defp requested_external_id(attrs, metadata) do
    from_metadata = if is_map(metadata), do: Map.get(metadata, "external_id")

    case {Map.get(attrs, :external_id), from_metadata} do
      {nil, nil} -> {:ok, nil}
      {nil, given} -> validated_external_id(given)
      {given, nil} -> validated_external_id(given)
      {given, given} -> validated_external_id(given)
      _different -> {:error, :invalid_external_id}
    end
  end

  defp validated_external_id(id) do
    if is_binary(id) and Regex.match?(@external_id_format, id),
      do: {:ok, id},
      else: {:error, :invalid_external_id}
  end

  @doc "True when `id` is a valid external id: 1 to 255 printable ASCII bytes, no spaces."
  @spec valid_external_id?(term()) :: boolean()
  def valid_external_id?(id), do: match?({:ok, _}, validated_external_id(id))

  defp next_slug(current, nil), do: {:ok, current.slug}
  defp next_slug(%{slug: slug}, slug), do: {:ok, slug}

  defp next_slug(%{id: @default_id}, _slug), do: {:error, :default_workspace_slug}
  defp next_slug(_current, slug), do: with(:ok <- check_slug(slug), do: {:ok, slug})

  @doc """
  Checks a slug for use as a workspace's handle: lowercase letters, digits
  and dashes, at most 128 characters, starting with a letter or digit
  (`{:error, :invalid_slug}`), and not the name of one of the engine root's
  own directories (`{:error, :slug_reserved}`): a default-tenant workspace
  lives in `<root>/<slug>` beside them.
  """
  @spec check_slug(term()) :: :ok | {:error, :invalid_slug | :slug_reserved}
  def check_slug(slug) do
    cond do
      not (is_binary(slug) and Regex.match?(@slug_format, slug)) -> {:error, :invalid_slug}
      slug in Filesystem.reserved_names() -> {:error, :slug_reserved}
      true -> :ok
    end
  end

  defp next_external_id(current, nil), do: {:ok, current.external_id}

  defp next_external_id(current, external_id) do
    case current.external_id do
      nil -> {:ok, external_id}
      ^external_id -> {:ok, external_id}
      _other -> {:error, :external_id_immutable}
    end
  end

  # Metadata as stored: the caller's keys, with the identity keys mirroring
  # the external id column and the handles the workspace held before.
  defp with_identity(metadata, external_id, held) do
    metadata
    |> Map.drop(@identity_keys)
    |> then(fn m -> if external_id, do: Map.put(m, "external_id", external_id), else: m end)
    |> then(fn m -> if held == [], do: m, else: Map.put(m, "previous_slugs", held) end)
  end

  # Each conflict check runs in one Store transaction with its write, so two
  # requests can never both take one slug or one external id.
  defp insert_unless_taken(workspace) do
    %{tenant_id: tenant_id, id: id, slug: slug, external_id: external_id} = workspace

    Store.transaction(fn txn ->
      cond do
        handle_taken?(txn, tenant_id, slug, id, nil) ->
          {:error, :slug_taken}

        external_id_taken?(txn, tenant_id, external_id, nil) ->
          {:error, :external_id_taken}

        true ->
          with {:ok, _} <- insert(txn, workspace), do: add_handle(txn, tenant_id, slug, id)
      end
    end)
  end

  defp insert(txn, workspace) do
    case Store.txn_execute(
           txn,
           """
           INSERT INTO workspaces (id, tenant_id, organization_id, slug, name, description, status, metadata, external_id)
           VALUES (?1, ?2, ?3, ?4, ?5, ?6, 'active', ?7, ?8)
           """,
           [
             workspace.id,
             workspace.tenant_id,
             workspace.organization_id,
             workspace.slug,
             workspace.name,
             workspace.description,
             Jason.encode!(workspace.metadata),
             workspace.external_id
           ]
         ) do
      {:ok, _} = ok -> ok
      {:error, reason} -> {:error, constraint(reason)}
    end
  end

  # The whole update runs on the row as read inside the transaction: the
  # slug, the external id and the metadata are computed from it, checked,
  # and written before any other writer can change it.
  defp write_unless_taken(txn, id, attrs, given_metadata, requested, {evidence_key, opts}) do
    with {:ok, current} <- locked(txn, id),
         {:ok, slug} <- next_slug(current, Map.get(attrs, :slug)),
         {:ok, external_id} <- next_external_id(current, requested),
         :ok <- unless_taken(txn, current, slug, external_id),
         {:ok, held} <- hold_handles(txn, current, slug) do
      updated = %{
        current
        | name: Map.get(attrs, :name, current.name),
          description: Map.get(attrs, :description, current.description),
          slug: slug,
          external_id: external_id,
          metadata: with_identity(given_metadata || current.metadata, external_id, held)
      }

      with {:ok, updated} <- write(txn, updated),
           :ok <-
             if(slug != current.slug,
               do: record_rename(txn, evidence_key, current, updated, opts),
               else: :ok
             ) do
        {:ok, {current, updated}}
      end
    end
  end

  defp locked(txn, id) do
    case Store.txn_query(txn, select_sql() <> " WHERE id = ?1", [id]) do
      {:ok, [row]} -> {:ok, row_to_struct(row)}
      {:ok, []} -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  defp unless_taken(txn, current, slug, external_id) do
    %{tenant_id: tenant_id, id: id} = current
    derived_id = derive_id(tenant_id, slug)
    renamed? = slug != current.slug

    with :ok <-
           if(renamed?, do: rename_target_free(txn, tenant_id, slug, derived_id, id), else: :ok) do
      if external_id != current.external_id and
           external_id_taken?(txn, tenant_id, external_id, id),
         do: {:error, :external_id_taken},
         else: :ok
    end
  end

  # A rename needs a slug no other workspace holds, and an id that holds no
  # rows of its own.
  defp rename_target_free(txn, tenant_id, slug, derived_id, id) do
    cond do
      handle_taken?(txn, tenant_id, slug, derived_id, id) ->
        {:error, :slug_taken}

      derived_id == id ->
        :ok

      true ->
        case rows_under(txn, derived_id) do
          {:ok, false} -> :ok
          {:ok, true} -> {:error, :slug_has_data}
          {:error, _reason} = error -> error
        end
    end
  end

  # The workspace holds its old and new slugs (one written before the handles
  # table may have no row yet). Returns the slugs it held before, oldest first.
  defp hold_handles(txn, current, slug) do
    with {:ok, _} <- add_handle(txn, current.tenant_id, current.slug, current.id),
         {:ok, _} <- add_handle(txn, current.tenant_id, slug, current.id),
         {:ok, rows} <-
           Store.txn_query(
             txn,
             "SELECT slug FROM workspace_handles WHERE workspace_id = ?1 AND slug != ?2 ORDER BY created_at, rowid",
             [current.id, slug]
           ) do
      {:ok, List.flatten(rows)}
    end
  end

  # The external id is bound only where the row has none or the same one and
  # no other active workspace of the tenant holds it, so the write itself can
  # never replace a bound id or bind a held one.
  defp write(txn, updated) do
    case Store.txn_execute(
           txn,
           """
           UPDATE workspaces SET name = ?1, description = ?2, metadata = ?3, slug = ?4, external_id = ?5
           WHERE id = ?6 AND (external_id IS NULL OR external_id = ?5)
             AND (?5 IS NULL OR NOT EXISTS (
               SELECT 1 FROM workspaces holder
               WHERE holder.tenant_id = workspaces.tenant_id AND holder.external_id = ?5
                 AND holder.status = 'active' AND holder.id != workspaces.id))
           """,
           [
             updated.name,
             updated.description,
             Jason.encode!(updated.metadata),
             updated.slug,
             updated.external_id,
             updated.id
           ]
         ) do
      {:ok, 1} -> {:ok, updated}
      {:ok, 0} -> {:error, :not_found}
      {:error, reason} -> {:error, constraint(reason)}
    end
  end

  defp add_handle(txn, tenant_id, slug, id) do
    Store.txn_execute(
      txn,
      "INSERT OR IGNORE INTO workspace_handles (tenant_id, slug, workspace_id) VALUES (?1, ?2, ?3)",
      [tenant_id, slug, id]
    )
  end

  # The unique indexes stand behind the checks above.
  defp constraint(reason) do
    message = if is_binary(reason), do: reason, else: inspect(reason)

    cond do
      message =~ "workspaces.external_id" -> :external_id_taken
      message =~ "workspaces.slug" or message =~ "workspace_handles" -> :slug_taken
      message =~ "workspaces.id" -> :slug_taken
      true -> reason
    end
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

  # Only an active workspace holds an external id; an archived one released it.
  defp external_id_taken?(_txn, _tenant_id, nil, _except_id), do: false

  defp external_id_taken?(txn, tenant_id, external_id, except_id) do
    {:ok, rows} =
      Store.txn_query(
        txn,
        "SELECT 1 FROM workspaces WHERE tenant_id = ?1 AND external_id = ?2 AND id != ?3 " <>
          "AND status = 'active' LIMIT 1",
        [tenant_id, external_id, except_id || ""]
      )

    rows != []
  end

  # Writes to an unregistered "<tenant>:<slug>" id are allowed, so an id can
  # hold rows before any workspace has it. A rename onto that slug would
  # strand them behind the renamed workspace's handle. Only the tables
  # indexed by workspace are asked (@indexed_by_workspace), each by one index
  # lookup, so the check stays short while it holds the Store's one writer.
  defp rows_under(txn, workspace_id) do
    with {:ok, tables} <- Store.txn_query(txn, @indexed_by_workspace, []) do
      tables
      |> List.flatten()
      |> Enum.reject(&(&1 in @own_tables))
      |> Enum.reduce_while({:ok, false}, fn table, _found ->
        case Store.txn_query(txn, ~s(SELECT 1 FROM "#{table}" WHERE workspace_id = ?1 LIMIT 1), [
               workspace_id
             ]) do
          {:ok, [_ | _]} -> {:halt, {:ok, true}}
          {:ok, []} -> {:cont, {:ok, false}}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
    end
  end

  defp rename_evidence_key(id) do
    case get(id) do
      {:ok, workspace} -> evidence_key(workspace)
      _ -> nil
    end
  end

  defp evidence_key(workspace) do
    case Keys.active(workspace.tenant_id, "evidence") do
      {:ok, key} ->
        key

      {:error, reason} ->
        Logger.warning(
          "[Workspace] rename of #{workspace.id} will not be recorded as evidence: #{inspect(reason)}"
        )

        nil
    end
  end

  defp record_rename(_txn, nil, _current, _updated, _opts), do: :ok

  defp record_rename(txn, key, current, updated, opts) do
    actor = opts[:actor] || "system:engine"

    # The action is the one the Authority plug names for this route (a PATCH
    # is a write); what the caller actually held is in the detail.
    {:ok, _entry} =
      Evidence.append_in(txn, key, current.tenant_id, "workspace.renamed", %{
        subject: actor,
        action: "write",
        resource: "optimal://#{current.id}",
        workspace_id: current.id,
        detail: %{
          "from" => current.slug,
          "to" => updated.slug,
          "by" => actor,
          "authority" => opts[:authority] || ["system"]
        }
      })

    :ok
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

  @doc """
  Soft-deletes a workspace by setting `status = 'archived'`. It keeps its
  handles and its external id value; the external id is released, so another
  workspace of the tenant can be bound to it.
  """
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
           w.created_at, w.archived_at, w.metadata, w.external_id, m.role
    FROM workspaces w
    INNER JOIN workspace_members m ON m.workspace_id = w.id
    WHERE m.principal_id = ?1 AND m.ended_at IS NULL AND w.status = 'active'
    ORDER BY w.name
    """

    case Store.raw_query(sql, [principal_id]) do
      {:ok, rows} ->
        {:ok,
         Enum.map(rows, fn row ->
           {ws_row, [role]} = Enum.split(row, 11)
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
    "SELECT id, tenant_id, organization_id, slug, name, description, status, created_at, archived_at, metadata, external_id FROM workspaces"
  end

  defp list_scope(tenant_id, organization_id, status, external_id) do
    {clauses, params} =
      if organization_id,
        do: {["tenant_id = ?1", "organization_id = ?2"], [tenant_id, organization_id]},
        else: {["tenant_id = ?1"], [tenant_id]}

    {clauses, params} =
      if external_id,
        do: {clauses ++ ["external_id = ?#{length(params) + 1}"], params ++ [external_id]},
        else: {clauses, params}

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
         meta_json,
         external_id
       ]) do
    metadata = decode_json(meta_json)

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
      external_id: external_id,
      # The column is the truth; metadata mirrors it for older readers.
      metadata:
        if(external_id,
          do: Map.put(metadata, "external_id", external_id),
          else: Map.delete(metadata, "external_id")
        )
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
