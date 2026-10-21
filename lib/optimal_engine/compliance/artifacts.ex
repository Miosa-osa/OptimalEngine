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
  erasure, retention) call `purge_workspace/1`, through
  `OptimalEngine.Store.FileCache.Maintenance.purge_workspace/2`, to remove the
  checkpoints and asset copies of a whole workspace. `Compliance.DerivedData`
  calls `remove/1` for the files of the exact rows it deletes with a context.

  A recorded path is data (a bundle import writes these rows too), so only a file
  of the shape this Engine writes is removed, and only a regular file at the end of
  the path, never a link and never a directory:

    * a checkpoint is named `<run id>.json` and is under the cache path or the
      Engine root;
    * a local asset is `assets/<xx>/<file>` in a workspace directory under the Engine
      root, not any other file of the root, and not another workspace's notes;
    * an asset copy is under `<cache_path>/assets`.

  The directories removed are the object copies of one workspace, strictly inside
  its tenant's directory of `<cache_path>/assets`: never the tenant's directory, the
  copies of another workspace, `<cache_path>/assets` or the Engine root. A path that
  names anything else is skipped, not followed. Errors name the kind of artifact and
  the cause, never the path.
  """

  alias OptimalEngine.Storage.{Assets, S3}
  alias OptimalEngine.Store
  alias OptimalEngine.Store.FileCache

  @type artifact ::
          {:checkpoint, run_id :: String.t(), uri :: String.t()}
          | {:asset_file, storage_path :: String.t()}
          | {:asset_copy, storage_path :: String.t()}

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
             "SELECT storage_path FROM assets WHERE workspace_id = ?1 AND storage_path LIKE 's3://%'",
             [workspace_id]
           ),
         {:ok, tenants} <-
           query("SELECT DISTINCT tenant_id FROM workspaces WHERE id = ?1", [workspace_id]) do
      artifacts =
        Enum.map(runs, fn [run_id, uri] -> {:checkpoint, run_id, uri} end) ++
          Enum.map(remote, fn [path] -> {:asset_copy, path} end)

      {:ok, %{artifacts: artifacts, copy_dirs: copy_dirs(List.flatten(tenants), workspace_id)}}
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

  defp kind({:checkpoint, _, _}), do: :checkpoint
  defp kind({:asset_file, _}), do: :asset_file
  defp kind({:asset_copy, _}), do: :asset_copy

  # ── one file ───────────────────────────────────────────────────────────────

  defp remove_one({:checkpoint, run_id, uri}) do
    if checkpoint?(run_id, uri) do
      under(uri, [FileCache.root(), root_path()], fn _relative, path -> remove_file(path) end)
    else
      {:ok, none()}
    end
  end

  defp remove_one({:asset_file, storage_path}) do
    if S3.uri?(storage_path) do
      {:ok, none()}
    else
      under(storage_path, [root_path()], fn relative, path ->
        if asset_layout?(relative), do: remove_file(path), else: {:ok, none()}
      end)
    end
  end

  defp remove_one({:asset_copy, storage_path}) do
    with true <- S3.uri?(storage_path),
         {:ok, _bucket, key} <- S3.parse_uri(storage_path) do
      under(Path.join(Assets.cache_dir(), key), [Assets.cache_dir()], fn _relative, path ->
        remove_file(path)
      end)
    else
      _ -> {:ok, none()}
    end
  end

  # The file this Engine names for the run.
  defp checkpoint?(run_id, uri) do
    is_binary(run_id) and is_binary(uri) and not String.contains?(uri, <<0>>) and
      Path.basename(uri) == run_id <> ".json"
  end

  # Where `Storage.Assets.local_path/1` puts an asset, relative to the Engine root:
  # the default workspace's directory is the root itself.
  defp asset_layout?(relative) do
    Regex.match?(
      ~r/\A(?:tenants\/[^\/]+\/[^\/]+\/|[^\/]+\/)?assets\/[0-9a-f]{2}\/[^\/]+\z/,
      relative
    ) and
      not String.starts_with?(relative, ".")
  end

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

  defp remove_file(path) do
    case File.lstat(path) do
      {:ok, %{type: :regular, size: size}} ->
        case File.rm(path) do
          :ok -> {:ok, %{files: 1, bytes: size}}
          {:error, :enoent} -> {:ok, none()}
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

  # ── directories of asset copies ────────────────────────────────────────────

  # `<cache_path>/assets/<prefix>/<tenant>/<workspace id>`: where a workspace's object
  # copies land when the object key was built from the configured prefix. A key that
  # would leave the cache is not used.
  defp copy_dirs(tenants, workspace_id) do
    for tenant <- tenants,
        tenant_dir = Path.expand(Path.join(Assets.cache_dir(), S3.object_key([tenant]))),
        dir = Path.expand(Path.join(Assets.cache_dir(), S3.object_key([tenant, workspace_id]))),
        String.starts_with?(tenant_dir, Path.expand(Assets.cache_dir()) <> "/"),
        String.starts_with?(dir, tenant_dir <> "/"),
        do: dir
  end

  defp remove_dirs(dirs) do
    Enum.reduce_while(dirs, {:ok, none()}, fn dir, {:ok, acc} ->
      case remove_tree(dir) do
        {:ok, removed} -> {:cont, {:ok, add(acc, removed)}}
        {:error, posix} -> {:halt, {:error, {:artifact_not_removed, :asset_copy, posix}}}
      end
    end)
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

  defp root_path, do: Application.get_env(:optimal_engine, :root_path, File.cwd!())

  defp none, do: %{files: 0, bytes: 0}

  defp add(%{files: a, bytes: b}, %{files: c, bytes: d}), do: %{files: a + c, bytes: b + d}
end
