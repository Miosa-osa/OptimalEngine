defmodule OptimalEngine.Imports.Notion.Plan do
  @moduledoc """
  Plans a Notion export from its file paths alone: which files are pages,
  databases and assets, the id of each page, and its parent.

  A Notion export (Settings, Export, Markdown and CSV) names every page,
  database and folder after its title followed by the 32 hex id Notion gives
  it (`Roadmap 0123...cdef.md`). A page's children sit in a folder of the same
  name (`Roadmap 0123...cdef/`); a database is a CSV (`Tasks <id>.csv`, and
  `Tasks <id>_all.csv` with every property when the view hides some) whose
  row pages sit in its folder.

  The parent of a page or database is the owner of the nearest folder above it
  that belongs to an exported page or database, matched by path and then by the
  id in the folder's name; with none it is a root. A file without an id keeps a
  stable id derived from its path (`path-<hex>`), so re-importing the same
  export finds the same items.

  Pure: no disk, no database.
  """

  @id_suffix ~r/\A(?:(?<name>.*?)\s+)?(?<id>[0-9a-f]{32})\z/
  @all_view ~r/\A(?<base>.*)_all\z/
  @litter ~w(.DS_Store Thumbs.db desktop.ini)

  @type item :: %{
          id: String.t(),
          kind: :page | :database,
          path: String.t(),
          folder: String.t(),
          title: String.t(),
          parent: String.t() | nil,
          file: map()
        }

  @type t :: %{
          items: [item()],
          by_id: %{String.t() => item()},
          by_path: %{String.t() => String.t()},
          assets: non_neg_integer(),
          skipped: non_neg_integer(),
          errors: [map()]
        }

  @doc """
  Plans `files`, each a map with at least `:path` (the entry's UTF-8 name, no
  trailing slash). The rest of each map is kept on the item as `:file`.
  """
  @spec build([map()]) :: t()
  def build(files) do
    {litter, files} = Enum.split_with(files, &litter?(&1.path))

    {pages, rest} = Enum.split_with(files, &(ext(&1.path) == ".md"))
    {csvs, assets} = Enum.split_with(rest, &(ext(&1.path) == ".csv"))

    {databases, view_skips} = databases(csvs)
    {page_items, duplicate_errors} = pages(pages)

    # A page and a database never share a context: on an id clash the
    # database takes a suffixed id. Its folder still belongs to it, since row
    # pages sit there.
    page_ids = MapSet.new(page_items, & &1.id)

    databases =
      Enum.map(databases, fn db ->
        if MapSet.member?(page_ids, db.id), do: %{db | id: db.id <> "-database"}, else: db
      end)

    items = Enum.sort_by(page_items ++ databases, & &1.path)
    folders = Map.new(Enum.sort_by(items, &(&1.kind == :database)), &{&1.folder, &1.id})
    by_id = Map.new(items, &{&1.id, &1})

    items = Enum.map(items, &%{&1 | parent: parent_of(&1, folders, by_id)})
    by_id = Map.new(items, &{&1.id, &1})

    by_path =
      Enum.reduce(items, %{}, fn item, acc ->
        acc
        |> Map.put(item.path, item.id)
        |> then(fn acc ->
          case item.file[:view_paths] do
            paths when is_list(paths) -> Enum.reduce(paths, acc, &Map.put(&2, &1, item.id))
            _ -> acc
          end
        end)
      end)

    %{
      items: items,
      by_id: by_id,
      by_path: by_path,
      assets: length(assets),
      skipped: length(litter) + view_skips,
      errors: duplicate_errors
    }
  end

  @doc "The 32 hex Notion id at the end of a file or folder name, if any."
  @spec id_of(String.t()) :: String.t() | nil
  def id_of(name) do
    base = name |> Path.basename() |> strip_known_ext() |> strip_all_view()

    case Regex.named_captures(@id_suffix, base) do
      %{"id" => id} -> id
      _ -> nil
    end
  end

  @doc "The title a Notion file name carries: the name without its id and extension."
  @spec title_of(String.t()) :: String.t()
  def title_of(path) do
    base = path |> Path.basename() |> strip_known_ext() |> strip_all_view()

    case Regex.named_captures(@id_suffix, base) do
      %{"name" => "", "id" => _} -> "Untitled"
      %{"name" => name} -> String.trim(name)
      _ -> String.trim(base)
    end
  end

  @doc """
  The child pages of a database, keyed by normalized title, for matching CSV
  rows to their row pages.
  """
  @spec row_pages(t(), String.t()) :: %{String.t() => [item()]}
  def row_pages(plan, database_id) do
    plan.items
    |> Enum.filter(&(&1.kind == :page and &1.parent == database_id))
    |> Enum.group_by(&normalize_title(&1.title))
  end

  @doc "A title folded for matching: lower case, letters and digits only."
  @spec normalize_title(String.t()) :: String.t()
  def normalize_title(title) do
    title
    |> String.downcase()
    |> String.replace(~r/[^\p{L}\p{N}]+/u, "")
  end

  # ── databases ──────────────────────────────────────────────────────────

  # One database per id. When both `X <id>.csv` and `X <id>_all.csv` exist,
  # the `_all` view (every property) is read and the other is skipped.
  defp databases(csvs) do
    csvs
    |> Enum.group_by(&(id_of(&1.path) || path_id(strip_all_path(&1.path))))
    |> Enum.map_reduce(0, fn {id, views}, skipped ->
      chosen = Enum.find(views, &all_view?(&1.path)) || hd(Enum.sort_by(views, & &1.path))
      folder = chosen.path |> strip_all_path() |> strip_known_ext()

      item = %{
        id: id,
        kind: :database,
        path: chosen.path,
        folder: folder,
        title: title_of(chosen.path),
        parent: nil,
        file: Map.put(chosen, :view_paths, Enum.map(views, & &1.path))
      }

      {item, skipped + length(views) - 1}
    end)
  end

  # One page per id; a later duplicate is reported, not imported.
  defp pages(pages) do
    pages
    |> Enum.sort_by(& &1.path)
    |> Enum.reduce({[], %{}, []}, fn file, {items, seen, errors} ->
      id = id_of(file.path) || path_id(file.path)

      if Map.has_key?(seen, id) do
        error = %{
          "path" => file.path,
          "reason" => "duplicate_page",
          "detail" => "same id as #{seen[id]}"
        }

        {items, seen, [error | errors]}
      else
        item = %{
          id: id,
          kind: :page,
          path: file.path,
          folder: strip_known_ext(file.path),
          title: title_of(file.path),
          parent: nil,
          file: file
        }

        {[item | items], Map.put(seen, id, file.path), errors}
      end
    end)
    |> then(fn {items, _seen, errors} -> {Enum.reverse(items), Enum.reverse(errors)} end)
  end

  # ── hierarchy ──────────────────────────────────────────────────────────

  defp parent_of(item, folders, by_id) do
    item.path |> Path.dirname() |> owner(item.id, folders, by_id)
  end

  defp owner(".", _self, _folders, _by_id), do: nil

  defp owner(dir, self, folders, by_id) do
    id =
      case Map.get(folders, dir) do
        nil ->
          case id_of(dir) do
            nil -> nil
            id -> if Map.has_key?(by_id, id), do: id
          end

        id ->
          id
      end

    if id && id != self, do: id, else: owner(Path.dirname(dir), self, folders, by_id)
  end

  # ── names ──────────────────────────────────────────────────────────────

  defp litter?(path) do
    String.starts_with?(path, "__MACOSX/") or Path.basename(path) in @litter or
      String.starts_with?(Path.basename(path), "._")
  end

  defp ext(path), do: path |> Path.extname() |> String.downcase()

  # Only the extensions an export gives pages and databases: a folder named
  # "Plan v1.2 <id>" has no extension to strip.
  defp strip_known_ext(name) do
    case name |> Path.extname() |> String.downcase() do
      ext when ext in [".md", ".csv"] -> binary_part(name, 0, byte_size(name) - byte_size(ext))
      _ -> name
    end
  end

  defp all_view?(path), do: Regex.match?(@all_view, strip_known_ext(path))

  defp strip_all_view(base) do
    case Regex.named_captures(@all_view, base) do
      %{"base" => b} -> if Regex.match?(@id_suffix, b), do: b, else: base
      _ -> base
    end
  end

  defp strip_all_path(path) do
    dir = Path.dirname(path)
    base = path |> Path.basename() |> strip_known_ext() |> strip_all_view()
    name = base <> Path.extname(path)
    if dir == ".", do: name, else: dir <> "/" <> name
  end

  @doc "The stable id of a file that carries no Notion id."
  @spec path_id(String.t()) :: String.t()
  def path_id(path) do
    "path-" <> (:crypto.hash(:sha256, path) |> Base.encode16(case: :lower) |> binary_part(0, 24))
  end
end
