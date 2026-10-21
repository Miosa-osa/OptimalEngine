defmodule OptimalEngine.MemoryCore.ContextRefreshGrantsTest do
  @moduledoc """
  A refresh re-runs a stored Context Package's query and hands the new package
  to whoever asked. It reads under that caller's grants, the ones governed
  recall applies, never under the grants the package was first built for and
  never under none at all. A maintenance refresh with no caller stays inside
  the package's own recorded envelope.
  """

  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias OptimalEngine.API.Router
  alias OptimalEngine.Auth.ApiKey
  alias OptimalEngine.MemoryCore
  alias OptimalEngine.MemoryCore.ContextRefreshScheduler
  alias OptimalEngine.MemoryCore.ID
  alias OptimalEngine.MemoryCore.RetrievalCoordinator
  alias OptimalEngine.MemoryCore.Store, as: MemoryCoreStore
  alias OptimalEngine.Store

  @opts Router.init([])

  # One fact and one memory object per tier: {tag, security_labels, partition_ids}.
  @tiers [
    {"open", [], []},
    {"public", ["public"], []},
    {"internal", ["internal"], []},
    {"restricted", ["restricted"], []},
    {"partitioned", ["public"], ["team-x"]}
  ]

  # {name, key metadata, tiers that key reads through governed recall}
  @grant_cases [
    {"no grants", %{}, ["open"]},
    {"the public label", %{"allowed_security_labels" => ["public"]}, ["open", "public"]},
    {"every label", %{"allowed_security_labels" => ["public", "internal", "restricted"]},
     ["open", "public", "internal", "restricted"]},
    {"the public label and the team-x partition",
     %{"allowed_security_labels" => ["public"], "allowed_partitions" => ["team-x"]},
     ["partitioned"]},
    {"grants that are not lists", %{"allowed_security_labels" => "restricted"}, ["open"]}
  ]

  setup do
    workspace_id = "refresh-grants-#{System.unique_integer([:positive])}"
    rows = seed_rows!(workspace_id)
    {:ok, workspace_id: workspace_id, rows: rows}
  end

  describe "fixture" do
    test "governed recall gives each grant set exactly its tiers", ctx do
      for {_name, metadata, tags} <- @grant_cases do
        {:ok, package} =
          RetrievalCoordinator.retrieve_package("launch",
            workspace_id: ctx.workspace_id,
            actor_id: "agent:recall",
            allowed_partitions: grant_list(metadata, "allowed_partitions"),
            allowed_security_labels: grant_list(metadata, "allowed_security_labels")
          )

        recalled = MapSet.new(Enum.map(package.facts ++ package.memory_objects, & &1.id))
        assert recalled == ids_for(ctx.rows, tags)
      end
    end
  end

  describe "POST /api/memory-core/context-packages/refresh-stale" do
    for {name, metadata, tags} <- @grant_cases do
      test "a key with #{name} gets what governed recall gives it", ctx do
        _packages = build_packages!(ctx.workspace_id, ctx.rows)
        token = mint_key!(["write"], unquote(Macro.escape(metadata)))

        conn =
          with_auth_required(fn ->
            request(:post, "/api/memory-core/context-packages/refresh-stale", token, %{
              "workspace" => ctx.workspace_id,
              "batch_limit" => 10
            })
          end)

        assert conn.status == 200
        body = Jason.decode!(conn.resp_body)
        assert body["refreshed_count"] == 2
        assert body["error_count"] == 0
        assert_within(body["refreshed_context_packages"], conn.resp_body, ctx.rows, unquote(tags))
      end
    end

    test "grants in the body of a keyed request are ignored", ctx do
      _packages = build_packages!(ctx.workspace_id, ctx.rows)
      token = mint_key!(["write"], %{})

      conn =
        with_auth_required(fn ->
          request(:post, "/api/memory-core/context-packages/refresh-stale", token, %{
            "workspace" => ctx.workspace_id,
            "allowed_security_labels" => ["public", "internal", "restricted"],
            "allowed_partitions" => ["team-x"]
          })
        end)

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert_within(body["refreshed_context_packages"], conn.resp_body, ctx.rows, ["open"])
    end

    test "a root key whose grants cover the rows still gets them", ctx do
      _packages = build_packages!(ctx.workspace_id, ctx.rows)

      token =
        mint_key!(["*"], %{"allowed_security_labels" => ["public", "internal", "restricted"]})

      conn =
        with_auth_required(fn ->
          request(:post, "/api/memory-core/context-packages/refresh-stale", token, %{
            "workspace" => ctx.workspace_id
          })
        end)

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)

      assert_within(
        body["refreshed_context_packages"],
        conn.resp_body,
        ctx.rows,
        ["open", "public", "internal", "restricted"]
      )
    end

    test "a caller with no key and no grants in the body gets unlabelled rows only", ctx do
      _packages = build_packages!(ctx.workspace_id, ctx.rows)

      conn =
        request(:post, "/api/memory-core/context-packages/refresh-stale", nil, %{
          "workspace" => ctx.workspace_id
        })

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert_within(body["refreshed_context_packages"], conn.resp_body, ctx.rows, ["open"])
    end

    test "a caller with no key may state its grants in the body", ctx do
      _packages = build_packages!(ctx.workspace_id, ctx.rows)

      conn =
        request(:post, "/api/memory-core/context-packages/refresh-stale", nil, %{
          "workspace" => ctx.workspace_id,
          "allowed_security_labels" => ["public"]
        })

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)

      assert_within(body["refreshed_context_packages"], conn.resp_body, ctx.rows, ["open", "public"])
    end
  end

  describe "POST /api/memory-core/active-pools/:id/refresh-context" do
    for {name, metadata, tags} <- @grant_cases do
      test "a key with #{name} gets what governed recall gives it", ctx do
        pool_id = open_pool_with!(ctx.workspace_id, build_packages!(ctx.workspace_id, ctx.rows))
        token = mint_key!(["write"], unquote(Macro.escape(metadata)))

        conn =
          with_auth_required(fn ->
            request(
              :post,
              "/api/memory-core/active-pools/#{pool_id}/refresh-context",
              token,
              %{}
            )
          end)

        assert conn.status == 200
        body = Jason.decode!(conn.resp_body)
        assert body["refreshed_count"] == 2
        assert body["errors"] == []
        assert_within(body["refreshed_context_packages"], conn.resp_body, ctx.rows, unquote(tags))
      end
    end

    test "grants in the body of a keyed request are ignored", ctx do
      pool_id = open_pool_with!(ctx.workspace_id, build_packages!(ctx.workspace_id, ctx.rows))
      token = mint_key!(["write"], %{})

      conn =
        with_auth_required(fn ->
          request(:post, "/api/memory-core/active-pools/#{pool_id}/refresh-context", token, %{
            "allowed_security_labels" => ["public", "internal", "restricted"],
            "allowed_partitions" => ["team-x"]
          })
        end)

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert_within(body["refreshed_context_packages"], conn.resp_body, ctx.rows, ["open"])
    end
  end

  describe "RetrievalCoordinator.refresh_context_package/2" do
    test "with no caller grants it stays inside the package's recorded envelope", ctx do
      package = build_package!(ctx.workspace_id, ["public"], [])
      make_stale!(ctx.workspace_id, ctx.rows)

      assert {:ok, refreshed} =
               RetrievalCoordinator.refresh_context_package(package.id,
                 workspace_id: ctx.workspace_id
               )

      assert returned_ids(refreshed) == ids_for(ctx.rows, ["open", "public"])
    end

    test "grants the caller passes replace the recorded envelope", ctx do
      package = build_package!(ctx.workspace_id, ["public"], [])
      make_stale!(ctx.workspace_id, ctx.rows)

      assert {:ok, refreshed} =
               RetrievalCoordinator.refresh_context_package(package.id,
                 workspace_id: ctx.workspace_id,
                 allowed_partitions: [],
                 allowed_security_labels: ["internal"]
               )

      assert returned_ids(refreshed) == ids_for(ctx.rows, ["open", "internal"])
    end

    test "a grant the caller leaves out is read from the recorded envelope", ctx do
      package = build_package!(ctx.workspace_id, ["public"], [])
      make_stale!(ctx.workspace_id, ctx.rows)

      assert {:ok, refreshed} =
               RetrievalCoordinator.refresh_context_package(package.id,
                 workspace_id: ctx.workspace_id,
                 allowed_partitions: []
               )

      assert returned_ids(refreshed) == ids_for(ctx.rows, ["open", "public"])
    end

    test "a recorded envelope that cannot be read fails closed and leaves the package stale",
         ctx do
      package = build_package!(ctx.workspace_id, ["public"], [])
      make_stale!(ctx.workspace_id, ctx.rows)

      assert :ok =
               Store.raw_execute(
                 "UPDATE context_packages SET authorization_envelope = '{}' WHERE id = ?1",
                 [package.id]
               )

      assert {:error, :authorization_envelope_unreadable} =
               RetrievalCoordinator.refresh_context_package(package.id,
                 workspace_id: ctx.workspace_id
               )

      assert {:ok, [["stale"]]} =
               Store.raw_query("SELECT refresh_state FROM context_packages WHERE id = ?1", [
                 package.id
               ])
    end

    test "grants that are not lists fail closed", ctx do
      package = build_package!(ctx.workspace_id, ["public"], [])
      make_stale!(ctx.workspace_id, ctx.rows)

      assert {:error, :invalid_refresh_grants} =
               RetrievalCoordinator.refresh_context_package(package.id,
                 workspace_id: ctx.workspace_id,
                 allowed_security_labels: "restricted"
               )
    end

    test "a scheduled refresh does not widen the package it replaces", ctx do
      package = build_package!(ctx.workspace_id, ["public"], [])
      make_stale!(ctx.workspace_id, ctx.rows)

      assert {:ok, summary} =
               ContextRefreshScheduler.run_once(
                 workspace_id: ctx.workspace_id,
                 tenant_id: "default"
               )

      assert summary.stale_context_package_ids == [package.id]
      assert [refreshed_id] = summary.refreshed_context_package_ids

      assert {:ok, [[fact_links, memory_links]]} =
               Store.raw_query(
                 "SELECT fact_links, memory_links FROM context_packages WHERE id = ?1",
                 [refreshed_id]
               )

      stored =
        (Jason.decode!(fact_links) ++ Jason.decode!(memory_links))
        |> Enum.map(& &1["id"])
        |> MapSet.new()

      assert stored == ids_for(ctx.rows, ["open", "public"])
    end
  end

  # -- fixtures ---------------------------------------------------------------

  defp seed_rows!(workspace_id) do
    Map.new(@tiers, fn {tag, labels, partitions} ->
      shared = %{
        tenant_id: "default",
        workspace_id: workspace_id,
        subject_anchor: "launch",
        action_class: "noted",
        security_labels: labels,
        partition_ids: partitions
      }

      fact =
        Map.merge(shared, %{
          id: ID.random_id("fact"),
          fact_text: "Launch note #{tag}-marker.",
          lifecycle_state: "accepted",
          contradiction_status: "none"
        })

      memory =
        Map.merge(shared, %{
          id: ID.random_id("mem"),
          summary: "Launch memory #{tag}-marker.",
          lifecycle_state: "current"
        })

      :ok = MemoryCoreStore.insert_fact(fact)
      :ok = MemoryCoreStore.insert_memory_object(memory)
      {tag, MapSet.new([fact.id, memory.id])}
    end)
  end

  # Two packages that between them hold every tier, then marked stale.
  defp build_packages!(workspace_id, rows) do
    packages = [
      build_package!(workspace_id, ["public", "internal", "restricted"], []),
      build_package!(workspace_id, ["public"], ["team-x"])
    ]

    make_stale!(workspace_id, rows)
    packages
  end

  defp build_package!(workspace_id, labels, partitions) do
    {:ok, package} =
      RetrievalCoordinator.retrieve("launch",
        workspace_id: workspace_id,
        actor_id: "agent:builder",
        allowed_partitions: partitions,
        allowed_security_labels: labels
      )

    package
  end

  defp make_stale!(workspace_id, rows) do
    [any_id | _] = rows |> Map.fetch!("open") |> Enum.to_list()

    :ok =
      MemoryCoreStore.invalidate_context_packages_for_object("fact", any_id,
        workspace_id: workspace_id,
        reason: "refresh_grants_test"
      )
  end

  defp open_pool_with!(workspace_id, packages) do
    {:ok, pool} =
      MemoryCore.open_active_pool(
        tenant_id: "default",
        workspace_id: workspace_id,
        task_type: "refresh_grants_#{System.unique_integer([:positive])}"
      )

    for package <- packages, do: {:ok, _pool} = MemoryCore.load_context_package(pool.id, package)
    pool.id
  end

  defp mint_key!(scopes, metadata) do
    {:ok, %{key: token}} =
      ApiKey.mint(%{
        tenant_id: "default",
        name: "refresh grants #{System.unique_integer([:positive])}",
        scopes: scopes,
        workspace_scope: ["*"],
        metadata: metadata
      })

    token
  end

  defp grant_list(metadata, grant) do
    case Map.get(metadata, grant) do
      grants when is_list(grants) -> grants
      _ -> []
    end
  end

  # -- assertions -------------------------------------------------------------

  defp ids_for(rows, tags) do
    Enum.reduce(tags, MapSet.new(), fn tag, acc -> MapSet.union(acc, Map.fetch!(rows, tag)) end)
  end

  defp returned_ids(%{fact_links: facts, memory_links: memories}) do
    MapSet.new(Enum.map(facts ++ memories, & &1.id))
  end

  defp returned_ids(%{"fact_links" => facts, "memory_links" => memories}) do
    MapSet.new(Enum.map(facts ++ memories, & &1["id"]))
  end

  # Every package holds the ids and the text of exactly the tiers in `tags`.
  defp assert_within(packages, raw_body, rows, tags) do
    assert length(packages) == 2

    for package <- packages do
      assert returned_ids(package) == ids_for(rows, tags)
    end

    leaked =
      for {tag, _labels, _partitions} <- @tiers,
          tag not in tags,
          String.contains?(raw_body, "#{tag}-marker"),
          do: tag

    assert leaked == []

    for tag <- tags do
      assert String.contains?(raw_body, "#{tag}-marker")
    end
  end

  # -- HTTP -------------------------------------------------------------------

  defp request(method, path, token, body) do
    conn =
      method
      |> conn(path, Jason.encode!(body))
      |> put_req_header("content-type", "application/json")

    conn = if token, do: put_req_header(conn, "authorization", "Bearer " <> token), else: conn
    Router.call(conn, @opts)
  end

  defp with_auth_required(fun) do
    original = Application.get_env(:optimal_engine, :auth, [])
    Application.put_env(:optimal_engine, :auth, Keyword.merge(original, auth_required: true))

    try do
      fun.()
    after
      Application.put_env(:optimal_engine, :auth, original)
    end
  end
end
