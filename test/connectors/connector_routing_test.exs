defmodule OptimalEngine.Connectors.ConnectorRoutingTest do
  @moduledoc """
  What a connector's Signals leave behind once they land: the workspace they
  are routed to, the open loops they imply, and the outward event that tells
  System 4 the source is outside the organization.

  The adapter is scripted through the connector config for the routing and
  loop cases, so the test drives the real path (Runner -> sink -> Routing ->
  Intake -> Loops -> SignalEvents) without any provider. The last case runs
  the whole path end to end on the real `:fathom` adapter, over a broker-issued
  credential and a recorded meeting.
  """

  use ExUnit.Case, async: false

  alias OptimalEngine.Connectors
  alias OptimalEngine.Connectors.PullScheduler
  alias OptimalEngine.Connectors.Runner
  alias OptimalEngine.Operating.Loops
  alias OptimalEngine.Routing.RuleStore
  alias OptimalEngine.Store
  alias OptimalEngine.Tenancy.Tenant
  alias OptimalEngine.Test.ConnectorFixtureStub
  alias OptimalEngine.Viability.SignalEvents

  @tenant "default"

  defmodule ScriptedAdapter do
    @moduledoc "Behaviour-compliant adapter that emits the Signals named in its config."

    @behaviour OptimalEngine.Connectors.Behaviour

    alias OptimalEngine.Connectors.Transform
    alias OptimalEngine.Signal

    @impl true
    def kind, do: :scripted

    @impl true
    def display_name, do: "Scripted"

    @impl true
    def auth_scheme, do: :token

    @impl true
    def required_config_keys, do: []

    @impl true
    def init(config), do: {:ok, config}

    @impl true
    def sync(state, _cursor) do
      signals =
        state
        |> Map.get("signals", [])
        |> Enum.map(fn raw ->
          Transform.new_signal(%{
            id: Transform.signal_id(:scripted, raw["id"]),
            title: raw["title"],
            content: raw["content"],
            path: Transform.source_uri(:scripted, raw["id"]),
            genre: raw["genre"] || "message",
            entities: raw["entities"] || [],
            modified_at: Transform.parse_iso8601(raw["modified_at"])
          })
        end)

      {:ok, %{signals: signals, cursor: "cursor-1"}}
    end

    @impl true
    def transform(raw) when is_map(raw), do: {:ok, %Signal{id: raw["id"] || "scripted"}}
  end

  # Routing rules are tenant-wide, so every case names a person and a domain
  # only it uses: a rule another case left behind can then never dilute the
  # score margin that decides a high-confidence route.
  setup do
    suffix = System.unique_integer([:positive])
    domain = "example-#{suffix}.com"

    {:ok,
     workspace: "scripted-primary-#{suffix}",
     other: "scripted-other-#{suffix}",
     vault: "scripted-vault-#{suffix}",
     intake: "scripted-intake-#{suffix}",
     connector_id: "scripted-connector-#{suffix}",
     title: "scripted-subject-#{suffix}",
     domain: domain,
     sender: "jane@#{domain}"}
  end

  describe "routing rules run before the connector's own workspace" do
    test "a sender rule claims the Signal for the workspace it names", ctx do
      add_rule(ctx.other, "sender", ctx.sender)

      run_scripted(ctx, [%{"id" => "m-1", "entities" => ["Jane Example <#{ctx.sender}>"]}])

      assert contexts_in(ctx.other, ctx.title) >= 1
      assert contexts_in(ctx.workspace, ctx.title) == 0
    end

    test "a Signal no rule claims stays in the connector's own workspace", ctx do
      add_rule(ctx.other, "sender", "someone-else@#{ctx.domain}")

      run_scripted(ctx, [%{"id" => "m-2", "entities" => ["stranger@example.net"]}])

      assert contexts_in(ctx.workspace, ctx.title) >= 1
      assert contexts_in(ctx.other, ctx.title) == 0
    end

    test "a review-confidence route goes to the review workspace when one is named", ctx do
      # A single low-weight keyword rule scores under the high-confidence bar.
      add_rule(ctx.other, "keyword", ctx.title, 1)

      run_scripted(
        ctx,
        [%{"id" => "m-3", "content" => "The #{ctx.title} schedule is attached."}],
        config: %{"review_workspace_id" => ctx.intake}
      )

      assert contexts_in(ctx.intake, ctx.title) >= 1
      assert contexts_in(ctx.other, ctx.title) == 0
    end

    test "a keyword rule never opens a walled workspace", ctx do
      add_rule(ctx.vault, "keyword", ctx.title, 10)

      run_scripted(
        ctx,
        [%{"id" => "m-4", "content" => "The #{ctx.title} invoice is attached."}],
        config: %{"routing_walled_workspaces" => [ctx.vault]}
      )

      assert contexts_in(ctx.vault, ctx.title) == 0
      assert contexts_in(ctx.workspace, ctx.title) >= 1
    end

    test "an identity rule does open a walled workspace", ctx do
      add_rule(ctx.vault, "domain", ctx.domain, 10)

      run_scripted(
        ctx,
        [%{"id" => "m-5", "entities" => [ctx.sender]}],
        config: %{"routing_walled_workspaces" => [ctx.vault]}
      )

      assert contexts_in(ctx.vault, ctx.title) >= 1
    end
  end

  describe "open loops" do
    test "a message that expects a reply becomes an owed_reply loop", ctx do
      run_scripted(ctx, [
        %{
          "id" => "m-6",
          "content" => "Could you please confirm the signed order form by Friday?",
          "modified_at" => "2026-10-26T09:00:00Z",
          "entities" => ["Jane Example <#{ctx.sender}>"]
        }
      ])

      assert [loop] = Loops.list(@tenant, workspace_ids: [ctx.workspace])
      assert loop.kind == "owed_reply"
      assert loop.workspace_id == ctx.workspace
      assert loop.counterparty == ctx.sender
      assert loop.detected
      assert loop.source_uri =~ "optimal://"
      assert loop.due_at =~ "2026-10-30"
    end

    test "an unpaid invoice becomes a payment loop with the invoice's due date", ctx do
      run_scripted(ctx, [
        %{
          "id" => "m-7",
          "content" => "Invoice INV-0007 is outstanding, 1200.00 USD due 2026-11-01.",
          "modified_at" => "2026-10-26T09:00:00Z"
        }
      ])

      assert [loop] = Loops.list(@tenant, workspace_ids: [ctx.workspace])
      assert loop.kind == "payment_owed"
      assert loop.due_at == "2026-11-01"
    end

    test "a message with nothing owed creates no loop", ctx do
      run_scripted(ctx, [%{"id" => "m-8", "content" => "Here is the weekly digest of activity."}])

      assert Loops.list(@tenant, workspace_ids: [ctx.workspace]) == []
    end
  end

  describe "outward evidence" do
    test "a connector with an outward topic tags each Signal with an outward event", ctx do
      run_scripted(
        ctx,
        [%{"id" => "m-9", "entities" => [ctx.sender]}],
        config: %{"outward_topic" => "customers"}
      )

      assert [event] = SignalEvents.list(@tenant, [ctx.workspace], kind: "outward")
      assert event.topic == "customers"
      assert event.ref =~ "scripted:"
      assert event.workspace_id == ctx.workspace
    end

    test "a connector with no outward topic records none", ctx do
      run_scripted(ctx, [%{"id" => "m-10"}])

      assert SignalEvents.list(@tenant, [ctx.workspace], kind: "outward") == []
    end

    test "an unknown outward topic is refused when the connector is registered", ctx do
      assert {:error, :invalid_outward_topic} =
               Connectors.register(%{
                 id: ctx.connector_id,
                 kind: :scripted,
                 workspace_id: ctx.workspace,
                 config: %{"outward_topic" => "vibes"}
               })
    end
  end

  describe "the whole path on the real adapter" do
    test "a broker-issued credential pulls a meeting, which routes, loops and tags", ctx do
      stub = ConnectorFixtureStub.install(:fathom_e2e)
      on_exit(fn -> ConnectorFixtureStub.uninstall(stub) end)

      add_rule(ctx.other, "sender", "jane@example.com")

      {:ok, summary} =
        PullScheduler.run_once(
          connectors: [
            %{
              kind: :fathom,
              id: ctx.connector_id,
              workspace_id: ctx.workspace,
              config: %{
                "outward_topic" => "customers",
                "credential_source" => "broker",
                "broker_url" => "https://connect.example.com/api/credentials",
                "broker_reference" => "conn_0000000000",
                "broker_scopes" => ["meetings.read"]
              }
            }
          ],
          tenant_id: @tenant
        )

      assert summary.error_count == 0
      assert summary.ingested_count == 1

      # The Engine asked the broker, then used what the broker issued.
      assert [credential_call] = ConnectorFixtureStub.calls_matching(stub, "connect.example.com")
      assert credential_call.method == "POST"
      assert credential_call.body["reference"] == "conn_0000000000"

      assert [meeting_call] = ConnectorFixtureStub.calls_matching(stub, "api.fathom.ai")

      assert Enum.any?(meeting_call.headers, fn {k, v} ->
               String.downcase(k) == "x-api-key" and v == "example-broker-issued-key"
             end)

      # Nothing from the broker was written down.
      {:ok, [[stored_config]]} =
        Store.raw_query("SELECT config FROM connectors WHERE id = ?1", [ctx.connector_id])

      refute stored_config =~ "example-broker-issued-key"

      # The meeting routed to the workspace its invitee is mapped to, not to the
      # connector's own workspace.
      assert contexts_in(ctx.other, "Discovery call") >= 1
      assert contexts_in(ctx.workspace, "Discovery call") == 0

      # The commitment spoken in the transcript became a loop, dated from the
      # day of the meeting rather than the day of the sync. The transcript also
      # carries a question, so this asserts the commitment among the loops the
      # meeting implies.
      loops = Loops.list(@tenant, workspace_ids: [ctx.other])
      assert Enum.any?(loops, &(&1.kind == "owed_reply"))

      assert [commitment] = Enum.filter(loops, &(&1.kind == "commitment"))
      assert commitment.due_at == "2026-10-15"
      assert commitment.counterparty == "jane@example.com"
      assert commitment.source_uri =~ "optimal://"

      assert [event] = SignalEvents.list(@tenant, [ctx.other], kind: "outward")
      assert event.topic == "customers"
    end
  end

  # ─── helpers ──────────────────────────────────────────────────────────────

  # Registers the connector and runs one sync through the real intake sink, so
  # the signals are routed, looped and tagged exactly as a scheduled pull would
  # do it. The Signal's title carries the test's own marker, so the contexts it
  # produced can be counted without counting anything else in the workspace.
  defp run_scripted(ctx, signals, opts \\ []) do
    signals =
      Enum.map(signals, fn signal ->
        signal
        |> Map.put_new("title", ctx.title)
        |> Map.put_new("content", "Could you please confirm the signed order form by Friday?")
      end)

    config = Map.merge(%{"signals" => signals}, Keyword.get(opts, :config, %{}))

    {:ok, id} =
      Connectors.register(%{
        id: ctx.connector_id,
        kind: :scripted,
        workspace_id: ctx.workspace,
        config: config
      })

    {:ok, result} =
      Runner.run(id, adapter: ScriptedAdapter, signal_sink: PullScheduler.intake_sink())

    assert result.status == :success
    result
  end

  defp add_rule(workspace_id, field, pattern, weight \\ 10) do
    {:ok, _} =
      RuleStore.add(
        @tenant,
        %{
          "workspace_id" => workspace_id,
          "field" => field,
          "pattern" => pattern,
          "weight" => weight,
          "source" => "manual"
        },
        "test"
      )
  end

  # A Signal routed to several nodes is indexed once per node, so a workspace
  # holds more than one context per Signal. The marker in the title keeps the
  # count meaning "Signals that landed here".
  defp contexts_in(workspace_id, title) do
    {:ok, [[count]]} =
      Store.raw_query(
        "SELECT COUNT(*) FROM contexts WHERE tenant_id = ?1 AND workspace_id = ?2 AND title = ?3",
        [Tenant.default_id(), workspace_id, title]
      )

    count
  end
end
