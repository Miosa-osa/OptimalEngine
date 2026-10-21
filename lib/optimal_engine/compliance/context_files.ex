defmodule OptimalEngine.Compliance.ContextFiles do
  @moduledoc """
  The files a context was made from, removed with the context.

  Intake writes a signal as a markdown file under its workspace's directory and the
  indexer reads it back, so deleting the row alone leaves the text on disk, and the
  next index brings the context back. A context row names its file in `path`. Three
  things belong with it:

    * the summary sidecars beside the file, `<name>.abstract.md` and `<name>.overview.md`;
    * the cross-reference copies intake writes to the other nodes the signal was routed
      to (`routed_to`), each indexed as a context of its own. They are the same text,
      so erasing a context erases them, and their rows with it;
    * the markdown file of each wiki page that cites one of the contexts' chunks
      (`<workspace>/.wiki/<slug>.md`), because the page row goes with them
      (`Compliance.DerivedData`) and the page is written again from what is left;
    * nothing else: not the node's `context.md`, which collects facts from many
      signals and cannot be attributed to one, and not an asset (`Compliance.Artifacts`).

  `plan/3` reads what a set of contexts owns; `remove/1` deletes those files and
  `redact/1` rewrites them through `Compliance.Redact`, for a context whose text is
  redacted in place.

  A path in a row is data, and a bundle import writes these rows too, so a file is
  planned only if it is the workspace's own:

    * a regular file, never a link or a directory, and no directory between the Engine
      root and it is a link (every component is looked at without being followed, again
      when the file is removed or rewritten);
    * strictly inside the directory of the context's workspace
      (`Workspace.Filesystem.path/2`) and so inside the Engine root, never the root or
      the workspace directory itself;
    * not inside the directory of another workspace, which matters for the default
      workspace because its directory is the root that holds the others;
    * not in a hidden directory, `assets`, `architectures` or `tenants` of the workspace.

  Errors name the kind of file and the cause, never the path.
  """

  alias OptimalEngine.Compliance.{Artifacts, Redact}
  alias OptimalEngine.Pipeline.Intake.Writer
  alias OptimalEngine.Store
  alias OptimalEngine.Workspace.Filesystem

  @type plan :: %{files: [String.t()], wiki_files: [String.t()], copy_ids: [String.t()]}

  @sidecars [".abstract.md", ".overview.md"]
  @not_signal_dirs ["assets", "architectures", "tenants"]

  @doc """
  The files of `context_ids` (of `tenant_id`, or of any tenant when it is nil) and, with
  `copies: true` (the default), the cross-reference copies of their files and the ids of
  the contexts that index those copies.
  """
  @spec plan(String.t() | nil, [String.t()], keyword()) :: {:ok, plan()} | {:error, term()}
  def plan(tenant_id, context_ids, opts \\ []) when is_list(context_ids) do
    copies? = Keyword.get(opts, :copies, true)

    with {:ok, rows} <- contexts(tenant_id, context_ids),
         {:ok, workspace_dirs} <- workspace_dirs() do
      root = root()

      owned =
        for [_id, workspace_id, path, routed_to] <- rows,
            is_binary(path),
            do: {workspace_id, path, routed_to}

      primary = for {workspace_id, path, _routed} <- owned, do: {workspace_id, path}

      copies =
        if copies?,
          do:
            for(
              {ws, path, routed} <- owned,
              copy <- copy_paths(tenant_id, ws, path, routed),
              do: {ws, copy}
            ),
          else: []

      candidates =
        for {workspace_id, path} <- primary ++ copies,
            file <- [path | sidecars(path)],
            do: {workspace_id, file}

      files =
        candidates
        |> Enum.uniq()
        |> Enum.filter(fn {workspace_id, file} ->
          owned?(file, workspace_id, root, workspace_dirs)
        end)
        |> Enum.map(fn {_workspace_id, file} -> Path.expand(file) end)
        |> Enum.uniq()

      with {:ok, copy_ids} <- copy_context_ids(tenant_id, copies, workspace_dirs, root),
           {:ok, wiki_files} <-
             wiki_files(tenant_id, Enum.uniq(context_ids ++ copy_ids), root, workspace_dirs) do
        {:ok, %{files: files, wiki_files: wiki_files, copy_ids: copy_ids}}
      end
    end
  end

  @doc """
  Delete the planned files. Stops at the first one that cannot be removed and returns
  `{:error, {:artifact_not_removed, :context_file, posix}}`; a file already gone counts
  as removed.
  """
  @spec remove([String.t()]) ::
          {:ok, %{files: non_neg_integer(), bytes: non_neg_integer()}} | {:error, term()}
  def remove(files) when is_list(files) do
    each(files, fn file ->
      with :ok <- real_parents(file) do
        case File.lstat(file) do
          {:ok, %{type: :regular, size: size}} ->
            case File.rm(file) do
              :ok -> {:done, size}
              {:error, :enoent} -> :skipped
              {:error, posix} -> {:error, posix}
            end

          {:ok, _other} ->
            :skipped

          {:error, :enoent} ->
            :skipped

          {:error, posix} ->
            {:error, posix}
        end
      end
    end)
  end

  @doc """
  Rewrite the planned files through `Compliance.Redact`, keeping them in place, for a
  context whose text was redacted in the database: the file would otherwise hold the
  original, and an index of the directory would read it back. A file with nothing to
  redact is not written.
  """
  @spec redact([String.t()]) ::
          {:ok, %{files: non_neg_integer(), bytes: non_neg_integer()}} | {:error, term()}
  def redact(files) when is_list(files) do
    each(files, fn file ->
      with :ok <- real_parents(file),
           {:ok, %{type: :regular, mode: mode}} <- File.lstat(file),
           {:ok, text} <- File.read(file),
           redacted = Redact.redact!(text),
           true <- redacted != text,
           tmp = file <> ".tmp-redact-#{System.unique_integer([:positive])}",
           :ok <- File.write(tmp, redacted),
           :ok <- File.chmod(tmp, Bitwise.band(mode, 0o777)),
           :ok <- File.rename(tmp, file) do
        {:done, byte_size(redacted)}
      else
        {:error, :enoent} -> :skipped
        {:error, posix} when is_atom(posix) -> {:error, posix}
        _unchanged_or_not_a_file -> :skipped
      end
    end)
  end

  # ── what is planned ────────────────────────────────────────────────────────

  defp contexts(tenant_id, ids) do
    {sql, params} =
      if tenant_id,
        do:
          {"SELECT id, workspace_id, path, routed_to FROM contexts WHERE tenant_id = ?1 AND id IN (SELECT value FROM json_each(?2))",
           [tenant_id, Jason.encode!(ids)]},
        else:
          {"SELECT id, workspace_id, path, routed_to FROM contexts WHERE id IN (SELECT value FROM json_each(?1))",
           [Jason.encode!(ids)]}

    case Store.raw_query(sql, params) do
      {:ok, rows} -> {:ok, rows}
      {:error, reason} -> {:error, {:context_files_unreadable, reason}}
    end
  end

  # Every workspace's directory, to tell the workspace's own files from those of a
  # workspace that lives inside the default workspace's directory.
  defp workspace_dirs do
    case Store.raw_query("SELECT id FROM workspaces", []) do
      {:ok, rows} ->
        root = root()
        {:ok, rows |> List.flatten() |> Enum.map(&Path.expand(Filesystem.path(root, &1)))}

      {:error, reason} ->
        {:error, {:context_files_unreadable, reason}}
    end
  end

  # The file intake writes to each node a signal was routed to: the same name in that
  # node's signals directory.
  defp copy_paths(tenant_id, workspace_id, path, routed_to) do
    primary_folder = Path.expand(Path.dirname(Path.dirname(path)))

    scope =
      [tenant_id: tenant_id, workspace_id: workspace_id]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    for dest <- decode_list(routed_to),
        is_binary(dest),
        folder = Path.expand(Path.join(root(), Writer.node_to_folder(dest, scope))),
        folder != primary_folder,
        do: Path.join([folder, "signals", Path.basename(path)])
  end

  defp decode_list(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, list} when is_list(list) -> list
      _ -> []
    end
  end

  defp decode_list(list) when is_list(list), do: list
  defp decode_list(_other), do: []

  defp sidecars(path) do
    base = Path.rootname(path)
    Enum.map(@sidecars, &(base <> &1))
  end

  # The contexts that index the copies: same workspace, and a path that passes the same
  # test as the file itself.
  defp copy_context_ids(_tenant_id, [], _dirs, _root), do: {:ok, []}

  defp copy_context_ids(tenant_id, copies, dirs, root) do
    paths = copies |> Enum.map(fn {_ws, path} -> path end) |> Enum.uniq()

    {sql, params} =
      if tenant_id,
        do:
          {"SELECT id, workspace_id, path FROM contexts WHERE tenant_id = ?1 AND path IN (SELECT value FROM json_each(?2))",
           [tenant_id, Jason.encode!(paths)]},
        else:
          {"SELECT id, workspace_id, path FROM contexts WHERE path IN (SELECT value FROM json_each(?1))",
           [Jason.encode!(paths)]}

    case Store.raw_query(sql, params) do
      {:ok, rows} ->
        wanted = MapSet.new(copies)

        ids =
          for [id, workspace_id, path] <- rows,
              MapSet.member?(wanted, {workspace_id, path}),
              owned?(path, workspace_id, root, dirs),
              do: id

        {:ok, ids}

      {:error, reason} ->
        {:error, {:context_files_unreadable, reason}}
    end
  end

  # The page files of the wiki pages `DerivedData` deletes with these contexts: those with
  # a citation to one of their chunks, in the workspace the chunk is in.
  defp wiki_files(tenant_id, context_ids, root, workspace_dirs) do
    {sql, params} =
      if tenant_id,
        do:
          {"""
           SELECT DISTINCT ch.workspace_id, ci.wiki_slug FROM citations ci
             JOIN chunks ch ON ch.id = ci.chunk_id
            WHERE ci.tenant_id = ?1
              AND ch.signal_id IN (SELECT value FROM json_each(?2))
           """, [tenant_id, Jason.encode!(context_ids)]},
        else:
          {"""
           SELECT DISTINCT ch.workspace_id, ci.wiki_slug FROM citations ci
             JOIN chunks ch ON ch.id = ci.chunk_id
            WHERE ch.signal_id IN (SELECT value FROM json_each(?1))
           """, [Jason.encode!(context_ids)]}

    case Store.raw_query(sql, params) do
      {:ok, rows} ->
        files =
          for [workspace_id, slug] <- rows,
              is_binary(workspace_id),
              is_binary(slug),
              plain_name?(slug),
              dir = Path.expand(Filesystem.path(root, workspace_id)),
              file = Path.join([dir, ".wiki", slug <> ".md"]),
              wiki_file?(file, dir, workspace_dirs),
              do: file

        {:ok, Enum.uniq(files)}

      {:error, reason} ->
        {:error, {:context_files_unreadable, reason}}
    end
  end

  defp plain_name?(name),
    do: name not in ["", ".", ".."] and not String.contains?(name, ["/", <<0>>])

  defp wiki_file?(file, dir, workspace_dirs) do
    (dir == root() or inside?(dir, root())) and regular?(file) and
      not in_another_workspace?(file, dir, workspace_dirs)
  end

  # ── whose a file is ────────────────────────────────────────────────────────

  defp owned?(path, workspace_id, root, workspace_dirs)
       when is_binary(path) and is_binary(workspace_id) do
    expanded = Path.expand(path)
    dir = Path.expand(Filesystem.path(root, workspace_id))

    not String.contains?(path, <<0>>) and inside?(expanded, dir) and
      (dir == root or inside?(dir, root)) and own_area?(Path.relative_to(expanded, dir)) and
      not in_another_workspace?(expanded, dir, workspace_dirs) and regular?(expanded)
  end

  defp owned?(_path, _workspace_id, _root, _dirs), do: false

  # A signal is written to `<node folder>/signals/<name>.md`, with its sidecars. A file a
  # person put in a node's folder and the indexer read is theirs, not the Engine's, and
  # so is anything outside a `signals` directory. The hidden directories and the ones the
  # Engine keeps other things in are not a signal's place either.
  defp own_area?(relative) do
    case Path.split(relative) do
      [first | [_ | _] = rest] ->
        not String.starts_with?(first, ".") and first not in @not_signal_dirs and
          Enum.at(rest, -2, first) == "signals"

      _no_directory ->
        false
    end
  end

  defp in_another_workspace?(path, dir, workspace_dirs) do
    Enum.any?(workspace_dirs, fn other ->
      other != dir and inside?(other, dir) and inside?(path, other)
    end)
  end

  defp inside?(path, dir), do: String.starts_with?(path, dir <> "/")

  defp regular?(path),
    do: match?({:ok, %{type: :regular}}, File.lstat(path)) and real_parents?(path)

  defp real_parents?(path), do: real_parents(path) == :ok

  # Every directory between the root and `path` is a real directory; `:skipped` otherwise,
  # which `each/2` counts as nothing to do. `path` is expanded and inside the root.
  defp real_parents(path) do
    root = root()

    if inside?(path, root) do
      {directories, _name} = path |> Path.relative_to(root) |> Path.split() |> Enum.split(-1)

      case Artifacts.real_directories(root, directories) do
        :ok -> :ok
        :skip -> :skipped
        {:error, _} = error -> error
      end
    else
      :skipped
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp each(files, fun) do
    Enum.reduce_while(files, {:ok, %{files: 0, bytes: 0}}, fn file, {:ok, acc} ->
      case fun.(file) do
        :skipped -> {:cont, {:ok, acc}}
        {:done, bytes} -> {:cont, {:ok, %{files: acc.files + 1, bytes: acc.bytes + bytes}}}
        {:error, posix} -> {:halt, {:error, {:artifact_not_removed, :context_file, posix}}}
      end
    end)
  end

  defp root, do: Path.expand(Application.get_env(:optimal_engine, :root_path, File.cwd!()))
end
