defmodule OptimalEngine.Portability.WorkspaceBundle do
  @moduledoc """
  Moves one workspace between Engines without reindexing: split a workspace
  out of an org Engine into its own Engine, merge it back, or seed a new
  Engine from a snapshot.

  A bundle is a gzip tar file:

      manifest.json            format, versions, workspace, per-table and per-file SHA-256
      tables/<table>.jsonl     every row of the workspace, one JSON object per line
      files/<relative path>    the workspace's directory on disk

  Every table that carries a `workspace_id` column is included, plus child
  rows that hang off them without one, the principals the workspace's
  memberships name, and workspace-scoped operating documents. Connectors,
  their run log and queued jobs stay with the Engine that runs them. Embeddings and
  other binary columns travel as base64, so vectors are copied, not
  recomputed; full-text indexes are filled by the Engine's own triggers as
  rows are inserted. Authority state (keys, packs, grants, evidence) stays
  with the Engine that issued it; replica cursors and metric samples are
  operational and are not moved.

  A bundle is a whole-workspace move and does not follow the data-class gate
  of replication (`OptimalEngine.Sync.Gate`): it carries every row and file,
  restricted ones included, because `finalize_move/4` deletes the source and
  a move that left them behind would lose them. A replica cleared for less
  than the workspace holds must not be seeded from it.

  Import verifies every checksum before writing, rewrites tenant and
  workspace ids to the target, lets integer row ids be reassigned, and
  either refuses an existing workspace (`mode: :create`, default) or keeps
  existing rows (`mode: :merge`). Rows are written in short transactions of
  `:batch_rows` rows (default 1,000), tables in foreign-key order and rows of
  a self-referencing table parents first, so a large workspace never holds
  the single-writer Store long enough to stall the Engine or time out. A
  failed create import removes everything it wrote and the workspace record;
  a failed merge can be run again (it only adds missing rows). `finalize_move/4` then removes the
  workspace from the source Engine and records a redirect, so `optimal://`
  citations keep resolving (`resolve/2`).
  """

  require Logger

  alias OptimalEngine.Authority.CanonicalJSON
  alias OptimalEngine.Store
  alias OptimalEngine.Sync.Capture
  alias OptimalEngine.Workspace
  alias OptimalEngine.Workspace.Filesystem

  @format "optimal-workspace-bundle"
  @version 1

  # Engine bookkeeping that names a workspace but is not its data stays on the
  # source Engine: `Capture.bundle_excluded?/1` says which tables (connectors carry
  # credentials sealed with this Engine's CONNECTOR_KEY and pull on its
  # schedule, so the target registers its own; queued jobs would run twice).

  # Registry rows every Engine derives for itself under the same id: a target
  # that already holds one keeps it.
  @keep_existing ~w(principals model_call_operations)
  @children %{"memory_reconstruction_steps" => {"run_id", "memory_reconstruction_runs"}}
  # Registry tables an export reads by membership and scope, not by a
  # workspace_id column.
  @member_tables ~w(workspace_members node_members)
  @principals "principals"
  @documents "operating_documents"
  @batch_rows 1_000

  @doc """
  Writes a bundle for `workspace_id` to `path`. Returns the manifest.
  """
  @spec export(String.t(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def export(tenant_id, workspace_id, path) do
    with {:ok, workspace} <- Workspace.get(workspace_id),
         true <- workspace.tenant_id == tenant_id || {:error, :not_found} do
      staging = staging_dir()

      try do
        tables = export_tables(tenant_id, workspace_id, staging)
        files = export_files(workspace_id, staging)

        manifest =
          %{
            "format" => @format,
            "version" => @version,
            "engine_version" => engine_version(),
            "migration" => current_migration(),
            "created_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
            "tenant_id" => tenant_id,
            "workspace" => %{
              "id" => workspace.id,
              "slug" => workspace.slug,
              "name" => workspace.name,
              "description" => workspace.description,
              "external_id" => workspace.external_id,
              "metadata" => workspace.metadata
            },
            "tables" => tables,
            "files" => files,
            "ledger_sequence" => ledger_sequence(tenant_id, workspace_id)
          }
          |> then(&Map.put(&1, "bundle_sha256", CanonicalJSON.hash(&1)))

        File.write!(Path.join(staging, "manifest.json"), Jason.encode!(manifest, pretty: true))
        :ok = pack(staging, path)
        {:ok, manifest}
      after
        File.rm_rf(staging)
      end
    end
  end

  @doc """
  Imports a bundle into `tenant_id`. Options: `:workspace_id` (target id;
  default the source id with the target tenant), `:organization_id`,
  `:mode` (`:create` or `:merge`). Returns a summary with the bundle hash.
  """
  @spec import(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def import(path, tenant_id, opts \\ []) do
    staging = staging_dir()

    try do
      with :ok <- unpack(path, staging),
           {:ok, manifest} <- read_manifest(staging),
           :ok <- permitted(manifest),
           :ok <- verify(manifest, staging),
           {:ok, plan} <- plan(manifest, tenant_id, opts),
           :ok <- compatible(manifest, staging),
           {:ok, counts} <- write_rows(manifest, staging, plan, opts),
           {:ok, file_count} <- write_files(manifest, staging, plan) do
        {:ok,
         %{
           workspace_id: plan.workspace_id,
           tenant_id: tenant_id,
           mode: plan.mode,
           rows: counts,
           files: file_count,
           bundle_sha256: manifest["bundle_sha256"],
           source_workspace_id: manifest["workspace"]["id"],
           external_id: plan.external_id,
           imported_external_id: plan.imported_external_id
         }}
      end
    after
      File.rm_rf(staging)
    end
  end

  @doc "Reads and verifies a bundle's manifest without importing it."
  @spec inspect_bundle(String.t()) :: {:ok, map()} | {:error, term()}
  def inspect_bundle(path) do
    staging = staging_dir()

    try do
      with :ok <- unpack(path, staging),
           {:ok, manifest} <- read_manifest(staging),
           :ok <- verify(manifest, staging) do
        {:ok, manifest}
      end
    after
      File.rm_rf(staging)
    end
  end

  @doc """
  Completes a move on the source Engine: removes the workspace's rows and
  files, marks it moved, and records where it went. `bundle_sha256` must be
  the hash the target reported after importing, so nothing is deleted
  until the target holds a verified copy.
  """
  @spec finalize_move(String.t(), String.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def finalize_move(tenant_id, workspace_id, bundle_sha256, %{"target_url" => target_url} = target)
      when is_binary(bundle_sha256) and is_binary(target_url) do
    with {:ok, workspace} <- Workspace.get(workspace_id),
         true <- workspace.tenant_id == tenant_id || {:error, :not_found},
         {:ok, [[expected]]} <-
           Store.raw_query(
             "SELECT bundle_sha256 FROM uri_redirects WHERE tenant_id = ?1 AND workspace_id = ?2 AND state = 'pending'",
             [tenant_id, workspace_id]
           ),
         true <- expected == bundle_sha256 || {:error, :checksum_mismatch} do
      deleted = delete_rows(tenant_id, workspace_id)
      File.rm_rf(Filesystem.path(root(), workspace_id))

      # Only the move keys are written; the archived stub keeps its slugs and
      # its external id value (archiving releases the id itself).
      {:ok, _} =
        Store.raw_query(
          """
          UPDATE workspaces SET status = 'archived',
            metadata = json_set(CASE WHEN json_valid(metadata) THEN metadata ELSE '{}' END,
                                '$.moved_to', ?2, '$.moved_at', ?3)
          WHERE id = ?1
          """,
          [workspace_id, target_url, DateTime.utc_now() |> DateTime.to_iso8601()]
        )

      {:ok, _} =
        Store.raw_query(
          """
          UPDATE uri_redirects SET state = 'moved', target_url = ?3, target_workspace_id = ?4,
            moved_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
          WHERE tenant_id = ?1 AND workspace_id = ?2
          """,
          [tenant_id, workspace_id, target_url, target["target_workspace_id"] || workspace_id]
        )

      {:ok, %{workspace_id: workspace_id, deleted_rows: deleted, target_url: target_url}}
    else
      {:ok, []} -> {:error, :no_pending_export}
      error -> error
    end
  end

  def finalize_move(_tenant_id, _workspace_id, _sha, _target), do: {:error, :target_url_required}

  @doc """
  Records that `workspace_id` was exported for a move, with the bundle hash
  the target must report back before `finalize_move/4` deletes anything.
  """
  @spec prepare_move(String.t(), String.t(), String.t()) :: :ok
  def prepare_move(tenant_id, workspace_id, bundle_sha256) do
    {:ok, _} =
      Store.raw_query(
        """
        INSERT INTO uri_redirects (tenant_id, workspace_id, bundle_sha256, state)
        VALUES (?1, ?2, ?3, 'pending')
        ON CONFLICT(tenant_id, workspace_id) DO UPDATE SET bundle_sha256 = excluded.bundle_sha256, state = 'pending'
        """,
        [tenant_id, workspace_id, bundle_sha256]
      )

    :ok
  end

  @doc """
  Resolves an `optimal://<workspace>/...` address: `{:local, uri}` when this
  Engine serves it, `{:moved, location}` when the workspace moved, or
  `{:error, :not_found}`. An address written with a slug the workspace holds
  now or held before a rename resolves locally to the address by its id.
  """
  @spec resolve(String.t(), String.t()) :: {:local, String.t()} | {:moved, map()} | {:error, atom()}
  def resolve(tenant_id, "optimal://" <> rest = uri) do
    [workspace_id | path] = String.split(rest, "/", parts: 2)

    case Store.raw_query(
           "SELECT target_url, target_workspace_id FROM uri_redirects WHERE tenant_id = ?1 AND workspace_id = ?2 AND state = 'moved'",
           [tenant_id, workspace_id]
         ) do
      {:ok, [[url, target_workspace]]} ->
        {:moved,
         %{
           "engine_url" => url,
           "workspace_id" => target_workspace,
           "uri" => "optimal://" <> Enum.join([target_workspace | path], "/")
         }}

      _ ->
        case Workspace.get(workspace_id) do
          {:ok, %{tenant_id: ^tenant_id}} -> {:local, uri}
          {:error, :not_found} -> resolve_handle(tenant_id, workspace_id, path)
          _ -> {:error, :not_found}
        end
    end
  end

  def resolve(_tenant_id, _uri), do: {:error, :invalid_uri}

  # An address written with a slug names the workspace by its id, which is
  # then resolved as any address by id is: a workspace that moved answers
  # `{:moved, location}`, not local.
  defp resolve_handle(tenant_id, handle, path) do
    with [^tenant_id, slug] <- String.split(handle, ":", parts: 2),
         {:ok, workspace} <- Workspace.get_by_handle(slug, tenant_id) do
      resolve(tenant_id, "optimal://" <> Enum.join([workspace.id | path], "/"))
    else
      _ -> {:error, :not_found}
    end
  end

  # ---------------------------------------------------------------------------
  # Export

  defp export_tables(tenant_id, workspace_id, staging) do
    File.mkdir_p!(Path.join(staging, "tables"))

    scoped =
      for table <- workspace_tables() do
        columns = columns(table)
        {where, params} = scope_clause(table, columns, tenant_id, workspace_id)

        write_table(
          staging,
          table,
          columns,
          "SELECT * FROM #{quote_name(table)} WHERE #{where}",
          params
        )
      end

    children =
      for {table, {fk, parent}} <- @children, table_exists?(table) do
        columns = columns(table)
        parent_columns = columns(parent)
        {where, params} = scope_clause(parent, parent_columns, tenant_id, workspace_id)

        write_table(
          staging,
          table,
          columns,
          "SELECT * FROM #{quote_name(table)} WHERE #{quote_name(fk)} IN (SELECT id FROM #{quote_name(parent)} WHERE #{where})",
          params
        )
      end

    principals =
      write_table(
        staging,
        @principals,
        columns(@principals),
        """
        SELECT * FROM principals WHERE id IN (
          SELECT principal_id FROM workspace_members WHERE workspace_id = ?1
          UNION SELECT principal_id FROM node_members WHERE workspace_id = ?1
        )
        """,
        [workspace_id]
      )

    documents =
      write_table(
        staging,
        @documents,
        columns(@documents),
        "SELECT * FROM operating_documents WHERE tenant_id = ?1 AND scope_type = 'workspace' AND scope_id = ?2",
        [tenant_id, workspace_id]
      )

    Enum.reject(scoped ++ children ++ [principals, documents], &(&1["rows"] == 0))
  end

  defp write_table(staging, table, columns, sql, params) do
    {:ok, rows} = Store.raw_query(sql, params)
    file = Path.join([staging, "tables", table <> ".jsonl"])

    content =
      Enum.map_join(rows, "", fn row ->
        row
        |> Enum.zip(columns)
        |> Map.new(fn {value, {name, _type, _pk}} -> {name, encode_value(value)} end)
        |> Jason.encode!()
        |> Kernel.<>("\n")
      end)

    File.write!(file, content)

    %{
      "name" => table,
      "rows" => length(rows),
      "columns" => Enum.map(columns, &elem(&1, 0)),
      "sha256" => sha256(content)
    }
  end

  defp export_files(workspace_id, staging) do
    source = Filesystem.path(root(), workspace_id)
    target = Path.join(staging, "files")

    if File.dir?(source) and workspace_id != "default" do
      source
      |> Path.join("**")
      |> Path.wildcard(match_dot: true)
      |> Enum.filter(&File.regular?/1)
      |> Enum.map(fn file ->
        relative = Path.relative_to(file, source)
        destination = Path.join(target, relative)
        File.mkdir_p!(Path.dirname(destination))
        File.cp!(file, destination)

        %{
          "path" => relative,
          "bytes" => File.stat!(file).size,
          "sha256" => sha256(File.read!(file))
        }
      end)
      |> Enum.sort_by(& &1["path"])
    else
      []
    end
  end

  # ---------------------------------------------------------------------------
  # Import

  defp read_manifest(staging) do
    with {:ok, json} <- File.read(Path.join(staging, "manifest.json")),
         {:ok, %{"format" => @format, "version" => @version} = manifest} <- Jason.decode(json) do
      {:ok, manifest}
    else
      {:ok, _other} -> {:error, :not_a_workspace_bundle}
      _ -> {:error, :manifest_unreadable}
    end
  end

  @doc """
  Exactly the tables an export can write, and so the only ones an import
  accepts: the workspace's own tables, the child tables read through a parent,
  and the registry tables an export selects by membership or scope (the
  principals of the workspace's members, its operating documents).
  """
  @spec exportable_tables() :: [String.t()]
  def exportable_tables do
    Enum.uniq(workspace_tables() ++ Map.keys(@children) ++ [@principals, @documents])
  end

  # A bundle carries a workspace's data, and only that. Anyone can write one
  # and sign its manifest, so the tables it names are checked against the ones
  # this Engine exports: never a table it keeps for itself (connectors and their
  # credentials, jobs, sync state) and never one the manifest invents.
  #
  # What a bundle may still do within those tables: add rows to the workspace it
  # creates or merges into, and add principals to the importing tenant (every
  # principals row is written with that tenant, and an id the Engine already has
  # keeps its existing row).
  defp permitted(%{"tables" => tables}) when is_list(tables) do
    allowed = exportable_tables()

    refused =
      for table <- tables, name = table_name(table), name not in allowed, do: name

    if refused == [], do: :ok, else: {:error, {:table_not_allowed, Enum.sort(refused)}}
  end

  defp permitted(_manifest), do: {:error, :manifest_unreadable}

  defp table_name(%{"name" => name}) when is_binary(name), do: name
  defp table_name(_table), do: "(unnamed)"

  defp verify(manifest, staging) do
    claimed = manifest["bundle_sha256"]
    recomputed = manifest |> Map.delete("bundle_sha256") |> CanonicalJSON.hash()

    table_ok =
      Enum.all?(manifest["tables"], fn table ->
        case File.read(Path.join([staging, "tables", table["name"] <> ".jsonl"])) do
          {:ok, content} -> sha256(content) == table["sha256"]
          _ -> false
        end
      end)

    files_ok =
      Enum.all?(manifest["files"], fn file ->
        case File.read(Path.join([staging, "files", file["path"]])) do
          {:ok, content} -> sha256(content) == file["sha256"]
          _ -> false
        end
      end)

    cond do
      claimed != recomputed -> {:error, :manifest_checksum_mismatch}
      not table_ok -> {:error, :table_checksum_mismatch}
      not files_ok -> {:error, :file_checksum_mismatch}
      true -> :ok
    end
  end

  defp plan(manifest, tenant_id, opts) do
    with {:ok, requested} <- requested_workspace_id(opts[:workspace_id], tenant_id) do
      plan_target(manifest, tenant_id, Keyword.put(opts, :workspace_id, requested))
    end
  end

  # A workspace id names its tenant (`<tenant>:<slug>`), so a caller that asks
  # for one may not take another tenant's name; a bare slug gets this tenant's.
  defp requested_workspace_id(nil, _tenant_id), do: {:ok, nil}

  defp requested_workspace_id(id, tenant_id) when is_binary(id) do
    case String.split(id, ":", parts: 2) do
      [^tenant_id, slug] when slug != "" -> {:ok, id}
      [_other_tenant, _slug] -> {:error, :workspace_id_not_in_tenant}
      [slug] when slug != "" -> {:ok, tenant_id <> ":" <> slug}
      _blank -> {:error, :invalid_workspace_id}
    end
  end

  defp requested_workspace_id(_id, _tenant_id), do: {:error, :invalid_workspace_id}

  defp plan_target(manifest, tenant_id, opts) do
    source = manifest["workspace"]
    mode = Keyword.get(opts, :mode, :create)
    target_id = opts[:workspace_id] || target_id(source, tenant_id, mode)

    # A renamed workspace keeps its id and its current slug; any other
    # target takes the slug its id names.
    target_slug =
      if target_id == source["id"],
        do: source["slug"],
        else: target_id |> String.split(":", parts: 2) |> List.last()

    case {Workspace.get(target_id), mode} do
      {{:ok, _existing}, :create} ->
        {:error, :workspace_exists}

      {{:ok, existing}, :merge} ->
        if existing.tenant_id == tenant_id,
          do:
            {:ok,
             %{
               workspace_id: target_id,
               tenant_id: tenant_id,
               mode: :merge,
               source: source,
               external_id: existing.external_id,
               imported_external_id: nil
             }},
          else: {:error, :workspace_exists}

      {{:error, :not_found}, _mode} ->
        metadata = source["metadata"] || %{}

        attrs = %{
          id: target_id,
          tenant_id: tenant_id,
          slug: target_slug,
          name: source["name"] || target_slug,
          description: source["description"],
          external_id: source["external_id"] || metadata["external_id"],
          # Slugs the source held are reserved on the source Engine only.
          metadata:
            metadata
            |> Map.drop(["previous_slugs", "external_id"])
            |> Map.put("imported_from", source["id"]),
          organization_id:
            opts[:organization_id] || OptimalEngine.Organization.default_for(tenant_id)
        }

        case create_keeping_external_id(attrs) do
          {:ok, workspace, set_aside} ->
            {:ok,
             %{
               workspace_id: target_id,
               tenant_id: tenant_id,
               mode: mode,
               source: source,
               external_id: workspace.external_id,
               imported_external_id: set_aside
             }}

          error ->
            error
        end
    end
  end

  # An external id names at most one active workspace of a tenant (an
  # archived holder released it), so a copy into a tenant where an active
  # workspace holds it, or a bundle carrying a malformed one, gets none: the
  # copy keeps it as `imported_external_id` and the import summary reports it.
  defp create_keeping_external_id(%{external_id: nil} = attrs) do
    with {:ok, workspace} <- Workspace.create(attrs), do: {:ok, workspace, nil}
  end

  defp create_keeping_external_id(%{external_id: external_id} = attrs) do
    case Workspace.create(attrs) do
      {:ok, workspace} ->
        {:ok, workspace, nil}

      {:error, reason} when reason in [:external_id_taken, :invalid_external_id] ->
        aside = %{
          attrs
          | external_id: nil,
            metadata: Map.put(attrs.metadata, "imported_external_id", external_id)
        }

        with {:ok, workspace} <- Workspace.create(aside), do: {:ok, workspace, external_id}

      error ->
        error
    end
  end

  # A workspace keeps its id when it lands in the tenant it came from and the
  # id is free there (or, for a merge, already the target): a renamed
  # workspace's id is not the one its slug derives, and links name the id.
  # Anywhere else the id derives from the slug, as for a new workspace.
  defp target_id(source, tenant_id, mode) do
    derived =
      if tenant_id == "default",
        do: "default:" <> source["slug"],
        else: "#{tenant_id}:#{source["slug"]}"

    id = source["id"]

    same_tenant? = is_binary(id) and match?([^tenant_id, _slug], String.split(id, ":", parts: 2))

    cond do
      not same_tenant? -> derived
      mode == :merge -> id
      match?({:error, :not_found}, Workspace.get(id)) -> id
      true -> derived
    end
  end

  # The tenant's default organization, created on first use.
  # Every column a bundle carries must exist in the target Engine.
  defp compatible(manifest, _staging) do
    missing =
      for table <- manifest["tables"],
          not table_exists?(table["name"]) or
            table["columns"] -- Enum.map(columns(table["name"]), &elem(&1, 0)) != [] do
        table["name"]
      end

    if missing == [], do: :ok, else: {:error, {:incompatible_tables, missing}}
  end

  defp write_rows(manifest, staging, plan, opts) do
    insert = if plan.mode == :merge, do: "INSERT OR IGNORE", else: "INSERT"
    batch_rows = opts |> Keyword.get(:batch_rows, @batch_rows) |> max(1)
    names = Enum.map(manifest["tables"], & &1["name"])

    # Schema reads go through the Store process, so they happen before any
    # transaction (which runs inside that process).
    drops = Map.new(names, &{&1, autoincrement_key(columns(&1))})
    keys = Map.new(names, &{&1, foreign_keys(&1)})
    column_names = Map.new(names, &{&1, MapSet.new(columns(&1), fn {column, _, _} -> column end)})

    # Every table is checked before any is written, so a refused bundle leaves
    # nothing behind.
    result =
      with :ok <- check_tables(names, staging, column_names, plan) do
        names
        |> parents_first(keys)
        |> Enum.reduce_while({:ok, %{}}, fn name, {:ok, counts} ->
          verb = if name in @keep_existing, do: "INSERT OR IGNORE", else: insert

          rows =
            Path.join([staging, "tables", name <> ".jsonl"])
            |> File.stream!()
            |> Stream.map(&Jason.decode!/1)
            |> Stream.map(&(&1 |> rewrite(name, plan, column_names[name]) |> Map.drop(drops[name])))
            |> self_parents_first(Enum.filter(keys[name], &(&1.table == name)))

          case write_batches(name, rows, verb, batch_rows) do
            {:ok, written} -> {:cont, {:ok, Map.put(counts, name, written)}}
            {:error, reason} -> {:halt, {:error, {:import_failed, name, reason}}}
          end
        end)
      end

    with {:error, _} = error <- result do
      if plan.mode == :create, do: undo_create(plan)
      error
    end
  end

  # Each batch is its own transaction with foreign keys checked at its commit;
  # parents are always written in an earlier batch than their children.
  defp write_batches(name, rows, verb, batch_rows) do
    rows
    |> Stream.chunk_every(batch_rows)
    |> Enum.reduce_while({:ok, 0}, fn batch, {:ok, total} ->
      case write_batch(name, batch, verb) do
        {:ok, written} -> {:cont, {:ok, total + written}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp write_batch(name, batch, verb) do
    Store.transaction(fn txn ->
      {:ok, _} = Store.txn_execute(txn, "PRAGMA defer_foreign_keys = ON", [])

      written =
        Enum.reduce(batch, 0, fn row, count ->
          names = Map.keys(row)

          placeholders =
            names |> Enum.with_index(1) |> Enum.map_join(", ", fn {_, i} -> "?#{i}" end)

          {:ok, changed} =
            Store.txn_execute(
              txn,
              "#{verb} INTO #{quote_name(name)} (#{Enum.map_join(names, ", ", &quote_name/1)}) VALUES (#{placeholders})",
              Enum.map(names, &decode_value(row[&1]))
            )

          count + changed
        end)

      {:ok, written}
    end)
  rescue
    error -> {:error, Exception.message(error)}
  end

  # A failed create import leaves nothing behind: its rows, then the
  # workspace record it made.
  defp undo_create(plan) do
    delete_rows(plan.tenant_id, plan.workspace_id)
    Store.raw_query("DELETE FROM workspaces WHERE id = ?1", [plan.workspace_id])
  rescue
    error ->
      Logger.error(
        "[WorkspaceBundle] could not remove the failed import of #{plan.workspace_id}: #{Exception.message(error)}"
      )
  end

  # Tables a table points at come first; tables outside the bundle and
  # self-references do not constrain the order, and a cycle keeps its tables
  # in bundle order.
  defp parents_first(names, keys) do
    in_bundle = MapSet.new(names)

    deps =
      Map.new(names, fn name ->
        parents =
          for %{table: parent} <- keys[name], parent != name, parent in in_bundle, do: parent

        {name, MapSet.new(parents)}
      end)

    order(names, deps, MapSet.new(), [])
  end

  defp order([], _deps, _placed, acc), do: Enum.reverse(acc)

  defp order(pending, deps, placed, acc) do
    case Enum.split_with(pending, &MapSet.subset?(deps[&1], placed)) do
      {[], [first | rest]} -> order(rest, deps, MapSet.put(placed, first), [first | acc])
      {ready, rest} -> order(rest, deps, Enum.into(ready, placed), Enum.reverse(ready) ++ acc)
    end
  end

  # Rows of a table that points at itself (a memory's parent memory, a node's
  # parent node) are ordered so a parent precedes its children; other tables
  # stream through unchanged.
  defp self_parents_first(rows, []), do: rows

  defp self_parents_first(rows, self_keys) do
    rows = Enum.to_list(rows)
    ids = for row <- rows, key <- self_keys, into: MapSet.new(), do: row[key.to]
    place_rows(rows, self_keys, ids, MapSet.new(), [])
  end

  defp place_rows([], _keys, _ids, _placed, acc), do: Enum.reverse(acc)

  defp place_rows(pending, keys, ids, placed, acc) do
    ready? = fn row ->
      Enum.all?(keys, fn key ->
        parent = row[key.from]
        is_nil(parent) or not MapSet.member?(ids, parent) or MapSet.member?(placed, parent)
      end)
    end

    case Enum.split_with(pending, ready?) do
      {[], [first | rest]} ->
        place_rows(rest, keys, ids, mark(placed, first, keys), [first | acc])

      {ready, rest} ->
        placed = Enum.reduce(ready, placed, &mark(&2, &1, keys))
        place_rows(rest, keys, ids, placed, Enum.reverse(ready) ++ acc)
    end
  end

  defp mark(placed, row, keys), do: Enum.reduce(keys, placed, &MapSet.put(&2, row[&1.to]))

  defp foreign_keys(table) do
    case Store.raw_query(
           "SELECT \"table\", \"from\", \"to\" FROM pragma_foreign_key_list(?1)",
           [table]
         ) do
      {:ok, rows} ->
        Enum.map(rows, fn [parent, from, to] -> %{table: parent, from: from, to: to} end)

      _ ->
        []
    end
  end

  # Every row is written into the importing tenant and the workspace it makes,
  # whatever the bundle says, and whether or not it says anything: a column the
  # table has is always set, so a missing key cannot fall to the column's
  # default. An operating document is always the workspace's, never the tenant's.
  defp rewrite(row, name, plan, columns) do
    row
    |> scope_column(columns, "tenant_id", plan.tenant_id)
    |> scope_column(columns, "workspace_id", plan.workspace_id)
    |> document_scope(name, plan)
  end

  defp scope_column(row, columns, column, value) do
    if MapSet.member?(columns, column), do: Map.put(row, column, value), else: row
  end

  defp document_scope(row, "operating_documents", plan),
    do: row |> Map.put("scope_type", "workspace") |> Map.put("scope_id", plan.workspace_id)

  defp document_scope(row, _name, _plan), do: row

  # What a table's rows may be, checked before any of them is written. Every key
  # must be a column of the table, spelled as the table spells it: SQLite matches
  # column names without regard to case and takes the first of two that match, so
  # a key that only looks like a column could carry a value past `rewrite/4`.
  # And a member of the workspace must be a principal of the importing tenant.
  defp check_tables(names, staging, column_names, plan) do
    Enum.find_value(names, :ok, fn name ->
      path = Path.join([staging, "tables", name <> ".jsonl"])

      with :ok <- check_columns(path, column_names[name]),
           :ok <- if(name in @member_tables, do: check_members(path, plan.tenant_id), else: :ok) do
        nil
      else
        {:error, reason} -> {:error, {:import_failed, name, reason}}
      end
    end)
  end

  defp check_columns(path, columns) do
    known? =
      path
      |> File.stream!()
      |> Enum.all?(fn line ->
        case Jason.decode(line) do
          {:ok, row} when is_map(row) -> Enum.all?(Map.keys(row), &MapSet.member?(columns, &1))
          _not_a_row -> false
        end
      end)

    if known?, do: :ok, else: {:error, :unknown_column}
  end

  defp check_members(path, tenant_id) do
    foreign? =
      path
      |> File.stream!()
      |> Stream.map(&(&1 |> Jason.decode!() |> Map.get("principal_id")))
      |> Stream.reject(&is_nil/1)
      |> Stream.uniq()
      |> Stream.chunk_every(200)
      |> Enum.any?(&principals_of_another_tenant?(&1, tenant_id))

    if foreign?, do: {:error, :foreign_principal}, else: :ok
  end

  defp principals_of_another_tenant?(ids, tenant_id) do
    marks = Enum.map_join(1..length(ids), ", ", &"?#{&1}")

    {:ok, rows} =
      Store.raw_query(
        "SELECT 1 FROM principals WHERE id IN (#{marks}) AND tenant_id != ?#{length(ids) + 1} LIMIT 1",
        ids ++ [tenant_id]
      )

    rows != []
  end

  defp write_files(manifest, staging, plan) do
    target = Filesystem.path(root(), plan.workspace_id)

    Enum.each(manifest["files"], fn file ->
      destination = Path.join(target, file["path"])

      if String.starts_with?(Path.expand(destination), Path.expand(target) <> "/") do
        File.mkdir_p!(Path.dirname(destination))
        File.cp!(Path.join([staging, "files", file["path"]]), destination)
      end
    end)

    {:ok, length(manifest["files"])}
  end

  defp delete_rows(tenant_id, workspace_id) do
    # Statements are planned before the transaction: schema reads go through
    # the Store process the transaction runs in.
    child_statements =
      for {table, {fk, parent}} <- @children, table_exists?(table) do
        {where, params} = scope_clause(parent, columns(parent), tenant_id, workspace_id)

        {"DELETE FROM #{quote_name(table)} WHERE #{quote_name(fk)} IN (SELECT id FROM #{quote_name(parent)} WHERE #{where})",
         params}
      end

    scoped_statements =
      for table <- workspace_tables() do
        {where, params} = scope_clause(table, columns(table), tenant_id, workspace_id)
        {"DELETE FROM #{quote_name(table)} WHERE #{where}", params}
      end

    {:ok, total} =
      Store.transaction(fn txn ->
        {:ok, _} = Store.txn_execute(txn, "PRAGMA defer_foreign_keys = ON", [])

        total =
          Enum.reduce(child_statements ++ scoped_statements, 0, fn {sql, params}, acc ->
            {:ok, n} = Store.txn_execute(txn, sql, params)
            acc + n
          end)

        {:ok, total}
      end)

    total
  end

  # ---------------------------------------------------------------------------
  # Schema helpers

  defp workspace_tables do
    {:ok, rows} =
      Store.raw_query("SELECT name, sql FROM sqlite_master WHERE type = 'table' ORDER BY name", [])

    for [name, sql] <- rows,
        not Capture.bundle_excluded?(name),
        not String.starts_with?(name, "sqlite_"),
        not (is_binary(sql) and String.contains?(sql, "VIRTUAL")),
        not fts_shadow?(name),
        Enum.any?(columns(name), &(elem(&1, 0) == "workspace_id")) do
      name
    end
  end

  defp fts_shadow?(name), do: Regex.match?(~r/_fts_(data|idx|docsize|config|content)\z/, name)

  defp columns(table) do
    {:ok, rows} =
      Store.raw_query("SELECT name, type, pk FROM pragma_table_info(?1) ORDER BY cid", [table])

    Enum.map(rows, fn [name, type, pk] -> {name, String.upcase(type || ""), pk} end)
  end

  defp table_exists?(table) do
    match?(
      {:ok, [_]},
      Store.raw_query("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?1", [table])
    )
  end

  # A single INTEGER PRIMARY KEY is a rowid alias: let the target assign it.
  defp autoincrement_key(columns) do
    case Enum.filter(columns, fn {_name, _type, pk} -> pk > 0 end) do
      [{name, "INTEGER", _}] -> [name]
      _ -> []
    end
  end

  # A table with a tenant column is bound to the tenant. A mention written
  # before it recorded one has none, and belongs to the workspace, which is
  # the tenant's.
  defp scope_clause(table, columns, tenant_id, workspace_id) do
    cond do
      not Enum.any?(columns, &(elem(&1, 0) == "tenant_id")) ->
        {"workspace_id = ?1", [workspace_id]}

      table == "entity_mentions" ->
        {"workspace_id = ?1 AND (tenant_id = ?2 OR tenant_id IS NULL)", [workspace_id, tenant_id]}

      true ->
        {"workspace_id = ?1 AND tenant_id = ?2", [workspace_id, tenant_id]}
    end
  end

  defp quote_name(name) do
    if Regex.match?(~r/\A[A-Za-z_][A-Za-z0-9_]*\z/, name),
      do: ~s("#{name}"),
      else: raise(ArgumentError, "unsafe identifier #{inspect(name)}")
  end

  defp encode_value(value) when is_binary(value) do
    if String.valid?(value), do: value, else: %{"$b64" => Base.encode64(value)}
  end

  defp encode_value(value), do: value

  defp decode_value(%{"$b64" => data}), do: {:blob, Base.decode64!(data)}
  defp decode_value(value), do: value

  # ---------------------------------------------------------------------------
  # Packing

  defp pack(staging, path) do
    File.mkdir_p!(Path.dirname(path))

    entries =
      staging
      |> Path.join("**")
      |> Path.wildcard(match_dot: true)
      |> Enum.filter(&File.regular?/1)
      |> Enum.map(fn file ->
        {String.to_charlist(Path.relative_to(file, staging)), String.to_charlist(file)}
      end)

    :erl_tar.create(String.to_charlist(path), entries, [:compressed])
  end

  defp unpack(path, staging) do
    case :erl_tar.extract(String.to_charlist(path), [
           :compressed,
           {:cwd, String.to_charlist(staging)}
         ]) do
      :ok -> if escaped?(staging), do: {:error, :unsafe_bundle}, else: :ok
      {:error, reason} -> {:error, {:unreadable_bundle, reason}}
    end
  end

  # erl_tar refuses absolute and parent-relative names; still confirm nothing
  # landed outside the staging directory through a link.
  defp escaped?(staging) do
    staging
    |> Path.join("**")
    |> Path.wildcard(match_dot: true)
    |> Enum.any?(fn file ->
      case File.lstat(file) do
        {:ok, %{type: :symlink}} -> true
        _ -> false
      end
    end)
  end

  defp staging_dir do
    dir = Path.join(System.tmp_dir!(), "optimal-bundle-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    dir
  end

  defp root, do: Application.get_env(:optimal_engine, :root_path, File.cwd!())

  defp sha256(content), do: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

  # The replication ledger's high-water mark when the bundle was taken: a
  # replica seeded from this bundle pulls from here.
  defp ledger_sequence(tenant_id, workspace_id) do
    case Store.raw_query(
           "SELECT COALESCE(MAX(sequence), 0) FROM sync_mutations WHERE tenant_id = ?1 AND workspace_id = ?2",
           [tenant_id, workspace_id]
         ) do
      {:ok, [[n]]} -> n
      _ -> 0
    end
  end

  defp engine_version, do: Application.spec(:optimal_engine, :vsn) |> to_string()

  defp current_migration do
    case Store.raw_query("SELECT MAX(version) FROM schema_migrations", []) do
      {:ok, [[n]]} -> n
      _ -> nil
    end
  end
end
