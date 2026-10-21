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

  `plan/3` reads what a set of contexts owns; `remove/2` deletes those files and
  `redact/2` rewrites them through `Compliance.Redact`, for a context whose text is
  redacted in place.

  A path in a row is data, and a bundle import writes these rows too, so a file is
  planned only if it is the workspace's own:

    * a regular file, never a link or a directory, and no directory between the Engine
      root and it is a link (every component is looked at without being followed, again
      when the file is removed or rewritten);
    * a markdown file (`.md`) that is this context's: it holds the text intake wrote for the
      context (the body after the frontmatter, byte for byte), or it is named for the
      context's id (the suffix intake gives a name another context held). A file a person
      wrote or edited under the plain name, or one that holds another context's text, is
      theirs;
    * for a cross-reference copy, a markdown file at a name intake gives a copy (the
      primary's name, or that name with the suffix of the context's id when another context
      already held it in the node) that holds the text of the context it was copied from. A
      file of another context or of a person at the same name is not a copy, and a context
      goes with a copy only if it says it is the copy of this one (`metadata.cross_ref_of`),
      never because its row names the same path;
    * a file no other context holds: a row of the same workspace with the same path
      that is not one of the contexts being erased or the copies of their files names it
      too (the index of `path` is not unique, so a legacy or forged row can). The file
      stays, and the row of the erased context goes;
    * strictly inside the directory of the context's workspace
      (`Workspace.Filesystem.path/2`) and so inside the Engine root, never the root or
      the workspace directory itself;
    * not inside the directory of another workspace, which matters for the default
      workspace because its directory is the root that holds the others;
    * not in a hidden directory, `assets`, `architectures` or `tenants` of the workspace.

  Errors name the kind of file and the cause, never the path.
  """

  require Logger

  alias OptimalEngine.Compliance.{Artifacts, Redact}
  alias OptimalEngine.Context
  alias OptimalEngine.Pipeline.Intake.{Address, Writer}
  alias OptimalEngine.Store
  alias OptimalEngine.Workspace.Filesystem

  @typedoc """
  `owned` says which workspace each planned file is in, for the second look `remove/2` and
  `redact/2` take at who else holds it.
  """
  @type plan :: %{
          files: [String.t()],
          wiki_files: [String.t()],
          copy_ids: [String.t()],
          owned: %{String.t() => String.t()}
        }

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

      # A file the row names is the context's own when it is in the workspace's place and
      # is the context's (its text, or its name). Its copies are found from it.
      placed =
        for [id, workspace_id, path, routed_to] <- rows,
            is_binary(path),
            owned?(path, workspace_id, root, workspace_dirs),
            do: {id, workspace_id, path, routed_to, context_body(id)}

      {mine, foreign} =
        Enum.split_with(placed, fn {id, _workspace_id, path, _routed, body} ->
          this_contexts_file?(id, path, body)
        end)

      copies =
        if copies?,
          do:
            for(
              {id, workspace_id, path, routed_to, body} <- mine,
              copy <- copy_paths(tenant_id, workspace_id, id, path, routed_to),
              do: {id, workspace_id, copy, body}
            ),
          else: []

      with {:ok, copies, copy_ids} <- verified_copies(tenant_id, copies, workspace_dirs, root) do
        allowed = Enum.uniq(context_ids ++ copy_ids)

        located =
          for {workspace_id, path} <-
                Enum.uniq(
                  for({_id, ws, path, _routed, _body} <- mine, do: {ws, path}) ++
                    for({_id, ws, path} <- copies, do: {ws, path})
                ),
              file <- [path | sidecars(path)],
              owned?(file, workspace_id, root, workspace_dirs),
              uniq: true,
              do: {workspace_id, Path.expand(file)}

        with {:ok, held} <- held_elsewhere(located, allowed),
             {:ok, wiki_files} <- wiki_files(tenant_id, allowed, root, workspace_dirs) do
          {kept, going} = Enum.split_with(located, &MapSet.member?(held, &1))
          log_left(length(foreign), length(kept))

          {:ok,
           %{
             files: going |> Enum.map(&elem(&1, 1)) |> Enum.uniq(),
             wiki_files: wiki_files,
             copy_ids: copy_ids,
             owned: Map.new(going, fn {workspace_id, file} -> {file, workspace_id} end)
           }}
        end
      end
    end
  end

  @doc """
  Delete the planned files. Stops at the first one that cannot be removed and returns
  `{:error, {:artifact_not_removed, :context_file, posix}}`; a file already gone counts
  as removed.

  With `except:` (the ids of the contexts being erased and the copies of their files) and
  `owned:` (`plan.owned`), the files are looked at once more just before they go, and one
  that a context outside `except` has come to hold stays: the plan was read before the
  objects of the assets were deleted.
  """
  @spec remove([String.t()], keyword()) ::
          {:ok, %{files: non_neg_integer(), bytes: non_neg_integer()}} | {:error, term()}
  def remove(files, opts \\ []) when is_list(files) do
    with {:ok, files} <- not_held(files, opts) do
      remove_each(files)
    end
  end

  defp remove_each(files) do
    each(files, fn file ->
      with :ok <- real_parents(file) do
        case File.lstat(file) do
          {:ok, %{type: :regular, size: size, links: links}} ->
            case File.rm(file) do
              :ok -> {:done, size, links}
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
  @spec redact([String.t()], keyword()) ::
          {:ok, %{files: non_neg_integer(), bytes: non_neg_integer()}} | {:error, term()}
  def redact(files, opts \\ []) when is_list(files) do
    with {:ok, files} <- not_held(files, opts) do
      redact_each(files)
    end
  end

  defp redact_each(files) do
    each(files, fn file ->
      with :ok <- real_parents(file),
           {:ok, %{type: :regular, mode: mode, links: links} = seen} <- File.lstat(file),
           {:ok, text} <- read_same(file, seen),
           redacted = Redact.redact!(text),
           true <- redacted != text,
           :ok <- replace(file, redacted, Bitwise.band(mode, 0o777)) do
        {:done, byte_size(redacted), links}
      else
        {:error, :enoent} -> :skipped
        {:error, posix} when is_atom(posix) -> {:error, posix}
        _unchanged_or_not_a_file -> :skipped
      end
    end)
  end

  # The text of the file, read through one handle and only if that handle is the regular file
  # `lstat` saw (same device and inode): a link put in its place since is not read.
  defp read_same(file, seen) do
    case File.open(file, [:read, :binary, :raw]) do
      {:ok, fd} ->
        try do
          with {:ok, stat} <- fstat(fd, file),
               true <-
                 stat.type == :regular and stat.inode == seen.inode and
                   stat.major_device == seen.major_device do
            read_all(fd, stat.size)
          else
            false -> :changed
            {:error, _} = error -> error
          end
        after
          :file.close(fd)
        end

      {:error, _} = error ->
        error
    end
  end

  # The handle's own file information; where the runtime has no call for it, the path's.
  defp fstat(fd, file) do
    if function_exported?(:prim_file, :read_handle_info, 1) do
      case apply(:prim_file, :read_handle_info, [fd]) do
        {:ok, info} -> {:ok, File.Stat.from_record(info)}
        {:error, _} = error -> error
      end
    else
      File.lstat(file)
    end
  end

  defp read_all(_fd, 0), do: {:ok, ""}

  defp read_all(fd, size) do
    case :file.read(fd, size) do
      {:ok, data} -> {:ok, data}
      :eof -> {:ok, ""}
      {:error, _} = error -> error
    end
  end

  # The new text goes into a file created for it (exclusively, under a name nobody can
  # guess, so no link left at that name is written through) and takes the place of `file`.
  # The old inode is never written to, so another name for it keeps its content.
  defp replace(file, text, mode) do
    tmp = file <> ".tmp-redact-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

    with :ok <- write_new(tmp, text, mode),
         :ok <- File.rename(tmp, file) do
      :ok
    else
      {:error, :eexist} ->
        {:error, :eexist}

      {:error, reason} ->
        File.rm(tmp)
        {:error, reason}
    end
  end

  # A new file, private until the text is in it, then given the mode of the file it replaces.
  defp write_new(path, text, mode) do
    case :file.open(path, [:write, :exclusive, :binary]) do
      {:ok, io} ->
        written = with :ok <- File.chmod(path, 0o600), do: :file.write(io, text)
        closed = :file.close(io)

        with :ok <- written, :ok <- closed, do: File.chmod(path, mode)

      {:error, reason} ->
        {:error, reason}
    end
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

  # The files intake may have written to each node a signal was routed to. A copy is named
  # after the primary file, and takes the primary's name with the suffix of the signal's id
  # when another context already holds that name in the node (`Address.resolve/5`), so the
  # candidates are those names. Which of them is a copy is decided by what the file holds.
  defp copy_paths(tenant_id, workspace_id, id, path, routed_to) do
    primary_folder = Path.expand(Path.dirname(Path.dirname(path)))
    base = Path.basename(path)

    scope =
      [tenant_id: tenant_id, workspace_id: workspace_id]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    names = [base | Enum.map(Address.candidate_suffixes(id), &Address.suffixed(base, &1))]

    for dest <- decode_list(routed_to),
        is_binary(dest),
        folder = Path.expand(Path.join(root(), Writer.node_to_folder(dest, scope))),
        folder != primary_folder,
        name <- names,
        do: Path.join([folder, "signals", name])
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

  # The copies that are the context's copies, and the contexts that index them. A file at a
  # name intake may have given a copy is one only when it is markdown and holds the text of
  # the context it was copied from, byte for byte after the frontmatter; a file of another
  # context under the plain name (when the copy took a suffixed one), or of a person, is not,
  # and neither is any context that merely names it. The contexts that go with a copy are the
  # rows at its path that say they are the copy of this context (`metadata.cross_ref_of`).
  defp verified_copies(_tenant_id, [], _dirs, _root), do: {:ok, [], []}

  defp verified_copies(tenant_id, copies, dirs, root) do
    verified =
      copies
      |> Enum.filter(fn {_id, workspace_id, path, body} ->
        is_binary(body) and Path.extname(path) == ".md" and
          owned?(path, workspace_id, root, dirs) and file_body(path) == body
      end)
      |> Enum.map(fn {id, workspace_id, path, _body} -> {id, workspace_id, path} end)
      |> Enum.uniq()

    paths = verified |> Enum.map(fn {_id, _ws, path} -> path end) |> Enum.uniq()

    {sql, params} =
      if tenant_id,
        do:
          {"SELECT id, workspace_id, path, CASE WHEN json_valid(metadata) THEN json_extract(metadata, '$.cross_ref_of') END FROM contexts WHERE tenant_id = ?1 AND path IN (SELECT value FROM json_each(?2))",
           [tenant_id, Jason.encode!(paths)]},
        else:
          {"SELECT id, workspace_id, path, CASE WHEN json_valid(metadata) THEN json_extract(metadata, '$.cross_ref_of') END FROM contexts WHERE path IN (SELECT value FROM json_each(?1))",
           [Jason.encode!(paths)]}

    case if(paths == [], do: {:ok, []}, else: Store.raw_query(sql, params)) do
      {:ok, rows} ->
        wanted = MapSet.new(verified)

        ids =
          for [id, workspace_id, path, parent] <- rows,
              MapSet.member?(wanted, {parent, workspace_id, path}),
              uniq: true,
              do: id

        {:ok, verified, ids}

      {:error, reason} ->
        {:error, {:context_files_unreadable, reason}}
    end
  end

  # The page files of the wiki pages `DerivedData` deletes with these contexts: those with
  # a citation to one of their chunks, in the workspace the chunk is in. A chunk row names
  # its workspace and a bundle import writes it verbatim, so the chunk counts only when its
  # workspace is the context's own; a page file of another workspace stays.
  defp wiki_files(tenant_id, context_ids, root, workspace_dirs) do
    {sql, params} =
      if tenant_id,
        do:
          {"""
           SELECT DISTINCT ch.workspace_id, ci.wiki_slug FROM citations ci
             JOIN chunks ch ON ch.id = ci.chunk_id
             JOIN contexts c ON c.id = ch.signal_id AND c.workspace_id = ch.workspace_id
            WHERE ci.tenant_id = ?1
              AND c.id IN (SELECT value FROM json_each(?2))
           """, [tenant_id, Jason.encode!(context_ids)]},
        else:
          {"""
           SELECT DISTINCT ch.workspace_id, ci.wiki_slug FROM citations ci
             JOIN chunks ch ON ch.id = ci.chunk_id
             JOIN contexts c ON c.id = ch.signal_id AND c.workspace_id = ch.workspace_id
            WHERE c.id IN (SELECT value FROM json_each(?1))
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

  # ── is the context's ───────────────────────────────────────────────────────

  # A markdown file that holds the text intake wrote for the context, or whose name carries
  # the suffix of the context's id. The frontmatter has no id, so the text is the proof;
  # the body (title, genre and content) is what identifies it, not the summaries around it.
  defp this_contexts_file?(id, path, body) do
    Path.extname(path) == ".md" and
      (named_for?(id, path) or (is_binary(body) and file_body(path) == body))
  end

  defp named_for?(id, path) do
    name = Path.basename(path)
    Enum.any?(Address.candidate_suffixes(id), &String.ends_with?(name, "-" <> &1 <> ".md"))
  end

  # The body intake writes for the context, from the row as the database holds it, not from
  # the read cache: a rewrite of the row by raw SQL (retention) leaves the cached copy with
  # the old text. nil when the row cannot be read.
  defp context_body(id) do
    with :ok <- Store.evict_cached([id]),
         {:ok, %Context{} = context} <- Store.get_context(id) do
      context |> Context.to_signal() |> Writer.body()
    else
      _ -> nil
    end
  end

  # What follows the frontmatter of a file intake wrote; nil for any other file.
  defp file_body(path) do
    with {:ok, text} <- File.read(path),
         {:ok, body} <- Writer.body_of_file(text) do
      body
    else
      _ -> nil
    end
  end

  # The `{workspace, file}` pairs that a context outside `allowed` also names, whatever way
  # its row spells the path: the rows whose path ends in the name of a file are fetched and
  # compared expanded, so `a/./b` and `a/c/../b` are the same file.
  defp held_elsewhere([], _allowed), do: {:ok, MapSet.new()}

  defp held_elsewhere(located, allowed) do
    workspaces = located |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
    names = located |> Enum.map(fn {_ws, file} -> Path.basename(file) end) |> Enum.uniq()
    wanted = MapSet.new(located)

    case Store.raw_query(
           """
           SELECT workspace_id, path FROM contexts
            WHERE workspace_id IN (SELECT value FROM json_each(?1))
              AND EXISTS (SELECT 1 FROM json_each(?2) n WHERE contexts.path LIKE '%' || n.value)
              AND id NOT IN (SELECT value FROM json_each(?3))
           """,
           [Jason.encode!(workspaces), Jason.encode!(names), Jason.encode!(allowed)]
         ) do
      {:ok, rows} ->
        {:ok,
         for(
           [workspace_id, path] <- rows,
           is_binary(path),
           key = {workspace_id, Path.expand(path)},
           MapSet.member?(wanted, key),
           into: MapSet.new(),
           do: key
         )}

      {:error, reason} ->
        {:error, {:context_files_unreadable, reason}}
    end
  end

  # The second look: files a context outside `except` holds now are dropped from the list.
  defp not_held(files, opts) do
    with except when is_list(except) <- Keyword.get(opts, :except),
         owned when is_map(owned) <- Keyword.get(opts, :owned) do
      located = for file <- files, workspace_id = owned[file], do: {workspace_id, file}

      with {:ok, held} <- held_elsewhere(located, except) do
        {:ok, Enum.reject(files, fn file -> {owned[file], file} in held end)}
      end
    else
      _no_second_look -> {:ok, files}
    end
  end

  # Counts only, never a path.
  defp log_left(0, 0), do: :ok

  defp log_left(foreign, shared) do
    Logger.info(
      "[ContextFiles] left #{foreign} file(s) that are not the context's own " <>
        "and #{shared} that another context holds"
    )
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp each(files, fun) do
    files
    |> Enum.reduce_while({:ok, %{files: 0, bytes: 0, linked: 0}}, fn file, {:ok, acc} ->
      case fun.(file) do
        :skipped ->
          {:cont, {:ok, acc}}

        {:done, bytes, links} ->
          done = %{
            files: acc.files + 1,
            bytes: acc.bytes + bytes,
            linked: acc.linked + if(links > 1, do: 1, else: 0)
          }

          {:cont, {:ok, done}}

        {:error, posix} ->
          {:halt, {:error, {:artifact_not_removed, :context_file, posix}}}
      end
    end)
    |> case do
      {:ok, %{linked: linked} = done} ->
        log_linked(linked)
        {:ok, Map.delete(done, :linked)}

      error ->
        error
    end
  end

  # A file with another name keeps its text under that name: the name the Engine knows is
  # dealt with, the other is not ours to find. Counts only.
  defp log_linked(0), do: :ok

  defp log_linked(linked) do
    Logger.warning(
      "[ContextFiles] #{linked} file(s) have other hard links; the text stays under the other names"
    )
  end

  defp root, do: Path.expand(Application.get_env(:optimal_engine, :root_path, File.cwd!()))
end
