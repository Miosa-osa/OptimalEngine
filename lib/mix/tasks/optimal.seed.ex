defmodule Mix.Tasks.Optimal.Seed do
  @shortdoc "Load a small demo dataset so the graph + RAG + wiki have something to show"

  @moduledoc """
  Seeds the engine with a realistic mini-company dataset — people, orgs,
  products, concepts, operations, and the signals that connect them.

  Use this after a fresh `mix compile` to have something to look at when
  you fire up the desktop UI (the `/graph` route goes dark on an empty
  engine).

  ## Usage

      mix optimal.seed                    — default ~20 signals
      mix optimal.seed --reset            — wipe demo rows first, re-seed
      mix optimal.seed --tenant acme      — target a specific tenant

  ## What gets created

    * 6 organizational nodes (roberto, miosa, redacted, redacted, agency,
      content-creators)
    * ~20 signals spanning decisions, calls, plans, transcripts
    * ~30 extracted entities with type stamps (person, org, product,
      concept, operation) so the `/api/optimal/graph` co-occurrence
      query produces a navigable graph
    * 1 curated wiki page so `/api/wiki` has at least one example

  Idempotent — re-running inserts fresh rows with unique ids unless
  `--reset` is passed.
  """

  use Mix.Task

  alias OptimalEngine.Store
  alias OptimalEngine.Wiki
  alias OptimalEngine.Wiki.Page

  @demo_tag "demo-seed"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {parsed, _, _} =
      OptionParser.parse(args, strict: [reset: :boolean, tenant: :string])

    tenant = Keyword.get(parsed, :tenant, "default")
    reset? = Keyword.get(parsed, :reset, false)

    if reset?, do: wipe_demo_rows(tenant)

    seed_nodes(tenant)
    signals = seed_signals(tenant)
    seed_entities(signals)
    seed_wiki_page(tenant)

    stats = count_rows(tenant)

    IO.puts("""

    Demo seed complete.
      tenant:    #{tenant}
      nodes:     #{stats.nodes}
      contexts:  #{stats.contexts}
      entities:  #{stats.entities}
      wiki:      #{stats.wiki}

    Try:
      mix optimal.rag "redacted pricing"
      mix optimal.wiki list
      (enable the HTTP API and open the desktop at /graph)
    """)
  end

  # ─── schema seeding ─────────────────────────────────────────────────────

  defp seed_nodes(tenant) do
    nodes = [
      {"redacted", "redacted", "person"},
      {"02-miosa", "MIOSA LLC", "org"},
      {"03-redacted", "redacted LLC", "org"},
      {"04-redacted", "redacted Course", "operation"},
      {"06-agency-accelerants", "redacted", "org"},
      {"08-content-creators", "Content Creators Network", "org"}
    ]

    Enum.each(nodes, fn {slug, name, kind} ->
      id = "#{tenant}:node:#{slug}"

      Store.raw_query(
        """
        INSERT OR IGNORE INTO nodes (id, tenant_id, slug, name, kind, path, metadata)
        VALUES (?1, ?2, ?3, ?4, ?5, ?3, ?6)
        """,
        [id, tenant, slug, name, kind, Jason.encode!(%{tag: @demo_tag})]
      )
    end)
  end

  defp seed_signals(tenant) do
    signals = signal_fixtures()

    Enum.map(signals, fn sig ->
      id = "seed-#{sig.slug}-#{System.unique_integer([:positive])}"
      uri = "optimal://nodes/#{sig.node}/signals/#{sig.slug}.md"

      Store.raw_query(
        """
        INSERT INTO contexts (
          id, tenant_id, uri, type, path, title, l0_abstract, l1_overview,
          content, genre, mode, signal_type, format, structure, node,
          sn_ratio, entities, created_at, modified_at, metadata
        )
        VALUES (?1, ?2, ?3, 'signal', ?4, ?5, ?6, ?7, ?8, ?9, 'linguistic',
                'inform', 'markdown', 'prose', ?10, 0.75, '[]',
                datetime('now'), datetime('now'), ?11)
        """,
        [
          id,
          tenant,
          uri,
          uri,
          sig.title,
          sig.abstract,
          sig.abstract,
          sig.content,
          sig.genre,
          sig.node,
          Jason.encode!(%{tag: @demo_tag})
        ]
      )

      Map.put(sig, :id, id)
    end)
  end

  defp seed_entities(signals) do
    Enum.each(signals, fn sig ->
      Enum.each(sig.entities, fn {name, type} ->
        Store.raw_query(
          "INSERT OR IGNORE INTO entities (context_id, name, type) VALUES (?1, ?2, ?3)",
          [sig.id, name, type]
        )
      end)
    end)
  end

  defp seed_wiki_page(tenant) do
    slug = "redacted-pricing-decision"

    page = %Page{
      tenant_id: tenant,
      slug: slug,
      audience: "default",
      version: 1,
      frontmatter: %{"slug" => slug, "title" => "redacted Pricing Decision", "tag" => @demo_tag},
      body: """
      ## Summary

      redacted pricing set at $2K per seat for Q4 based on the redacted
      call {{cite: optimal://nodes/04-redacted/signals/ed-honour-call.md}}.

      ## Related

      Bennett closed the first redacted deal {{cite: optimal://nodes/06-agency-accelerants/signals/redacted-first-close.md}}.
      """,
      last_curated: DateTime.utc_now() |> DateTime.to_iso8601(),
      curated_by: "deterministic:demo-seed"
    }

    Wiki.put(page)
  end

  # ─── fixtures ───────────────────────────────────────────────────────────

  defp signal_fixtures do
    [
      %{
        slug: "ed-honour-call",
        node: "04-redacted",
        title: "redacted — pricing call Q4",
        genre: "transcript",
        abstract: "Ed called about Q4 pricing; wants $2K per seat.",
        content:
          "redacted called to discuss redacted pricing for Q4. He wants $2K per seat. Roberto agreed to run the numbers with redacted before replying.",
        entities: [
          {"redacted", "person"},
          {"redacted", "person"},
          {"redacted", "person"},
          {"redacted", "product"},
          {"redacted Course", "operation"}
        ]
      },
      %{
        slug: "redacted-first-close",
        node: "06-agency-accelerants",
        title: "Bennett closed first redacted deal",
        genre: "note",
        abstract: "Bennett closed first redacted deal.",
        content:
          "Bennett closed the first redacted deal with Atif's clinic network in Sacramento. Onboarding handoff to Len; Roberto CC'd for context.",
        entities: [
          {"Bennett", "person"},
          {"Atif", "person"},
          {"redacted", "product"},
          {"redacted", "org"},
          {"Len", "person"}
        ]
      },
      %{
        slug: "redacted-spec",
        node: "02-miosa",
        title: "MIOSA platform — Firecracker VM isolation",
        genre: "spec",
        abstract: "Firecracker-based VM per tenant on the MIOSA compute plane.",
        content:
          "redacted and Pedro scoped Firecracker microVM isolation on the MIOSA compute plane. Each tenant gets an isolated VM; envd runs inside. Nejd owns the proxy layer.",
        entities: [
          {"redacted", "person"},
          {"Pedro", "person"},
          {"Nejd", "person"},
          {"MIOSA", "product"},
          {"Firecracker", "concept"},
          {"envd", "concept"}
        ]
      },
      %{
        slug: "redacted-package",
        node: "02-miosa",
        title: "redacted — redacted package",
        genre: "plan",
        abstract: "Send Robert the redacted sales package by Thursday.",
        content:
          "Assemble the redacted package for redacted — ad scripts, VSLs, the offer stack — and hand it off by Thursday. Bennett provides conversion data.",
        entities: [
          {"redacted", "person"},
          {"Bennett", "person"},
          {"MIOSA", "product"},
          {"redacted", "org"},
          {"Ad Scripts", "concept"}
        ]
      },
      %{
        slug: "content-os-launch",
        node: "08-content-creators",
        title: "ContentOS launch — Tejas build handoff",
        genre: "decision_log",
        abstract: "ContentOS launch handed off to Tejas after Ikram spec review.",
        content:
          "Decided: Tejas takes the ContentOS build now that Ikram finished the redacted spec review. redacted owns the launch podcast series.",
        entities: [
          {"Tejas", "person"},
          {"Ikram", "person"},
          {"redacted", "person"},
          {"ContentOS", "product"},
          {"redacted", "concept"}
        ]
      },
      %{
        slug: "redacted-course-structure",
        node: "04-redacted",
        title: "redacted course structure — beginner + advanced",
        genre: "plan",
        abstract: "redacted split into beginner + advanced tracks with a $10K tier on top.",
        content:
          "redacted structure confirmed: beginner track, advanced track, and a $10K tier on top. redacted co-teaches beginner; Adam handles advanced. redacted runs sales.",
        entities: [
          {"redacted", "person"},
          {"Adam", "person"},
          {"redacted", "person"},
          {"redacted Course", "operation"}
        ]
      },
      %{
        slug: "redacted-invoice-1234",
        node: "03-redacted",
        title: "redacted — invoice 1234",
        genre: "note",
        abstract: "redacted invoice 1234 to redacted for October agency services.",
        content:
          "redacted LLC invoiced redacted $8,500 for October agency services (invoice 1234). 30-day terms.",
        entities: [
          {"redacted LLC", "org"},
          {"redacted", "product"}
        ]
      },
      %{
        slug: "os-architect-youtube",
        node: "02-miosa",
        title: "OS Architect YouTube — Ahmed first pilot",
        genre: "plan",
        abstract: "Ahmed kicks off OS Architect YouTube channel with pilot episode.",
        content:
          "Ahmed is kicking off the OS Architect YouTube channel; pilot episode on compute-layer design. Roberto appears as guest.",
        entities: [
          {"Ahmed", "person"},
          {"redacted", "person"},
          {"OS Architect", "concept"}
        ]
      },
      %{
        slug: "redacted-partnership",
        node: "02-miosa",
        title: "redacted — 50/50 technical partnership",
        genre: "decision_log",
        abstract: "redacted confirmed as 50/50 technical partner on MIOSA.",
        content:
          "Decision: redacted is now 50/50 technical partner on MIOSA. Licensing, infrastructure, middleware all report to him.",
        entities: [
          {"redacted", "person"},
          {"redacted", "person"},
          {"MIOSA", "product"}
        ]
      },
      %{
        slug: "jordan-consortium-call",
        node: "redacted",
        title: "Jordan consortium call — political economy",
        genre: "transcript",
        abstract: "Jordan ran political economy pitch for consortium play.",
        content:
          "Jordan walked through the consortium pitch — political economy framing. Tom joined on recruitment. Roberto to follow up with a brief.",
        entities: [
          {"Jordan", "person"},
          {"Tom", "person"},
          {"redacted", "person"}
        ]
      }
    ]
  end

  # ─── housekeeping ───────────────────────────────────────────────────────

  defp wipe_demo_rows(tenant) do
    Store.raw_query(
      "DELETE FROM contexts WHERE tenant_id = ?1 AND json_extract(metadata, '$.tag') = ?2",
      [tenant, @demo_tag]
    )

    Store.raw_query(
      "DELETE FROM nodes WHERE tenant_id = ?1 AND json_extract(metadata, '$.tag') = ?2",
      [tenant, @demo_tag]
    )

    Store.raw_query(
      "DELETE FROM wiki_pages WHERE tenant_id = ?1 AND json_extract(frontmatter, '$.tag') = ?2",
      [tenant, @demo_tag]
    )
  end

  defp count_rows(tenant) do
    %{
      nodes: count(tenant, "SELECT COUNT(*) FROM nodes WHERE tenant_id = ?1"),
      contexts: count(tenant, "SELECT COUNT(*) FROM contexts WHERE tenant_id = ?1"),
      entities:
        count(tenant, """
        SELECT COUNT(*) FROM entities e
        JOIN contexts c ON c.id = e.context_id
        WHERE c.tenant_id = ?1
        """),
      wiki: count(tenant, "SELECT COUNT(*) FROM wiki_pages WHERE tenant_id = ?1")
    }
  end

  defp count(tenant, sql) do
    case Store.raw_query(sql, [tenant]) do
      {:ok, [[n]]} when is_integer(n) -> n
      _ -> 0
    end
  end
end
