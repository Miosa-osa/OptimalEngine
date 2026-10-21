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

  Every edge is asserted as `import.notion` (`Graph.assert_edge/4`
  `:asserted_by`). A re-import retracts the ones that no longer hold, so a
  page that moved has one parent, not two, and only those: an edge another
  writer asserted, the same edge included, is left alone.

  The archive is read by `OptimalEngine.Imports.Zip` under hard limits; a
  Notion export split into part zips at the archive root is read one level
  deep, and a root zip that cannot be read is one reported error. Assets
  (images, files) are counted, not imported. A database CSV is read as a
  stream, at most `:max_rows_per_csv` rows, and the whole import is held to
  `:max_contexts` contexts. A problem with one page is recorded in the report
  and the import continues; an archive that is refused, or an entry that
  inflates past its declared size, stops it. Contexts written before such a
  stop stay, without their edges; importing a corrected export completes them.
  """

  require Logger

  alias OptimalEngine.Graph
  alias OptimalEngine.Imports.Notion.{Database, Links, Plan}
  alias OptimalEngine.Imports.Zip
  alias OptimalEngine.Pipeline.{Classifier, Intake}
  alias OptimalEngine.Store

  @child_of "child_of"
  @asserted_by "import.notion"
  @links_to "links_to"
  @max_errors 200
  @max_roots 50
  @progress_every 25
  @progress_ms 5_000
  @store_backlog 50
  @store_wait_ms 30_000
  @batch 64
  @prefix_bytes 16
  @classify_bytes 65_536

  @default_limits %{
    max_entries: 50_000,
    max_directory_bytes: 64 * 1024 * 1024,
    max_total_bytes: 4 * 1024 * 1024 * 1024,
    max_entry_bytes: 64 * 1024 * 1024,
    max_page_bytes: 2 * 1024 * 1024,
    max_rows_per_csv: 10_000,
    max_contexts: 100_000
  }

  # Failures no other attempt can fix: the archive itself is refused.
  @fatal ~w(invalid_zip zip64_unsupported unsafe_path too_many_entries archive_too_large
            entry_size_mismatch empty_export source_missing too_many_contexts)a

  # A root zip that fails to read for one of these is not an export part.
  @unreadable_part ~w(invalid_zip zip64_unsupported crc_mismatch corrupt_entry encrypted_entry
                      unsupported_compression)a

  @type report :: map()

  @doc """
  The default limits: entries, central directory, total and per-entry bytes,
  page text bytes, rows per CSV, and contexts per import.
  """
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

  Options: `:limit` (default 500, at most 1,000), `:offset`, and `:tenant_id`
  (default: the workspace's tenant; a request passes the requester's, so
  another tenant's rows read as nothing). Returns `{:error, :not_found}` when
  `parent` names nothing imported in the workspace.
  """
  @spec tree(String.t(), String.t() | nil, keyword()) :: {:ok, map()} | {:error, term()}
  def tree(workspace_id, parent, opts \\ []) do
    limit = opts |> Keyword.get(:limit, 500) |> max(1) |> min(1_000)
    offset = opts |> Keyword.get(:offset, 0) |> max(0)
    prefix = uri(workspace_id, "")
    scope = Graph.scope(workspace_id: workspace_id, tenant_id: Keyword.get(opts, :tenant_id))
    {tenant_id, _workspace} = scope

    with {:ok, contexts} <- notion_contexts(scope),
         {:ok, edges} <-
           Graph.edges_by_relation([@child_of], workspace_id: workspace_id, tenant_id: tenant_id) do
      edges =
        Enum.filter(
          edges,
          &(Map.has_key?(contexts, &1.source_id) and Map.has_key?(contexts, &1.target_id))
        )

      parents = Map.new(edges, &{&1.source_id, &1.target_id})
      children = Enum.frequencies_by(edges, & &1.target_id)

      level =
        case parent do
          nil ->
            {:ok, Enum.reject(contexts, fn {id, _} -> Map.has_key?(parents, id) end)}

          parent_id ->
            parent_ctx = context_id(workspace_id, parent_id)

            if Map.has_key?(contexts, parent_ctx),
              do: {:ok, Enum.filter(contexts, fn {id, _} -> parents[id] == parent_ctx end)},
              else: {:error, :not_found}
        end

      with {:ok, level} <- level do
        pages =
          level
          |> Enum.sort_by(fn {_id, %{title: title, uri: uri}} -> {title || "", uri} end)
          |> Enum.drop(offset)
          |> Enum.take(limit)
          |> Enum.map(fn {id, %{title: title, uri: page_uri}} ->
            %{
              page_id: String.replace_prefix(page_uri, prefix, ""),
              uri: page_uri,
              title: title,
              children: Map.get(children, id, 0)
            }
          end)

        {:ok,
         %{workspace_id: workspace_id, parent: parent && uri(workspace_id, parent), pages: pages}}
      end
    end
  end

  # Every imported Notion context of a workspace, within a tenant:
  # id => %{uri, title}.
  defp notion_contexts({tenant_id, workspace_id}) do
    prefix = uri(workspace_id, "")

    case Store.raw_query(
           "SELECT id, uri, title FROM contexts WHERE tenant_id = ?4 AND workspace_id = ?1 AND substr(uri, 1, ?3) = ?2",
           [workspace_id, prefix, String.length(prefix), tenant_id]
         ) do
      {:ok, rows} ->
        {:ok, Map.new(rows, fn [id, uri, title] -> {id, %{uri: uri, title: title}} end)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "True when a failure reason refuses the archive, so retrying cannot help."
  @spec fatal?(term()) :: boolean()
  def fatal?({reason, _detail}), do: reason in @fatal
  def fatal?(reason), do: reason in @fatal

  @doc """
  Imports the export at `zip_path` into `workspace_id`.

  Options: `:tenant_id`, `:actor_id`, `:work_dir` (where part zips and CSVs
  are unpacked; default the zip's folder), `:limits` (merged over
  `default_limits/0`), `:progress`, a function called with the report so far
  every few pages, and `:heartbeat`, a function called while the archive is
  read (a job extends its lease with both).

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
      work_dir: work_dir,
      progress: Keyword.get(opts, :progress, fn _report -> :ok end),
      heartbeat: Keyword.get(opts, :heartbeat, fn -> :ok end)
    }

    with {:ok, files, read} <- collect(zip_path, ctx) do
      plan = Plan.build(files)

      cond do
        plan.items == [] ->
          {:error, :empty_export}

        length(plan.items) > limits.max_contexts ->
          {:error, {:too_many_contexts, "#{length(plan.items)} items"}}

        true ->
          run(plan, read, ctx)
      end
    end
  end

  # ── reading the archive ────────────────────────────────────────────────

  defp collect(zip_path, ctx) do
    zip_limits = Map.take(ctx.limits, [:max_entries, :max_directory_bytes, :max_total_bytes])

    with {:ok, archive} <- Zip.open(zip_path, zip_limits) do
      read = %{entries: 0, declared: 0, parts: 0, errors: []}

      archive.entries
      |> Enum.reject(& &1.dir?)
      |> Enum.reduce_while({:ok, [], read}, fn entry, {:ok, files, read} ->
        case outer_entry(entry, archive, ctx, read) do
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

  defp outer_entry(%{name: nil} = entry, _archive, _ctx, read) do
    {:ok, [], invalid_name(entry, read)}
  end

  defp outer_entry(entry, archive, ctx, read) do
    if part_zip?(entry.name) do
      read_part(entry, archive, ctx, read)
    else
      {:ok, [file(entry, archive)], count(read, entry)}
    end
  end

  # Notion splits a large export into part zips at the root of the one it
  # hands out. Each is unpacked (its own bytes count against the total) and
  # read like the outer zip, against the same running limits. A root zip that
  # is not a readable archive is reported and skipped; a part that breaks a
  # safety limit refuses the whole import. A zip anywhere else is an
  # attachment.
  defp read_part(entry, archive, ctx, read) do
    limits = ctx.limits
    dest = Path.join(ctx.work_dir, "part-#{read.parts + 1}.zip")
    budget = limits.max_total_bytes - read.declared
    read = %{read | declared: read.declared + entry.size}
    left = limits.max_total_bytes - read.declared

    result =
      with :ok <- check_total(left),
           :ok <- Zip.extract(archive, entry, dest, budget) do
        Zip.open(dest, %{
          max_entries: limits.max_entries - read.entries,
          max_directory_bytes: limits.max_directory_bytes,
          max_total_bytes: left
        })
      end

    ctx.heartbeat.()

    case result do
      {:ok, part} ->
        read = %{read | parts: read.parts + 1}

        {files, read} =
          part.entries
          |> Enum.reject(& &1.dir?)
          |> Enum.reduce({[], read}, fn
            %{name: nil} = inner, {files, read} -> {files, invalid_name(inner, read)}
            inner, {files, read} -> {[file(inner, part) | files], count(read, inner)}
          end)

        {:ok, files, read}

      {:error, {:entry_too_large, _}} ->
        {:error, :archive_too_large}

      {:error, reason} ->
        if unreadable_part?(reason) do
          File.rm(dest)
          error = %{"path" => entry.name, "reason" => "part_unreadable", "detail" => code(reason)}
          {:ok, [], %{read | errors: [error | read.errors]}}
        else
          {:error, reason}
        end
    end
  end

  defp check_total(left) when left >= 0, do: :ok
  defp check_total(_left), do: {:error, :archive_too_large}

  defp unreadable_part?({reason, _name}), do: reason in @unreadable_part
  defp unreadable_part?(reason), do: reason in @unreadable_part

  defp code({reason, _detail}) when is_atom(reason), do: Atom.to_string(reason)
  defp code(reason) when is_atom(reason), do: Atom.to_string(reason)

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

    # The gazetteer intake classifies against, read once for the import, and
    # each database's row pages, found once.
    ctx =
      ctx
      |> Map.put(:known_entities, Intake.known_entities())
      |> Map.put(:row_pages, pages |> Enum.filter(& &1.parent) |> Enum.group_by(& &1.parent))

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

  # One page that cannot be read or rewritten is reported and skipped; only a
  # refused archive (thrown as :fatal) stops the import.
  defp prepare_page(item, plan, state, ctx) do
    case read_text(item, ctx, ctx.limits.max_page_bytes) do
      {:ok, data, warnings} ->
        try do
          title = h1_title(data) || item.title
          linked = Links.rewrite(data, item.path, plan, &uri(ctx.workspace_id, &1))
          text = if String.trim(linked.text) == "", do: "# #{title}", else: linked.text

          state =
            state
            |> add_warnings(item.path, warnings)
            |> bump("links_unresolved", linked.unresolved)
            |> put_links(item.id, linked.targets)

          {entry(item.id, title, text, item.path), state}
        rescue
          _error ->
            {nil, state |> add_error(error(item.path, "page_unreadable", nil)) |> step(ctx, plan)}
        end

      {:error, error} ->
        {nil, state |> add_error(error) |> step(ctx, plan)}
    end
  end

  defp import_database(item, plan, state, ctx) do
    with {:ok, table} <- read_table(item, ctx) do
      rows = match_rows(table.rows, row_index(Map.get(ctx.row_pages, item.id, [])), item.id)
      row_ids = rows |> Enum.map(&elem(&1, 1)) |> List.to_tuple()
      max_bytes = ctx.limits.max_page_bytes

      text =
        Database.text(item.title, table, &uri(ctx.workspace_id, elem(row_ids, &1)), max_bytes)

      own_rows = for {:own, id, row} <- rows, do: {id, row}

      if state.total + length(own_rows) > ctx.limits.max_contexts,
        do: throw({:fatal, {:too_many_contexts, item.path}})

      state =
        state
        |> then(fn state ->
          if table.truncated,
            do:
              add_error(state, error(item.path, "csv_truncated", "kept #{length(table.rows)} rows")),
            else: state
        end)
        |> bump("rows", length(table.rows))
        |> Map.update!(:total, &(&1 + length(own_rows)))
        |> Map.update!(:parents, fn parents ->
          Enum.reduce(own_rows, parents, fn {id, _row}, acc -> Map.put(acc, id, item.id) end)
        end)
        |> store_all([entry(item.id, item.title, text, item.path)], plan, ctx)

      own_rows
      |> Enum.map(fn {id, row} ->
        text = Database.row_text(table.columns, row, item.title, max_bytes)
        entry(id, Database.row_title(row), text, item.path)
      end)
      |> Enum.chunk_every(@batch)
      |> Enum.reduce(state, &store_all(&2, &1, plan, ctx))
    else
      {:error, error} -> state |> add_error(error) |> step(ctx, plan)
    end
  end

  # The CSV is unpacked to an owner-only file and parsed as a stream, so only
  # the rows kept are ever in memory.
  defp read_table(item, ctx) do
    %{entry: entry, archive: archive} = item.file
    path = Path.join(ctx.work_dir, "csv-#{System.unique_integer([:positive])}.csv")

    try do
      case Zip.extract(archive, entry, path, ctx.limits.max_entry_bytes) do
        :ok ->
          case Database.read(path, ctx.limits.max_rows_per_csv) do
            {:ok, table} -> {:ok, table}
            {:error, :csv_unreadable} -> {:error, error(item.path, "csv_unreadable", nil)}
          end

        {:error, error} ->
          entry_error(error, item)
      end
    after
      File.rm(path)
    end
  end

  # A CSV row is its row page when the export holds one with the same title
  # (exact, or the start of a long title Notion shortened in the file name);
  # otherwise it becomes a context of its own with an id derived from its
  # title and how many rows before it share that title.
  defp match_rows(rows, index, database_id) do
    {matched, _state} =
      Enum.map_reduce(rows, {MapSet.new(), %{}}, fn row, {used, seen} ->
        key = row |> Database.row_title() |> Plan.normalize_title()
        n = Map.get(seen, key, 0)
        seen = Map.put(seen, key, n + 1)

        case row_page(key, index, used) do
          nil ->
            hash = :crypto.hash(:sha256, "#{key}\0#{n}") |> Base.encode16(case: :lower)
            {{:own, "#{database_id}-row-#{binary_part(hash, 0, 16)}", row}, {used, seen}}

          page ->
            {{:page, page.id, row}, {MapSet.put(used, page.id), seen}}
        end
      end)

    matched
  end

  # The row pages of one database by normalized title, and the long titles
  # (which Notion may have shortened in the file name) by their first bytes,
  # so a row finds its page without scanning every page.
  defp row_index(row_pages) do
    by_title = Enum.group_by(row_pages, &Plan.normalize_title(&1.title))

    by_prefix =
      by_title
      |> Enum.filter(fn {key, _pages} -> byte_size(key) >= @prefix_bytes end)
      |> Enum.group_by(fn {key, _pages} -> binary_part(key, 0, @prefix_bytes) end)

    %{by_title: by_title, by_prefix: by_prefix}
  end

  defp row_page(key, index, used) do
    unused = &Enum.find(&1, fn page -> not MapSet.member?(used, page.id) end)

    case unused.(Map.get(index.by_title, key, [])) do
      nil when byte_size(key) >= @prefix_bytes ->
        index.by_prefix
        |> Map.get(binary_part(key, 0, @prefix_bytes), [])
        |> Enum.find_value(fn {title_key, pages} ->
          if String.starts_with?(key, title_key), do: unused.(pages)
        end)

      found ->
        found
    end
  end

  # ── reading text ───────────────────────────────────────────────────────

  defp read_text(item, ctx, max_text_bytes) do
    %{entry: entry, archive: archive} = item.file

    case Zip.read(archive, entry, ctx.limits.max_entry_bytes) do
      {:ok, data} ->
        {data, warnings} = clean_text(data, max_text_bytes)
        {:ok, data, warnings}

      {:error, error} ->
        entry_error(error, item)
    end
  end

  defp entry_error({reason, _name}, item) do
    if reason in @fatal, do: throw({:fatal, {reason, item.path}})
    {:error, error(item.path, Atom.to_string(reason), nil)}
  end

  defp entry_error(reason, _item), do: throw({:fatal, reason})

  defp clean_text(data, max_bytes) do
    data = String.replace_prefix(data, "\uFEFF", "")

    {data, warnings} =
      if String.valid?(data),
        do: {data, []},
        else: {String.replace_invalid(data, "\uFFFD"), [{"invalid_utf8", "repaired"}]}

    if byte_size(data) > max_bytes do
      {Database.clip(data, max_bytes), [{"page_truncated", "kept #{max_bytes} bytes"} | warnings]}
    else
      {data, warnings}
    end
  end

  defp h1_title(data) do
    data
    |> String.split("\n", parts: 12)
    |> Enum.take(11)
    |> Enum.find(&(String.trim(&1) != ""))
    |> case do
      "# " <> title ->
        case String.trim(title) do
          "" -> nil
          title -> String.slice(title, 0, 500)
        end

      _ ->
        nil
    end
  end

  # ── writing ────────────────────────────────────────────────────────────

  defp entry(id, title, text, path), do: %{id: id, title: title, text: text, path: path}

  # Stores a batch of contexts in order. Intake runs one call at a time and
  # classification is the costly part of a call, so the batch is classified in
  # parallel, a few texts ahead of the one intake is storing, and intake
  # stores each classification as it is. An unchanged context is skipped. A
  # text that cannot be classified is reported, never handed to intake to
  # classify again inside its single process. Each task gets only the two
  # values it reads: the import context holds the plan's items and through
  # them the archive's whole entry list, and a closure over it would copy
  # all of that into every task.
  defp store_all(state, entries, plan, ctx) do
    scope = %{workspace_id: ctx.workspace_id, known_entities: ctx.known_entities}

    entries
    |> Task.async_stream(&{&1, classification(&1, scope)},
      max_concurrency: concurrency(),
      ordered: true,
      timeout: :infinity
    )
    |> Enum.reduce(state, fn
      {:ok, {entry, :unchanged}}, state ->
        state |> bump("unchanged", 1) |> stored(entry.id) |> step(ctx, plan)

      {:ok, {entry, nil}}, state ->
        state
        |> add_error(error(entry.path, "page_unreadable", "classification_failed"))
        |> step(ctx, plan)

      {:ok, {entry, classified}}, state ->
        state |> store(entry, classified, ctx) |> step(ctx, plan)
    end)
  end

  # Half the schedulers by default, so an import leaves room for the Engine's
  # other work (`config :optimal_engine, :import_classify_concurrency`).
  defp concurrency do
    case Application.get_env(:optimal_engine, :import_classify_concurrency) do
      n when is_integer(n) and n > 0 -> n
      _ -> max(div(System.schedulers_online(), 2), 1)
    end
  end

  defp classification(entry, scope) do
    context_id = context_id(scope.workspace_id, entry.id)

    if unchanged?(context_id, scope.workspace_id, entry.title, entry.text),
      do: :unchanged,
      else: classify(entry, scope)
  end

  # A long page is classified by its head: genre, mode and summary come from
  # its first @classify_bytes, and entities from the whole text. Mode
  # detection is quadratic in the length of a line with no spaces, so a page
  # built that way would otherwise hold a classifier for hours. The signal
  # carries the whole text, so intake stores all of it.
  defp classify(entry, scope) do
    known = scope.known_entities

    if byte_size(entry.text) <= @classify_bytes do
      Intake.classify(entry.text, title: entry.title, known_entities: known)
    else
      head = Database.clip(entry.text, @classify_bytes)
      entities = Classifier.extract_entities(entry.text, known)
      signal = Intake.classify(head, title: entry.title, known_entities: known, entities: entities)
      %{signal | content: entry.text}
    end
  rescue
    _ -> nil
  end

  defp store(state, entry, classified, ctx) do
    yield_to_store(System.monotonic_time(:millisecond) + @store_wait_ms)

    case intake(entry, classified, ctx) do
      {:ok, _result} -> state |> bump("contexts", 1) |> stored(entry.id)
      {:error, reason} -> add_error(state, error(entry.path, "intake_failed", reason_code(reason)))
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
      source_uri: uri(ctx.workspace_id, entry.id),
      classified: classified
    ]

    Intake.process(entry.text, opts)
  catch
    :exit, _reason -> {:error, :intake_unavailable}
  end

  defp reason_code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_code({reason, _}) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_code(_reason), do: "failed"

  # A store that does not answer makes the context count as changed: intake
  # then writes it, which is right either way.
  defp unchanged?(context_id, workspace_id, title, text) do
    case Store.raw_query(
           "SELECT title, content FROM contexts WHERE id = ?1 AND workspace_id = ?2",
           [context_id, workspace_id]
         ) do
      {:ok, [[^title, ^text]]} -> true
      _ -> false
    end
  catch
    :exit, _reason -> false
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

  # The edges the import implies, for the contexts it stored. An edge this
  # importer asserted alone, starting at one this import stored, that no
  # longer holds is retracted. Every edge goes through Graph.
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
    existing = importer_edges(ws, sources)

    desired
    |> MapSet.difference(existing)
    |> Enum.each(fn {source, target, relation} ->
      Graph.assert_edge(source, target, relation, workspace_id: ws, asserted_by: @asserted_by)
    end)

    existing
    |> MapSet.difference(desired)
    |> Enum.each(fn {source, target, relation} ->
      Graph.retract_edge(source, target, relation, workspace_id: ws, asserted_by: @asserted_by)
    end)

    state
    |> bump("edges_child_of", length(child_edges))
    |> bump("edges_links_to", MapSet.size(MapSet.new(link_edges)))
  end

  defp importer_edges(ws, sources) do
    opts = [workspace_id: ws, asserted_by: @asserted_by]

    case Graph.edges_by_relation([@child_of, @links_to], opts) do
      {:ok, edges} ->
        for %{source_id: source, target_id: target, relation: relation} <- edges,
            MapSet.member?(sources, source),
            into: MapSet.new(),
            do: {source, target, relation}

      {:error, reason} ->
        Logger.warning("[Imports.Notion] could not read existing edges: #{reason_code(reason)}")
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
