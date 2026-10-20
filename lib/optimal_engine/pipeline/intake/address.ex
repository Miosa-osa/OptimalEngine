defmodule OptimalEngine.Pipeline.Intake.Address do
  @moduledoc """
  The address of a written signal: one file name per context in a folder, and so
  one `optimal://` URI per context in its workspace.

  The URI of a signal is derived from the path of its file
  (`OptimalEngine.URI.from_path/1`), and the file name is
  `{date}-{title slug}.md` with the slug cut to 60 characters. Two contexts
  whose titles agree on those 60 characters and whose dates agree therefore name
  the same file. `contexts.uri` has no unique constraint and a row is replaced
  by id, so the second ingest overwrote the first file while both rows survived
  under one address.

  ## The rule

  A name is *taken* when the folder already holds, for a different context, a
  row with that path or URI, or a file with different bytes. A context takes the
  plain name when it is free. When it is taken, the context takes the name with
  a short suffix of its own id inserted before the extension:

      2026-03-01-weekly-pipeline-review.md
      2026-03-01-weekly-pipeline-review-9f3c01ab.md

  The suffix is the first 8 characters of the id; if that name is taken too, the
  first 16, then 32, then the SHA-256 of the id. The suffix depends on the id
  only, never on a counter or on how many contexts arrived before, so the same
  context ingested with the same id gets the same name on any Engine that holds
  the same earlier names.

  ## Untitled documents

  A title with no letters or digits in it (empty, only symbols, or not Latin)
  and the default `Untitled` all slug to nothing useful, and connectors give
  thousands of documents exactly that title. Such a document never takes the
  plain name: its name always carries the suffix of its id
  (`2026-03-01-untitled-9f3c01ab.md`), so its address is a function of the id
  and needs no lookup to be unique.

  ## Same context, same address

  The row of the context being written is never "another context": a context
  that is ingested again (same id) keeps the file name it already has in that
  folder, whatever its title or date has become since, so an update stays in
  place. So are the rows that index the same file (`file_index_id/1`) and the
  cross-reference copies that carry `metadata.cross_ref_of` set to the id.

  A file with no row is protected by its bytes: it is overwritten only by the
  same text, so a retry of an interrupted write finds its own file again.
  """

  require Logger

  alias OptimalEngine.Signal
  alias OptimalEngine.Store
  alias OptimalEngine.URI

  @suffix_lengths [8, 16, 32]

  @doc """
  The file name `signal` takes in `signals_dir` (an absolute folder).

  `base_name` is the plain name derived from the title and date; `content` is
  the text that will be written, so a file already holding it counts as free.
  `opts` carries the `:workspace_id` the uniqueness is scoped to (default
  `"default"`) and `:always_suffix`, true for an untitled document, which never
  takes the plain name.
  """
  @spec resolve(Signal.t(), String.t(), String.t(), binary(), keyword()) :: String.t()
  def resolve(%Signal{} = signal, signals_dir, base_name, content, opts \\ []) do
    workspace_id = workspace_id(opts)
    id = signal.id || digest(content)

    case kept_name(id, signals_dir, workspace_id) do
      {:ok, name} ->
        name

      :none ->
        choose(
          base_name,
          id,
          fn name -> taken?(Path.join(signals_dir, name), id, workspace_id, content) end,
          always_suffix: Keyword.get(opts, :always_suffix, false)
        )
    end
  end

  @doc """
  The first name for `id` that `taken?` does not refuse: `base_name`, then
  `base_name` with a suffix of the id before the extension. With
  `always_suffix: true` the plain `base_name` is not a candidate.

  Pure: the answer depends on the name, the id and what `taken?` says, and on
  nothing else, so two stores holding the same names answer the same.
  """
  @spec choose(String.t(), String.t(), (String.t() -> boolean()), keyword()) :: String.t()
  def choose(base_name, id, taken?, opts \\ [])
      when is_binary(base_name) and is_function(taken?, 1) do
    suffixed_names = Enum.map(suffixes(id), &suffixed(base_name, &1))

    candidates =
      if Keyword.get(opts, :always_suffix, false),
        do: suffixed_names,
        else: [base_name | suffixed_names]

    Enum.find(candidates, &(not taken?.(&1))) || List.last(candidates)
  end

  @doc "`base_name` with `suffix` before its extension: `a-b.md` and `9f3c01ab` give `a-b-9f3c01ab.md`."
  @spec suffixed(String.t(), String.t()) :: String.t()
  def suffixed(base_name, suffix) do
    extension = Path.extname(base_name)

    stem =
      base_name
      |> String.replace_suffix(extension, "")
      |> String.trim_trailing("-")

    stem <> "-" <> suffix <> extension
  end

  @doc """
  The id the indexer gives the row of a file: the hash of its path. A row with
  this id at its own path indexes the file itself, not another document.
  """
  @spec file_index_id(String.t()) :: String.t()
  def file_index_id(path) when is_binary(path) do
    :crypto.hash(:sha256, path) |> Base.encode16(case: :lower) |> String.slice(0, 32)
  end

  @doc """
  Whether `path`, or the URI derived from it, belongs to a context other than
  `id` in the workspace: a row with that path or URI, or, when no row holds it,
  a file with bytes other than `content`.
  """
  @spec taken?(String.t(), String.t(), String.t(), binary() | nil) :: boolean()
  def taken?(path, id, workspace_id, content) do
    case claim(path, id, workspace_id) do
      :other -> true
      :ours -> false
      :none -> foreign_file?(path, content)
    end
  end

  # -- private ---------------------------------------------------------------

  # A context ingested again keeps its file name in the folder, unless another
  # context holds the same address (rows written before addresses were unique;
  # the repair job separates those).
  defp kept_name(id, signals_dir, workspace_id) do
    with {:ok, [[path]]} when is_binary(path) <-
           query("SELECT path FROM contexts WHERE id = ?1 AND workspace_id = ?2", [
             id,
             workspace_id
           ]),
         true <- Path.dirname(path) == signals_dir,
         :ours <- claim(path, id, workspace_id) do
      {:ok, Path.basename(path)}
    else
      _ -> :none
    end
  end

  # :other when a row of a different document holds the path or the URI; :ours
  # when only rows of this context do; :none when no row holds either.
  defp claim(path, id, workspace_id) do
    uri = URI.from_path(path)

    rows =
      case query(
             """
             SELECT id, path, metadata FROM contexts
             WHERE workspace_id = ?1 AND (path = ?2 OR uri = ?3)
             """,
             [workspace_id, path, uri]
           ) do
        {:ok, rows} -> rows
        _ -> []
      end

    classes =
      Enum.map(rows, fn [row_id, row_path, metadata] -> classify(row_id, row_path, metadata, id) end)

    cond do
      :other in classes -> :other
      :ours in classes -> :ours
      true -> :none
    end
  end

  defp classify(id, _path, _metadata, id), do: :ours

  defp classify(row_id, row_path, metadata, id) do
    cond do
      cross_ref_of(metadata) == id -> :ours
      is_binary(row_path) and row_id == file_index_id(row_path) -> :twin
      true -> :other
    end
  end

  defp cross_ref_of(metadata) when is_binary(metadata) do
    case Jason.decode(metadata) do
      {:ok, %{"cross_ref_of" => id}} -> id
      _ -> nil
    end
  end

  defp cross_ref_of(_metadata), do: nil

  # A file nobody has a row for is another document's unless it holds exactly
  # the text about to be written.
  defp foreign_file?(_path, nil), do: false

  defp foreign_file?(path, content) do
    case File.read(path) do
      {:ok, ^content} -> false
      {:ok, _other} -> true
      {:error, _} -> false
    end
  end

  defp suffixes(id) do
    id = to_string(id)
    clean = id |> String.downcase() |> String.replace(~r/[^a-z0-9]/, "")
    digest = digest(id)
    seed = if clean == "", do: digest, else: clean

    (Enum.map(@suffix_lengths, &String.slice(seed, 0, &1)) ++ [digest]) |> Enum.uniq()
  end

  defp digest(text), do: :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)

  defp workspace_id(opts) do
    case Keyword.get(opts, :workspace_id) do
      id when is_binary(id) and id != "" -> id
      _ -> "default"
    end
  end

  # The Store being unavailable must not stop a write: the file check still
  # refuses to overwrite different text.
  defp query(sql, params) do
    Store.raw_query(sql, params)
  rescue
    error ->
      Logger.warning("[Address] store lookup failed: #{Exception.message(error)}")
      {:error, error}
  catch
    :exit, reason ->
      Logger.warning("[Address] store lookup unavailable: #{inspect(reason)}")
      {:error, reason}
  end
end
