defmodule OptimalEngine.Store.FileCache do
  @moduledoc """
  Rebuildable filesystem cache under `:optimal_engine, :cache_path`.

  Every entry belongs to one tenant and workspace, its scope, so deleting or
  erasing a workspace can remove everything the cache holds for it
  (`purge_workspace/1`). Entries live at

      <cache_path>/tenants/<sha256 tenant>/<sha256 workspace>/<namespace>/<xx>/<sha256 key>.bin

  Directory names are digests, so an id never reaches the filesystem as a path.
  A file is named by the digest of its key and holds only `{version, digest,
  value}`: the key (for the embedder, the text that was embedded) is never
  written. Entries are written atomically (temporary file plus rename) and
  carry their digest, so a partially written file can never be returned as a
  hit. Anything unreadable is deleted and reported as a miss: the cache only
  accelerates work, it never holds truth, and deleting the whole directory is
  always safe.

  The embedder uses the `"embeddings"` namespace so identical text is only
  embedded once per model, endpoint and workspace across restarts.

  Entries expire by age (`sweep/1`), and the unpartitioned layout earlier
  versions wrote is removed once (`purge_legacy/0`); both run from
  `OptimalEngine.Store.FileCache.Maintenance`.
  """

  @version 2
  @tenants "tenants"
  # The one namespace the unpartitioned layout was ever written under.
  @legacy_namespaces ["embeddings"]

  @typedoc "Tenant id and workspace id."
  @type scope :: {tenant_id :: String.t(), workspace_id :: String.t()}

  @typedoc "Files and bytes a purge or sweep removed."
  @type removed :: %{files: non_neg_integer(), bytes: non_neg_integer()}

  @doc "Absolute cache root."
  @spec root() :: String.t()
  def root do
    :optimal_engine
    |> Application.get_env(:cache_path, ".optimal/cache")
    |> Path.expand()
  end

  @spec put(scope(), String.t(), binary(), term()) :: :ok | {:error, term()}
  def put(scope, namespace, key, value) when is_binary(key) do
    with {:ok, digest, path} <- entry_path(scope, namespace, key) do
      tmp = "#{path}.tmp-#{System.unique_integer([:positive])}"
      body = :erlang.term_to_binary({@version, digest, value})

      with :ok <- File.mkdir_p(Path.dirname(path)),
           :ok <- File.write(tmp, body),
           :ok <- File.rename(tmp, path) do
        :ok
      else
        {:error, reason} ->
          File.rm(tmp)
          {:error, reason}
      end
    end
  end

  @spec get(scope(), String.t(), binary()) :: {:ok, term()} | :miss | {:error, term()}
  def get(scope, namespace, key) when is_binary(key) do
    with {:ok, digest, path} <- entry_path(scope, namespace, key) do
      case File.read(path) do
        {:ok, body} -> decode(path, digest, body)
        {:error, :enoent} -> :miss
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Return the cached value or compute, cache, and return it. `fun` must
  return `{:ok, value}`; errors are returned uncached. Cache write failures
  never fail the computation.
  """
  @spec fetch(scope(), String.t(), binary(), (-> {:ok, term()} | {:error, term()})) ::
          {:ok, term()} | {:error, term()}
  def fetch(scope, namespace, key, fun) when is_function(fun, 0) do
    case get(scope, namespace, key) do
      {:ok, value} ->
        {:ok, value}

      _miss_or_error ->
        with {:ok, value} <- fun.() do
          _ = put(scope, namespace, key, value)
          {:ok, value}
        end
    end
  end

  @spec delete(scope(), String.t(), binary()) :: :ok | {:error, term()}
  def delete(scope, namespace, key) when is_binary(key) do
    with {:ok, _digest, path} <- entry_path(scope, namespace, key) do
      case File.rm(path) do
        :ok -> :ok
        {:error, :enoent} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc "Delete every entry of a scope in a namespace."
  @spec clear(scope(), String.t()) :: :ok | {:error, term()}
  def clear(scope, namespace) do
    with {:ok, dir} <- scope_dir(scope),
         :ok <- validate_namespace(namespace),
         {:ok, _} <- File.rm_rf(Path.join(dir, namespace)) do
      :ok
    end
  end

  @doc """
  Remove everything the cache holds for a workspace, whichever tenant wrote
  it. This is what workspace deletion, archiving and every erasure path call.
  An id that was never cached is not an error: `{:ok, %{files: 0, bytes: 0}}`.
  """
  @spec purge_workspace(String.t()) :: {:ok, removed()} | {:error, term()}
  def purge_workspace(workspace_id) when is_binary(workspace_id) and workspace_id != "" do
    target = segment(workspace_id)

    result =
      for tenant <- tenant_dirs(),
          dir = Path.join(tenant, target),
          directory?(dir),
          do: dir

    result
    |> remove_trees()
    |> tap(fn _ -> Enum.each(tenant_dirs(), &File.rmdir/1) end)
  end

  def purge_workspace(_workspace_id), do: {:error, :invalid_workspace}

  @doc """
  Remove entries last written more than `max_age_seconds` ago, and empty
  directories. A hit does not extend an entry's life: the age is the time
  since it was computed, so retention is a bound, not a recency rule.

  Only what this module wrote is touched: a file goes only at
  `tenants/<64 hex>/<64 hex>/<namespace>/<2 hex>/<64 hex>.bin`, or as the
  temporary file of a write that did not finish. A cache path that is also a
  directory holding other files loses none of them.
  """
  @spec sweep(pos_integer()) :: removed()
  def sweep(max_age_seconds) when is_integer(max_age_seconds) and max_age_seconds > 0 do
    cutoff = System.os_time(:second) - max_age_seconds

    removed =
      Enum.reduce(shard_dirs(), %{files: 0, bytes: 0}, fn shard, acc ->
        shard
        |> files(&entry_or_tmp?/1)
        |> Enum.reduce(acc, fn path, acc ->
          case File.stat(path, time: :posix) do
            {:ok, %{type: :regular, mtime: mtime, size: size}} when mtime < cutoff ->
              if File.rm(path) == :ok, do: add(acc, 1, size), else: acc

            _ ->
              acc
          end
        end)
      end)

    prune_empty_dirs()
    removed
  end

  @doc """
  Remove the unpartitioned layout earlier versions wrote,
  `<cache_path>/embeddings/<xx>/<sha256>.bin`.

  Those files held the embedded text in the clear and are not attributable to
  a workspace, so they cannot be purged with one. A cache is recomputable, so
  they are dropped. Only files of that exact shape are touched. Returns what
  was removed; nothing left to remove is `{:ok, %{files: 0, bytes: 0}}`.
  """
  @spec purge_legacy() :: {:ok, removed()} | {:error, term()}
  def purge_legacy do
    shards =
      for namespace <- @legacy_namespaces,
          shard <- subdirs(Path.join(root(), namespace), &shard?/1),
          do: shard

    result =
      Enum.reduce_while(shards, {:ok, %{files: 0, bytes: 0}}, fn shard, acc ->
        shard
        |> files(&entry_or_tmp?/1)
        |> Enum.reduce_while(acc, fn path, {:ok, removed} ->
          case remove_file(path) do
            {:ok, bytes} -> {:cont, {:ok, add(removed, 1, bytes)}}
            :gone -> {:cont, {:ok, removed}}
            {:error, reason} -> {:halt, {:error, {:legacy_purge_failed, reason, path}}}
          end
        end)
        |> case do
          {:ok, _} = ok -> {:cont, ok}
          error -> {:halt, error}
        end
      end)

    for namespace <- @legacy_namespaces do
      namespace_dir = Path.join(root(), namespace)
      Enum.each(subdirs(namespace_dir, &shard?/1), &File.rmdir/1)
      File.rmdir(namespace_dir)
    end

    result
  end

  @doc "Entry count and bytes per namespace, across every scope."
  @spec stats() :: %{String.t() => %{entries: non_neg_integer(), bytes: non_neg_integer()}}
  def stats do
    Enum.reduce(shard_dirs(), %{}, fn shard, acc ->
      namespace = shard |> Path.dirname() |> Path.basename()
      entries = files(shard, &entry?/1)
      bytes = entries |> Enum.map(&file_size/1) |> Enum.sum()

      Map.update(
        acc,
        namespace,
        %{entries: length(entries), bytes: bytes},
        &%{entries: &1.entries + length(entries), bytes: &1.bytes + bytes}
      )
    end)
    |> Map.reject(fn {_namespace, %{entries: entries}} -> entries == 0 end)
  end

  defp decode(path, digest, body) do
    case safe_binary_to_term(body) do
      {:ok, {@version, ^digest, value}} ->
        {:ok, value}

      _ ->
        File.rm(path)
        :miss
    end
  end

  defp safe_binary_to_term(body) do
    {:ok, :erlang.binary_to_term(body, [:safe])}
  rescue
    ArgumentError -> :error
  end

  defp entry_path(scope, namespace, key) do
    with {:ok, dir} <- scope_dir(scope),
         :ok <- validate_namespace(namespace) do
      digest = digest(key)
      {:ok, digest, Path.join([dir, namespace, binary_part(digest, 0, 2), digest <> ".bin"])}
    end
  end

  defp scope_dir({tenant_id, workspace_id})
       when is_binary(tenant_id) and tenant_id != "" and is_binary(workspace_id) and
              workspace_id != "" do
    {:ok, Path.join([root(), @tenants, segment(tenant_id), segment(workspace_id)])}
  end

  defp scope_dir(scope), do: {:error, {:invalid_scope, scope}}

  defp segment(id), do: digest(id)

  defp digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp validate_namespace(namespace) when is_binary(namespace) do
    if namespace?(namespace),
      do: :ok,
      else: {:error, {:invalid_namespace, namespace}}
  end

  defp validate_namespace(namespace), do: {:error, {:invalid_namespace, namespace}}

  # ── layout ─────────────────────────────────────────────────────────────────
  #
  # The tree is walked directory by directory, never globbed: a glob would read
  # the characters of `cache_path` (`[`, `*`, `?`, `{`) as a pattern and match
  # nothing, so a purge would report a clean workspace that it never touched.
  # Every level is also checked by name, so only what this module wrote is
  # listed.

  defp tenant_dirs, do: subdirs(Path.join(root(), @tenants), &hex64?/1)

  defp scope_dirs, do: Enum.flat_map(tenant_dirs(), fn dir -> subdirs(dir, &hex64?/1) end)

  defp namespace_dirs, do: Enum.flat_map(scope_dirs(), fn dir -> subdirs(dir, &namespace?/1) end)

  defp shard_dirs, do: Enum.flat_map(namespace_dirs(), fn dir -> subdirs(dir, &shard?/1) end)

  defp hex64?(name), do: Regex.match?(~r/\A[0-9a-f]{64}\z/, name)

  defp shard?(name), do: Regex.match?(~r/\A[0-9a-f]{2}\z/, name)

  defp namespace?(name), do: Regex.match?(~r/\A[a-z0-9][a-z0-9_-]*\z/, name)

  # `<sha256>.bin`, or the temporary file of a write that did not finish.
  defp entry?(name), do: Regex.match?(~r/\A[0-9a-f]{64}\.bin\z/, name)

  defp entry_or_tmp?(name), do: Regex.match?(~r/\A[0-9a-f]{64}\.bin(\.tmp-\d+)?\z/, name)

  # Subdirectories of `dir` whose names pass `keep?`, as paths. A symbolic link is not
  # followed, and a directory that cannot be listed has none.
  defp subdirs(dir, keep?), do: children(dir, keep?, :directory)

  defp files(dir, keep?), do: children(dir, keep?, :regular)

  defp children(dir, keep?, type) do
    case File.ls(dir) do
      {:ok, names} ->
        for name <- Enum.sort(names),
            keep?.(name),
            path = Path.join(dir, name),
            match?({:ok, %{type: ^type}}, File.lstat(path)),
            do: path

      {:error, _} ->
        []
    end
  end

  defp directory?(path), do: match?({:ok, %{type: :directory}}, File.lstat(path))

  # Count what is there, then remove it. A tree that is only partly removed is
  # an error: the caller reports it rather than claim the workspace is clean.
  defp remove_trees(paths) do
    Enum.reduce_while(paths, {:ok, %{files: 0, bytes: 0}}, fn path, {:ok, acc} ->
      {files, bytes} = measure(path)

      case remove_tree(path) do
        :ok -> {:cont, {:ok, add(acc, files, bytes)}}
        {:error, reason, failed} -> {:halt, {:error, {:purge_failed, reason, failed}}}
      end
    end)
  end

  # Remove a tree without following links, stopping at the first thing that
  # will not go. `File.rm_rf/1` names the directory it could not empty
  # (`:eexist`); this names the entry that refused and why (`:eacces`), the
  # same on every Elixir version.
  defp remove_tree(path) do
    case File.lstat(path) do
      {:ok, %{type: :directory}} -> remove_dir(path)
      {:ok, _} -> removed(File.rm(path), path)
      {:error, reason} -> removed({:error, reason}, path)
    end
  end

  defp remove_dir(path) do
    case File.ls(path) do
      {:ok, names} ->
        with :ok <- remove_children(path, names), do: removed(File.rmdir(path), path)

      {:error, reason} ->
        removed({:error, reason}, path)
    end
  end

  defp remove_children(dir, names) do
    Enum.reduce_while(names, :ok, fn name, :ok ->
      case remove_tree(Path.join(dir, name)) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp removed(:ok, _path), do: :ok
  defp removed({:error, :enoent}, _path), do: :ok
  defp removed({:error, reason}, path), do: {:error, reason, path}

  defp measure(path) do
    case File.lstat(path) do
      {:ok, %{type: :directory}} ->
        case File.ls(path) do
          {:ok, names} ->
            Enum.reduce(names, {0, 0}, fn name, {files, bytes} ->
              {f, b} = measure(Path.join(path, name))
              {files + f, bytes + b}
            end)

          {:error, _} ->
            {0, 0}
        end

      {:ok, %{size: size}} ->
        {1, size}

      {:error, _} ->
        {0, 0}
    end
  end

  # Deepest first, so a directory emptied by removing its children goes too.
  # `File.rmdir/1` refuses a directory that still has entries.
  defp prune_empty_dirs do
    Enum.each(shard_dirs(), &File.rmdir/1)
    Enum.each(namespace_dirs(), &File.rmdir/1)
    Enum.each(scope_dirs(), &File.rmdir/1)
    Enum.each(tenant_dirs(), &File.rmdir/1)
  end

  defp remove_file(path) do
    case File.stat(path) do
      {:ok, %{type: :regular, size: size}} ->
        with :ok <- File.rm(path), do: {:ok, size}

      _ ->
        :gone
    end
  end

  defp add(%{files: files, bytes: bytes}, more_files, more_bytes),
    do: %{files: files + more_files, bytes: bytes + more_bytes}

  defp file_size(path) do
    case File.stat(path) do
      {:ok, %{size: size}} -> size
      _ -> 0
    end
  end
end
