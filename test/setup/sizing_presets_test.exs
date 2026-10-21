defmodule OptimalEngine.SizingPresetsTest do
  @moduledoc """
  Size profiles, their tuning, usage gauges with resize recommendations, and
  use-case presets through the module and the HTTP API.
  """

  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias OptimalEngine.API.Router
  alias OptimalEngine.Auth.ApiKey
  alias OptimalEngine.Authority.Settings
  alias OptimalEngine.Operating.Protocol
  alias OptimalEngine.{Memory, MemoryCore, Presets, Sizing}
  alias OptimalEngine.Storage.PolicyStore
  alias OptimalEngine.Store
  alias OptimalEngine.Tenancy.Tenant
  alias OptimalEngine.Workspace

  setup do
    n = System.unique_integer([:positive])
    tenant = "setup-#{n}"
    {:ok, _} = Tenant.create(%{id: tenant, name: "Setup #{n}"})
    previous = Application.get_env(:optimal_engine, :size_profile)
    on_exit(fn -> restore(:size_profile, previous) end)
    %{tenant: tenant, n: n}
  end

  defp restore(key, nil), do: Application.delete_env(:optimal_engine, key)
  defp restore(key, value), do: Application.put_env(:optimal_engine, key, value)

  describe "size profiles" do
    test "are ordered, and the active one sets the tuning" do
      assert Enum.map(Sizing.profiles(), & &1.id) == ~w(agent workspace business platform scale)
      assert Sizing.profile().id == "business"

      Application.put_env(:optimal_engine, :size_profile, "agent")
      assert Sizing.profile().id == "agent"
      assert Sizing.tuning(:context_cache_entries) == 200
      assert Sizing.tuning(:api_per_minute) == 300
      assert Sizing.next("agent").id == "workspace"
      assert Sizing.next("scale") == nil

      # Explicit configuration wins over the profile.
      Application.put_env(:optimal_engine, :context_cache_entries, 42)
      assert Sizing.tuning(:context_cache_entries) == 42
      Application.delete_env(:optimal_engine, :context_cache_entries)

      Application.put_env(:optimal_engine, :size_profile, "nonsense")
      assert Sizing.profile().id == "business"
    end

    test "recommend the next profile at 70 percent of a limit" do
      {:ok, agent} = Sizing.fetch("agent")

      measures = %{
        vectors: 10_000,
        memories: 75_000,
        memory_candidates: 0,
        contexts: 100,
        disk_bytes: 0,
        memory_bytes: 0,
        writes_per_minute: 1.0
      }

      result = Sizing.evaluate(agent, measures)
      assert result.worst == %{name: "memories", percent: 75.0}
      assert %{action: "resize", to: "workspace", machine: %{size: "xs"}} = result.recommendation
      assert Enum.find(result.gauges, &(&1.name == "memories")).status == "watch"

      quiet = Sizing.evaluate(agent, %{measures | memories: 10})
      assert quiet.recommendation == %{action: "none"}

      {:ok, scale} = Sizing.fetch("scale")
      full = Sizing.evaluate(scale, %{measures | vectors: 9_000_000})
      assert %{action: "enable_providers", providers: ["qdrant"]} = full.recommendation
    end

    test "usage measures the live Engine" do
      usage = Sizing.usage()
      names = Enum.map(usage.gauges, & &1.name)

      assert names ==
               ~w(vectors memories memory_candidates contexts disk_bytes memory_bytes writes_per_minute)

      assert Enum.find(usage.gauges, &(&1.name == "memory_bytes")).used > 0
      assert is_integer(usage.boot_ms)
    end
  end

  describe "the memory_candidates gauge" do
    # The count is kept for a short while; a test that wrote a claim reads it
    # afresh.
    defp candidates_gauge do
      :persistent_term.erase({Sizing, :memory_candidates})
      Enum.find(Sizing.usage().gauges, &(&1.name == "memory_candidates"))
    end

    defp memories_used do
      Enum.find(Sizing.usage().gauges, &(&1.name == "memories")).used
    end

    defp remembered(n, label) do
      %{
        content: "Decision: Finance lead owns the #{label} renewal for Q4 at $2000 (#{n}).",
        workspace_id: "sizing-cand-#{n}"
      }
    end

    test "every profile limits it, a tenth of its memories" do
      for profile <- Sizing.profiles() do
        assert profile.limits.memory_candidates == div(profile.limits.memories, 10), profile.id
      end
    end

    test "is gauged against the active profile like the others" do
      {:ok, agent} = Sizing.fetch("agent")

      measures = %{
        vectors: 0,
        memories: 0,
        memory_candidates: 8_000,
        contexts: 0,
        disk_bytes: 0,
        memory_bytes: 0,
        writes_per_minute: 0.0
      }

      result = Sizing.evaluate(agent, measures)

      assert %{used: 8_000, limit: 10_000, percent: 80.0, status: "watch"} =
               Enum.find(result.gauges, &(&1.name == "memory_candidates"))

      assert result.worst == %{name: "memory_candidates", percent: 80.0}
      assert %{action: "resize", to: "workspace"} = result.recommendation
    end

    test "counts the pending memory-candidate claims a remembered fact writes", %{n: n} do
      before_candidates = candidates_gauge().used
      before_memories = memories_used()

      assert {:ok, %{action: :pending_claim, pending_claim: claim}} =
               Memory.remember(remembered(n, "pricing"))

      assert candidates_gauge().used == before_candidates + 1
      # The library intake writes the claim and no memory row.
      assert memories_used() == before_memories

      # A claim that is no longer pending is not a candidate waiting for review.
      assert :ok =
               MemoryCore.Store.update_claim_review(claim.id,
                 workspace_id: claim.workspace_id,
                 lifecycle_state: "rejected"
               )

      assert candidates_gauge().used == before_candidates
    end

    test "counts a fact the intake also stages as a memory in both gauges", %{n: n} do
      before_candidates = candidates_gauge().used
      before_memories = memories_used()

      assert {:ok, %{action: :add}} =
               Memory.remember(remembered(n, "support"), versioned_projection: true)

      assert candidates_gauge().used == before_candidates + 1
      assert memories_used() == before_memories + 1
    end

    test "does not count a fact the intake rejected", %{n: n} do
      before_candidates = candidates_gauge().used

      assert {:ok, %{action: :rejected}} =
               Memory.remember(%{content: "ok", workspace_id: "sizing-cand-#{n}"})

      assert candidates_gauge().used == before_candidates
    end

    test "the storage endpoint reports it", %{tenant: tenant} do
      reader = key(tenant, ["read"], ["*"])

      gauge =
        call(:get, "/api/storage", reader).resp_body
        |> Jason.decode!()
        |> Map.fetch!("gauges")
        |> Enum.find(&(&1["name"] == "memory_candidates"))

      assert %{"used" => used, "limit" => 200_000, "percent" => _, "status" => _} = gauge
      assert is_integer(used)
    end
  end

  describe "presets" do
    test "set a workspace up once and never overwrite", ctx do
      {:ok, result} =
        Presets.apply_preset(ctx.tenant, "business",
          slug: "brain",
          name: "Brain",
          actor: "user:owner"
        )

      workspace_id = result.workspace_id
      assert workspace_id == "#{ctx.tenant}:brain"
      assert length(result.applied) == 5
      assert result.env["OPTIMAL_SIZE_PROFILE"] == "business"
      assert result.env["OPTIMAL_ENGINE_SCOPE"] == "org"
      assert result.size.id == "business"

      {:ok, workspace} = Workspace.get(workspace_id)
      assert workspace.metadata["data_class"] == "confidential"
      assert {:ok, %{use_cases: ["desktop_local"]}} = PolicyStore.get_policy(workspace_id)
      assert Settings.mode(ctx.tenant) == "observe"

      assert {:ok, %{source: "workspace", content: content}} =
               Protocol.get(ctx.tenant, workspace_id, "repertoire")

      assert content =~ "- proposal"

      {:ok, [[packs]]} =
        Store.raw_query(
          "SELECT COUNT(*) FROM authority_policies WHERE tenant_id = ?1 AND status = 'active'",
          [ctx.tenant]
        )

      assert packs == 1

      {:ok, again} = Presets.apply_preset(ctx.tenant, "app", slug: "brain", actor: "user:owner")
      assert again.applied == []
      assert length(again.skipped) == 5
      {:ok, workspace} = Workspace.get(workspace_id)
      assert workspace.metadata["data_class"] == "confidential"

      assert {:error, :unknown_preset} = Presets.apply_preset(ctx.tenant, "everything")
    end

    test "a single-workspace preset names its workspace for the deployment", ctx do
      {:ok, result} = Presets.apply_preset(ctx.tenant, "agent", slug: "mailer", actor: "user:owner")
      assert result.env["OPTIMAL_ENGINE_SCOPE"] == "workspace"
      assert result.env["OPTIMAL_ENGINE_WORKSPACE"] == "#{ctx.tenant}:mailer"
      assert result.recipe == "docs/guides/recipes.md#agent-memory"
    end

    test "every preset's repertoire names registry genres" do
      for preset <- Presets.list(), genre <- preset.repertoire do
        assert OptimalEngine.Signal.GenreRegistry.valid?(genre), "#{preset.id}: #{genre}"
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

    test "storage usage, profiles, presets and init", ctx do
      root = key(ctx.tenant, ["*"], ["*"])
      reader = key(ctx.tenant, ["read"], ["*"])

      storage = call(:get, "/api/storage", reader)
      assert storage.status == 200
      body = Jason.decode!(storage.resp_body)
      assert body["profile"]["id"] == "business"
      assert length(body["gauges"]) == 7
      assert "memory_candidates" in Enum.map(body["gauges"], & &1["name"])

      assert %{"profiles" => [_, _, _, _, _], "active" => "business"} =
               call(:get, "/api/storage/profiles", reader).resp_body |> Jason.decode!()

      presets = call(:get, "/api/init/presets", reader).resp_body |> Jason.decode!()
      assert length(presets["presets"]) == 5

      assert call(:post, "/api/init", reader, %{"for" => "workspace", "slug" => "team"}).status ==
               403

      init =
        call(:post, "/api/init", root, %{"for" => "workspace", "slug" => "team", "name" => "Team"})

      assert init.status == 200
      assert Jason.decode!(init.resp_body)["workspace_id"] == "#{ctx.tenant}:team"

      bad = call(:post, "/api/init", root, %{"for" => "nope"})
      assert bad.status == 422
      assert "tenant-per-customer" in Jason.decode!(bad.resp_body)["presets"]

      metrics = call(:get, "/api/metrics", reader).resp_body |> Jason.decode!()
      assert metrics["sizing"]["profile"]["id"] == "business"
    end
  end
end
