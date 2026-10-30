defmodule OptimalEngine.Wiki.Scheduler do
  @moduledoc """
  Periodic wiki maintenance. Scans for stale pages and queues re-curation.

  A page is "stale" when:
  - `last_curated` is older than the workspace's configured `max_stale_days` (default 7)
  - AND either it has no citations, or new signals have been ingested into
    its cited nodes since `last_curated`

  Both conditions must hold. A cited page that is old but has no new
  supporting signals is not worth re-curating — the LLM would have nothing
  new to integrate. A page without citations has nothing to check against,
  so age alone makes it stale (see `OptimalEngine.Wiki.Freshness`).

  Runs every `interval_minutes` (default 60, configurable per workspace via
  the `:curation` config section). Each tick processes at most
  `max_pages_per_cycle` pages per workspace to avoid overwhelming Ollama.

  ## Re-curation needs material

  A stale page is queued only when the curator has something to work with:
  new chunks in its cited nodes, or, for a page with no citations, the most
  recent chunks of its own node (frontmatter `node_slug`) or of its
  workspace. A curation that changes nothing (refused, or failed) is
  recorded in the page frontmatter and not retried until the next stale
  window, so one page never costs a model call every tick. `stale_pages/2`
  and `/api/wiki/stale` still list it.

  ## Scheduling

  The first tick fires after a 5-minute boot delay so the rest of the
  supervision tree (Ollama, SQLite) can come up before any work begins.
  Subsequent ticks are governed by the shortest `interval_minutes` across
  all active workspaces, re-evaluated on each tick.

  ## Manual control

      OptimalEngine.Wiki.Scheduler.force_run("default")
  """

  use GenServer
  require Logger

  alias OptimalEngine.Store, as: RawStore
  alias OptimalEngine.Wiki.{Curator, Freshness, Page}
  alias OptimalEngine.Wiki.Store, as: WikiStore
  alias OptimalEngine.Workspace
  alias OptimalEngine.Workspace.Config

  @boot_delay_ms 5 * 60 * 1_000
  @default_interval_minutes 60
  @default_max_stale_days 7
  @default_max_pages_per_cycle 5
  @material_limit 50

  defstruct timer_ref: nil,
            last_run: nil

  # ── Public API ───────────────────────────────────────────────────────────────

  @doc "Start the scheduler under the supervision tree."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns stale pages for a workspace — those older than `max_stale_days`
  that also have new signals in their cited nodes since `last_curated`.

  Options:
    * `:max_stale_days` — override days threshold (default from workspace config)
    * `:tenant_id`      — tenant to scope (default: `"default"`)
  """
  @spec stale_pages(String.t(), keyword()) :: [Page.t()]
  def stale_pages(workspace_id, opts \\ []) do
    GenServer.call(__MODULE__, {:stale_pages, workspace_id, opts})
  end

  @doc "Trigger an immediate curation scan for a workspace without waiting for the tick."
  @spec force_run(String.t()) :: :ok
  def force_run(workspace_id) do
    GenServer.cast(__MODULE__, {:force_run, workspace_id})
  end

  @doc """
  Run one curation scan for a workspace and return the pages it queued.

  A stale page is queued only when the curator has material for it and it was
  not attempted within the stale window. `slugs: [..]` limits the scan to
  those pages. With `sync: true` each curation runs
  before the call returns (otherwise it runs in a detached task).
  Returns `[%{slug: _, audience: _, citations: [citation]}]`.
  """
  @spec run_scan(String.t(), keyword()) :: [map()]
  def run_scan(workspace_id, opts \\ []) do
    GenServer.call(__MODULE__, {:run_scan, workspace_id, opts}, :infinity)
  end

  # ── GenServer callbacks ──────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    timer_ref = Process.send_after(self(), :tick, @boot_delay_ms)

    Logger.info("[Wiki.Scheduler] started — first scan in #{div(@boot_delay_ms, 60_000)}min")

    {:ok, %__MODULE__{timer_ref: timer_ref}}
  end

  @impl true
  def handle_call({:stale_pages, workspace_id, opts}, _from, state) do
    tenant_id = Keyword.get(opts, :tenant_id, "default")
    cur_cfg = curation_config(workspace_id)

    max_stale_days =
      Keyword.get(opts, :max_stale_days, Map.get(cur_cfg, :max_stale_days, @default_max_stale_days))

    pages = find_stale_pages(tenant_id, workspace_id, max_stale_days)
    {:reply, pages, state}
  end

  def handle_call({:run_scan, workspace_id, opts}, _from, state) do
    {:reply, run_workspace_scan(workspace_id, opts), state}
  end

  @impl true
  def handle_cast({:force_run, workspace_id}, state) do
    Logger.info("[Wiki.Scheduler] force_run requested for workspace=#{workspace_id}")
    run_workspace_scan(workspace_id)
    {:noreply, state}
  end

  @impl true
  def handle_info(:tick, state) do
    state = cancel_timer(state)

    Logger.debug("[Wiki.Scheduler] tick — scanning all active workspaces")
    run_all_workspaces()

    next_ms = next_interval_ms()
    timer_ref = Process.send_after(self(), :tick, next_ms)

    {:noreply, %{state | timer_ref: timer_ref, last_run: DateTime.utc_now()}}
  end

  # ── Core scanning logic ──────────────────────────────────────────────────────

  defp run_all_workspaces do
    case Workspace.list(status: :active) do
      {:ok, workspaces} ->
        Enum.each(workspaces, fn ws -> run_workspace_scan(ws.id) end)

      {:error, reason} ->
        Logger.warning("[Wiki.Scheduler] failed to list workspaces: #{inspect(reason)}")
    end
  end

  defp run_workspace_scan(workspace_id, opts \\ []) do
    cur_cfg = curation_config(workspace_id)

    if Map.get(cur_cfg, :enabled, true) do
      max_stale_days = Map.get(cur_cfg, :max_stale_days, @default_max_stale_days)
      max_pages = Map.get(cur_cfg, :max_pages_per_cycle, @default_max_pages_per_cycle)
      sync? = Keyword.get(opts, :sync, false)

      # We use the workspace id as both workspace_id and tenant_id for now.
      # The default workspace has tenant "default"; multi-tenant support
      # can layer in a workspace→tenant lookup here later.
      tenant_id = "default"

      stale =
        tenant_id
        |> find_stale_pages(workspace_id, max_stale_days)
        |> restrict_to(Keyword.get(opts, :slugs))

      # A stale page is queued only when the curator has material for it and
      # the last attempt is outside the stale window; /api/wiki/stale keeps
      # listing it either way.
      batch =
        stale
        |> Stream.reject(&attempted_within?(&1, max_stale_days))
        |> Stream.map(fn page -> {page, curation_material(page)} end)
        |> Stream.reject(fn {_page, citations} -> citations == [] end)
        |> Enum.take(max_pages)

      if batch == [] do
        Logger.debug(
          "[Wiki.Scheduler] nothing to re-curate for workspace=#{workspace_id} (#{length(stale)} stale)"
        )
      else
        Logger.info(
          "[Wiki.Scheduler] workspace=#{workspace_id} — #{length(batch)} stale pages to re-curate (#{length(stale)} total stale)"
        )

        Enum.each(batch, fn {page, citations} ->
          if sync?,
            do: curate_page(page, citations, workspace_id),
            else: Task.start(fn -> curate_page(page, citations, workspace_id) end)
        end)
      end

      Enum.map(batch, fn {page, citations} ->
        %{slug: page.slug, audience: page.audience, citations: citations}
      end)
    else
      Logger.debug("[Wiki.Scheduler] curation disabled for workspace=#{workspace_id}, skipping")
      []
    end
  end

  defp restrict_to(pages, nil), do: pages
  defp restrict_to(pages, slugs), do: Enum.filter(pages, &(&1.slug in slugs))

  # ── Stale page detection ─────────────────────────────────────────────────────

  # A page is stale when:
  #   1. last_curated < now - max_stale_days
  #   2. it has no citations, or at least one context in a cited node has
  #      been ingested since last_curated
  #
  # Cited nodes are derived from the citations table:
  #   citation → chunk → signal (context) → node
  #
  # We do this in two queries to keep each query readable:
  #   Query 1 — pages older than max_stale_days
  #   Query 2 — for each, check if new signals exist in cited nodes
  defp find_stale_pages(tenant_id, workspace_id, max_stale_days) do
    age_sql = """
    SELECT w.tenant_id, w.workspace_id, w.slug, w.audience, w.version,
           w.frontmatter, w.body, w.last_curated, w.curated_by
    FROM wiki_pages w
    INNER JOIN (
      SELECT tenant_id, workspace_id, slug, audience, MAX(version) AS max_version
      FROM wiki_pages
      WHERE tenant_id = ?1 AND workspace_id = ?2
      GROUP BY tenant_id, workspace_id, slug, audience
    ) latest
      ON w.tenant_id    = latest.tenant_id
     AND w.workspace_id = latest.workspace_id
     AND w.slug         = latest.slug
     AND w.audience     = latest.audience
     AND w.version      = latest.max_version
    WHERE datetime(w.last_curated) < datetime('now', ?3)
    ORDER BY w.last_curated ASC
    """

    age_param = "-#{max_stale_days} days"

    case RawStore.raw_query(age_sql, [tenant_id, workspace_id, age_param]) do
      {:ok, rows} ->
        rows
        |> Enum.map(&row_to_page/1)
        |> Enum.filter(&Freshness.needs_curation?/1)

      {:error, reason} ->
        Logger.warning("[Wiki.Scheduler] stale query failed: #{inspect(reason)}")
        []
    end
  end

  # ── Async curation dispatch ──────────────────────────────────────────────────

  defp curate_page(%Page{} = page, citations, workspace_id) do
    Logger.info(
      "[Wiki.Scheduler] curating page=#{page.slug} audience=#{page.audience} workspace=#{workspace_id} last_curated=#{page.last_curated}"
    )

    outcome = curator().curate(page, citations)

    if outcome.ok? and outcome.metadata[:reason] != :no_new_citations do
      committed = %{outcome.page | frontmatter: clear_attempt(outcome.page.frontmatter)}

      case WikiStore.put(committed) do
        :ok ->
          Logger.info(
            "[Wiki.Scheduler] re-curation committed: page=#{page.slug} v#{outcome.page.version}"
          )

        {:error, reason} ->
          Logger.warning(
            "[Wiki.Scheduler] store.put failed after curation of page=#{page.slug}: #{inspect(reason)}"
          )

          WikiStore.record_curation_attempt(page)
      end
    else
      Logger.warning(
        "[Wiki.Scheduler] curation produced no change for page=#{page.slug}: #{inspect(outcome.metadata)}"
      )

      WikiStore.record_curation_attempt(page)
    end
  end

  # Overridable so tests can stand in a curator that refuses.
  defp curator, do: Application.get_env(:optimal_engine, :wiki_curator, Curator)

  defp clear_attempt(fm) when is_map(fm), do: Map.delete(fm, WikiStore.attempt_key())
  defp clear_attempt(fm), do: fm

  # An attempt is recorded in the page frontmatter (not last_curated, which
  # would make a stale page look fresh). It blocks another attempt until the
  # next stale window.
  defp attempted_within?(%Page{frontmatter: fm}, max_stale_days) when is_map(fm) do
    case Freshness.parse_time(Map.get(fm, WikiStore.attempt_key())) do
      {:ok, at} -> DateTime.diff(DateTime.utc_now(), at, :second) < max_stale_days * 86_400
      :error -> false
    end
  end

  defp attempted_within?(_, _), do: false

  # What the curator can work with: new chunks in the cited nodes, or, for a
  # page with no citations, the most recent chunks of its own node (or its
  # workspace when it has no node). Bounded at @material_limit either way.
  defp curation_material(%Page{} = page) do
    if Freshness.cited?(page), do: gather_new_citations(page), else: gather_node_citations(page)
  end

  defp gather_node_citations(%Page{} = page) do
    node = page_node(page)

    {sql, params} =
      if node do
        {"""
         SELECT DISTINCT ch.id, ch.text, ctx.node, ctx.created_at
         FROM contexts ctx
         JOIN chunks ch ON ch.signal_id = ctx.id
         WHERE ctx.tenant_id = ?1 AND ctx.workspace_id = ?2 AND ctx.node = ?3
           AND ch.scale = 'paragraph'
         ORDER BY ctx.created_at DESC
         LIMIT #{@material_limit}
         """, [page.tenant_id, page.workspace_id, node]}
      else
        {"""
         SELECT DISTINCT ch.id, ch.text, ctx.node, ctx.created_at
         FROM contexts ctx
         JOIN chunks ch ON ch.signal_id = ctx.id
         WHERE ctx.tenant_id = ?1 AND ctx.workspace_id = ?2
           AND ch.scale = 'paragraph'
         ORDER BY ctx.created_at DESC
         LIMIT #{@material_limit}
         """, [page.tenant_id, page.workspace_id]}
      end

    case RawStore.raw_query(sql, params) do
      {:ok, rows} -> Enum.map(rows, fn [id, text, n, _at] -> citation(id, text, n) end)
      _ -> []
    end
  end

  defp page_node(%Page{frontmatter: fm}) when is_map(fm) do
    case Map.get(fm, "node_slug") do
      node when is_binary(node) and node != "" -> node
      _ -> nil
    end
  end

  defp page_node(_), do: nil

  defp citation(chunk_id, text, node),
    do: %{chunk_id: chunk_id, text: text || "", uri: "optimal://#{node}##{chunk_id}"}

  # Gather chunks from cited nodes that are newer than last_curated.
  # Returns a list of citation maps compatible with Curator.curate/3.
  defp gather_new_citations(%Page{last_curated: nil}), do: []

  defp gather_new_citations(%Page{} = page) do
    sql = """
    SELECT DISTINCT ch.id, ch.text, ctx.node
    FROM contexts ctx
    JOIN chunks ch ON ch.signal_id = ctx.id
    WHERE ctx.node IN (
      SELECT DISTINCT ctx2.node
      FROM contexts ctx2
      JOIN chunks ch2  ON ch2.signal_id = ctx2.id
      JOIN citations   cit ON cit.chunk_id = ch2.id
      WHERE cit.wiki_slug     = ?1
        AND cit.wiki_audience = ?2
        AND cit.tenant_id     = ?3
    )
    AND datetime(ctx.created_at) > datetime(?4)
    AND ctx.workspace_id = ?5
    AND ch.scale = 'paragraph'
    ORDER BY ctx.created_at ASC
    LIMIT 50
    """

    params = [
      page.slug,
      page.audience,
      page.tenant_id,
      page.last_curated,
      page.workspace_id
    ]

    case RawStore.raw_query(sql, params) do
      {:ok, rows} ->
        Enum.map(rows, fn [chunk_id, text, node] -> citation(chunk_id, text, node) end)

      _ ->
        []
    end
  end

  # ── Scheduling helpers ───────────────────────────────────────────────────────

  # Use the shortest configured interval across all active workspaces, so the
  # scheduler honours any workspace that wants more frequent scans.
  defp next_interval_ms do
    case Workspace.list(status: :active) do
      {:ok, workspaces} ->
        min_minutes =
          workspaces
          |> Enum.map(fn ws ->
            ws.id
            |> curation_config()
            |> Map.get(:interval_minutes, @default_interval_minutes)
          end)
          |> Enum.min(fn -> @default_interval_minutes end)

        min_minutes * 60 * 1_000

      _ ->
        @default_interval_minutes * 60 * 1_000
    end
  end

  defp curation_config(workspace_id) do
    Config.get_section(workspace_id, :curation, default_curation_config())
  end

  defp default_curation_config do
    %{
      enabled: true,
      interval_minutes: @default_interval_minutes,
      max_stale_days: @default_max_stale_days,
      max_pages_per_cycle: @default_max_pages_per_cycle
    }
  end

  defp cancel_timer(%__MODULE__{timer_ref: nil} = state), do: state

  defp cancel_timer(%__MODULE__{timer_ref: ref} = state) do
    Process.cancel_timer(ref)
    %{state | timer_ref: nil}
  end

  # ── Row conversion ───────────────────────────────────────────────────────────

  defp row_to_page([
         tenant_id,
         workspace_id,
         slug,
         audience,
         version,
         fm_json,
         body,
         last_curated,
         curated_by
       ]) do
    frontmatter =
      case Jason.decode(fm_json || "{}") do
        {:ok, m} -> m
        _ -> %{}
      end

    %Page{
      tenant_id: tenant_id,
      workspace_id: workspace_id,
      slug: slug,
      audience: audience,
      version: version,
      frontmatter: frontmatter,
      body: body,
      last_curated: last_curated,
      curated_by: curated_by
    }
  end
end
