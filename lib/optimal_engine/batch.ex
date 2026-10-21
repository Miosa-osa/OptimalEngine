defmodule OptimalEngine.Batch do
  @moduledoc """
  Batch import/export operations for workspace migration and backup.

  Provides bulk ingestion of signals and memories into a workspace, and
  bulk export of signals, memories, wiki pages, and workspace config as
  JSON-serializable maps suitable for migration or API backup endpoints.

  ## Import behaviour

  Every item in an import batch is processed independently. A failure on
  one item never aborts the batch — errors are accumulated and returned
  in the summary counters. Callers receive `{:ok, %{imported, skipped,
  errors}}` regardless of per-item failures.

  ## Deduplication

  - Signals: `Intake.process/2` content-hashes each signal and returns
    `{:error, :duplicate}` for already-known content. Duplicates are
    counted as `:skipped`.
  - Memories: `Memory.create/1` uses a content hash per workspace; an
    existing memory returns `was_existing: true` which is counted as
    `:skipped`.

  ## Workspace_id flow

  The `:workspace_id` option is threaded into every downstream call so
  imported data lands in the correct workspace. Defaults to `"default"`.

  ## Tenant

  Memories carry the tenant they are imported under, and exports read only
  one tenant's rows: a keyed caller's (`:reader`), otherwise `:tenant_id`,
  defaulting to the workspace's own tenant (`OptimalEngine.Graph.scope/1`).
  The HTTP routes pass the caller's tenant, so two tenants that name the same
  workspace id never read each other's signals or memories.
  """

  require Logger

  alias OptimalEngine.Graph
  alias OptimalEngine.Memory
  alias OptimalEngine.Pipeline.Intake
  alias OptimalEngine.ReadScope
  alias OptimalEngine.Store
  alias OptimalEngine.Wiki
  alias OptimalEngine.Workspace

  @type import_summary :: %{
          imported: non_neg_integer(),
          skipped: non_neg_integer(),
          errors: non_neg_integer()
        }

  # ---------------------------------------------------------------------------
  # Import
  # ---------------------------------------------------------------------------

  @doc """
  Import a list of signal maps into a workspace.

  Each map may contain: `content` (required), `title`, `genre`, `node`,
  `entities`. Unknown keys are ignored.

  Uses `Intake.process/2` for each item. Duplicate content (as detected by
  the pipeline's content hash) is counted as `:skipped`. Any other error
  (including `:signal_too_noisy`) is counted as `:errors`.

  Options:
    - `:workspace_id` — target workspace (default: `"default"`)
  """
  @spec import_signals(list(map()), keyword()) ::
          {:ok, import_summary()} | {:error, term()}
  def import_signals(items, opts \\ []) when is_list(items) do
    workspace_id = Keyword.get(opts, :workspace_id, "default")

    summary =
      Enum.reduce(items, %{imported: 0, skipped: 0, errors: 0}, fn item, acc ->
        case process_signal_item(item, workspace_id) do
          :imported -> Map.update!(acc, :imported, &(&1 + 1))
          :skipped -> Map.update!(acc, :skipped, &(&1 + 1))
          :error -> Map.update!(acc, :errors, &(&1 + 1))
        end
      end)

    {:ok, summary}
  end

  @doc """
  Import a list of memory maps into a workspace.

  Each map may contain: `content` (required), `is_static`, `audience`,
  `citation_uri`, `source_chunk_id`, `metadata`.

  Uses `Memory.create/1` for each item. Content-hash dedup is handled
  transparently — an existing memory returns `was_existing: true` which
  is counted as `:skipped`.

  Options:
    - `:workspace_id` - target workspace (default: `"default"`)
    - `:tenant_id` - tenant the memories belong to (default: the workspace's tenant)
  """
  @spec import_memories(list(map()), keyword()) ::
          {:ok, import_summary()} | {:error, term()}
  def import_memories(items, opts \\ []) when is_list(items) do
    scope = Graph.scope(opts)

    summary =
      Enum.reduce(items, %{imported: 0, skipped: 0, errors: 0}, fn item, acc ->
        case process_memory_item(item, scope) do
          :imported -> Map.update!(acc, :imported, &(&1 + 1))
          :skipped -> Map.update!(acc, :skipped, &(&1 + 1))
          :error -> Map.update!(acc, :errors, &(&1 + 1))
        end
      end)

    {:ok, summary}
  end

  # ---------------------------------------------------------------------------
  # Export
  # ---------------------------------------------------------------------------

  @doc """
  Export all signals (contexts of type 'signal') from a workspace as a
  list of JSON-serializable maps.

  Options:
    - `:workspace_id` — source workspace (default: `"default"`)
    - `:tenant_id`: tenant to read (default: the workspace's tenant)
    - `:reader`: the `OptimalEngine.ReadScope` of a keyed caller: only the
      signals it may see are exported, in its tenant (nil exports all of
      `:tenant_id`'s)

  A failing read of the Store is an error, never an empty export.
  """
  @spec export_signals(keyword()) :: {:ok, list(map())} | {:error, term()}
  def export_signals(opts \\ []) do
    with {:ok, signals, _withheld} <- read_signals(opts), do: {:ok, signals}
  end

  @doc """
  `export_signals/1` that also says how many signals the reader was not
  allowed to see: `{:ok, signals, withheld}`.
  """
  @spec read_signals(keyword()) :: {:ok, list(map()), non_neg_integer()} | {:error, term()}
  def read_signals(opts \\ []) do
    {tenant_id, workspace_id} = read_scope(opts)
    reader = Keyword.get(opts, :reader)

    sql = """
    SELECT id, uri, title, genre, mode, signal_type, format, structure,
           node, sn_ratio, content, l0_abstract, l1_overview,
           modified_at, created_at, workspace_id
    FROM contexts
    WHERE tenant_id = ?2 AND workspace_id = ?1 AND type = 'signal'
    ORDER BY created_at ASC
    """

    with {:ok, rows} <- Store.raw_query(sql, [workspace_id, tenant_id]) do
      {signals, withheld} =
        ReadScope.filter(
          reader,
          workspace_id,
          "contexts",
          Enum.map(rows, &signal_row_to_map/1),
          & &1.id,
          &(&1.uri || &1.id)
        )

      {:ok, signals, withheld}
    end
  end

  @doc """
  Export all active memories (latest, non-forgotten) from a workspace as
  a list of JSON-serializable maps.

  Options:
    - `:workspace_id` — source workspace (default: `"default"`)
    - `:tenant_id`: tenant to read (default: the workspace's tenant)
    - `:reader`: the `OptimalEngine.ReadScope` of a keyed caller: only the
      memories it may see are exported, in its tenant (nil exports all of
      `:tenant_id`'s)

  A failing read of the Store is an error, never an empty export.
  """
  @spec export_memories(keyword()) :: {:ok, list(map())} | {:error, term()}
  def export_memories(opts \\ []) do
    with {:ok, memories, _withheld} <- read_memories(opts), do: {:ok, memories}
  end

  @doc """
  `export_memories/1` that also says how many memories the reader was not
  allowed to see: `{:ok, memories, withheld}`.
  """
  @spec read_memories(keyword()) :: {:ok, list(map()), non_neg_integer()} | {:error, term()}
  def read_memories(opts \\ []) do
    {tenant_id, workspace_id} = read_scope(opts)
    reader = Keyword.get(opts, :reader)

    sql = """
    SELECT id, tenant_id, workspace_id, content, content_hash,
           is_static, is_forgotten, forget_after, forget_reason,
           version, parent_memory_id, root_memory_id, is_latest,
           citation_uri, source_chunk_id, audience, metadata,
           created_at, updated_at
    FROM memories
    WHERE tenant_id = ?2 AND workspace_id = ?1 AND is_latest = 1 AND is_forgotten = 0
    ORDER BY created_at ASC
    """

    with {:ok, rows} <- Store.raw_query(sql, [workspace_id, tenant_id]) do
      {memories, withheld} =
        ReadScope.filter(
          reader,
          workspace_id,
          "memories",
          Enum.map(rows, &memory_row_to_map/1),
          & &1.id,
          &"optimal://memory/#{&1.workspace_id}/#{&1.id}"
        )

      {:ok, memories, withheld}
    end
  end

  @doc """
  Export a full workspace snapshot combining signals, memories, wiki pages,
  and workspace config into a single JSON-serializable map.

  Options:
    - `:tenant_id`: tenant id (default: the workspace's tenant)
    - `:reader`: the `OptimalEngine.ReadScope` of a keyed caller: only the
      signals, memories and wiki pages it may see are exported, and the
      tenant is the reader's (nil exports all of `:tenant_id`'s)
  """
  @spec export_workspace(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def export_workspace(workspace_id, opts \\ []) when is_binary(workspace_id) do
    with {:ok, snapshot, _withheld} <- read_workspace(workspace_id, opts), do: {:ok, snapshot}
  end

  @doc """
  `export_workspace/2` that also says how many signals, memories and wiki
  pages the reader was not allowed to see: `{:ok, snapshot, withheld}`.
  """
  @spec read_workspace(String.t(), keyword()) ::
          {:ok, map(), non_neg_integer()} | {:error, term()}
  def read_workspace(workspace_id, opts \\ []) when is_binary(workspace_id) do
    reader = Keyword.get(opts, :reader)
    {tenant_id, workspace_id} = read_scope(Keyword.put(opts, :workspace_id, workspace_id))

    with {:ok, signals, hidden_signals} <-
           read_signals(workspace_id: workspace_id, tenant_id: tenant_id, reader: reader),
         {:ok, memories, hidden_memories} <-
           read_memories(workspace_id: workspace_id, tenant_id: tenant_id, reader: reader),
         {:ok, pages} <- export_wiki_pages(workspace_id, tenant_id) do
      {wiki_pages, hidden_pages} =
        ReadScope.filter_rows(
          reader,
          workspace_id,
          "wiki_pages",
          pages,
          &wiki_row/1,
          &"wiki:#{&1.slug}:#{&1.audience}"
        )

      snapshot = %{
        workspace_id: workspace_id,
        tenant_id: tenant_id,
        exported_at: DateTime.utc_now() |> DateTime.to_iso8601(),
        signals: signals,
        memories: memories,
        wiki: wiki_pages,
        config: export_workspace_config(workspace_id)
      }

      {:ok, snapshot, hidden_signals + hidden_memories + hidden_pages}
    end
  end

  # ---------------------------------------------------------------------------
  # Private: import helpers
  # ---------------------------------------------------------------------------

  defp process_signal_item(item, workspace_id) when is_map(item) do
    content = Map.get(item, "content") || Map.get(item, :content)

    if not (is_binary(content) and content != "") do
      Logger.warning("[Batch] Skipping signal item — missing content: #{inspect(Map.keys(item))}")
      :error
    else
      intake_opts =
        [workspace_id: workspace_id]
        |> maybe_kw_put(:genre, item["genre"] || item[:genre])
        |> maybe_kw_put(:node, item["node"] || item[:node])
        |> maybe_kw_put(:title, item["title"] || item[:title])
        |> maybe_kw_put(:entities, item["entities"] || item[:entities])

      case Intake.process(content, intake_opts) do
        {:ok, _result} ->
          :imported

        {:error, :duplicate} ->
          :skipped

        {:error, reason} ->
          Logger.warning("[Batch] Signal import error: #{inspect(reason)}")
          :error
      end
    end
  rescue
    e ->
      Logger.warning("[Batch] Signal import exception: #{inspect(e)}")
      :error
  end

  defp process_signal_item(_item, _workspace_id), do: :error

  defp process_memory_item(item, {tenant_id, workspace_id}) when is_map(item) do
    content = Map.get(item, "content") || Map.get(item, :content)

    if not (is_binary(content) and content != "") do
      Logger.warning("[Batch] Skipping memory item — missing content")
      :error
    else
      attrs =
        %{content: content, workspace_id: workspace_id, tenant_id: tenant_id}
        |> maybe_map_put(:is_static, item["is_static"] || item[:is_static])
        |> maybe_map_put(:audience, item["audience"] || item[:audience])
        |> maybe_map_put(:citation_uri, item["citation_uri"] || item[:citation_uri])
        |> maybe_map_put(:source_chunk_id, item["source_chunk_id"] || item[:source_chunk_id])
        |> maybe_map_put(:metadata, item["metadata"] || item[:metadata])

      case Memory.create(attrs) do
        {:ok, %{was_existing: true}} ->
          :skipped

        {:ok, _mem} ->
          :imported

        {:error, reason} ->
          Logger.warning("[Batch] Memory import error: #{inspect(reason)}")
          :error
      end
    end
  rescue
    e ->
      Logger.warning("[Batch] Memory import exception: #{inspect(e)}")
      :error
  end

  defp process_memory_item(_item, _scope), do: :error

  # ---------------------------------------------------------------------------
  # Private: export helpers
  # ---------------------------------------------------------------------------

  # Every page of the workspace, a page of rows at a time (`Wiki.list/3` stops
  # at 50 unless it is asked for more). A Store that cannot be read is an
  # error, never a shorter list.
  @wiki_page_size 500

  defp export_wiki_pages(workspace_id, tenant_id), do: wiki_pages(workspace_id, tenant_id, 0, [])

  defp wiki_pages(workspace_id, tenant_id, offset, acc) do
    case Wiki.list(tenant_id, workspace_id, limit: @wiki_page_size, offset: offset) do
      {:ok, pages} ->
        acc = [Enum.map(pages, &wiki_export/1) | acc]

        if length(pages) < @wiki_page_size,
          do: {:ok, acc |> Enum.reverse() |> Enum.concat()},
          else: wiki_pages(workspace_id, tenant_id, offset + @wiki_page_size, acc)

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, other}
    end
  end

  defp wiki_export(p) do
    %{
      slug: p.slug,
      audience: p.audience,
      version: p.version,
      body: p.body,
      last_curated: p.last_curated,
      curated_by: p.curated_by,
      frontmatter: p.frontmatter,
      workspace_id: p.workspace_id,
      tenant_id: p.tenant_id
    }
  end

  # A reader sees its own tenant only; the trusted operator (no reader) is not
  # narrowed, as before.
  # A keyed caller reads its own tenant; anyone else `:tenant_id`, defaulting to
  # the workspace's own tenant (OptimalEngine.Graph.scope/1).
  defp read_scope(opts) do
    case Keyword.get(opts, :reader) do
      %ReadScope{tenant_id: tenant_id} -> {tenant_id, Keyword.get(opts, :workspace_id, "default")}
      nil -> Graph.scope(opts)
    end
  end

  # A wiki page as the columns the lineage reads it by.
  defp wiki_row(page) do
    %{
      "tenant_id" => page.tenant_id,
      "workspace_id" => page.workspace_id,
      "slug" => page.slug,
      "audience" => page.audience,
      "version" => page.version,
      "frontmatter" => page.frontmatter,
      "body" => page.body
    }
  end

  defp export_workspace_config(workspace_id) do
    with {:ok, ws} <- Workspace.get(workspace_id),
         {:ok, cfg} <- OptimalEngine.Workspace.Config.get(ws.id) do
      cfg
    else
      _ -> %{}
    end
  end

  defp signal_row_to_map([
         id,
         uri,
         title,
         genre,
         mode,
         signal_type,
         format,
         structure,
         node,
         sn_ratio,
         content,
         l0_abstract,
         l1_overview,
         modified_at,
         created_at,
         workspace_id
       ]) do
    %{
      id: id,
      uri: uri,
      title: title,
      genre: genre,
      mode: mode,
      signal_type: signal_type,
      format: format,
      structure: structure,
      node: node,
      sn_ratio: sn_ratio,
      content: content,
      l0_abstract: l0_abstract,
      l1_overview: l1_overview,
      modified_at: modified_at,
      created_at: created_at,
      workspace_id: workspace_id
    }
  end

  defp memory_row_to_map([
         id,
         tenant_id,
         workspace_id,
         content,
         content_hash,
         is_static,
         is_forgotten,
         forget_after,
         forget_reason,
         version,
         parent_memory_id,
         root_memory_id,
         is_latest,
         citation_uri,
         source_chunk_id,
         audience,
         metadata_json,
         created_at,
         updated_at
       ]) do
    %{
      id: id,
      tenant_id: tenant_id,
      workspace_id: workspace_id,
      content: content,
      content_hash: content_hash,
      is_static: is_static == 1,
      is_forgotten: is_forgotten == 1,
      forget_after: forget_after,
      forget_reason: forget_reason,
      version: version,
      parent_memory_id: parent_memory_id,
      root_memory_id: root_memory_id,
      is_latest: is_latest == 1,
      citation_uri: citation_uri,
      source_chunk_id: source_chunk_id,
      audience: audience,
      metadata: decode_json(metadata_json),
      created_at: created_at,
      updated_at: updated_at
    }
  end

  defp decode_json(nil), do: %{}
  defp decode_json(""), do: %{}

  defp decode_json(s) when is_binary(s) do
    case Jason.decode(s) do
      {:ok, m} -> m
      _ -> %{}
    end
  end

  defp maybe_kw_put(kw, _key, nil), do: kw
  defp maybe_kw_put(kw, _key, []), do: kw
  defp maybe_kw_put(kw, key, val), do: Keyword.put(kw, key, val)

  defp maybe_map_put(map, _key, nil), do: map
  defp maybe_map_put(map, key, val), do: Map.put(map, key, val)
end
