defmodule OptimalEngine.Connectors.RoutingTenantTest do
  @moduledoc """
  A connector's Signals are placed in workspaces of the connector's own tenant.

  The review workspace a connector names, and the workspace a routing rule
  names, are data a tenant supplies. Neither can send a Signal into a
  workspace of another tenant: registering a connector with such a review
  workspace is refused, and a Signal whose route names one (a row that
  predates the check, a rule written for another tenant's workspace) stays in
  the connector's own workspace.
  """

  use ExUnit.Case, async: false

  alias OptimalEngine.Connectors
  alias OptimalEngine.Connectors.{PullScheduler, Runner}
  alias OptimalEngine.{Organization, Store, Workspace}
  alias OptimalEngine.Routing.RuleStore
  alias OptimalEngine.Tenancy.Tenant

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
            genre: "message",
            entities: raw["entities"] || [],
            modified_at: Transform.parse_iso8601(raw["modified_at"])
          })
        end)

      {:ok, %{signals: signals, cursor: "cursor-1"}}
    end

    @impl true
    def transform(raw) when is_map(raw), do: {:ok, %Signal{id: raw["id"] || "scripted"}}
  end

  setup do
    n = System.unique_integer([:positive])
    tenant = "conn-b-#{n}"
    {:ok, _} = Tenant.create(%{id: tenant, name: tenant})

    workspace = fn tenant_id, slug ->
      {:ok, created} =
        Workspace.create(%{
          tenant_id: tenant_id,
          organization_id: Organization.default_for(tenant_id),
          slug: slug,
          name: slug
        })

      created.id
    end

    {:ok, other} = Workspace.create(%{slug: "conn-default-#{n}", name: "Default workspace #{n}"})

    {:ok,
     n: n,
     tenant: tenant,
     home: workspace.(tenant, "home"),
     review: workspace.(tenant, "review"),
     retired: workspace.(tenant, "retired"),
     foreign: other.id,
     connector_id: "conn-tenant-#{n}",
     title: "tenant-subject-#{n}"}
  end

  defp register(ctx, config) do
    Connectors.register(%{
      id: ctx.connector_id,
      kind: :scripted,
      tenant_id: ctx.tenant,
      workspace_id: ctx.home,
      config: config
    })
  end

  defp signals(ctx) do
    [
      %{
        "id" => "m-#{ctx.n}",
        "title" => ctx.title,
        "content" => "The #{ctx.title} schedule is attached."
      }
    ]
  end

  defp run(ctx) do
    {:ok, result} =
      Runner.run(ctx.connector_id,
        adapter: ScriptedAdapter,
        signal_sink: PullScheduler.intake_sink()
      )

    assert result.status == :success
  end

  defp contexts_in(ctx, workspace_id) do
    {:ok, [[count]]} =
      Store.raw_query("SELECT COUNT(*) FROM contexts WHERE workspace_id = ?1 AND title = ?2", [
        workspace_id,
        ctx.title
      ])

    count
  end

  # A rule that scores under the high-confidence bar proposes its workspace for
  # review; one at the top of the scale claims the Signal.
  defp rule(ctx, workspace_id, weight) do
    {:ok, _} =
      RuleStore.add(
        ctx.tenant,
        %{
          "workspace_id" => workspace_id,
          "field" => "keyword",
          "pattern" => ctx.title,
          "weight" => weight,
          "source" => "manual"
        },
        "test"
      )
  end

  describe "the review workspace of a connector" do
    test "is a workspace of the connector's tenant", ctx do
      assert {:ok, _} = register(ctx, %{"review_workspace_id" => ctx.review})
    end

    test "is refused when it belongs to another tenant, or is archived", ctx do
      :ok = Workspace.archive(ctx.retired)

      for workspace <- [ctx.foreign, ctx.retired, "default:no-such-#{ctx.n}"] do
        assert {:error, :invalid_review_workspace} =
                 register(ctx, %{"review_workspace_id" => workspace}),
               workspace
      end

      assert {:error, :invalid_review_workspace} =
               register(ctx, %{"review_workspace_id" => 42})
    end

    test "a Signal for review lands there", ctx do
      {:ok, _} = register(ctx, %{"signals" => signals(ctx), "review_workspace_id" => ctx.review})
      rule(ctx, ctx.home, 1)
      run(ctx)

      assert contexts_in(ctx, ctx.review) >= 1
      assert contexts_in(ctx, ctx.foreign) == 0
    end

    test "a stored row that names another tenant's workspace keeps the Signal at home", ctx do
      {:ok, _} = register(ctx, %{"signals" => signals(ctx)})

      {:ok, _} =
        Store.raw_query(
          "UPDATE connectors SET config = json_set(config, '$.review_workspace_id', ?2) WHERE id = ?1",
          [ctx.connector_id, ctx.foreign]
        )

      rule(ctx, ctx.review, 1)
      run(ctx)

      assert contexts_in(ctx, ctx.foreign) == 0
      assert contexts_in(ctx, ctx.home) >= 1
    end
  end

  describe "the workspace of a routing rule" do
    test "a rule that names another tenant's workspace does not claim the Signal", ctx do
      {:ok, _} = register(ctx, %{"signals" => signals(ctx)})
      rule(ctx, ctx.foreign, 10)
      run(ctx)

      assert contexts_in(ctx, ctx.foreign) == 0
      assert contexts_in(ctx, ctx.home) >= 1
    end

    test "a rule that names the tenant's own workspace does", ctx do
      {:ok, _} = register(ctx, %{"signals" => signals(ctx)})
      rule(ctx, ctx.review, 10)
      run(ctx)

      assert contexts_in(ctx, ctx.review) >= 1
      assert contexts_in(ctx, ctx.home) == 0
    end
  end
end
