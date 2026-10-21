defmodule OptimalEngine.MemoryCore.ContextRefreshGrantsTest do
  @moduledoc """
  A refresh re-runs a stored Context Package's query and hands the new package
  to whoever asked. It reads under that caller's grants, the ones governed
  recall applies, never under the grants the package was first built for and
  never under none at all. A caller refreshes only the packages it requested or
  whose recorded envelope its grants cover, and is not handed the original
  reader's query. A maintenance refresh with no caller stays inside the
  package's own recorded envelope.
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

  # The reader that built the packages in the tests that are not about owners.
  @builder "agent:builder"

  # Two clauses: "launch note" matches the fixture rows, and the rest is a word
  # that appears in none of them, so any copy of it in a response is the query.
  @query "launch note, zxqvkj frobnicate"
  @query_marker "zxqvkj"

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
    {"grants that are not lists", %{"allowed_security_labels" => "restricted"}, ["open"]},
    {"the wildcard for labels and partitions",
     %{"allowed_security_labels" => ["*"], "allowed_partitions" => ["*"]},
     ["open", "public", "internal", "restricted", "partitioned"]}
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

  describe "POST /api/memory-core/context-packages/refresh-stale, the caller's own packages" do
    for {name, metadata, tags} <- @grant_cases do
      test "a key with #{name} gets what governed recall gives it", ctx do
        {token, principal} = mint_key!(["write"], unquote(Macro.escape(metadata)))
        _packages = build_packages!(ctx.workspace_id, ctx.rows, principal)

        conn = refresh_stale(ctx.workspace_id, token)

        assert conn.status == 200
        body = Jason.decode!(conn.resp_body)
        assert body["refreshed_count"] == 2
        assert body["error_count"] == 0
        assert_within(body["refreshed_context_packages"], conn.resp_body, ctx.rows, unquote(tags))
      end
    end

    test "grants in the body of a keyed request are ignored", ctx do
      {token, principal} = mint_key!(["write"], %{})
      _packages = build_packages!(ctx.workspace_id, ctx.rows, principal)

      conn =
        refresh_stale(ctx.workspace_id, token, %{
          "allowed_security_labels" => ["public", "internal", "restricted"],
          "allowed_partitions" => ["team-x"]
        })

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert_within(body["refreshed_context_packages"], conn.resp_body, ctx.rows, ["open"])
    end

    test "the requester gets its query back, and no invalidation reason", ctx do
      {token, principal} = mint_key!(["write"], %{})
      _packages = build_packages!(ctx.workspace_id, ctx.rows, principal)

      conn = refresh_stale(ctx.workspace_id, token)
      body = Jason.decode!(conn.resp_body)
      assert conn.resp_body =~ @query_marker
      assert conn.resp_body =~ "candidates"

      for package <- body["refreshed_context_packages"] do
        assert package["retrieval_plan"]["query"] == @query
        assert package["metadata"]["query"] == @query
        assert package["metadata"]["refreshed_from_context_package_id"]
        refute Map.has_key?(package["metadata"], "refreshed_from_invalidation_reason")
      end
    end

    test "a caller with no key and no grants in the body gets unlabelled rows only", ctx do
      _packages = build_packages!(ctx.workspace_id, ctx.rows, local_actor())

      conn =
        request(:post, "/api/memory-core/context-packages/refresh-stale", nil, %{
          "workspace" => ctx.workspace_id
        })

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert_within(body["refreshed_context_packages"], conn.resp_body, ctx.rows, ["open"])
    end

    test "a caller with no key may state its grants in the body", ctx do
      _packages = build_packages!(ctx.workspace_id, ctx.rows, local_actor())

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

  describe "POST /api/memory-core/context-packages/refresh-stale, another reader's packages" do
    test "a key that neither requested nor covers them neither lists nor refreshes them", ctx do
      packages = build_packages!(ctx.workspace_id, ctx.rows, @builder)

      for metadata <- [%{}, %{"allowed_security_labels" => ["public"]}] do
        {token, _principal} = mint_key!(["write"], metadata)

        conn = refresh_stale(ctx.workspace_id, token)

        assert conn.status == 200
        body = Jason.decode!(conn.resp_body)
        assert body["stale_context_package_ids"] == []
        assert body["refreshed_count"] == 0
        assert body["error_count"] == 0
      end

      assert_states(packages, "stale")
    end

    test "a key refreshes the packages whose envelope its grants cover, and only those", ctx do
      [labelled, partitioned] = build_packages!(ctx.workspace_id, ctx.rows, @builder)

      {token, _principal} =
        mint_key!(["write"], %{"allowed_security_labels" => ["public", "internal", "restricted"]})

      conn = refresh_stale(ctx.workspace_id, token)

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["stale_context_package_ids"] == [labelled.id]
      assert body["refreshed_count"] == 1

      assert_within(
        body["refreshed_context_packages"],
        conn.resp_body,
        ctx.rows,
        ["open", "public", "internal", "restricted"],
        1
      )

      # The reader got a package of its own; the owner's is left for the owner.
      assert_states([labelled, partitioned], "stale")
    end

    test "a key that did not ask the query is handed it nowhere in the response", ctx do
      _packages = build_packages!(ctx.workspace_id, ctx.rows, @builder)

      {token, _principal} =
        mint_key!(["write"], %{"allowed_security_labels" => ["*"], "allowed_partitions" => ["*"]})

      conn = refresh_stale(ctx.workspace_id, token)
      body = Jason.decode!(conn.resp_body)
      assert body["refreshed_count"] == 2
      refute conn.resp_body =~ @query_marker
      refute conn.resp_body =~ "req-#{@builder}"
      refute conn.resp_body =~ "candidates"
      refute conn.resp_body =~ "Policy-excluded"

      for package <- body["refreshed_context_packages"] do
        for key <- ~w(query evidence_plan evidence_obligations evidence_probes) do
          refute Map.has_key?(package["retrieval_plan"], key)
        end

        refute Map.has_key?(package["metadata"], "query")
        refute Map.has_key?(package["metadata"], "query_owner_actor_id")
        refute Map.has_key?(package["metadata"], "refreshed_from_invalidation_reason")
        assert package["metadata"]["refreshed_from_context_package_id"]
        assert package["request_id"] == nil
        assert package["active_memory_pool_id"] == nil
        assert package["redacted_object_links"] == []
        assert package["filtered_object_summary"] == %{}
      end
    end

    test "the query stays hidden from the reader that refreshed it, on the next refresh too",
         ctx do
      _packages = build_packages!(ctx.workspace_id, ctx.rows, @builder)

      {token, principal} =
        mint_key!(["write"], %{"allowed_security_labels" => ["*"], "allowed_partitions" => ["*"]})

      first = refresh_stale(ctx.workspace_id, token)
      assert Jason.decode!(first.resp_body)["refreshed_count"] == 2
      refute first.resp_body =~ @query_marker

      # The successors were requested by `principal`, who is not who asked the query.
      make_stale!(ctx.workspace_id, ctx.rows)
      second = refresh_stale(ctx.workspace_id, token)
      assert Jason.decode!(second.resp_body)["refreshed_count"] >= 2
      refute second.resp_body =~ @query_marker

      assert {:ok, [[owners]]} =
               Store.raw_query(
                 "SELECT json_group_array(DISTINCT json_extract(metadata, '$.query_owner_actor_id')) FROM context_packages WHERE workspace_id = ?1 AND requesting_actor_id = ?2",
                 [ctx.workspace_id, principal]
               )

      assert Jason.decode!(owners) == [@builder]

      # The reader that asked it still sees it.
      make_stale!(ctx.workspace_id, ctx.rows)
      [stale_id | _] = stale_ids(ctx.workspace_id)

      assert {:ok, refreshed} =
               RetrievalCoordinator.refresh_context_package(stale_id,
                 workspace_id: ctx.workspace_id,
                 actor_id: @builder,
                 allowed_partitions: ["*"],
                 allowed_security_labels: ["*"]
               )

      assert refreshed.retrieval_plan.query == @query
    end

    test "the wildcard covers every package and returns every tier", ctx do
      _packages = build_packages!(ctx.workspace_id, ctx.rows, @builder)

      {token, _principal} =
        mint_key!(["write"], %{"allowed_security_labels" => ["*"], "allowed_partitions" => ["*"]})

      conn = refresh_stale(ctx.workspace_id, token)

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["refreshed_count"] == 2

      assert_within(
        body["refreshed_context_packages"],
        conn.resp_body,
        ctx.rows,
        ["open", "public", "internal", "restricted", "partitioned"]
      )
    end

    test "a caller with no key states grants that cover the packages", ctx do
      _packages = build_packages!(ctx.workspace_id, ctx.rows, @builder)

      conn =
        request(:post, "/api/memory-core/context-packages/refresh-stale", nil, %{
          "workspace" => ctx.workspace_id,
          "allowed_security_labels" => ["public", "internal", "restricted"]
        })

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["refreshed_count"] == 1
    end
  end

  describe "POST /api/memory-core/active-pools/:id/refresh-context" do
    for {name, metadata, tags} <- @grant_cases do
      test "a key with #{name} gets what governed recall gives it", ctx do
        {token, principal} = mint_key!(["write"], unquote(Macro.escape(metadata)))
        packages = build_packages!(ctx.workspace_id, ctx.rows, principal)
        pool_id = open_pool_with!(ctx.workspace_id, packages)

        conn = refresh_context(pool_id, token)

        assert conn.status == 200
        body = Jason.decode!(conn.resp_body)
        assert body["refreshed_count"] == 2
        assert body["errors"] == []
        assert_within(body["refreshed_context_packages"], conn.resp_body, ctx.rows, unquote(tags))
      end
    end

    test "grants in the body of a keyed request are ignored", ctx do
      {token, principal} = mint_key!(["write"], %{})
      packages = build_packages!(ctx.workspace_id, ctx.rows, principal)
      pool_id = open_pool_with!(ctx.workspace_id, packages)

      conn =
        refresh_context(pool_id, token, %{
          "allowed_security_labels" => ["public", "internal", "restricted"],
          "allowed_partitions" => ["team-x"]
        })

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert_within(body["refreshed_context_packages"], conn.resp_body, ctx.rows, ["open"])
    end

    test "a key that neither requested nor covers the loaded packages refreshes none", ctx do
      packages = build_packages!(ctx.workspace_id, ctx.rows, @builder)
      pool_id = open_pool_with!(ctx.workspace_id, packages)
      {token, _principal} = mint_key!(["write"], %{"allowed_security_labels" => ["public"]})

      conn = refresh_context(pool_id, token)

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["refreshed_count"] == 0
      assert length(body["errors"]) == 2
      assert Enum.all?(body["errors"], &(&1["reason"] == "not_found"))
      assert_states(packages, "stale")
    end

    test "the wildcard covers the loaded packages and returns every tier", ctx do
      packages = build_packages!(ctx.workspace_id, ctx.rows, @builder)
      pool_id = open_pool_with!(ctx.workspace_id, packages)

      {token, _principal} =
        mint_key!(["write"], %{"allowed_security_labels" => ["*"], "allowed_partitions" => ["*"]})

      conn = refresh_context(pool_id, token)

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["refreshed_count"] == 2

      assert_within(
        body["refreshed_context_packages"],
        conn.resp_body,
        ctx.rows,
        ["open", "public", "internal", "restricted", "partitioned"]
      )
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

    test "grants the requester passes replace the recorded envelope", ctx do
      package = build_package!(ctx.workspace_id, ["public"], [])
      make_stale!(ctx.workspace_id, ctx.rows)

      assert {:ok, refreshed} =
               RetrievalCoordinator.refresh_context_package(package.id,
                 workspace_id: ctx.workspace_id,
                 actor_id: @builder,
                 allowed_partitions: [],
                 allowed_security_labels: ["internal"]
               )

      assert returned_ids(refreshed) == ids_for(ctx.rows, ["open", "internal"])
      assert refreshed.retrieval_plan.query == @query
      assert refreshed.metadata.query == @query
      assert refreshed.sections.summary =~ @query_marker
    end

    test "a grant the caller leaves out is read from the recorded envelope", ctx do
      package = build_package!(ctx.workspace_id, ["public"], [])
      make_stale!(ctx.workspace_id, ctx.rows)

      assert {:ok, refreshed} =
               RetrievalCoordinator.refresh_context_package(package.id,
                 workspace_id: ctx.workspace_id,
                 actor_id: @builder,
                 allowed_partitions: []
               )

      assert returned_ids(refreshed) == ids_for(ctx.rows, ["open", "public"])
    end

    test "a caller that neither requested nor covers the package finds none", ctx do
      package = build_package!(ctx.workspace_id, ["public", "internal"], [])
      make_stale!(ctx.workspace_id, ctx.rows)

      for grants <- [
            [allowed_partitions: [], allowed_security_labels: []],
            [allowed_partitions: [], allowed_security_labels: ["public"]],
            [allowed_partitions: ["team-x"], allowed_security_labels: ["public", "internal"]]
          ] do
        assert {:error, :not_found} =
                 RetrievalCoordinator.refresh_context_package(
                   package.id,
                   [workspace_id: ctx.workspace_id, actor_id: "agent:other"] ++ grants
                 )
      end

      assert_states([package], "stale")
    end

    test "a caller whose grants cover the package gets it without the query", ctx do
      package = build_package!(ctx.workspace_id, ["public", "internal"], [])
      make_stale!(ctx.workspace_id, ctx.rows)

      assert {:ok, refreshed} =
               RetrievalCoordinator.refresh_context_package(package.id,
                 workspace_id: ctx.workspace_id,
                 actor_id: "agent:other",
                 allowed_partitions: [],
                 allowed_security_labels: ["public", "internal", "restricted"]
               )

      assert returned_ids(refreshed) ==
               ids_for(ctx.rows, ["open", "public", "internal", "restricted"])

      refute Map.has_key?(refreshed.retrieval_plan, :query)
      refute Map.has_key?(refreshed.metadata, :query)
      refute Map.has_key?(refreshed.metadata, :query_owner_actor_id)
      refute Map.has_key?(refreshed.metadata, :refreshed_from_invalidation_reason)
      refute refreshed.sections.summary =~ @query_marker
      refute refreshed.metadata.sections.summary =~ @query_marker
      refute refreshed.sections.summary =~ "candidates"
      assert refreshed.redacted_object_links == []
      assert refreshed.filtered_object_summary == %{}
      assert refreshed.request_id == nil

      # The stored package keeps the query, so it can be refreshed again.
      assert {:ok, [[metadata]]} =
               Store.raw_query("SELECT metadata FROM context_packages WHERE id = ?1", [refreshed.id])

      metadata = Jason.decode!(metadata)
      assert metadata["query"] == @query
      assert metadata["query_owner_actor_id"] == @builder
      refute metadata["sections"]["summary"] =~ @query_marker
    end

    test "the request and pool of the stale package carry over only to its requester", ctx do
      {:ok, pool} =
        MemoryCore.open_active_pool(
          tenant_id: "default",
          workspace_id: ctx.workspace_id,
          task_type: "refresh_carry_#{System.unique_integer([:positive])}"
        )

      for {actor, inherits?} <- [{@builder, true}, {"agent:other", false}] do
        package =
          build_package!(ctx.workspace_id, ["public"], [], @builder, active_memory_pool_id: pool.id)

        make_stale!(ctx.workspace_id, ctx.rows)

        assert {:ok, refreshed} =
                 RetrievalCoordinator.refresh_context_package(package.id,
                   workspace_id: ctx.workspace_id,
                   actor_id: actor,
                   allowed_partitions: [],
                   allowed_security_labels: ["public"]
                 )

        assert refreshed.request_id == if(inherits?, do: "req-#{@builder}")
        assert refreshed.active_memory_pool_id == if(inherits?, do: pool.id)
      end
    end

    test "a reader that only covers a package does not replace it; its requester does", ctx do
      package = build_package!(ctx.workspace_id, ["public"], [])
      make_stale!(ctx.workspace_id, ctx.rows)

      assert {:ok, _own} =
               RetrievalCoordinator.refresh_context_package(package.id,
                 workspace_id: ctx.workspace_id,
                 actor_id: "agent:other",
                 allowed_partitions: [],
                 allowed_security_labels: ["public"]
               )

      assert_states([package], "stale")

      assert {:ok, _own} =
               RetrievalCoordinator.refresh_context_package(package.id,
                 workspace_id: ctx.workspace_id,
                 actor_id: @builder,
                 allowed_partitions: [],
                 allowed_security_labels: ["public"]
               )

      assert_states([package], "refreshed")
    end

    test "a receiver looks at no more stale packages than the scan limit", ctx do
      for _ <- 1..4, do: build_package!(ctx.workspace_id, ["public"], [])
      make_stale!(ctx.workspace_id, ctx.rows)

      receiver = [
        workspace_id: ctx.workspace_id,
        actor_id: "agent:other",
        allowed_partitions: [],
        allowed_security_labels: ["public"],
        batch_limit: 10
      ]

      assert {:ok, all} = RetrievalCoordinator.refresh_stale_context_packages(receiver)
      assert length(all.stale_context_package_ids) == 4

      make_stale!(ctx.workspace_id, ctx.rows)

      assert {:ok, bounded} =
               RetrievalCoordinator.refresh_stale_context_packages([scan_limit: 2] ++ receiver)

      assert length(bounded.stale_context_package_ids) == 2
    end

    test "a package the caller does not cover answers not_found whether or not it is stale",
         ctx do
      stale = build_package!(ctx.workspace_id, ["public", "internal"], [])
      make_stale!(ctx.workspace_id, ctx.rows)
      fresh = build_package!(ctx.workspace_id, ["public", "internal"], [])

      for package <- [stale, fresh] do
        assert {:error, :not_found} =
                 RetrievalCoordinator.refresh_context_package(package.id,
                   workspace_id: ctx.workspace_id,
                   actor_id: "agent:other",
                   allowed_partitions: [],
                   allowed_security_labels: ["public"]
                 )
      end

      assert {:error, :context_package_not_stale} =
               RetrievalCoordinator.refresh_context_package(fresh.id,
                 workspace_id: ctx.workspace_id,
                 actor_id: @builder,
                 allowed_partitions: [],
                 allowed_security_labels: ["public"]
               )
    end

    test "grants that are not lists fail closed", ctx do
      package = build_package!(ctx.workspace_id, ["public"], [])
      make_stale!(ctx.workspace_id, ctx.rows)

      assert {:error, :invalid_refresh_grants} =
               RetrievalCoordinator.refresh_context_package(package.id,
                 workspace_id: ctx.workspace_id,
                 actor_id: @builder,
                 allowed_security_labels: "restricted"
               )
    end

    test "a receiver is offered its own packages before the batch limit", ctx do
      for _ <- 1..3, do: build_package!(ctx.workspace_id, ["public", "internal"], [])
      mine = build_package!(ctx.workspace_id, ["public"], [], "agent:me")
      make_stale!(ctx.workspace_id, ctx.rows)

      assert {:ok, batch} =
               RetrievalCoordinator.refresh_stale_context_packages(
                 workspace_id: ctx.workspace_id,
                 batch_limit: 1,
                 actor_id: "agent:me",
                 allowed_partitions: [],
                 allowed_security_labels: []
               )

      assert batch.stale_context_package_ids == [mine.id]
      assert [_refreshed] = batch.refreshed_context_packages
    end
  end

  describe "a package whose recorded envelope cannot be read" do
    test "leaves the stale list as failed, and an invalidation does not revive it", ctx do
      package = build_package!(ctx.workspace_id, ["public"], [])
      make_stale!(ctx.workspace_id, ctx.rows)
      break_envelope!(package)

      assert {:ok, batch} =
               RetrievalCoordinator.refresh_stale_context_packages(workspace_id: ctx.workspace_id)

      assert batch.stale_context_package_ids == [package.id]
      assert [%{context_package_id: id, reason: :authorization_envelope_unreadable}] = batch.errors
      assert id == package.id
      assert_states([package], "failed")

      assert {:ok, again} =
               RetrievalCoordinator.refresh_stale_context_packages(workspace_id: ctx.workspace_id)

      assert again.stale_context_package_ids == []

      make_stale!(ctx.workspace_id, ctx.rows)
      assert_states([package], "failed")
    end

    test "is not refreshed, or marked failed, for a receiver that does not own it", ctx do
      package = build_package!(ctx.workspace_id, ["public"], [])
      make_stale!(ctx.workspace_id, ctx.rows)
      break_envelope!(package)

      assert {:error, :not_found} =
               RetrievalCoordinator.refresh_context_package(package.id,
                 workspace_id: ctx.workspace_id,
                 actor_id: "agent:other",
                 allowed_partitions: [],
                 allowed_security_labels: ["public"]
               )

      assert_states([package], "stale")
    end

    test "is refreshed for the requester, which needs no recorded envelope", ctx do
      package = build_package!(ctx.workspace_id, ["public"], [])
      make_stale!(ctx.workspace_id, ctx.rows)
      break_envelope!(package)

      assert {:ok, refreshed} =
               RetrievalCoordinator.refresh_context_package(package.id,
                 workspace_id: ctx.workspace_id,
                 actor_id: @builder,
                 allowed_partitions: [],
                 allowed_security_labels: ["public"]
               )

      assert returned_ids(refreshed) == ids_for(ctx.rows, ["open", "public"])
    end
  end

  describe "ContextRefreshScheduler" do
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
          summary: "Launch note memory #{tag}-marker.",
          lifecycle_state: "current"
        })

      :ok = MemoryCoreStore.insert_fact(fact)
      :ok = MemoryCoreStore.insert_memory_object(memory)
      {tag, MapSet.new([fact.id, memory.id])}
    end)
  end

  # Two packages that between them hold every tier, requested by `actor` and
  # then marked stale: one built under every label, one under a partition.
  defp build_packages!(workspace_id, rows, actor) do
    packages = [
      build_package!(workspace_id, ["public", "internal", "restricted"], [], actor),
      build_package!(workspace_id, ["public"], ["team-x"], actor)
    ]

    make_stale!(workspace_id, rows)
    packages
  end

  defp build_package!(workspace_id, labels, partitions, actor \\ @builder, extra \\ []) do
    {:ok, package} =
      RetrievalCoordinator.retrieve(
        @query,
        [
          workspace_id: workspace_id,
          actor_id: actor,
          request_id: "req-#{actor}",
          allowed_partitions: partitions,
          allowed_security_labels: labels
        ] ++ extra
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

  defp stale_ids(workspace_id) do
    {:ok, rows} =
      Store.raw_query(
        "SELECT id FROM context_packages WHERE workspace_id = ?1 AND refresh_state = 'stale' ORDER BY id",
        [workspace_id]
      )

    List.flatten(rows)
  end

  defp break_envelope!(package) do
    assert :ok =
             Store.raw_execute(
               "UPDATE context_packages SET authorization_envelope = '{}' WHERE id = ?1",
               [package.id]
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

  # {token, the principal the key acts as}
  defp mint_key!(scopes, metadata) do
    {:ok, %{key: token, id: id}} =
      ApiKey.mint(%{
        tenant_id: "default",
        name: "refresh grants #{System.unique_integer([:positive])}",
        scopes: scopes,
        workspace_scope: ["*"],
        metadata: metadata
      })

    {token, "api_key:" <> id}
  end

  # The actor an anonymous request acts as when its body names none.
  defp local_actor, do: OptimalEngine.API.Actor.local_operator()

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

  defp assert_states(packages, state) do
    for package <- packages do
      assert {:ok, [[^state]]} =
               Store.raw_query("SELECT refresh_state FROM context_packages WHERE id = ?1", [
                 package.id
               ])
    end
  end

  # Every package holds the ids and the text of exactly the tiers in `tags`.
  defp assert_within(packages, raw_body, rows, tags, count \\ 2) do
    assert length(packages) == count

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

  defp refresh_stale(workspace_id, token, extra \\ %{}) do
    with_auth_required(fn ->
      request(
        :post,
        "/api/memory-core/context-packages/refresh-stale",
        token,
        Map.merge(%{"workspace" => workspace_id, "batch_limit" => 10}, extra)
      )
    end)
  end

  defp refresh_context(pool_id, token, body \\ %{}) do
    with_auth_required(fn ->
      request(:post, "/api/memory-core/active-pools/#{pool_id}/refresh-context", token, body)
    end)
  end

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
