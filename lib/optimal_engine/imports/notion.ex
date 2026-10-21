defmodule OptimalEngine.Imports.Notion do
  @moduledoc """
  Imports a Notion export zip (Markdown and CSV) into one workspace.

  Every page, every database, and every database row the export holds no page
  for becomes one context, written through `OptimalEngine.Pipeline.Intake`
  into the database only (no files), with:

    * a stable id from the Notion id (`source_id` `notion:<id>`), so importing
      the same export again updates each context in place; a page whose title
      and text are unchanged is skipped, not ingested again
    * the URI `optimal://<workspace>/notion/<id>`, which search results and
      RAG citations carry and `GET /api/read?uri=` serves
    * a `child_of` edge to its parent (a page to its parent page, a row to its
      database, a database to the page it sits in) and a `links_to` edge to
      every exported page or database it links to; links in the stored text
      point at the target's URI (`OptimalEngine.Imports.Notion.Links`)

  A re-import replaces the `child_of` and `links_to` edges of the contexts it
  writes, so a page that moved has one parent, not two.

  The archive is read by `OptimalEngine.Imports.Zip` under hard limits; a
  Notion export split into part zips at the archive root is read one level
  deep. Assets (images, files) are counted, not imported. A problem with one
  page is recorded in the report and the import continues; an archive that is
  refused, or an entry that inflates past its declared size, stops it.
  """

  require Logger

  alias OptimalEngine.Graph
  alias OptimalEngine.Imports.Notion.{Database, Links, Plan}
  alias OptimalEngine.Imports.Zip
  alias OptimalEngine.Pipeline.Intake
  alias OptimalEngine.Store

  @child_of "child_of"
  @links_to "links_to"
  @max_errors 200
  @max_roots 50
  @progress_every 25
  @progress_ms 5_000
  @store_backlog 50
  @store_wait_ms 30_000
  @batch 64

  @default_limits %{
    max_entries: 50_000,
    max_total_bytes: 4 * 1024 * 1024 * 1024,
    max_entry_bytes: 64 * 1024 * 1024,
    max_page_bytes: 2 * 1024 * 1024
  }

  # Failures no other attempt can fix: the archive itself is refused.
  @fatal ~w(invalid_zip zip64_unsupported unsafe_path too_many_entries archive_too_large
            entry_size_mismatch empty_export source_missing)a

  @type report :: map()

  @doc "The default limits: entries, total and per-entry bytes, page text bytes."
  @spec default_limits() :: map()
  def default_limits, do: @default_limits

  @doc "The URI of an imported page, database or row."
  @spec uri(String.t(), String.t()) :: String.t()
  def uri(workspace_id, page_id), do: "optimal://#{workspace_id}/notion/#{page_id}"

  @doc "The intake source id of an imported page, database or row."
  @spec source_id(String.t()) :: String.t()
  def source_id(page_id), do: "notion:" <> page_id

  @doc "The context id an imported page, database or row has in a workspace."
  @spec context_id(String.t(), String.t()) :: String.t()
  def context_id(workspace_id, page_id),
    do: Intake.context_id_for_source(workspace_id, source_id(page_id))

  @doc """
  The imported Notion hierarchy of a workspace, one level at a time: the
  contexts whose `child_of` edge points at `parent` (a Notion id), or, with
  `parent` nil, the imported contexts that have no parent. Each carries its
  page id, URI, title and number of children.

  Options: `:limit` (default 500, at most 1,000) and `:offset`. Returns
  `{:error, :not_found}` when `parent` names nothing imported in the workspace.
  """
  @spec tree(String.t(), String.t() | nil, keyword()) :: {:ok, map()} | {:error, term()}
  def tree(workspace_id, parent, opts \\ []) do
    limit = opts |> Keyword.get(:limit, 500) |> max(1) |> min(1_000)
    offset = opts |> Keyword.get(:offset, 0) |> max(0)
    prefix = uri(workspace_id, "")

    children = """
    (SELECT COUNT(*) FROM edges k
     WHERE k.target_id = c.id AND k.relation = 'child_of' AND k.workspace_id = ?1)
    """

    query =
      case parent do
        nil ->
          {:ok,
           Store.raw_query(
             """
             SELECT c.uri, c.title, #{children}
             FROM contexts c
             WHERE c.workspace_id = ?1 AND substr(c.uri, 1, ?3) = ?2
               AND NOT EXISTS (SELECT 1 FROM edges e
                               WHERE e.source_id = c.id AND e.relation = 'child_of'
                                 AND e.workspace_id = ?1)
             ORDER BY c.title, c.uri LIMIT ?4 OFFSET ?5
             """,
             [workspace_id, prefix, String.length(prefix), limit, offset]
           )}

        parent_id ->
          parent_ctx = context_id(workspace_id, parent_id)

          case Store.raw_query("SELECT 1 FROM contexts WHERE id = ?1 AND workspace_id = ?2", [
                 parent_ctx,
                 workspace_id
               ]) do
            {:ok, [_ | _]} ->
              {:ok,
               Store.raw_query(
                 """
                 SELECT c.uri, c.title, #{children}
                 FROM edges e JOIN contexts c ON c.id = e.source_id
                 WHERE e.target_id = ?2 AND e.relation = 'child_of' AND e.workspace_id = ?1
                   AND c.workspace_id = ?1
                 ORDER BY c.title, c.uri LIMIT ?3 OFFSET ?4
                 """,
                 [workspace_id, parent_ctx, limit, offset]
               )}

            {:ok, []} ->
              {:error, :not_found}

            {:error, reason} ->
              {:error, reason}
          end
      end

    with {:ok, {:ok, rows}} <- query do
      {:ok,
       %{
         workspace_id: workspace_id,
         parent: parent && uri(workspace_id, parent),
         pages:
           Enum.map(rows, fn [page_uri, title, count] ->
             %{
               page_id: String.replace_prefix(page_uri, prefix, ""),
               uri: page_uri,
               title: title,
               children: count
             }
           end)
       }}
    else
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "True when a failure reason refuses the archive, so retrying cannot help."
  @spec fatal?(term()) :: boolean()
  def fatal?({reason, _detail}), do: reason in @fatal
  def fatal?(reason), do: reason in @fatal

  @doc """
  Imports the export at `zip_path` into `workspace_id`.

  Options: `:tenant_id`, `:actor_id`, `:work_dir` (where part zips are
  unpacked; default the zip's folder), `:limits` (merged over
  `default_limits/0`), and `:progress`, a function called with the report so
  far every few pages.

  Returns `{:ok, report}` or `{:error, reason}` when the archive is refused.
  """
  @spec import_file(Path.t(), String.t(), keyword()) :: {:ok, report()} | {:error, term()}
  def import_file(zip_path, workspace_id, opts \\ []) do
    limits = Map.merge(@default_limits, Map.new(Keyword.get(opts, :limits, %{})))
    work_dir = Keyword.get(opts, :work_dir) || Path.dirname(zip_path)

    ctx = %{
      workspace_id: workspace_id,
      tenant_id: Keyword.get(opts, :tenant_id, "default"),
      actor_id: Keyword.get(opts, :actor_id, "system:notion-import"),
      limits: limits,
      progress: Keyword.get(opts, :progress, fn _report -> :ok end)
    }

    with {:ok, files, read} <- collect(zip_path, work_dir, limits) do
      plan = Plan.build(files)

      if Enum.any?(plan.items),
        do: run(plan, read, ctx),
        else: {:error, :empty_export}
    end
  end

  # ── reading the archive ────────────────────────────────────────────────

  defp collect(zip_path, work_dir, limits) do
    with {:ok, archive} <- Zip.open(zip_path, Map.take(limits, [:max_entries, :max_total_bytes])) do
      read = %{entries: 0, declared: 0, parts: 0, errors: []}

      archive.entries
      |> Enum.reject(& &1.dir?)
      |> Enum.reduce_while({:ok, [], read}, fn entry, {:ok, files, read} ->
        case outer_entry(entry, archive, work_dir, limits, read) do
          {:ok, new_files, read} -> {:cont, {:ok, new_files ++ files, read}}
          {:error, _} = error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, files, read} -> {:ok, Enum.reverse(files), read}
        error -> error
      end
    end
  end

  defp outer_entry(%{name: nil} = entry, _archive, _work_dir, _limits, read) do
    {:ok, [], invalid_name(entry, read)}
  end

  defp outer_entry(entry, archive, work_dir, limits, read) do
    if part_zip?(entry.name) do
      read_part(entry, archive, work_dir, limits, read)
    else
      {:ok, [file(entry, archive)], count(read, entry)}
    end
  end

  # Notion splits a large export into part zips at the root of the one it
  # hands out. They are unpacked one at a time and read like the outer zip,
  # against the same running limits; a zip anywhere else is an attachment.
  defp read_part(entry, archive, work_dir, limits, read) do
    dest = Path.join(work_dir, "part-#{read.parts + 1}.zip")
    left = %{limits | max_total_bytes: limits.max_total_bytes - read.declared}

    with :ok <- Zip.extract(archive, entry, dest, left.max_total_bytes),
         {:ok, part} <-
           Zip.open(dest, %{
             max_entries: limits.max_entries - read.entries,
             max_total_bytes: left.max_total_bytes
           }) do
      read = %{read | parts: read.parts + 1}

      {files, read} =
        part.entries
        |> Enum.reject(& &1.dir?)
        |> Enum.reduce({[], read}, fn
          %{name: nil} = inner, {files, read} -> {files, invalid_name(inner, read)}
          inner, {files, read} -> {[file(inner, part) | files], count(read, inner)}
        end)

      {:ok, files, read}
    else
      {:error, {:entry_too_large, _}} -> {:error, :archive_too_large}
      {:error, _} = error -> error
    end
  end

  defp part_zip?(name),
    do: not String.contains?(name, "/") and String.downcase(Path.extname(name)) == ".zip"

  defp file(entry, archive), do: %{path: entry.name, entry: entry, archive: archive}

  defp count(read, entry),
    do: %{read | entries: read.entries + 1, declared: read.declared + entry.size}

  defp invalid_name(entry, read) do
    error = %{"path" => Zip.display(entry), "reason" => "invalid_name", "detail" => "not UTF-8"}
    %{read | entries: read.entries + 1, errors: [error | read.errors]}
  end

  # ── the import ─────────────────────────────────────────────────────────

  defp run(plan, read, ctx) do
    {databases, pages} = Enum.split_with(plan.items, &(&1.kind == :database))

    state = %{
      counts: %{
        "entries" => read.entries,
        "parts" => read.parts,
        "pages" => length(pages),
        "databases" => length(databases),
        "rows" => 0,
        "assets" => plan.assets,
        "skipped" => plan.skipped,
        "contexts" => 0,
        "unchanged" => 0,
        "edges_child_of" => 0,
        "edges_links_to" => 0,
        "links_unresolved" => 0,
        "errors" => 0
      },
      errors: [],
      done: 0,
      total: length(plan.items),
      stored: MapSet.new(),
      parents: Map.new(plan.items, &{&1.id, &1.parent}),
      links: %{},
      last_progress: System.monotonic_time(:millisecond)
    }

    state = Enum.reduce(Enum.reverse(read.errors) ++ plan.errors, state, &add_error(&2, &1))

    # The gazetteer intake classifies against, read once for the import.
    ctx = Map.put(ctx, :known_entities, Intake.known_entities())

    try do
      state = Enum.reduce(databases, state, &import_database(&1, plan, &2, ctx))

      state =
        pages
        |> Enum.chunk_every(@batch)
        |> Enum.reduce(state, &import_pages(&1, plan, &2, ctx))

      state = write_edges(state, ctx)
      {:ok, report(state, plan, ctx)}
    catch
      {:fatal, reason} -> {:error, reason}
    end
  end

  defp import_pages(items, plan, state, ctx) do
    {entries, state} = Enum.map_reduce(items, state, &prepare_page(&1, plan, &2, ctx))
    store_all(state, Enum.reject(entries, &is_nil/1), plan, ctx)
  end

  defp prepare_page(item, plan, state, ctx) do
    case read_text(item, ctx, ctx.limits.max_page_bytes) do
      {:ok, data, warnings} ->
        title = h1_title(data) || item.title
        linked = Links.rewrite(data, item.path, plan, &uri(ctx.workspace_id, &1))
        text = if String.trim(linked.text) == "", do: "# #{title}", else: linked.text

        state =
          state
          |> add_warnings(item.path, warnings)
          |> bump("links_unresolved", linked.unresolved)
          |> put_links(item.id, linked.targets)

        {entry(item.id, title, text, item.path), state}

      {:error, error} ->
        {nil, state |> add_error(error) |> step(ctx, plan)}
    end
  end

  defp import_database(item, plan, state, ctx) do
    # A CSV is read whole (up to the entry limit): its rows are the data.
    with {:ok, data, warnings} <- read_text(item, ctx, :infinity),
         {:ok, table} <- parse_table(data, item) do
      rows = match_rows(table.rows, Plan.row_pages(plan, item.id), item.id)
      row_ids = rows |> Enum.map(&elem(&1, 1)) |> List.to_tuple()

      text =
        Database.text(item.title, table, fn index ->
          uri(ctx.workspace_id, elem(row_ids, index))
        end)

      own_rows = for {:own, id, row} <- rows, do: {id, row}

      state =
        state
        |> add_warnings(item.path, warnings)
        |> bump("rows", length(table.rows))
        |> Map.update!(:total, &(&1 + length(own_rows)))
        |> Map.update!(:parents, fn parents ->
          Enum.reduce(own_rows, parents, fn {id, _row}, acc -> Map.put(acc, id, item.id) end)
        end)
        |> store_all([entry(item.id, item.title, text, item.path)], plan, ctx)

      own_rows
      |> Enum.map(fn {id, row} ->
        text = Database.row_text(table.columns, row, item.title)
        entry(id, Database.row_title(row), text, item.path)
      end)
      |> Enum.chunk_every(@batch)
      |> Enum.reduce(state, &store_all(&2, &1, plan, ctx))
    else
      {:error, error} -> state |> add_error(error) |> step(ctx, plan)
    end
  end

  defp parse_table(data, item) do
    case Database.parse(data) do
      {:ok, table} -> {:ok, table}
      {:error, :csv_unreadable} -> {:error, error(item.path, "csv_unreadable", nil)}
    end
  end

  # A CSV row is its row page when the export holds one with the same title
  # (exact, or the start of a long title Notion shortened in the file name);
  # otherwise it becomes a context of its own with an id derived from its
  # title and how many rows before it share that title.
  defp match_rows(rows, row_pages, database_id) do
    {matched, _state} =
      Enum.map_reduce(rows, {MapSet.new(), %{}}, fn row, {used, seen} ->
        key = row |> Database.row_title() |> Plan.normalize_title()
        n = Map.get(seen, key, 0)
        seen = Map.put(seen, key, n + 1)

        case row_page(key, row_pages, used) do
          nil ->
            hash = :crypto.hash(:sha256, "#{key}\0#{n}") |> Base.encode16(case: :lower)
            {{:own, "#{database_id}-row-#{binary_part(hash, 0, 16)}", row}, {used, seen}}

          page ->
            {{:page, page.id, row}, {MapSet.put(used, page.id), seen}}
        end
      end)

    matched
  end

  defp row_page(key, row_pages, used) do
    exact = row_pages |> Map.get(key, []) |> Enum.find(&(not MapSet.member?(used, &1.id)))

    exact ||
      Enum.find_value(row_pages, fn {title_key, pages} ->
        if byte_size(title_key) >= 16 and String.starts_with?(key, title_key),
          do: Enum.find(pages, &(not MapSet.member?(used, &1.id)))
      end)
  end

  # ── reading text ───────────────────────────────────────────────────────

  defp read_text(item, ctx, max_text_bytes) do
    %{entry: entry, archive: archive} = item.file

    case Zip.read(archive, entry, ctx.limits.max_entry_bytes) do
      {:ok, data} ->
        {data, warnings} = clean_text(data, max_text_bytes)
        {:ok, data, warnings}

      {:error, {reason, _name}} ->
        if reason in @fatal, do: throw({:fatal, {reason, item.path}})
        {:error, error(item.path, Atom.to_string(reason), nil)}

      {:error, reason} ->
        throw({:fatal, reason})
    end
  end

  defp clean_text(data, max_bytes) do
    data = String.replace_prefix(data, "\uFEFF", "")

    {data, warnings} =
      if String.valid?(data),
        do: {data, []},
        else: {String.replace_invalid(data, "\uFFFD"), [{"invalid_utf8", "repaired"}]}

    if max_bytes != :infinity and byte_size(data) > max_bytes do
      {truncate(data, max_bytes), [{"page_truncated", "kept #{max_bytes} bytes"} | warnings]}
    else
      {data, warnings}
    end
  end

  defp truncate(data, max_bytes) do
    case :unicode.characters_to_binary(binary_part(data, 0, max_bytes)) do
      text when is_binary(text) -> text
      {:incomplete, text, _rest} -> text
      {:error, text, _rest} -> text
    end
  end

  defp h1_title(data) do
    data
    |> String.split("\n", parts: 12)
    |> Enum.take(11)
    |> Enum.find(&(String.trim(&1) != ""))
    |> case do
      "# " <> title -> if String.trim(title) == "", do: nil, else: String.trim(title)
      _ -> nil
    end
  end

  # ── writing ────────────────────────────────────────────────────────────

  defp entry(id, title, text, path), do: %{id: id, title: title, text: text, path: path}

  # Stores a batch of contexts in order. Intake runs one call at a time and
  # classification is the costly part of a call, so the batch is classified in
  # parallel, a few texts ahead of the one intake is storing, and intake
  # stores each classification as it is. An unchanged context is skipped.
  defp store_all(state, entries, plan, ctx) do
    entries
    |> Task.async_stream(&{&1, classification(&1, ctx)},
      max_concurrency: System.schedulers_online(),
      ordered: true,
      timeout: :infinity
    )
    |> Enum.reduce(state, fn
      {:ok, {entry, :unchanged}}, state ->
        state |> bump("unchanged", 1) |> stored(entry.id) |> step(ctx, plan)

      {:ok, {entry, classified}}, state ->
        state |> store(entry, classified, ctx) |> step(ctx, plan)
    end)
  end

  defp classification(entry, ctx) do
    context_id = context_id(ctx.workspace_id, entry.id)

    if unchanged?(context_id, ctx.workspace_id, entry.title, entry.text),
      do: :unchanged,
      else: classify(entry, ctx)
  end

  defp classify(entry, ctx) do
    Intake.classify(entry.text, title: entry.title, known_entities: ctx.known_entities)
  rescue
    _ -> nil
  end

  defp store(state, entry, classified, ctx) do
    yield_to_store(System.monotonic_time(:millisecond) + @store_wait_ms)

    case intake(entry, classified, ctx) do
      {:ok, _result} ->
        state |> bump("contexts", 1) |> stored(entry.id)

      {:error, reason} ->
        add_error(state, error(entry.path, "intake_failed", inspect(reason)))
    end
  end

  defp intake(entry, classified, ctx) do
    opts = [
      workspace_id: ctx.workspace_id,
      tenant_id: ctx.tenant_id,
      actor_id: ctx.actor_id,
      title: entry.title,
      write_files: false,
      source_id: source_id(entry.id),
      source_uri: uri(ctx.workspace_id, entry.id)
    ]

    opts = if classified, do: [{:classified, classified} | opts], else: opts
    Intake.process(entry.text, opts)
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp unchanged?(context_id, workspace_id, title, text) do
    case Store.raw_query(
           "SELECT title, content FROM contexts WHERE id = ?1 AND workspace_id = ?2",
           [context_id, workspace_id]
         ) do
      {:ok, [[^title, ^text]]} -> true
      _ -> false
    end
  end

  defp stored(state, id), do: %{state | stored: MapSet.put(state.stored, id)}

  # A bulk import must not starve the store. Each page leaves asynchronous
  # chunking behind it, and other callers share the same store process, so
  # while more than @store_backlog requests wait for the store the import
  # waits too, for at most @store_wait_ms per page.
  defp yield_to_store(deadline) do
    with pid when is_pid(pid) <- Process.whereis(Store.adapter()),
         {:message_queue_len, waiting} when waiting > @store_backlog <-
           Process.info(pid, :message_queue_len),
         true <- System.monotonic_time(:millisecond) < deadline do
      Process.sleep(20)
      yield_to_store(deadline)
    else
      _ -> :ok
    end
  end

  defp put_links(state, _id, []), do: state
  defp put_links(state, id, targets), do: %{state | links: Map.put(state.links, id, targets)}

  # The edges the import implies, for the contexts it stored; existing
  # child_of and links_to edges from those contexts that no longer hold are
  # retracted.
  defp write_edges(state, ctx) do
    ws = ctx.workspace_id
    ctx_id = &context_id(ws, &1)
    stored? = &MapSet.member?(state.stored, &1)

    child_edges =
      for {id, parent} <- state.parents,
          parent != nil,
          stored?.(id),
          stored?.(parent),
          do: {ctx_id.(id), ctx_id.(parent), @child_of}

    link_edges =
      for {id, targets} <- state.links,
          stored?.(id),
          target <- targets,
          target != id,
          stored?.(target),
          do: {ctx_id.(id), ctx_id.(target), @links_to}

    desired = MapSet.new(child_edges ++ link_edges)
    sources = MapSet.new(state.stored, ctx_id)
    existing = existing_edges(ws, sources)

    desired
    |> MapSet.difference(existing)
    |> Enum.each(fn {source, target, relation} ->
      Graph.assert_edge(source, target, relation, workspace_id: ws)
    end)

    existing
    |> MapSet.difference(desired)
    |> Enum.each(fn {source, target, relation} ->
      Graph.retract_edge(source, target, relation, workspace_id: ws)
    end)

    state
    |> bump("edges_child_of", length(child_edges))
    |> bump("edges_links_to", MapSet.size(MapSet.new(link_edges)))
  end

  defp existing_edges(ws, sources) do
    case Store.raw_query(
           "SELECT source_id, target_id, relation FROM edges WHERE workspace_id = ?1 AND relation IN (?2, ?3)",
           [ws, @child_of, @links_to]
         ) do
      {:ok, rows} ->
        for [source, target, relation] <- rows,
            MapSet.member?(sources, source),
            into: MapSet.new(),
            do: {source, target, relation}

      {:error, reason} ->
        Logger.warning("[Imports.Notion] could not read existing edges: #{inspect(reason)}")
        MapSet.new()
    end
  end

  # ── the report ─────────────────────────────────────────────────────────

  defp step(state, ctx, plan) do
    state = %{state | done: state.done + 1}
    now = System.monotonic_time(:millisecond)

    if rem(state.done, @progress_every) == 0 or now - state.last_progress >= @progress_ms do
      ctx.progress.(report(state, plan, ctx))
      %{state | last_progress: now}
    else
      state
    end
  end

  defp report(state, plan, ctx) do
    roots =
      plan.items
      |> Enum.filter(&(&1.parent == nil and MapSet.member?(state.stored, &1.id)))
      |> Enum.take(@max_roots)
      |> Enum.map(&uri(ctx.workspace_id, &1.id))

    %{
      "counts" => state.counts,
      "progress" => %{"done" => state.done, "total" => state.total},
      "errors" => Enum.reverse(state.errors),
      "errors_truncated" => state.counts["errors"] > @max_errors,
      "root_uris" => roots
    }
  end

  defp bump(state, _key, 0), do: state
  defp bump(state, key, n), do: %{state | counts: Map.update!(state.counts, key, &(&1 + n))}

  defp add_warnings(state, path, warnings) do
    Enum.reduce(warnings, state, fn {reason, detail}, state ->
      add_error(state, error(path, reason, detail))
    end)
  end

  defp add_error(state, error) do
    state = bump(state, "errors", 1)

    if length(state.errors) < @max_errors,
      do: %{state | errors: [error | state.errors]},
      else: state
  end

  defp error(path, reason, detail), do: %{"path" => path, "reason" => reason, "detail" => detail}
end
