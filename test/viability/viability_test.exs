defmodule OptimalEngine.ViabilityTest do
  @moduledoc """
  Viability: the five systems, the six proxy metrics and the variety ratio,
  trajectory alerts, the System 3* audit, history, agent action chains, and
  their HTTP routes. Each test runs in its own tenant with fixed dates.
  """

  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias OptimalEngine.API.Router
  alias OptimalEngine.Auth.ApiKey
  alias OptimalEngine.Authority
  alias OptimalEngine.Authority.ActionChain
  alias OptimalEngine.Operating.{Brief, Protocol}
  alias OptimalEngine.ReviewQueue
  alias OptimalEngine.Routing.RuleStore
  alias OptimalEngine.Store
  alias OptimalEngine.Tenancy.Tenant
  alias OptimalEngine.Viability
  alias OptimalEngine.Viability.{Audit, Metrics, SignalEvents, Systems, Trajectory}

  @today ~D[2026-10-18]

  setup do
    n = System.unique_integer([:positive])
    tenant = "viability-#{n}"
    {:ok, _} = Tenant.create(%{id: tenant, name: "Viability #{n}"})
    workspace = "#{tenant}:ops"
    other = "#{tenant}:sales"

    for {id, slug} <- [{workspace, "ops"}, {other, "sales"}] do
      {:ok, _} =
        Store.raw_query(
          "INSERT INTO workspaces (id, tenant_id, slug, name, status, metadata) VALUES (?1, ?2, ?3, ?3, 'active', '{}')",
          [id, tenant, slug]
        )
    end

    %{tenant: tenant, workspace: workspace, other: other, n: n}
  end

  defp signal(ctx, id, attrs) do
    attrs =
      Map.merge(
        %{
          workspace: ctx.workspace,
          title: "Signal #{id}",
          content: "A plain update about the account and the next delivery date for the team.",
          genre: "email",
          mode: "linguistic",
          signal_type: "inform",
          sn_ratio: 0.7,
          node: "ops",
          created_at: "2026-10-15T09:00:00Z",
          metadata: %{}
        },
        attrs
      )

    {:ok, _} =
      Store.raw_query(
        """
        INSERT INTO contexts (id, tenant_id, workspace_id, type, title, content, genre, mode, signal_type,
                              sn_ratio, node, created_at, metadata)
        VALUES (?1, ?2, ?3, 'signal', ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)
        """,
        [
          id,
          ctx.tenant,
          attrs.workspace,
          attrs.title,
          attrs.content,
          attrs.genre,
          attrs.mode,
          attrs.signal_type,
          attrs.sn_ratio,
          attrs.node,
          attrs.created_at,
          Jason.encode!(attrs.metadata)
        ]
      )

    id
  end

  defp loop(ctx, attrs) do
    attrs =
      Map.merge(
        %{
          kind: "commitment",
          state: "open",
          due_at: nil,
          closed_at: nil,
          source: nil,
          created_at: "2026-10-12T09:00:00Z"
        },
        attrs
      )

    id = "loop-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Store.raw_query(
        """
        INSERT INTO open_loops (id, tenant_id, workspace_id, kind, title, state, due_at, fingerprint,
                                source_context_id, created_at, closed_at)
        VALUES (?1, ?2, ?3, ?4, 'A loop', ?5, ?6, ?1, ?7, ?8, ?9)
        """,
        [
          id,
          ctx.tenant,
          ctx.workspace,
          attrs.kind,
          attrs.state,
          attrs.due_at,
          attrs.source,
          attrs.created_at,
          attrs.closed_at
        ]
      )

    id
  end

  # Events land inside the fixed window unless a test names their time.
  defp event(ctx, attrs) do
    attrs =
      attrs
      |> Map.put("workspace_id", ctx.workspace)
      |> Map.put_new("occurred_at", "2026-10-16T10:00:00Z")

    {:ok, _} = SignalEvents.record(ctx.tenant, attrs)
  end

  defp metric(result, name), do: Enum.find(result.metrics, &(&1.name == name))

  defp window, do: Viability.window(@today)

  describe "proxy metrics" do
    test "the ratio is not measured without a repertoire", ctx do
      signal(ctx, "r1-#{ctx.n}", %{})
      variety = Metrics.compute(ctx.tenant, [ctx.workspace], window()).variety
      assert variety.status == "no_repertoire"
      assert variety.r == nil
      assert variety.v_disturbance == 1
    end

    test "say no_data when there is nothing to measure", ctx do
      result = Metrics.compute(ctx.tenant, [ctx.workspace], window())

      assert result.signals_received == 0
      assert Enum.all?(result.metrics, &(&1.value == nil and &1.status == "no_data"))
      assert result.variety.status == "no_data"
      assert result.variety.r == nil
    end

    test "are computed from Signals, loops and events", ctx do
      s1 = signal(ctx, "s1-#{ctx.n}", %{created_at: "2026-10-13T10:00:00Z"})
      signal(ctx, "s2-#{ctx.n}", %{})
      s3 = signal(ctx, "s3-#{ctx.n}", %{created_at: "2026-10-14T08:00:00Z"})
      signal(ctx, "s4-#{ctx.n}", %{content: "To clarify what I asked yesterday: the dates moved."})

      for i <- 5..7, do: signal(ctx, "s#{i}-#{ctx.n}", %{genre: "transcript"})

      signal(ctx, "s8-#{ctx.n}", %{genre: "note", content: "As I said before, we need the file."})
      signal(ctx, "s9-#{ctx.n}", %{genre: "note", signal_type: "direct"})
      s10 = signal(ctx, "s10-#{ctx.n}", %{genre: "invoice", mode: "visual", signal_type: "direct"})

      # Outside the window, outbound, or an agent action step: not received.
      signal(ctx, "old-#{ctx.n}", %{created_at: "2026-10-01T09:00:00Z"})
      signal(ctx, "out-#{ctx.n}", %{metadata: %{"direction" => "outbound"}})
      signal(ctx, "step-#{ctx.n}", %{metadata: %{"agent_action" => %{"stage" => "request"}}})

      loop(ctx, %{state: "closed", source: s1, closed_at: "2026-10-13T15:00:00Z"})
      loop(ctx, %{state: "closed", closed_at: "2026-10-16T09:00:00Z"})
      loop(ctx, %{kind: "owed_reply", state: "closed", closed_at: "2026-10-17T09:00:00Z"})
      loop(ctx, %{state: "dropped", closed_at: "2026-10-16T09:00:00Z"})
      loop(ctx, %{due_at: "2026-10-15"})
      loop(ctx, %{due_at: "2026-10-25"})

      event(ctx, %{"kind" => "rerouted", "context_id" => "s2-#{ctx.n}"})
      event(ctx, %{"kind" => "acted", "context_id" => s3, "occurred_at" => "2026-10-14T10:00:00Z"})
      event(ctx, %{"kind" => "re_encoded", "occurred_at" => "2026-10-16T10:00:00Z"})
      event(ctx, %{"kind" => "genre_checked", "value" => 1})
      event(ctx, %{"kind" => "genre_checked", "value" => 0})
      event(ctx, %{"kind" => "feedback_confirmed", "context_id" => s10})

      result = Metrics.compute(ctx.tenant, [ctx.workspace], window())
      assert result.signals_received == 10

      completion = metric(result, "action_completion_rate")
      assert completion.value == 0.6
      assert {completion.numerator, completion.denominator} == {3, 5}

      re_encoding = metric(result, "re_encoding_frequency")
      assert re_encoding.components == %{events: 1, follow_up_loops: 0, phrases: 2}
      assert re_encoding.value == 30.0

      decode = metric(result, "time_to_decode_hours")
      assert decode.value == 3.5
      assert decode.count == 2

      assert metric(result, "signal_bounce_rate").value == 0.1

      genre = metric(result, "genre_recognition_rate")
      assert genre.components.recognized_signals == 8
      assert genre.value == 0.75

      feedback = metric(result, "feedback_loop_closure_rate")
      assert feedback.components.direct_signals == 2
      assert feedback.components.direct_confirmed == 1
      assert feedback.value == 0.667

      # Only the one outbound email is in the repertoire so far.
      assert result.variety.v_disturbance == 4
      assert result.variety.v_system == 1
      assert result.variety.r == 0.25
      assert result.variety.band == "failing"

      {:ok, _} =
        Protocol.put(
          ctx.tenant,
          "workspace",
          ctx.workspace,
          "repertoire",
          "# Genres we use\n- email\n- transcript/linguistic\n- report\n- invoice/visual\n- spec\n- plan\n- not-a-genre",
          "user:owner"
        )

      event(ctx, %{"kind" => "produced", "genre" => "brief", "mode" => "linguistic"})

      variety = Metrics.compute(ctx.tenant, [ctx.workspace], window()).variety
      # Six declared genres, the outbound email and the produced brief.
      assert variety.v_system == 8
      assert variety.r == 2.0
      assert variety.band == "marginal"
      assert variety.coverage == 0.75
      assert [%{genre: "note", mode: "linguistic", signals: 2}] = variety.gaps
    end

    test "a Signal routed to two nodes counts once", ctx do
      signal(ctx, "p1-#{ctx.n}", %{})
      signal(ctx, "p1x-#{ctx.n}", %{node: "revenue", metadata: %{"cross_ref_from" => "ops"}})
      assert Metrics.compute(ctx.tenant, [ctx.workspace], window()).signals_received == 1

      assert OptimalEngine.Pipeline.Classifier.frontmatter_metadata(
               "---\ncross_ref_from: inbox\ndirection: outbound\noutward: market\ntitle: x\n---\nBody"
             ) == %{"cross_ref_from" => "inbox", "direction" => "outbound", "outward" => "market"}

      # Copies indexed before the marker existed are repaired from their files.
      dir = Path.join(System.tmp_dir!(), "viability-#{ctx.n}/revenue/signals")
      File.mkdir_p!(dir)
      file = Path.join(dir, "2026-10-15-update.md")
      File.write!(file, "---\nnode: revenue\ncross_ref_from: ops\n---\nA plain update.")

      {:ok, _} =
        Store.raw_query(
          "INSERT INTO contexts (id, tenant_id, workspace_id, type, title, content, path, created_at, metadata) VALUES (?1, ?2, ?3, 'signal', 'Old copy', 'A plain update.', ?4, '2026-10-15T09:00:00Z', '{}')",
          ["p2x-#{ctx.n}", ctx.tenant, ctx.workspace, file]
        )

      assert Metrics.compute(ctx.tenant, [ctx.workspace], window()).signals_received == 2
      assert {:ok, %{marked: marked}} = Viability.repair_cross_refs()
      assert marked >= 1
      assert Metrics.compute(ctx.tenant, [ctx.workspace], window()).signals_received == 1
    end

    test "bands follow the paper" do
      assert Metrics.band(0.5) == "failing"
      assert Metrics.band(1.0) == "marginal"
      assert Metrics.band(3.0) == "adequate"
      assert Metrics.band(10.0) == "robust"
    end
  end

  describe "the five systems" do
    test "report evidence and the failure each missing system predicts", ctx do
      for i <- 1..4, do: signal(ctx, "a#{i}-#{ctx.n}", %{node: "sales"})
      signal(ctx, "b1-#{ctx.n}", %{node: "delivery"})

      systems = Systems.evaluate(ctx.tenant, [ctx.workspace], :workspace, @today)
      by_id = Map.new(systems, &{&1.id, &1})

      assert by_id["s1"].status == "present"
      assert [bottleneck] = by_id["s1"].findings
      assert bottleneck =~ "sales"

      assert by_id["s2"].predicted_failure == %{
               failure: "Cross-team misalignment.",
               source: "paper P3"
             }

      assert by_id["s3"].status == "missing"
      assert by_id["s3_star"].status == "missing"
      assert by_id["s4"].status == "missing"
      assert by_id["s4"].evidence == ["No outward-scan Signals in 30 days (last: never)."]
      assert by_id["s4"].predicted_failure.failure == "Blindsided by change."
      assert by_id["s5"].predicted_failure.failure == "Inconsistent encoding standards."

      report = Viability.report(ctx.tenant, workspace_ids: [ctx.workspace], today: @today)
      assert report.summary.verdict == "not_viable"
      assert length(report.summary.predicted_failures) == 5

      # Give the workspace each system.
      {:ok, _} =
        RuleStore.add(
          ctx.tenant,
          %{"workspace_id" => ctx.workspace, "field" => "keyword", "pattern" => "invoice"},
          "user:owner"
        )

      {:ok, _} =
        Store.raw_query(
          "INSERT INTO rhythm_notes (tenant_id, workspace_id, cadence, period, content, updated_at) VALUES (?1, ?2, 'daily', '2026-10-17', 'Today', '2026-10-17T08:00:00Z')",
          [ctx.tenant, ctx.workspace]
        )

      loop(ctx, %{state: "closed", closed_at: "2026-10-10T09:00:00Z"})

      signal(ctx, "m1-#{ctx.n}", %{
        metadata: %{"outward" => "market"},
        created_at: "2026-10-16T09:00:00Z"
      })

      {:ok, _} =
        Authority.publish_policy(
          ctx.tenant,
          "workspace",
          ctx.workspace,
          Authority.default_pack(),
          "user:owner"
        )

      {:ok, _} =
        Protocol.put(
          ctx.tenant,
          "workspace",
          ctx.workspace,
          "protocol",
          "# Our protocol\n1. Boot first.",
          "user:owner"
        )

      {:ok, %{sampled: sampled}} = Audit.run(ctx.tenant, ctx.workspace, today: @today)
      assert sampled > 0

      statuses =
        ctx.tenant
        |> Systems.evaluate([ctx.workspace], :workspace, @today)
        |> Map.new(&{&1.id, &1.status})

      assert statuses["s2"] == "present"
      assert statuses["s3"] == "present"
      assert statuses["s4"] == "present"
      assert statuses["s5"] == "present"
      assert statuses["s3_star"] in ["present", "degraded"]
    end

    test "the org view covers its workspaces", ctx do
      signal(ctx, "o1-#{ctx.n}", %{})
      signal(ctx, "o2-#{ctx.n}", %{workspace: ctx.other, node: "sales"})

      report = Viability.report(ctx.tenant, scope: :org, today: @today)
      assert Enum.sort(report.workspace_ids) == Enum.sort([ctx.workspace, ctx.other])
      assert report.signals_received == 2
      assert length(report.workspaces) == 2

      s1 = Enum.find(report.systems, &(&1.id == "s1"))
      assert Enum.map(s1.units, & &1.unit) |> Enum.sort() == Enum.sort([ctx.workspace, ctx.other])

      partial =
        Viability.report(ctx.tenant, scope: :org, workspace_ids: [ctx.workspace], today: @today)

      assert partial.workspace_ids == [ctx.workspace]
    end
  end

  describe "trajectory" do
    test "alerts after three periods of decline" do
      assert Trajectory.degrading?([12, 9, 6, 3], :higher)
      assert Trajectory.degrading?([1.0, 2.0, 3.5, 4.0], :lower)
      refute Trajectory.degrading?([12, 9, 9, 3], :higher)
      refute Trajectory.degrading?([12, nil, 6, 3], :higher)
    end

    test "flags a falling inbound flow and a falling unit", ctx do
      [w1, w2, w3, w4] = Trajectory.windows(@today)
      assert w4.to == Date.add(@today, 1)
      assert Date.diff(w2.from, w1.from) == 7

      for {window, count} <- Enum.zip([w1, w2, w3, w4], [12, 9, 6, 3]), i <- 1..count do
        day = window.from |> Date.add(rem(i, 7)) |> Date.to_iso8601()

        signal(ctx, "t-#{window.from}-#{i}-#{ctx.n}", %{
          node: "leads",
          created_at: day <> "T09:00:00Z"
        })
      end

      %{alerts: alerts, series: series} = Trajectory.analyze(ctx.tenant, [ctx.workspace], @today)
      assert series["inbound_signals"] == [12, 9, 6, 3]
      subjects = Enum.map(alerts, & &1.subject)
      assert "flow:inbound_signals" in subjects
      assert "unit:leads" in subjects
    end
  end

  describe "System 3* audit" do
    test "scores the three layers", _ctx do
      good =
        Audit.score(
          %{
            title: "Weekly status",
            content:
              "# Summary\nShipping moved to Friday after the vendor confirmed parts.\n# Risks\nThe second supplier has not replied, so the backup plan starts Monday if nothing arrives by then.",
            genre: "status-report",
            signal_type: "inform",
            mode: "linguistic",
            sn_ratio: 0.8
          },
          []
        )

      repeat = "ok see above thanks"

      bad =
        Audit.score(
          %{
            title: "",
            content: repeat,
            genre: "spec",
            signal_type: nil,
            mode: "linguistic",
            sn_ratio: 0.2
          },
          [repeat]
        )

      assert good.score > 0.5
      assert bad.score < 0.5
      assert bad.information == 0.0
      assert Enum.any?(bad.findings, &(&1 =~ "no title"))
      assert Enum.any?(bad.findings, &(&1 =~ "repeats an earlier Signal"))
    end

    test "re-reads the stored mode from the text" do
      scored =
        Audit.score(
          %{
            title: "Kickoff call",
            content:
              "Speaker 1: Thanks everyone for joining the kickoff. Speaker 2: I will send the revised timeline by Monday and we agree on the vendor next week.",
            genre: "transcript",
            signal_type: "inform",
            mode: "code",
            sn_ratio: 0.6
          },
          []
        )

      assert "Recorded as mode code but reads as linguistic." in scored.findings
    end

    test "flags low scores into the review queue and the brief", ctx do
      outbound = %{"direction" => "outbound"}

      signal(ctx, "g-#{ctx.n}", %{
        title: "Delivery plan",
        content:
          "The delivery moves to Friday. The vendor confirmed the parts and the crew is booked for the morning, with a backup crew on standby.",
        metadata: outbound
      })

      signal(ctx, "x-#{ctx.n}", %{
        title: "",
        content: "ok",
        genre: "spec",
        sn_ratio: 0.1,
        metadata: outbound
      })

      {:ok, run} = Audit.run(ctx.tenant, ctx.workspace, today: @today)
      assert run.basis == "sent"
      assert run.sampled == 2
      assert run.flagged >= 1
      assert run.period == "2026-W42"

      {:ok, again} = Audit.run(ctx.tenant, ctx.workspace, today: @today)
      assert again.sampled == 0

      {:ok, [flagged | _]} = ReviewQueue.audits(ctx.tenant, [ctx.workspace])
      assert flagged.state == "flagged"

      brief = Brief.build(ctx.tenant, workspace_ids: [ctx.workspace])
      assert Enum.any?(brief.items, &(&1.category == "audit"))

      assert {:ok, "confirmed"} =
               ReviewQueue.decide_audit(ctx.tenant, flagged.id, :confirm, actor_id: "user:owner")

      assert {:error, :not_flagged} =
               ReviewQueue.decide_audit(ctx.tenant, flagged.id, :dismiss, actor_id: "user:owner")
    end
  end

  describe "history" do
    test "backfills 30 days once, keeps one snapshot per day, refreshes today", ctx do
      signal(ctx, "h1-#{ctx.n}", %{created_at: "2026-10-10T09:00:00Z"})

      assert {:ok, 30} = Viability.catch_up(ctx.tenant, ctx.workspace, today: @today)
      # Past days are kept; only today is refreshed.
      assert {:ok, 1} = Viability.catch_up(ctx.tenant, ctx.workspace, today: @today)

      history = Viability.history(ctx.tenant, ctx.workspace, 30, @today)
      assert length(history.snapshots) == 30
      assert history.missing == []

      [first | _] = history.snapshots
      last = List.last(history.snapshots)
      assert first["backfilled"] == true
      assert first["systems"] == nil
      assert last["period"] == "2026-10-18"
      assert last["backfilled"] == false
      assert Map.has_key?(last["systems"], "s4")
      assert Map.has_key?(last["metrics"], "feedback_loop_closure_rate")
    end
  end

  describe "agent action chains" do
    test "link request, approval, action, result and reply as signed Signals", ctx do
      {:ok, request} =
        ActionChain.record(
          ctx.tenant,
          %{
            "workspace_id" => ctx.workspace,
            "stage" => "request",
            "agent" => "agent:mailer",
            "action" => "send_email",
            "resource" => "mailto:client",
            "summary" => "Send the revised proposal."
          },
          "service:approvals"
        )

      correlation = request["correlation_id"]
      assert String.starts_with?(correlation, "act_")

      for stage <- ~w(approval action result reply) do
        {:ok, step} =
          ActionChain.record(
            ctx.tenant,
            %{"workspace_id" => ctx.workspace, "stage" => stage, "correlation_id" => correlation},
            "service:approvals"
          )

        assert step["agent"] == "agent:mailer"
      end

      {:ok, chain} = ActionChain.trace(ctx.tenant, correlation)
      assert chain.complete
      assert chain.verified
      assert chain.findings == []
      assert Enum.map(chain.steps, & &1["stage"]) == ~w(request approval action result reply)
      [first, second | _] = chain.steps
      assert second["causation_id"] == first["id"]

      {:ok, [[genre, meta]]} =
        Store.raw_query("SELECT genre, metadata FROM contexts WHERE id = ?1", [first["context_id"]])

      assert genre == "audit-trail"
      assert Jason.decode!(meta)["correlation_id"] == correlation

      # Steps out of order or in another workspace are refused.
      assert {:error, :request_required} =
               ActionChain.record(
                 ctx.tenant,
                 %{
                   "workspace_id" => ctx.workspace,
                   "stage" => "approval",
                   "correlation_id" => "act_none"
                 },
                 "x"
               )

      assert {:error, :already_requested} =
               ActionChain.record(
                 ctx.tenant,
                 %{
                   "workspace_id" => ctx.workspace,
                   "stage" => "request",
                   "correlation_id" => correlation
                 },
                 "x"
               )

      assert {:error, :workspace_mismatch} =
               ActionChain.record(
                 ctx.tenant,
                 %{
                   "workspace_id" => ctx.other,
                   "stage" => "result",
                   "correlation_id" => correlation
                 },
                 "x"
               )

      # Changing a recorded step is detected.
      {:ok, _} =
        Store.raw_query("UPDATE authority_action_steps SET summary = 'changed' WHERE id = ?1", [
          second["id"]
        ])

      {:ok, tampered} = ActionChain.trace(ctx.tenant, correlation)
      refute tampered.verified
      assert "At least one step does not verify against the signed evidence." in tampered.findings

      [summary] = ActionChain.list(ctx.tenant, [ctx.workspace])
      assert summary.steps == 5
    end

    test "follow the Engine's own approval flow", ctx do
      pack = %{
        "name" => "ops",
        "rules" => [%{"id" => "exports-ask", "effect" => "ask", "actions" => ["export"]}]
      }

      {:ok, _} =
        Authority.publish_policy(ctx.tenant, "workspace", ctx.workspace, pack, "user:owner")

      {:ok, request, _decision} =
        Authority.request_approval(
          ctx.tenant,
          %{
            "subject" => "agent:x",
            "action" => "export",
            "resource" => "optimal://#{ctx.workspace}/memory/report",
            "workspace_id" => ctx.workspace
          },
          "agent:x"
        )

      {:ok, _approved, grant} = Authority.approve(ctx.tenant, request.id, "user:owner")

      {:ok, chain} = ActionChain.trace(ctx.tenant, request.id)
      assert chain.stages["request"]
      assert chain.stages["approval"]
      assert chain.verified
      assert Enum.all?(chain.steps, &(&1["source"] == "engine"))

      # A reported chain that names the request joins the Engine's evidence.
      {:ok, step} =
        ActionChain.record(
          ctx.tenant,
          %{
            "workspace_id" => ctx.workspace,
            "stage" => "request",
            "action" => "export",
            "detail" => %{"request_id" => request.id, "jti" => grant.jti}
          },
          "service:approvals"
        )

      {:ok, joined} = ActionChain.trace(ctx.tenant, step["correlation_id"])
      sources = joined.steps |> Enum.map(& &1["source"]) |> Enum.uniq() |> Enum.sort()
      assert sources == ["engine", "reported"]
      assert joined.stages["approval"]
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

    defp decode(conn), do: Jason.decode!(conn.resp_body)

    test "viability, events, audits and action chains through the API", ctx do
      signal(ctx, "api1-#{ctx.n}", %{created_at: Date.to_iso8601(Date.utc_today()) <> "T08:00:00Z"})
      root = key(ctx.tenant, ["*"], ["*"])
      ops = key(ctx.tenant, ["read", "write"], [ctx.workspace])
      enforcer = key(ctx.tenant, ["read", "write", "authority:enforce"], [ctx.workspace])

      report = call(:get, "/api/viability?workspace=#{ctx.workspace}", ops)
      assert report.status == 200
      body = decode(report)
      assert length(body["systems"]) == 6
      assert length(body["metrics"]) == 6
      assert Map.has_key?(body["variety"], "r")
      assert Map.has_key?(body["trajectory"], "alerts")

      assert call(:get, "/api/viability?workspace=#{ctx.other}", ops).status == 403

      org = call(:get, "/api/viability?workspaces=*", ops)
      assert org.status == 200
      assert decode(org)["workspace_ids"] == [ctx.workspace]

      assert call(:get, "/api/viability/history?workspaces=*", ops).status == 403
      assert call(:get, "/api/viability/history?workspaces=*", root).status == 200

      assert call(:post, "/api/viability/snapshot", ops, %{
               "workspace" => ctx.workspace,
               "days" => 3
             }).status == 403

      snap =
        call(:post, "/api/viability/snapshot", root, %{"workspace" => ctx.workspace, "days" => 3})

      assert decode(snap)["written"] == 3

      metrics =
        call(
          :get,
          "/api/viability/metrics?workspace=#{ctx.workspace}&from=2026-10-01&to=2026-10-18",
          ops
        )

      assert metrics.status == 200

      assert call(
               :get,
               "/api/viability/metrics?workspace=#{ctx.workspace}&from=2026-10-18&to=2026-10-01",
               ops
             ).status == 400

      created =
        call(:post, "/api/signal-events", ops, %{
          "workspace" => ctx.workspace,
          "kind" => "outward",
          "topic" => "market",
          "context_id" => "api1-#{ctx.n}"
        })

      assert created.status == 201
      assert decode(created)["actor"] =~ "api_key:"

      assert call(:post, "/api/signal-events", ops, %{
               "workspace" => ctx.workspace,
               "kind" => "outward",
               "topic" => "gossip"
             }).status == 422

      assert call(:post, "/api/signal-events", ops, %{"workspace" => ctx.other, "kind" => "acted"}).status ==
               403

      events = call(:get, "/api/signal-events?workspace=#{ctx.workspace}&kind=outward", ops)
      assert [%{"topic" => "market"}] = decode(events)["events"]

      assert call(:post, "/api/viability/audit/run", ops, %{"workspace" => ctx.workspace}).status ==
               403

      assert call(:post, "/api/viability/audit/run", root, %{"workspace" => ctx.workspace}).status ==
               200

      assert call(:get, "/api/viability/audit?workspace=#{ctx.workspace}", ops).status == 200

      requested =
        call(:post, "/api/agent-actions", ops, %{
          "workspace" => ctx.workspace,
          "stage" => "request",
          "agent" => "agent:mailer",
          "action" => "send_email"
        })

      assert requested.status == 201
      correlation = decode(requested)["correlation_id"]

      approval = %{
        "workspace" => ctx.workspace,
        "stage" => "approval",
        "correlation_id" => correlation
      }

      assert call(:post, "/api/agent-actions", ops, approval).status == 403
      assert call(:post, "/api/agent-actions", enforcer, approval).status == 201

      trace = call(:get, "/api/agent-actions/#{correlation}?workspace=#{ctx.workspace}", ops)
      assert trace.status == 200
      assert decode(trace)["verified"] == true

      assert call(:get, "/api/agent-actions/#{correlation}?workspace=#{ctx.other}", root).status ==
               404

      chains = call(:get, "/api/agent-actions?workspace=#{ctx.workspace}", ops)
      assert [%{"steps" => 2}] = decode(chains)["chains"]
    end

    test "a rejected routing decision counts as a bounce", ctx do
      {:ok, rule} =
        RuleStore.add(
          ctx.tenant,
          %{"workspace_id" => ctx.workspace, "field" => "keyword", "pattern" => "invoice"},
          "user:owner"
        )

      {:ok, 1} = RuleStore.feedback(ctx.tenant, [rule.id], :reject)

      assert [%{kind: "rerouted", metadata: %{"source" => "routing_feedback"}}] =
               SignalEvents.list(ctx.tenant, [ctx.workspace], kind: "rerouted")
    end
  end
end
