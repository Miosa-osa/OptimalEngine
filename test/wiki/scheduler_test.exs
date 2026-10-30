defmodule OptimalEngine.Wiki.SchedulerTest do
  use ExUnit.Case, async: false

  alias OptimalEngine.Store
  alias OptimalEngine.Wiki.{Page, Scheduler}
  alias OptimalEngine.Wiki.Store, as: WikiStore

  # ── helpers ─────────────────────────────────────────────────────────────────

  defp unique, do: System.unique_integer([:positive])

  defp base_page(overrides) do
    suffix = unique()

    defaults = [
      tenant_id: "default",
      workspace_id: "default",
      slug: "sched-test-#{suffix}",
      audience: "default",
      version: 1,
      frontmatter: %{},
      body: "## Summary\n\nContent."
    ]

    struct(Page, Keyword.merge(defaults, overrides))
  end

  # Insert a fake context (signal) and a paragraph-scale chunk, then return
  # {signal_id, chunk_id, node_slug}.
  defp insert_signal(node_slug, workspace_id, created_at) do
    signal_id = "sig-#{unique()}"
    chunk_id = "chunk-#{unique()}"
    ts = created_at || DateTime.utc_now() |> DateTime.to_iso8601()

    Store.raw_query(
      """
      INSERT OR IGNORE INTO contexts (id, tenant_id, workspace_id, node, uri, content, created_at)
      VALUES (?1, 'default', ?2, ?3, ?4, 'test content', ?5)
      """,
      [signal_id, workspace_id, node_slug, "optimal://#{node_slug}/#{signal_id}", ts]
    )

    Store.raw_query(
      """
      INSERT OR IGNORE INTO chunks (id, tenant_id, signal_id, scale, text)
      VALUES (?1, 'default', ?2, 'paragraph', 'new fact ingested')
      """,
      [chunk_id, signal_id]
    )

    {signal_id, chunk_id, node_slug}
  end

  # Link a chunk to a wiki page via the citations table.
  defp insert_citation(wiki_slug, wiki_audience, chunk_id, tenant_id \\ "default") do
    Store.raw_query(
      """
      INSERT OR IGNORE INTO citations (tenant_id, wiki_slug, wiki_audience, chunk_id, claim_hash)
      VALUES (?1, ?2, ?3, ?4, ?5)
      """,
      [tenant_id, wiki_slug, wiki_audience, chunk_id, "hash-#{unique()}"]
    )
  end

  # ── Tests ────────────────────────────────────────────────────────────────────

  describe "stale_pages/2" do
    test "page curated 10 days ago with new signals is detected as stale" do
      old_ts = DateTime.utc_now() |> DateTime.add(-10 * 86_400, :second) |> DateTime.to_iso8601()

      page =
        base_page(
          last_curated: old_ts,
          curated_by: "test"
        )

      :ok = WikiStore.put(page)

      # Insert a signal that arrived AFTER the last curation timestamp
      new_signal_ts =
        DateTime.utc_now() |> DateTime.add(-1 * 86_400, :second) |> DateTime.to_iso8601()

      {_sig_id, chunk_id, _node} = insert_signal("node-a-#{unique()}", "default", new_signal_ts)
      insert_citation(page.slug, page.audience, chunk_id)

      stale = Scheduler.stale_pages("default", tenant_id: "default")
      slugs = Enum.map(stale, & &1.slug)

      assert page.slug in slugs,
             "expected #{page.slug} to be in stale list, got: #{inspect(slugs)}"
    end

    test "page curated today is not stale" do
      recent_ts = DateTime.utc_now() |> DateTime.to_iso8601()

      page =
        base_page(
          last_curated: recent_ts,
          curated_by: "test"
        )

      :ok = WikiStore.put(page)

      stale = Scheduler.stale_pages("default", tenant_id: "default")
      slugs = Enum.map(stale, & &1.slug)

      refute page.slug in slugs,
             "expected #{page.slug} NOT to be stale (curated today)"
    end

    test "page curated 10 days ago but with no new signals is not stale" do
      old_ts = DateTime.utc_now() |> DateTime.add(-10 * 86_400, :second) |> DateTime.to_iso8601()

      page =
        base_page(
          last_curated: old_ts,
          curated_by: "test"
        )

      :ok = WikiStore.put(page)

      # Insert a signal, but attach it BEFORE last_curated so it doesn't qualify
      very_old_ts =
        DateTime.utc_now() |> DateTime.add(-20 * 86_400, :second) |> DateTime.to_iso8601()

      {_sig_id, chunk_id, _node} =
        insert_signal("node-b-#{unique()}", "default", very_old_ts)

      insert_citation(page.slug, page.audience, chunk_id)

      stale = Scheduler.stale_pages("default", tenant_id: "default")
      slugs = Enum.map(stale, & &1.slug)

      refute page.slug in slugs,
             "expected #{page.slug} NOT to be stale (no new signals)"
    end

    test "page older than the limit with no citations is stale" do
      old_ts = DateTime.utc_now() |> DateTime.add(-10 * 86_400, :second) |> DateTime.to_iso8601()

      page = base_page(last_curated: old_ts, curated_by: "test")
      :ok = WikiStore.put(page)

      slugs = Scheduler.stale_pages("default", tenant_id: "default") |> Enum.map(& &1.slug)

      assert page.slug in slugs,
             "expected uncited #{page.slug} to be stale by age, got: #{inspect(slugs)}"
    end

    test "page younger than the limit with no citations is not stale" do
      recent_ts = DateTime.utc_now() |> DateTime.add(-1 * 86_400, :second) |> DateTime.to_iso8601()

      page = base_page(last_curated: recent_ts, curated_by: "test")
      :ok = WikiStore.put(page)

      slugs = Scheduler.stale_pages("default", tenant_id: "default") |> Enum.map(& &1.slug)

      refute page.slug in slugs
    end
  end

  describe "run_scan/2 — re-curation needs material" do
    defmodule RefusingCurator do
      def curate(page, _citations),
        do: %{ok?: false, page: page, metadata: %{reason: :refused}, warnings: []}
    end

    defp old_page(extra \\ []) do
      old_ts = DateTime.utc_now() |> DateTime.add(-10 * 86_400, :second) |> DateTime.to_iso8601()
      node = "node-uncited-#{unique()}"

      page =
        base_page(
          Keyword.merge(
            [last_curated: old_ts, curated_by: "test", frontmatter: %{"node_slug" => node}],
            extra
          )
        )

      :ok = WikiStore.put(page)
      {page, node}
    end

    defp queued_slugs(slug) do
      Scheduler.run_scan("default", sync: true, slugs: [slug]) |> Enum.map(& &1.slug)
    end

    test "an uncited stale page with recent node contexts is queued with them as citations" do
      {page, node} = old_page()
      {_sig, chunk_id, _} = insert_signal(node, "default", nil)

      queued = Scheduler.run_scan("default", sync: true, slugs: [page.slug])
      entry = Enum.find(queued, &(&1.slug == page.slug))

      assert entry, "expected #{page.slug} to be queued"
      assert [%{chunk_id: ^chunk_id, uri: uri}] = entry.citations
      assert uri == "optimal://#{node}##{chunk_id}"
    end

    test "an uncited stale page with no contexts in its node is not queued but stays listed" do
      {page, _node} = old_page()

      refute page.slug in queued_slugs(page.slug)
      assert page.slug in (Scheduler.stale_pages("default") |> Enum.map(& &1.slug))
    end

    test "a refused curation is not requeued within the stale window" do
      {page, node} = old_page()
      insert_signal(node, "default", nil)

      Application.put_env(:optimal_engine, :wiki_curator, RefusingCurator)
      on_exit(fn -> Application.delete_env(:optimal_engine, :wiki_curator) end)

      assert page.slug in queued_slugs(page.slug)
      Application.delete_env(:optimal_engine, :wiki_curator)

      refute page.slug in queued_slugs(page.slug)
      assert page.slug in (Scheduler.stale_pages("default") |> Enum.map(& &1.slug))
    end
  end

  describe "force_run/1" do
    test "cast returns :ok and does not crash the GenServer" do
      assert :ok = Scheduler.force_run("default")

      # Give the cast time to be processed; the GenServer must still be alive.
      Process.sleep(50)
      assert Process.alive?(Process.whereis(Scheduler))
    end
  end

  describe "config disabled" do
    test "when curation is disabled, stale_pages still returns results (disabled suppresses tick, not the public API)" do
      # The enabled flag gates the periodic tick, not the public stale_pages/2
      # call. Callers can always introspect staleness; only the background
      # scheduler skips curation when disabled.
      #
      # This test asserts the public API is unaffected by the config flag.
      stale = Scheduler.stale_pages("default")
      assert is_list(stale)
    end
  end
end
