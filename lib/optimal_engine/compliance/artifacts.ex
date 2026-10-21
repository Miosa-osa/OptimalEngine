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
      the directory of the workspace the row is erased with.

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

  @type removed :: %{files: non_neg_integer(), bytes: non_neg_integer()}

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
  """
  @spec remove([artifact()]) :: {:ok, removed()} | {:error, term()}
  def remove(artifacts) when is_list(artifacts) do
    Enum.reduce_while(artifacts, {:ok, %{files: 0, bytes: 0}}, fn artifact, {:ok, acc} ->
      case remove_one(artifact) do
        {:ok, removed} -> {:cont, {:ok, add(acc, removed)}}
        {:error, posix} -> {:halt, {:error, {:artifact_not_removed, kind(artifact), posix}}}
      end
    end)
  end

  defp kind({:checkpoint, _, _, _}), do: :checkpoint
  defp kind({:asset_file, _, _}), do: :asset_file
  defp kind({:asset_copy, _, _, _}), do: :asset_copy

  # ── one file ───────────────────────────────────────────────────────────────

  defp remove_one({:checkpoint, run_id, uri, workspace_id}) do
    case checkpoint_path(run_id, uri) do
      {:ok, path} ->
        remove_below(cache_root(), path, &checkpoint_of?(&1, &2, run_id, workspace_id))

      :error ->
        {:ok, none()}
    end
  end

  defp remove_one({:asset_file, storage_path, workspace_id}) do
    with false <- S3.uri?(storage_path),
         {:ok, assets_dir} <- assets_dir(workspace_id) do
      under(storage_path, [assets_dir], fn relative, path ->
        if Regex.match?(@asset_name, relative),
          do: remove_below(root_dir(), path),
          else: {:ok, none()}
      end)
    else
      _ -> {:ok, none()}
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
      _ -> {:ok, none()}
    end
  end

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

    if found, do: fun.(found, expanded), else: {:ok, none()}
  end

  defp under(_path, _roots, _fun), do: {:ok, none()}

  # Removes the regular file at `path`, which is under `trusted`, if no directory between
  # them is a link. `trusted` itself may be (a temporary directory often is). `verify` gets
  # the path and its size and says whether the file is the one meant.
  defp remove_below(trusted, path, verify \\ fn _path, _size -> true end) do
    trusted = Path.expand(trusted)

    if String.starts_with?(path, trusted <> "/") do
      {directories, [_name]} = path |> Path.relative_to(trusted) |> Path.split() |> Enum.split(-1)

      case real_directories(trusted, directories) do
        :ok -> remove_file(path, verify)
        :skip -> {:ok, none()}
        {:error, posix} -> {:error, posix}
      end
    else
      {:ok, none()}
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
          false -> {:ok, none()}
          {:error, posix} -> {:error, posix}
        end

      {:ok, _other} ->
        {:ok, none()}

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
