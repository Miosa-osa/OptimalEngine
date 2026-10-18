defmodule OptimalEngine.OperatingTest do
  @moduledoc """
  The operating layer: open loops, rhythm, protocol, brief, boot, portable
  topology, and routing rules. Each test runs in its own tenant.
  """

  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias OptimalEngine.API.Router
  alias OptimalEngine.Auth.ApiKey
  alias OptimalEngine.Operating.{Boot, Brief, Loops, Protocol, Rhythm}
  alias OptimalEngine.Routing.RuleStore
  alias OptimalEngine.Store
  alias OptimalEngine.Tenancy.Tenant
  alias OptimalEngine.Topology.Portable

  setup do
    n = System.unique_integer([:positive])
    tenant = "operating-#{n}"
    {:ok, _} = Tenant.create(%{id: tenant, name: "Operating #{n}"})
    %{tenant: tenant, workspace: "#{tenant}:ops", other: "#{tenant}:sales", n: n}
  end

  defp insert_context(tenant, workspace, id, title, content, created_at, metadata \\ %{}) do
    {:ok, _} =
      Store.raw_query(
        """
        INSERT INTO contexts (id, tenant_id, workspace_id, title, content, created_at, metadata)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
        """,
        [id, tenant, workspace, title, content, created_at, Jason.encode!(metadata)]
      )
  end

  describe "loop detection" do
    test "commitments, asks, money and decisions with due dates" do
      # 2026-10-14 is a Wednesday.
      reference = ~D[2026-10-14]

      found =
        Loops.detect(
          """
          Thanks for the call. I'll send the revised proposal by Friday.
          Can you confirm the start date before next Monday?
          The deposit invoice is still outstanding.
          We need your decision on the vendor by 2026-10-20.
          The weather was nice.
          """,
          reference
        )

      assert [
               %{"kind" => "commitment", "due_at" => "2026-10-16"},
               %{"kind" => "owed_reply", "due_at" => "2026-10-19"},
               %{"kind" => "payment_owed", "due_at" => nil},
               %{"kind" => "decision_needed", "due_at" => "2026-10-20"}
             ] = found
    end

    test "relative dates resolve against the reference day" do
      reference = ~D[2026-10-14]
      assert Loops.due_date("I'll do it tomorrow", reference) == ~D[2026-10-15]
      assert Loops.due_date("we will ship by end of week", reference) == ~D[2026-10-16]
      assert Loops.due_date("on Wednesday", reference) == ~D[2026-10-21]
      assert Loops.due_date("by Nov 3rd", reference) == ~D[2026-11-03]
      assert Loops.due_date("by Jan 5", reference) == ~D[2027-01-05]
      assert Loops.due_date("no date here", reference) == nil
    end
  end

  describe "loops" do
    test "create is idempotent, and close, drop, reopen move state", ctx do
      attrs = %{
        "workspace_id" => ctx.workspace,
        "title" => "Send the deck",
        "counterparty" => "Northwind",
        "due_at" => "2026-10-20"
      }

      {:ok, loop} = Loops.create(ctx.tenant, attrs, "user:owner")

      {:ok, again} =
        Loops.create(ctx.tenant, Map.put(attrs, "title", "send the DECK!"), "user:owner")

      assert again.id == loop.id

      assert {:ok, %{state: "closed", closed_by: "user:owner"}} =
               Loops.close(ctx.tenant, loop.id, "user:owner", %{
                 "reason" => "sent",
                 "source_uri" => "optimal://x"
               })

      assert {:error, :not_open} = Loops.drop(ctx.tenant, loop.id, "user:owner")
      assert {:ok, %{state: "open"}} = Loops.reopen(ctx.tenant, loop.id, "user:owner")
      assert {:ok, %{state: "dropped"}} = Loops.drop(ctx.tenant, loop.id, "user:owner")

      assert {:error, :invalid_kind} =
               Loops.create(ctx.tenant, Map.put(attrs, "kind", "maybe"), "x")

      assert {:error, :invalid_due_at} =
               Loops.create(ctx.tenant, Map.put(attrs, "due_at", "soon"), "x")
    end

    test "extraction reads contexts once and replies in the thread close loops", ctx do
      insert_context(
        ctx.tenant,
        ctx.workspace,
        "ctx-a-#{ctx.n}",
        "Call notes",
        "I'll send the contract tomorrow.",
        "2026-10-14T10:00:00Z",
        %{"thread_ref" => "thread-1"}
      )

      insert_context(
        ctx.tenant,
        ctx.workspace,
        "ctx-b-#{ctx.n}",
        "Other",
        "Nothing to do here at all.",
        "2026-10-14T11:00:00Z"
      )

      {:ok, [loop]} = Loops.extract(ctx.tenant, ctx.workspace, since: "2026-10-01")
      assert loop.kind == "commitment"
      assert loop.due_at == "2026-10-15"
      assert loop.detected
      assert loop.source_uri == "optimal://#{ctx.workspace}/contexts/ctx-a-#{ctx.n}"

      {:ok, again} = Loops.extract(ctx.tenant, ctx.workspace, since: "2026-10-01")
      assert Enum.map(again, & &1.id) == [loop.id]

      {:ok, _} =
        Store.raw_query(
          "UPDATE open_loops SET thread_ref = 'thread-1', created_at = '2026-10-14T10:00:00Z' WHERE id = ?1",
          [loop.id]
        )

      insert_context(
        ctx.tenant,
        ctx.workspace,
        "ctx-c-#{ctx.n}",
        "Re: contract",
        "Attached.",
        "2026-10-15T09:00:00Z",
        %{"thread_ref" => "thread-1"}
      )

      assert {:ok, [%{id: id, state: "closed", close_reason: "answered in thread"}]} =
               Loops.close_answered(ctx.tenant, ctx.workspace)

      assert id == loop.id
    end
  end

  describe "rhythm" do
    test "today's note is generated from current loops and never copies yesterday", ctx do
      {:ok, _} =
        Loops.create(
          ctx.tenant,
          %{
            "workspace_id" => ctx.workspace,
            "title" => "Ship the report",
            "due_at" => "2026-10-14"
          },
          "u"
        )

      {:ok, monday} = Rhythm.current(ctx.tenant, ctx.workspace, "daily", date: ~D[2026-10-14])
      assert monday.period == "2026-10-14"
      assert monday.content =~ "Wednesday, 2026-10-14"
      assert monday.content =~ "Ship the report"
      assert monday.generated

      {:ok, [loop]} = {:ok, Loops.list(ctx.tenant, workspace_ids: [ctx.workspace])}
      {:ok, _} = Loops.close(ctx.tenant, loop.id, "u")

      {:ok, _} =
        Loops.create(
          ctx.tenant,
          %{"workspace_id" => ctx.workspace, "title" => "Call the bank", "due_at" => "2026-10-15"},
          "u"
        )

      {:ok, tuesday} = Rhythm.current(ctx.tenant, ctx.workspace, "daily", date: ~D[2026-10-15])
      refute tuesday.content =~ "Ship the report"
      assert tuesday.content =~ "Call the bank"

      {:ok, same} = Rhythm.current(ctx.tenant, ctx.workspace, "daily", date: ~D[2026-10-14])
      assert same.content == monday.content
    end

    test "periods, templates, time zones and edits", ctx do
      assert Rhythm.period("weekly", ~D[2026-10-14]) == "2026-W42"
      assert Rhythm.period("monthly", ~D[2026-10-14]) == "2026-10"

      assert {:error, :unknown_timezone} =
               Rhythm.put_template(ctx.tenant, ctx.workspace, "daily", "x", "Mars/Olympus", "u")

      assert :ok =
               Rhythm.put_template(
                 ctx.tenant,
                 ctx.workspace,
                 "daily",
                 "Day {{date}} in {{workspace}}",
                 "America/Chicago",
                 "u"
               )

      assert Rhythm.timezone(ctx.tenant, ctx.workspace) == "America/Chicago"

      {:ok, note} = Rhythm.current(ctx.tenant, ctx.workspace, "daily", date: ~D[2026-10-16])
      assert note.content == "Day 2026-10-16 in #{ctx.workspace}"

      {:ok, edited} =
        Rhythm.put_note(ctx.tenant, ctx.workspace, "daily", "2026-10-16", "Edited", "u")

      refute edited.generated
      assert {:error, :invalid_cadence} = Rhythm.current(ctx.tenant, ctx.workspace, "hourly")
    end
  end

  describe "protocol" do
    test "workspace over tenant over default", ctx do
      {:ok, default} = Protocol.get(ctx.tenant, ctx.workspace)
      assert default.source == "default"
      assert default.content =~ "Close with evidence"

      {:ok, _} = Protocol.put(ctx.tenant, "tenant", ctx.tenant, "protocol", "Tenant protocol", "u")

      assert {:ok, %{source: "tenant", content: "Tenant protocol"}} =
               Protocol.get(ctx.tenant, ctx.workspace)

      {:ok, _} =
        Protocol.put(ctx.tenant, "workspace", ctx.workspace, "protocol", "Workspace protocol", "u")

      assert {:ok, %{source: "workspace"}} = Protocol.get(ctx.tenant, ctx.workspace)
      assert {:ok, %{source: "tenant"}} = Protocol.get(ctx.tenant, ctx.other)

      :ok = Protocol.reset(ctx.tenant, "workspace", ctx.workspace, "protocol")
      assert {:ok, %{source: "tenant"}} = Protocol.get(ctx.tenant, ctx.workspace)

      assert {:error, :empty_document} =
               Protocol.put(ctx.tenant, "tenant", ctx.tenant, "protocol", "  ", "u")
    end
  end

  describe "brief and boot" do
    test "a fresh workspace gets a valid empty state", ctx do
      brief = Brief.build(ctx.tenant, workspace_ids: [ctx.workspace], date: ~D[2026-10-14])
      assert brief.items == []
      assert brief.open_loops == 0

      boot = Boot.build(ctx.tenant, ctx.workspace, date: ~D[2026-10-14])
      assert boot.date == "2026-10-14"
      assert boot.weekday == "Wednesday"
      assert boot.fires == []
      assert boot.open_loops.total == 0
      assert boot.rhythm.content =~ "No open commitments"
      assert boot.protocol.source == "default"
    end

    test "items are ranked with sources and next actions", ctx do
      date = ~D[2026-10-14]

      create = fn attrs ->
        {:ok, _} = Loops.create(ctx.tenant, Map.put(attrs, "workspace_id", ctx.workspace), "u")
      end

      create.(%{
        "title" => "Overdue deck",
        "due_at" => "2026-10-10",
        "counterparty" => "Northwind",
        "source_uri" => "optimal://a"
      })

      create.(%{"title" => "Soon contract", "due_at" => "2026-10-16"})
      create.(%{"title" => "Reply on pricing", "kind" => "owed_reply", "counterparty" => "Contoso"})

      create.(%{
        "title" => "Invoice outstanding",
        "kind" => "payment_owed",
        "counterparty" => "Fabrikam"
      })

      create.(%{"title" => "Later item", "due_at" => "2026-11-30"})

      {:ok, _} =
        Store.raw_query(
          "INSERT INTO decisions (title, decision, decided_by, tenant_id, workspace_id, decided_at) VALUES ('Pick vendor', 'Northwind', 'u', ?1, ?2, '2026-10-13 10:00:00')",
          [ctx.tenant, ctx.workspace]
        )

      brief = Brief.build(ctx.tenant, workspace_ids: [ctx.workspace], date: date)
      assert Enum.map(brief.items, & &1.category) == ["overdue", "due_soon", "owed_reply", "money"]
      [overdue | _] = brief.items
      assert overdue.sources == ["optimal://a"]
      assert overdue.next_action =~ "with Northwind"

      boot = Boot.build(ctx.tenant, ctx.workspace, date: date)
      assert [%{title: "Overdue deck"}] = boot.fires
      assert [%{title: "Pick vendor"}] = boot.recent_decisions
      assert boot.open_loops.total == 5
    end
  end

  describe "portable topology" do
    @document %{
      "schema_version" => 1,
      "organizations" => [
        %{
          "slug" => "example-co",
          "name" => "Example Co",
          "status" => "active",
          "role" => "Operating company",
          "workspaces" => ["sales", "delivery"]
        },
        %{
          "slug" => "side-project",
          "name" => "Side Project",
          "status" => "dormant",
          "jurisdiction" => "Nowhere",
          "workspaces" => []
        }
      ],
      "people" => [
        %{
          "id" => "user:jane-PLACEHOLDER",
          "kind" => "user",
          "display_name" => "Jane Example",
          "title" => "Lead",
          "workspaces" => ["sales"]
        }
      ]
    }

    test "import then export returns the same document, and re-import changes nothing", ctx do
      document = put_in(@document, ["people", Access.at(0), "id"], "user:jane-#{ctx.n}")

      assert {:ok, %{organizations_created: 2, workspaces_created: 2, people: 1}} =
               Portable.import(ctx.tenant, document)

      assert Portable.export(ctx.tenant) == document

      assert {:ok, %{organizations_created: 0, organizations_updated: 2, workspaces_created: 0}} =
               Portable.import(ctx.tenant, document)

      assert Portable.export(ctx.tenant) == document
    end

    test "moving a workspace between organizations, and invalid documents", ctx do
      document = put_in(@document, ["people", Access.at(0), "id"], "user:jane-#{ctx.n}")
      {:ok, _} = Portable.import(ctx.tenant, document)

      moved =
        document
        |> put_in(["organizations", Access.at(0), "workspaces"], ["sales"])
        |> put_in(["organizations", Access.at(1), "workspaces"], ["delivery"])

      assert {:ok, %{workspaces_moved: 1}} = Portable.import(ctx.tenant, moved)
      assert Portable.export(ctx.tenant) == moved

      assert {:error, {:invalid_document, [_ | _]}} =
               Portable.import(ctx.tenant, %{
                 "organizations" => [%{"slug" => "Bad Slug", "name" => "x"}]
               })
    end
  end

  describe "routing rules" do
    test "classify, learn from feedback, and seed from the routing file", ctx do
      add = fn attrs -> RuleStore.add(ctx.tenant, attrs, "u") end

      {:ok, by_domain} =
        add.(%{
          "workspace_id" => ctx.workspace,
          "field" => "domain",
          "pattern" => "northwind.example",
          "weight" => 10
        })

      {:ok, _} =
        add.(%{
          "workspace_id" => ctx.other,
          "field" => "keyword",
          "pattern" => "pricing",
          "weight" => 4
        })

      high =
        RuleStore.classify(ctx.tenant, %{
          "sender" => "Jane <jane@mail.northwind.example>",
          "text" => "pricing question"
        })

      assert high.confidence == :high
      assert high.workspace_id == ctx.workspace
      assert by_domain.id in high.rules

      review = RuleStore.classify(ctx.tenant, %{"text" => "pricing update"})
      assert review.confidence == :review
      assert review.proposed_workspace_id == ctx.other

      assert RuleStore.classify(ctx.tenant, %{"text" => "repricing"}).confidence == :unresolved

      {:ok, 1} = RuleStore.feedback(ctx.tenant, [by_domain.id], :reject)
      {:ok, 1} = RuleStore.feedback(ctx.tenant, [by_domain.id], :reject)
      weakened = RuleStore.classify(ctx.tenant, %{"sender" => "jane@northwind.example"})
      assert weakened.confidence == :review

      assert {:error, :invalid_field} =
               RuleStore.add(
                 ctx.tenant,
                 %{"workspace_id" => ctx.workspace, "field" => "ip", "pattern" => "x"},
                 "u"
               )

      Application.put_env(:optimal_engine, :corpus_routing_rules, %{
        ctx.workspace => [{"northwind", 10}]
      })

      try do
        assert {:ok, 1} = RuleStore.seed_from_routing_file(ctx.tenant)

        assert Enum.any?(
                 RuleStore.list(ctx.tenant),
                 &(&1.source == "seed" and &1.pattern == "northwind")
               )
      after
        Application.delete_env(:optimal_engine, :corpus_routing_rules)
      end
    end
  end

  describe "HTTP API" do
    defp call(method, path, token, body \\ nil) do
      conn =
        case body do
          nil ->
            conn(method, path)

          body ->
            conn(method, path, Jason.encode!(body))
            |> put_req_header("content-type", "application/json")
        end

      conn = if token, do: put_req_header(conn, "authorization", "Bearer " <> token), else: conn
      Router.call(conn, Router.init([]))
    end

    defp key(tenant, scopes, workspaces) do
      {:ok, %{key: key}} =
        ApiKey.mint(%{tenant_id: tenant, name: "k", scopes: scopes, workspace_scope: workspaces})

      key
    end

    test "boot, brief, loops and scope", ctx do
      for {id, slug} <- [{ctx.workspace, "ops"}, {ctx.other, "sales"}] do
        {:ok, _} =
          Store.raw_query(
            "INSERT INTO workspaces (id, tenant_id, slug, name, status, metadata) VALUES (?1, ?2, ?3, ?3, 'active', '{}')",
            [id, ctx.tenant, slug]
          )
      end

      root = key(ctx.tenant, ["*"], ["*"])
      ops = key(ctx.tenant, ["read", "write"], [ctx.workspace])

      assert call(:get, "/api/boot?workspace=#{ctx.workspace}", ops).status == 200
      assert call(:get, "/api/boot?workspace=#{ctx.other}", ops).status == 403

      conn =
        call(:post, "/api/loops", ops, %{
          "workspace" => ctx.workspace,
          "title" => "Send the plan",
          "due_at" => "2026-10-20"
        })

      assert conn.status == 201
      ops_loop = Jason.decode!(conn.resp_body)

      conn =
        call(:post, "/api/loops", root, %{"workspace" => ctx.other, "title" => "Sales follow up"})

      other_loop = Jason.decode!(conn.resp_body)

      assert call(:post, "/api/loops/#{other_loop["id"]}/close", ops, %{
               "workspace" => ctx.workspace
             }).status == 404

      assert call(:post, "/api/loops/#{ops_loop["id"]}/close", ops, %{
               "workspace" => ctx.workspace,
               "reason" => "done"
             }).status == 200

      brief = call(:get, "/api/brief?workspaces=*", root) |> Map.get(:resp_body) |> Jason.decode!()
      assert brief["open_loops"] == 1

      mine = call(:get, "/api/brief?workspaces=*", ops) |> Map.get(:resp_body) |> Jason.decode!()
      assert mine["open_loops"] == 0
      assert mine["scope"] == [ctx.workspace]

      assert call(:get, "/api/brief", ops).status == 400
      assert call(:get, "/api/brief?workspaces=#{ctx.workspace}", ops).status == 200
      assert call(:get, "/api/brief?workspaces=#{ctx.other}", ops).status == 403
      assert call(:get, "/api/memory?workspaces=*", ops).status == 400

      assert call(:get, "/api/topology/export", ops).status == 403
      assert call(:get, "/api/topology/export", root).status == 200
      assert call(:get, "/api/protocol?workspace=#{ctx.workspace}", ops).status == 200
    end
  end
end
