defmodule OptimalEngine.Compliance.Artifacts do
  @moduledoc """
  Files on disk that hold, or stand in for, a workspace's data and that a
  database delete does not reach.

    * Decomposition checkpoints (`<cache_path>/decomposition/<run id>.json`).
      They carry the chunk text of the source package they were made from, and
      the only pointer to one is `decomposition_runs.checkpoint_uri`: delete the
      row first and the file is an orphan nothing will find.
    * The local copy of an object-store asset (`<cache_path>/assets/<object
      key>`), made when a parser needs a file path.
    * The bytes of an asset stored on the local filesystem.

  Two callers use this module. The workspace paths (archive, finalize-move,
  rename, repair, replication) call `purge_workspace/2`, through
  `OptimalEngine.Store.FileCache.Maintenance.purge_workspace/3`, to remove the
  checkpoints and asset copies of a whole workspace. `Compliance.DerivedData`
  calls `remove/1` for the files of the exact rows it deletes with a context.

  A recorded path is data (a bundle import writes these rows too, as they come), so
  a row names a file only as a claim, and a file is removed only when it is exactly
  the file this Engine writes for that row, in the place it writes it, for the
  workspace being erased:

    * a checkpoint is `<cache_path>/decomposition/<run id>.json` with a run id of
      letters, digits, `_` and `-`, the path is the one built from the run id (the
      recorded one has to be the same), and the file itself says it is that run's
      and that workspace's (`run_id` and `workspace_id`). A checkpoint written
      elsewhere (a caller can name a directory), or one that cannot be read back
      as JSON, is left;
    * a local asset is `assets/<xx>/<file>` in the directory of the workspace the
      row is erased with (`Workspace.Filesystem.path/2`), never in another
      workspace's or any other file of the root;
    * an asset copy is under `<cache_path>/assets/<prefix>/<tenant>/<workspace>`,
      the directory of the workspace the row is erased with;
    * an asset object is in the configured bucket, under the prefix its workspace's
      assets are written to, and is never a key with an empty, `.` or `..` segment.
      With no object store configured nothing is deleted. A workspace move deletes
      none, because the assets of the moved workspace still point at them.

  Only regular files are removed, and no directory on the way to one may be a link
  (every component below the Engine root, or the cache path, is looked at with
  `lstat` and must be a real directory), so a link is never followed, in the
  last component or above it.

  The directories removed with a workspace are its object copies, strictly inside
  its tenant's directory of `<cache_path>/assets`: never the tenant's directory, the
  copies of another workspace, `<cache_path>/assets` or the Engine root. A path that
  names anything else is skipped, not followed. Errors name the kind of artifact and
  the cause, never the path.
  """

  require Logger

  alias OptimalEngine.Pipeline.DecompositionRuns
  alias OptimalEngine.Storage.{Assets, S3}
  alias OptimalEngine.Store
  alias OptimalEngine.Workspace.Filesystem

  # A run id is generated; this is what one looks like. The name of a file is built from it.
  @run_id ~r/\A[\w-]+\z/
  @run_id_bytes 200
  # A checkpoint is read to check whose it is; one larger than this is refused rather
  # than held in memory.
  @checkpoint_bytes 256 * 1_048_576
  # Under a workspace's assets directory.
  @asset_name ~r/\A[0-9a-f]{2}\/[^\/]+\z/

  @typedoc """
  What a row claims, with the workspace it is being removed with: the file is removed only if
  it is that workspace's.
  """
  @type artifact ::
          {:checkpoint, run_id :: String.t(), uri :: String.t(), workspace_id :: String.t()}
          | {:asset_file, storage_path :: String.t(), workspace_id :: String.t()}
          | {:asset_copy, storage_path :: String.t(), tenant_id :: String.t(),
             workspace_id :: String.t()}
          | {:asset_object, storage_path :: String.t(), tenant_id :: String.t(),
             workspace_id :: String.t()}

  @type removed :: %{files: non_neg_integer(), bytes: non_neg_integer()}

  @typedoc """
  What `remove/1` left alone, by kind of artifact and reason: `:not_ours` (the row names
  something that is not the file this Engine writes for it, in the place it writes it, for the
  workspace), `:link` (a link is in the way, or is the file) and, for an object, `:not_configured`
  (the Engine has no object store), `:other_bucket` (the row names a bucket other than the
  configured one) and `:outside_prefix` (the key is not under the erased workspace's prefix).
  """
  @type skipped :: %{atom() => %{atom() => pos_integer()}}

  @type plan :: %{artifacts: [artifact()], copy_dirs: [String.t()]}

  @doc """
  What `purge_workspace/1` would remove, read now. Read it before deleting the
  rows that point at the files (a workspace move deletes them first).
  """
  @spec plan(String.t()) :: {:ok, plan()} | {:error, term()}
  def plan(workspace_id) when is_binary(workspace_id) do
    with {:ok, runs} <-
           query(
             "SELECT id, checkpoint_uri FROM decomposition_runs " <>
               "WHERE workspace_id = ?1 AND checkpoint_uri IS NOT NULL AND checkpoint_uri != ''",
             [workspace_id]
           ),
         {:ok, remote} <-
           query(
             "SELECT storage_path, tenant_id FROM assets WHERE workspace_id = ?1 AND storage_path LIKE 's3://%'",
             [workspace_id]
           ),
         {:ok, tenants} <-
           query("SELECT DISTINCT tenant_id FROM workspaces WHERE id = ?1", [workspace_id]) do
      tenants = List.flatten(tenants)

      artifacts =
        Enum.map(runs, fn [run_id, uri] -> {:checkpoint, run_id, uri, workspace_id} end) ++
          for(
            [path, tenant] <- remote,
            tenant in tenants,
            do: {:asset_copy, path, tenant, workspace_id}
          )

      {:ok, %{artifacts: artifacts, copy_dirs: copy_dirs(tenants, workspace_id)}}
    end
  end

  @doc """
  Remove the checkpoints and asset copies of a workspace, and clear the
  checkpoint pointers that remain. `plan` is the result of `plan/1` taken
  before the rows went; without it the plan is read now.
  """
  @spec purge_workspace(String.t(), plan() | nil) :: {:ok, removed()} | {:error, term()}
  def purge_workspace(workspace_id, taken \\ nil)

  def purge_workspace(workspace_id, taken)
      when is_binary(workspace_id) and workspace_id != "" do
    with {:ok, plan} <- taken_or_read(taken, workspace_id),
         {:ok, removed} <- remove(plan.artifacts),
         {:ok, dirs} <- remove_dirs(plan.copy_dirs),
         :ok <- clear_pointers(workspace_id) do
      {:ok, add(removed, dirs)}
    end
  end

  def purge_workspace(_workspace_id, _taken), do: {:error, :invalid_workspace}

  defp taken_or_read(nil, workspace_id), do: plan(workspace_id)
  defp taken_or_read(%{artifacts: _, copy_dirs: _} = plan, _workspace_id), do: {:ok, plan}

  @doc """
  Remove the files of `artifacts`. Stops at the first one that cannot be removed
  and returns `{:error, {:artifact_not_removed, kind, posix}}`; a file that is
  already gone counts as removed.

  A row that names something other than the file this Engine writes for it is left alone,
  and that is counted, not silent: the result carries `skipped` (`t:skipped/0`) when
  anything was left, and a warning with the counts (never a path) is logged, so a run that
  removed less than it was asked to can be seen.
  """
  @spec remove([artifact()]) :: {:ok, removed() | map()} | {:error, term()}
  def remove(artifacts) when is_list(artifacts) do
    artifacts
    |> Enum.reduce_while({:ok, none(), %{}}, fn artifact, {:ok, acc, skipped} ->
      case remove_one(artifact) do
        {:ok, removed} ->
          {:cont, {:ok, add(acc, removed), skipped}}

        {:skip, reason} ->
          {:cont, {:ok, acc, count_skip(skipped, kind(artifact), reason)}}

        {:error, posix} ->
          {:halt, {:error, {:artifact_not_removed, kind(artifact), posix}}}
      end
    end)
    |> finish()
  end

  defp finish({:ok, removed, skipped}) when skipped == %{}, do: {:ok, removed}

  defp finish({:ok, removed, skipped}) do
    Logger.warning(
      "[Artifacts] left alone #{skipped |> Map.values() |> Enum.flat_map(&Map.values/1) |> Enum.sum()} " <>
        "file(s) a row named that are not the Engine's to remove: #{inspect(skipped)}"
    )

    {:ok, Map.put(removed, :skipped, skipped)}
  end

  defp finish({:error, _} = error), do: error

  defp count_skip(skipped, kind, reason),
    do: Map.update(skipped, kind, %{reason => 1}, &Map.update(&1, reason, 1, fn n -> n + 1 end))

  defp kind({:checkpoint, _, _, _}), do: :checkpoint
  defp kind({:asset_file, _, _}), do: :asset_file
  defp kind({:asset_copy, _, _, _}), do: :asset_copy
  defp kind({:asset_object, _, _, _}), do: :asset_object

  # ── one file ───────────────────────────────────────────────────────────────

  defp remove_one({:checkpoint, run_id, uri, workspace_id}) do
    case checkpoint_path(run_id, uri) do
      {:ok, path} ->
        remove_below(cache_root(), path, &checkpoint_of?(&1, &2, run_id, workspace_id))

      :error ->
        {:skip, :not_ours}
    end
  end

  defp remove_one({:asset_file, storage_path, workspace_id}) do
    with false <- S3.uri?(storage_path),
         {:ok, assets_dir} <- assets_dir(workspace_id) do
      under(storage_path, [assets_dir], fn relative, path ->
        if Regex.match?(@asset_name, relative),
          do: remove_below(root_dir(), path),
          else: {:skip, :not_ours}
      end)
    else
      _ -> {:skip, :not_ours}
    end
  end

  defp remove_one({:asset_copy, storage_path, tenant_id, workspace_id}) do
    with true <- S3.uri?(storage_path),
         {:ok, _bucket, key} <- S3.parse_uri(storage_path),
         {:ok, dir} <- copy_dir(tenant_id, workspace_id) do
      under(Path.join(Assets.cache_dir(), key), [dir], fn _relative, path ->
        remove_below(Path.dirname(Assets.cache_dir()), path)
      end)
    else
      _ -> {:skip, :not_ours}
    end
  end

  # An object of the object store this Engine is configured for: in its bucket, and under
  # the prefix this workspace's assets are written to (`Storage.Assets.object_key/1`),
  # never outside it. With no object store configured there is nothing this Engine can
  # delete, and the object is left alone (counted as `not_configured`); a store that is
  # configured but whose settings cannot be read is an error, so the rows stay and the
  # objects are not orphaned. An object is never deleted by a workspace move: the
  # workspace's assets still point at it on the Engine the workspace moved to.
  defp remove_one({:asset_object, storage_path, tenant_id, workspace_id}) do
    with {:ok, bucket, key} <- object_address(storage_path, tenant_id, workspace_id),
         :ok <- object_store(bucket),
         :ok <- object_in_prefix(key, tenant_id, workspace_id) do
      delete_object(key)
    end
  end

  defp object_address(storage_path, tenant_id, workspace_id)
       when is_binary(storage_path) and is_binary(tenant_id) and is_binary(workspace_id) do
    case S3.parse_uri(storage_path) do
      {:ok, bucket, key} -> {:ok, bucket, key}
      {:error, _invalid} -> {:skip, :not_ours}
    end
  end

  defp object_address(_storage_path, _tenant_id, _workspace_id), do: {:skip, :not_ours}

  defp object_store(bucket) do
    case S3.config() do
      {:ok, %{bucket: ^bucket}} -> :ok
      {:ok, _another_bucket} -> {:skip, :other_bucket}
      {:error, :not_configured} -> {:skip, :not_configured}
      {:error, reason} -> {:error, reason}
    end
  end

  defp object_in_prefix(key, tenant_id, workspace_id) do
    if object_of?(key, tenant_id, workspace_id), do: :ok, else: {:skip, :outside_prefix}
  end

  defp delete_object(key) do
    case S3.delete_object(key) do
      :ok ->
        {:ok, %{files: 1, bytes: 0}}

      # A store that answers 404 to a delete of a key or bucket it does not have: the object
      # is gone, and an error here would stop every later run on the same rows.
      {:error, :not_found} ->
        {:ok, none()}

      {:error, reason} ->
        {:error, object_error(reason)}
    end
  end

  defp object_of?(key, tenant_id, workspace_id) do
    prefix = S3.object_key([tenant_id, workspace_id, "assets"]) <> "/"
    rest = String.replace_prefix(key, prefix, "")

    plain?(tenant_id) and plain?(workspace_id) and String.starts_with?(key, prefix) and
      rest != "" and Enum.all?(String.split(rest, "/"), &plain?/1)
  end

  # A name that is one path segment and not a dot.
  defp plain?(name), do: name not in ["", ".", ".."] and not String.contains?(name, "/")

  # What the store said, without its URL, its detail or anything signed.
  defp object_error(:access_denied), do: :access_denied
  defp object_error({:http_error, status, _detail}), do: {:http, status}
  defp object_error({:transport, _reason}), do: :transport
  defp object_error(reason) when is_atom(reason), do: reason
  defp object_error(_reason), do: :object_store_failed

  # The path this Engine builds for the run; the recorded one has to be it.
  defp checkpoint_path(run_id, uri) when is_binary(run_id) and is_binary(uri) do
    expected = Path.join(DecompositionRuns.checkpoint_dir(), run_id <> ".json")

    if byte_size(run_id) <= @run_id_bytes and Regex.match?(@run_id, run_id) and
         not String.contains?(uri, <<0>>) and Path.expand(uri) == expected,
       do: {:ok, expected},
       else: :error
  end

  defp checkpoint_path(_run_id, _uri), do: :error

  # The file says whose it is. A file that cannot be read back as a checkpoint of this run
  # and workspace is not removed; one too large to read is an error, so it is not left
  # behind unseen.
  defp checkpoint_of?(_path, size, _run_id, _workspace_id) when size > @checkpoint_bytes,
    do: {:error, :checkpoint_too_large}

  defp checkpoint_of?(path, _size, run_id, workspace_id) do
    case File.read(path) do
      {:ok, body} ->
        match?(
          {:ok, %{"run_id" => ^run_id, "workspace_id" => ^workspace_id}},
          Jason.decode(body)
        )

      {:error, :enoent} ->
        false

      {:error, posix} ->
        {:error, posix}
    end
  end

  # `<root>/<workspace directory>/assets`, for a workspace whose directory is a visible
  # directory under the root (the default workspace's is the root itself).
  defp assets_dir(workspace_id) when is_binary(workspace_id) and workspace_id != "" do
    root = root_dir()
    dir = Path.expand(Path.join(Filesystem.path(root, workspace_id), "assets"))

    if not String.contains?(workspace_id, <<0>>) and String.starts_with?(dir, root <> "/") and
         not String.starts_with?(Path.relative_to(dir, root), "."),
       do: {:ok, dir},
       else: :error
  end

  defp assets_dir(_workspace_id), do: :error

  # `fun` gets the path relative to the root it is under, and the path. A path that is
  # not strictly under one of `roots` is left alone.
  defp under(path, roots, fun) when is_binary(path) do
    expanded = Path.expand(path)

    found =
      not String.contains?(path, <<0>>) &&
        Enum.find_value(roots, fn root ->
          root = Path.expand(root)
          if String.starts_with?(expanded, root <> "/"), do: Path.relative_to(expanded, root)
        end)

    if found, do: fun.(found, expanded), else: {:skip, :not_ours}
  end

  defp under(_path, _roots, _fun), do: {:skip, :not_ours}

  # Removes the regular file at `path`, which is under `trusted`, if no directory between
  # them is a link. `trusted` itself may be (a temporary directory often is). `verify` gets
  # the path and its size and says whether the file is the one meant.
  defp remove_below(trusted, path, verify \\ fn _path, _size -> true end) do
    trusted = Path.expand(trusted)

    if String.starts_with?(path, trusted <> "/") do
      {directories, [_name]} = path |> Path.relative_to(trusted) |> Path.split() |> Enum.split(-1)

      case real_directories(trusted, directories) do
        :ok -> remove_file(path, verify)
        :skip -> blocked(path)
        {:error, posix} -> {:error, posix}
      end
    else
      {:skip, :not_ours}
    end
  end

  # A directory on the way is missing (the file is not there: nothing to remove), a link
  # (left alone) or not a directory (not ours).
  defp blocked(path) do
    case File.lstat(path) do
      {:error, :enoent} -> {:ok, none()}
      {:error, :enotdir} -> {:skip, :not_ours}
      {:error, posix} -> {:error, posix}
      {:ok, _reached_through_a_link} -> {:skip, :link}
    end
  end

  # Each directory on the way, looked at without following it.
  defp real_directories(_parent, []), do: :ok

  defp real_directories(parent, [name | rest]) do
    directory = Path.join(parent, name)

    case File.lstat(directory) do
      {:ok, %{type: :directory}} -> real_directories(directory, rest)
      {:ok, _link_or_file} -> :skip
      {:error, :enoent} -> :skip
      {:error, posix} -> {:error, posix}
    end
  end

  defp remove_file(path, verify) do
    case File.lstat(path) do
      {:ok, %{type: :regular, size: size}} ->
        case verify.(path, size) do
          true -> rm(path, size)
          false -> {:skip, :not_ours}
          {:error, posix} -> {:error, posix}
        end

      {:ok, %{type: :symlink}} ->
        {:skip, :link}

      {:ok, _other} ->
        {:skip, :not_ours}

      {:error, :enoent} ->
        {:ok, none()}

      {:error, posix} ->
        {:error, posix}
    end
  end

  defp rm(path, size) do
    case File.rm(path) do
      :ok -> {:ok, %{files: 1, bytes: size}}
      {:error, :enoent} -> {:ok, none()}
      {:error, posix} -> {:error, posix}
    end
  end

  # ── directories of asset copies ────────────────────────────────────────────

  # `<cache_path>/assets/<prefix>/<tenant>/<workspace id>`: where a workspace's object
  # copies land when the object key was built from the configured prefix. A key that
  # would leave the cache is not used.
  defp copy_dirs(tenants, workspace_id) do
    for tenant <- tenants, {:ok, dir} <- [copy_dir(tenant, workspace_id)], do: dir
  end

  defp copy_dir(tenant_id, workspace_id)
       when is_binary(tenant_id) and is_binary(workspace_id) and tenant_id != "" and
              workspace_id != "" do
    cache = Path.expand(Assets.cache_dir())
    tenant_dir = Path.expand(Path.join(cache, S3.object_key([tenant_id])))
    dir = Path.expand(Path.join(cache, S3.object_key([tenant_id, workspace_id])))

    if not String.contains?(tenant_id <> workspace_id, <<0>>) and
         String.starts_with?(tenant_dir, cache <> "/") and
         String.starts_with?(dir, tenant_dir <> "/"),
       do: {:ok, dir},
       else: :error
  end

  defp copy_dir(_tenant_id, _workspace_id), do: :error

  defp remove_dirs(dirs) do
    Enum.reduce_while(dirs, {:ok, none()}, fn dir, {:ok, acc} ->
      case remove_copy_dir(dir) do
        {:ok, removed} -> {:cont, {:ok, add(acc, removed)}}
        {:error, posix} -> {:halt, {:error, {:artifact_not_removed, :asset_copy, posix}}}
      end
    end)
  end

  # No directory on the way to it is a link, so the tree removed is the workspace's.
  defp remove_copy_dir(dir) do
    trusted = Path.expand(Path.dirname(Assets.cache_dir()))
    directories = dir |> Path.relative_to(trusted) |> Path.split()

    case real_directories(trusted, directories) do
      :ok -> remove_tree(dir)
      :skip -> {:ok, none()}
      {:error, posix} -> {:error, posix}
    end
  end

  defp remove_tree(path) do
    case File.lstat(path) do
      {:ok, %{type: :directory}} ->
        with {:ok, names} <- File.ls(path),
             {:ok, removed} <- remove_children(path, names),
             :ok <- File.rmdir(path) do
          {:ok, removed}
        end

      {:ok, %{type: :regular, size: size}} ->
        with :ok <- File.rm(path), do: {:ok, %{files: 1, bytes: size}}

      {:ok, _other} ->
        {:ok, none()}

      {:error, :enoent} ->
        {:ok, none()}

      {:error, posix} ->
        {:error, posix}
    end
  end

  defp remove_children(dir, names) do
    Enum.reduce_while(names, {:ok, none()}, fn name, {:ok, acc} ->
      case remove_tree(Path.join(dir, name)) do
        {:ok, removed} -> {:cont, {:ok, add(acc, removed)}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  # ── pointers ───────────────────────────────────────────────────────────────

  # The files are gone; a pointer to one would only mislead.
  defp clear_pointers(workspace_id) do
    case Store.raw_query(
           "UPDATE decomposition_runs SET checkpoint_uri = NULL " <>
             "WHERE workspace_id = ?1 AND checkpoint_uri IS NOT NULL",
           [workspace_id]
         ) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, {:checkpoint_pointers_not_cleared, reason}}
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp query(sql, params) do
    case Store.raw_query(sql, params) do
      {:ok, rows} -> {:ok, rows}
      {:error, reason} -> {:error, {:artifact_plan_unreadable, reason}}
    end
  end

  defp root_dir,
    do: :optimal_engine |> Application.get_env(:root_path, File.cwd!()) |> Path.expand()

  defp cache_root, do: Path.dirname(DecompositionRuns.checkpoint_dir())

  defp none, do: %{files: 0, bytes: 0}

  defp add(%{files: a, bytes: b}, %{files: c, bytes: d}), do: %{files: a + c, bytes: b + d}
end
