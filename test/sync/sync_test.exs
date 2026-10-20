defmodule OptimalEngine.SyncTest do
  @moduledoc """
  Replication: capture in the write's transaction, ordered ledger, idempotent
  apply with no echo, conflicts (facts become claims), data-class gates,
  peers with version safety, and seeding marks.

  One test database stands in for two Engines, so "remote" changes are
  synthetic mutations from another device with their own ids.
  """

  use ExUnit.Case, async: false

  alias OptimalEngine.{Store, Sync, Workspace}
  alias OptimalEngine.Sync.Capture
  alias OptimalEngine.Tenancy.Tenant

  setup do
    n = System.unique_integer([:positive])
    tenant = "sync-#{n}"
    {:ok, _} = Tenant.create(%{id: tenant, name: "Sync #{n}"})

    {:ok, _} =
      OptimalEngine.Organization.create(%{
        id: "#{tenant}:org",
        tenant_id: tenant,
        slug: "org",
        name: "Org"
      })

    {:ok, ws} =
      Workspace.create(%{
        tenant_id: tenant,
        organization_id: "#{tenant}:org",
        slug: "notes",
        name: "Notes"
      })

    {:ok, _} = Sync.enable(tenant, ws.id, "user:owner")
    %{tenant: tenant, ws: ws.id, n: n}
  end

  defp insert_context(tenant, ws, id, title) do
    {:ok, _} =
      Store.raw_query(
        "INSERT INTO contexts (id, tenant_id, workspace_id, title, content, created_at) VALUES (?1, ?2, ?3, ?4, 'body', '2026-10-14T10:00:00Z')",
        [id, tenant, ws, title]
      )
  end

  defp mutation(ctx, attrs) do
    Map.merge(
      %{
        "id" => "mut_remote_#{System.unique_integer([:positive])}",
        "device_id" => "rep_remote",
        "entity_type" => "contexts",
        "operation" => "create",
        "occurred_at" => "2026-10-14T12:00:00.000"
      },
      attrs
    )
    |> then(fn m -> Map.put_new(m, "entity_id", get_in(m, ["payload", "row", "id"])) end)
    |> tap(fn _ -> ctx end)
  end

  defp context_row(id, title, ws, tenant) do
    %{
      "row" => %{
        "id" => id,
        "title" => title,
        "content" => "remote body",
        "workspace_id" => ws,
        "tenant_id" => tenant
      },
      "blobs" => %{}
    }
  end

  describe "capture" do
    test "creates, updates and deletes are captured in order with blobs, only for enabled workspaces",
         ctx do
      insert_context(ctx.tenant, ctx.ws, "c-#{ctx.n}", "First")

      {:ok, _} =
        Store.raw_query("UPDATE contexts SET title = 'Second' WHERE id = ?1", ["c-#{ctx.n}"])

      {:ok, memory} =
        OptimalEngine.Memory.create(%{
          content: "captured memory",
          workspace_id: ctx.ws,
          tenant_id: ctx.tenant
        })

      blob = :crypto.strong_rand_bytes(16)

      {:ok, _} =
        Store.raw_query(
          "INSERT INTO memory_embeddings (memory_id, tenant_id, workspace_id, model, dimensions, embedding, content_hash) VALUES (?1, ?2, ?3, 'm', 4, ?4, 'h')",
          [memory.id, ctx.tenant, ctx.ws, {:blob, blob}]
        )

      {:ok, _} = Store.raw_query("DELETE FROM contexts WHERE id = ?1", ["c-#{ctx.n}"])

      {:ok, other} =
        Workspace.create(%{
          tenant_id: ctx.tenant,
          organization_id: "#{ctx.tenant}:org",
          slug: "quiet",
          name: "Quiet"
        })

      insert_context(ctx.tenant, other.id, "q-#{ctx.n}", "Not synced")

      page = Sync.changes(ctx.tenant, ctx.ws)

      contexts =
        Enum.filter(
          page["mutations"],
          &(&1["entity_type"] == "contexts" and &1["entity_id"] == "c-#{ctx.n}")
        )

      assert Enum.map(contexts, & &1["operation"]) == ["create", "update", "delete"]
      assert Enum.at(contexts, 1)["payload"]["row"]["title"] == "Second"

      embedding = Enum.find(page["mutations"], &(&1["entity_type"] == "memory_embeddings"))
      assert Base.decode16!(embedding["payload"]["blobs"]["embedding"]) == blob
      assert Enum.all?(page["mutations"], &(&1["device_id"] == Sync.replica_id()))

      assert Sync.changes(ctx.tenant, other.id)["mutations"] == []
      assert page["engine"]["migration"] == Sync.engine_info()["migration"]

      later = Sync.changes(ctx.tenant, ctx.ws, since: page["cursor"])
      assert later["mutations"] == []
    end
  end

  describe "apply" do
    test "remote changes apply once, never echo, and a hub forwards them", ctx do
      id = "remote-#{ctx.n}"
      create = mutation(ctx, %{"payload" => context_row(id, "From laptop", ctx.ws, ctx.tenant)})

      update =
        mutation(ctx, %{
          "operation" => "update",
          "occurred_at" => "2026-10-14T12:05:00.000",
          "payload" => context_row(id, "Edited on laptop", ctx.ws, ctx.tenant)
        })

      assert {:ok, %{applied: 2}} = Sync.apply_changes(ctx.tenant, ctx.ws, [create, update])

      assert {:ok, [["Edited on laptop"]]} =
               Store.raw_query("SELECT title FROM contexts WHERE id = ?1", [id])

      assert {:ok, %{applied: 0, skipped: %{duplicate: 2}}} =
               Sync.apply_changes(ctx.tenant, ctx.ws, [create, update])

      assert {:ok, [[0]]} =
               Store.raw_query("SELECT COUNT(*) FROM sync_capture WHERE workspace_id = ?1", [ctx.ws])

      ids = fn requester ->
        Sync.changes(ctx.tenant, ctx.ws, requester: requester)["mutations"] |> Enum.map(& &1["id"])
      end

      refute create["id"] in ids.("rep_remote")
      assert create["id"] in ids.("rep_third")

      delete =
        mutation(ctx, %{
          "operation" => "delete",
          "entity_id" => id,
          "payload" => %{"row" => %{"id" => id}, "blobs" => %{}}
        })

      assert {:ok, %{applied: 1}} = Sync.apply_changes(ctx.tenant, ctx.ws, [delete])
      assert {:ok, []} = Store.raw_query("SELECT 1 FROM contexts WHERE id = ?1", [id])
    end

    test "gates, unknown tables and own changes are counted, failures recorded", ctx do
      own =
        mutation(ctx, %{
          "device_id" => Sync.replica_id(),
          "payload" => context_row("own-#{ctx.n}", "x", ctx.ws, ctx.tenant)
        })

      restricted =
        mutation(ctx, %{
          "entity_type" => "facts",
          "payload" => %{
            "row" => %{
              "id" => "f-#{ctx.n}",
              "fact_text" => "secret",
              "security_labels" => ~s(["restricted"])
            },
            "blobs" => %{}
          }
        })

      unknown =
        mutation(ctx, %{
          "entity_type" => "no_such_table",
          "entity_id" => "x",
          "payload" => %{"row" => %{"id" => "x"}}
        })

      assert {:ok, result} = Sync.apply_changes(ctx.tenant, ctx.ws, [own, restricted, unknown])
      assert result.skipped == %{own: 1, gated: 1}
      assert [%{reason: :unknown_table}] = result.failed
      assert [%{kind: "apply_failed", table: "no_such_table"}] = Sync.conflicts(ctx.tenant, ctx.ws)
    end

    test "concurrent edits: the newer wins, the conflict is recorded, facts become two claims",
         ctx do
      fact_id = "fact-#{ctx.n}"

      {:ok, _} =
        Store.raw_query(
          "INSERT INTO facts (id, tenant_id, workspace_id, fact_text) VALUES (?1, ?2, ?3, 'Launch is on Monday')",
          [fact_id, ctx.tenant, ctx.ws]
        )

      {:ok, _} =
        Store.raw_query("UPDATE facts SET fact_text = 'Launch is on Tuesday' WHERE id = ?1", [
          fact_id
        ])

      {:ok, _} = OptimalEngine.Sync.Capture.seal()

      older_remote =
        mutation(ctx, %{
          "entity_type" => "facts",
          "entity_id" => fact_id,
          "operation" => "update",
          "occurred_at" => "2000-01-01T00:00:00.000",
          "payload" => %{
            "row" => %{
              "id" => fact_id,
              "fact_text" => "Launch is on Friday",
              "workspace_id" => ctx.ws,
              "tenant_id" => ctx.tenant
            },
            "blobs" => %{}
          }
        })

      assert {:ok, %{conflicts: 1, applied: 0}} =
               Sync.apply_changes(ctx.tenant, ctx.ws, [older_remote])

      assert {:ok, [["Launch is on Tuesday"]]} =
               Store.raw_query("SELECT fact_text FROM facts WHERE id = ?1", [fact_id])

      assert [%{resolution: "kept_local_newer", table: "facts"} = conflict] =
               Sync.conflicts(ctx.tenant, ctx.ws)

      {:ok, claims} =
        Store.raw_query(
          "SELECT claim_text FROM claims WHERE workspace_id = ?1 AND json_extract(metadata, '$.sync_conflict') = 1 ORDER BY claim_text",
          [ctx.ws]
        )

      assert claims == [["Launch is on Friday"], ["Launch is on Tuesday"]]

      :ok = Sync.resolve_conflict(ctx.tenant, conflict.id, "user:owner")
      assert Sync.conflicts(ctx.tenant, ctx.ws) == []
    end

    test "an append-only row from the other Engine is always added, even when its row id is taken locally",
         ctx do
      :ok =
        OptimalEngine.Graph.assert_edge("LocalA-#{ctx.n}", "LocalB-#{ctx.n}", "knows",
          workspace_id: ctx.ws
        )

      {:ok, [[local_id]]} =
        Store.raw_query("SELECT MAX(id) FROM edges WHERE workspace_id = ?1", [ctx.ws])

      {:ok, _} = Capture.seal()

      # An append-only row is named by its capture sequence on the Engine that
      # wrote it, so the other Engine's unrelated edge can carry the same name.
      {:ok, [[local_key]]} =
        Store.raw_query(
          "SELECT entity_id FROM sync_mutations WHERE workspace_id = ?1 AND entity_type = 'edges' ORDER BY sequence DESC LIMIT 1",
          [ctx.ws]
        )

      remote =
        mutation(ctx, %{
          "entity_type" => "edges",
          "entity_id" => local_key,
          "occurred_at" => "2000-01-01T00:00:00.000",
          "payload" => %{
            "row" => %{
              "id" => local_id,
              "source_id" => "RemoteA-#{ctx.n}",
              "target_id" => "RemoteB-#{ctx.n}",
              "relation" => "knows",
              "workspace_id" => ctx.ws,
              "tenant_id" => ctx.tenant
            },
            "blobs" => %{}
          }
        })

      assert {:ok, %{applied: 1, conflicts: 0}} = Sync.apply_changes(ctx.tenant, ctx.ws, [remote])

      assert {:ok, [[2]]} =
               Store.raw_query("SELECT COUNT(*) FROM edges WHERE workspace_id = ?1", [ctx.ws])

      assert Sync.conflicts(ctx.tenant, ctx.ws) == []
    end

    test "the same row derived on both Engines is not a conflict when only bookkeeping times differ",
         ctx do
      fact_id = "fact-same-#{ctx.n}"

      {:ok, _} =
        Store.raw_query(
          "INSERT INTO facts (id, tenant_id, workspace_id, fact_text, transaction_time_start) VALUES (?1, ?2, ?3, 'Office opens at nine', '2026-10-19T10:00:00.100Z')",
          [fact_id, ctx.tenant, ctx.ws]
        )

      {:ok, _} = Capture.seal()

      same_but_for_time =
        mutation(ctx, %{
          "entity_type" => "facts",
          "entity_id" => fact_id,
          "operation" => "create",
          "occurred_at" => "2000-01-01T00:00:00.000",
          "payload" => %{
            "row" => %{
              "id" => fact_id,
              "fact_text" => "Office opens at nine",
              "transaction_time_start" => "2026-10-19T10:00:00.900Z",
              "workspace_id" => ctx.ws,
              "tenant_id" => ctx.tenant
            },
            "blobs" => %{}
          }
        })

      assert {:ok, %{conflicts: 0}} = Sync.apply_changes(ctx.tenant, ctx.ws, [same_but_for_time])
      assert Sync.conflicts(ctx.tenant, ctx.ws) == []

      # A real difference is still a conflict, and the newer local text stays.
      different =
        mutation(ctx, %{
          "entity_type" => "facts",
          "entity_id" => fact_id,
          "operation" => "update",
          "occurred_at" => "2000-01-01T00:00:00.000",
          "payload" => %{
            "row" => %{
              "id" => fact_id,
              "fact_text" => "Office opens at ten",
              "workspace_id" => ctx.ws,
              "tenant_id" => ctx.tenant
            },
            "blobs" => %{}
          }
        })

      assert {:ok, %{conflicts: 1}} = Sync.apply_changes(ctx.tenant, ctx.ws, [different])

      assert {:ok, [["Office opens at nine"]]} =
               Store.raw_query("SELECT fact_text FROM facts WHERE id = ?1", [fact_id])
    end

    test "a change planned twice before either apply commits is applied once", ctx do
      # Apply plans outside its transaction and checks the ledger again inside
      # it. A batch carrying the same change twice stands in for two concurrent
      # applies (POST /api/sync/run during a scheduler tick), both planned before
      # either committed. An append-only row would otherwise be added twice.
      title = "Ship on Friday #{ctx.n}"

      remote =
        mutation(ctx, %{
          "entity_type" => "decisions",
          "entity_id" => "decision-#{ctx.n}",
          "payload" => %{
            "row" => %{
              "id" => 1,
              "title" => title,
              "decision" => "ship",
              "workspace_id" => ctx.ws,
              "tenant_id" => ctx.tenant
            },
            "blobs" => %{}
          }
        })

      assert {:ok, %{applied: 1, skipped: %{duplicate: 1}}} =
               Sync.apply_changes(ctx.tenant, ctx.ws, [remote, remote])

      assert {:ok, [[1]]} =
               Store.raw_query(
                 "SELECT COUNT(*) FROM decisions WHERE workspace_id = ?1 AND title = ?2",
                 [ctx.ws, title]
               )
    end

    test "a workspace above the peer's gate is refused whole", ctx do
      {:ok, _} =
        Store.raw_query(
          "UPDATE workspaces SET metadata = '{\"data_class\":\"restricted\"}' WHERE id = ?1",
          [ctx.ws]
        )

      assert {:error, :workspace_class_above_gate} = Sync.apply_changes(ctx.tenant, ctx.ws, [])
    end
  end

  describe "peers" do
    setup do
      previous = System.get_env("CONNECTOR_KEY")
      System.put_env("CONNECTOR_KEY", Base.encode16(:crypto.strong_rand_bytes(32)))

      # The scheduler runs every peer on its own timer; held here so a tick
      # never interleaves with the cycles a test runs and counts.
      scheduler = Process.whereis(OptimalEngine.Sync.Scheduler)
      if scheduler, do: :sys.suspend(scheduler, 60_000)

      on_exit(fn ->
        if scheduler && Process.alive?(scheduler), do: :sys.resume(scheduler)
        Application.delete_env(:optimal_engine, :http_mock)
        Application.delete_env(:optimal_engine, :sync_cycle_budget_ms)

        if previous,
          do: System.put_env("CONNECTOR_KEY", previous),
          else: System.delete_env("CONNECTOR_KEY")
      end)
    end

    defp respond(status, body) do
      {:ok,
       {{~c"HTTP/1.1", status, ~c"OK"}, [{~c"content-type", ~c"application/json"}],
        Jason.encode!(body)}}
    end

    test "pull applies the peer's page, push sends local changes, gated rows stay home", ctx do
      remote_id = "pulled-#{ctx.n}"
      engine = Sync.engine_info() |> Map.put("replica_id", "rep_cloud")
      pushed = :ets.new(:pushed, [:public])

      Application.put_env(:optimal_engine, :http_mock, fn url, opts ->
        assert {"authorization", "Bearer replica-key"} in opts[:headers]

        case opts[:method] do
          :get ->
            respond(200, %{
              "mutations" => [
                mutation(ctx, %{
                  "device_id" => "rep_cloud",
                  "payload" => context_row(remote_id, "From cloud", ctx.ws, ctx.tenant)
                })
              ],
              "cursor" => 41,
              "engine" => engine
            })

          :post ->
            :ets.insert(pushed, {:body, opts[:body]})
            assert String.ends_with?(url, "/api/sync/changes")
            respond(200, %{"applied" => length(opts[:body]["mutations"])})
        end
      end)

      {:ok, _} =
        Sync.add_peer(
          ctx.tenant,
          %{"workspace_id" => ctx.ws, "url" => "https://cloud.example", "api_key" => "replica-key"},
          "u"
        )

      insert_context(ctx.tenant, ctx.ws, "local-#{ctx.n}", "From laptop")

      {:ok, _} =
        Store.raw_query(
          "INSERT INTO facts (id, tenant_id, workspace_id, fact_text, security_labels) VALUES (?1, ?2, ?3, 'Bank detail', '[\"restricted\"]')",
          ["restricted-#{ctx.n}", ctx.tenant, ctx.ws]
        )

      [result] = Sync.run_all() |> Enum.filter(&(&1.workspace_id == ctx.ws))
      assert result.status == "active"
      assert {:ok, %{applied: 1, cursor: 41}} = result.pull

      assert {:ok, [["From cloud"]]} =
               Store.raw_query("SELECT title FROM contexts WHERE id = ?1", [remote_id])

      [{:body, body}] = :ets.lookup(pushed, :body)
      sent = Enum.map(body["mutations"], & &1["entity_id"])
      assert "local-#{ctx.n}" in sent
      refute "restricted-#{ctx.n}" in sent
      refute remote_id in sent
      assert {:ok, %{gated: 1}} = result.push

      [peer] = Sync.status(ctx.tenant, ctx.ws).peers
      assert peer.last_pulled_seq == 41
      assert peer.pending_push == 0
    end

    test "a relay peer enables sync first, pages the pull, pushes to ?workspace= with its engine envelope, and a repeat cycle sends nothing",
         ctx do
      relay = fake_relay(ctx, cloud: cloud_ledger(ctx, 5))
      {:ok, _} = add_relay_peer(ctx, "relay-key", "both")
      insert_context(ctx.tenant, ctx.ws, "offline-a-#{ctx.n}", "Written offline")
      insert_context(ctx.tenant, ctx.ws, "offline-b-#{ctx.n}", "Written offline")

      [first] = run_peers(ctx)
      assert first.status == "active"
      assert {:ok, %{applied: 5, cursor: 5, pages: 3}} = first.pull
      assert {:ok, %{sent: 2}} = first.push

      # Status before anything moves, enable because status said it was off,
      # then the pull loops on `more` from each cursor, then one push.
      assert routes(relay) == [
               {:get, "status"},
               {:post, "enable"},
               {:get, "pull"},
               {:get, "pull"},
               {:get, "pull"},
               {:post, "push"}
             ]

      assert for({:get, "pull", query} <- calls(relay), do: query["since"]) == ["0", "2", "4"]

      # Exactly once on each side: two changes delivered once each, five applied.
      assert relay |> received() |> Map.values() == [1, 1]
      assert relayed(ctx) == 5

      # The relay does not forward x-optimal-replica, so the cloud's next page
      # carries the laptop's own changes back: they are skipped, not applied,
      # and nothing new is pushed.
      [second] = run_peers(ctx)
      assert second.status == "active"
      assert {:ok, %{applied: 0, skipped: %{own: 2}}} = second.pull
      assert {:ok, %{sent: 0}} = second.push
      assert Enum.drop(routes(relay), 6) == [{:get, "status"}, {:get, "pull"}]

      [peer] = Sync.status(ctx.tenant, ctx.ws).peers
      assert peer.peer_replica_id == "rep_cloud"
      assert peer.last_pulled_seq == 7
      assert peer.pending_push == 0
    end

    test "a relay on another schema version pauses the peer before anything moves", ctx do
      relay = fake_relay(ctx, status_migration: Sync.engine_info()["migration"] + 1)
      {:ok, _} = add_relay_peer(ctx, "relay-key", "both")
      insert_context(ctx.tenant, ctx.ws, "held-#{ctx.n}", "Not sent")

      [result] = run_peers(ctx)
      assert result.status == "paused_version"
      assert routes(relay) == [{:get, "status"}]

      [peer] = Sync.status(ctx.tenant, ctx.ws).peers
      assert peer.message =~ "same Engine version"
      assert peer.pending_push == 1
    end

    test "a relay status without the other Engine's migration pauses the peer before anything moves",
         ctx do
      insert_context(ctx.tenant, ctx.ws, "held-#{ctx.n}", "Not sent")

      for reported <- [:omit, nil] do
        relay = fake_relay(ctx, status_migration: reported)
        {:ok, _} = add_relay_peer(ctx, "relay-key", "both")

        [result] = run_peers(ctx)
        assert result.status == "paused_version"
        assert routes(relay) == [{:get, "status"}]

        [peer] = Sync.peers(ctx.tenant, ctx.ws)
        assert peer.status == "paused_version"
        assert peer.message =~ "did not report the other Engine's schema version"
      end

      assert [%{pending_push: 1}] = Sync.status(ctx.tenant, ctx.ws).peers
    end

    test "a push the relay refuses with VERSION_MISMATCH pauses the peer and keeps the cursor",
         ctx do
      # Status matched, then the other Engine moved to another migration before
      # the push: the refused push is where the mismatch shows.
      relay =
        fake_relay(ctx,
          migration: Sync.engine_info()["migration"] + 1,
          status_migration: Sync.engine_info()["migration"]
        )

      {:ok, _} = add_relay_peer(ctx, "relay-key", "push")
      insert_context(ctx.tenant, ctx.ws, "held-#{ctx.n}", "Not applied")

      [result] = run_peers(ctx)
      assert result.status == "paused_version"
      assert {:error, {:version_mismatch, message}} = result.push
      assert message =~ "same Engine version"
      assert routes(relay) == [{:get, "status"}, {:post, "enable"}, {:post, "push"}]

      [peer] = Sync.status(ctx.tenant, ctx.ws).peers
      assert peer.status == "paused_version"
      assert peer.pending_push == 1
    end

    test "a page whose rows all stay home advances the cursor without an empty push", ctx do
      relay = fake_relay(ctx, [])
      {:ok, _} = add_relay_peer(ctx, "relay-key", "push")

      {:ok, _} =
        Store.raw_query(
          "INSERT INTO facts (id, tenant_id, workspace_id, fact_text, security_labels) VALUES (?1, ?2, ?3, 'Bank detail', '[\"restricted\"]')",
          ["restricted-#{ctx.n}", ctx.tenant, ctx.ws]
        )

      [result] = run_peers(ctx)
      assert result.status == "active"
      assert {:ok, %{sent: 0, gated: 1}} = result.push
      refute {:post, "push"} in routes(relay)

      [peer] = Sync.status(ctx.tenant, ctx.ws).peers
      assert peer.pending_push == 0
    end

    test "a relay refusal is kept on the peer with its reason and never the key", ctx do
      relay = fake_relay(ctx, [])
      {:ok, _} = add_relay_peer(ctx, "key-without-sync-scope", "both")

      [result] = run_peers(ctx)
      assert result.status == "error"
      assert routes(relay) == [{:get, "status"}]

      # The fake's 403 echoes the Authorization header it was sent.
      [peer] = Sync.peers(ctx.tenant, ctx.ws)
      assert peer.message =~ "403"
      assert peer.message =~ "engine:sync"
      assert peer.message =~ "[redacted]"
      refute peer.message =~ "key-without-sync-scope"
      refute inspect(result) =~ "key-without-sync-scope"
    end

    test "a key-shaped value a relay echoes in an error is neither kept nor returned", ctx do
      prefixed = "msk_u_" <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
      opaque = Base.encode16(:crypto.strong_rand_bytes(24), case: :lower)

      fake_relay(ctx,
        status_error:
          {422, "ENVIRONMENT_NOT_FOUND", "no environment named #{prefixed} or #{opaque}"}
      )

      {:ok, _} = add_relay_peer(ctx, "relay-key", "both")

      [result] = run_peers(ctx)
      assert result.status == "error"

      [peer] = Sync.peers(ctx.tenant, ctx.ws)
      assert peer.message =~ "422"
      assert peer.message =~ "no environment named [redacted] or [redacted]"

      for secret <- [prefixed, opaque] do
        refute peer.message =~ secret
        refute inspect(result) =~ secret
      end
    end

    test "a push whose acknowledgement is lost is sent again, applied once, then passed", ctx do
      # The relay applies the page, then its answer is lost (a timeout, then a
      # 502): the push cursor stays and the next cycle sends the page again.
      relay = fake_relay(ctx, lost_acks: [:timeout, 502])
      {:ok, _} = add_relay_peer(ctx, "relay-key", "push")
      insert_context(ctx.tenant, ctx.ws, "acked-a-#{ctx.n}", "Written offline")
      insert_context(ctx.tenant, ctx.ws, "acked-b-#{ctx.n}", "Written offline")

      [first] = run_peers(ctx)
      assert first.status == "error"
      assert {:error, :timeout} = first.push

      [second] = run_peers(ctx)
      assert second.status == "error"
      assert {:error, {:http_status, 502, _}} = second.push
      assert [%{pending_push: 2}] = Sync.status(ctx.tenant, ctx.ws).peers

      [third] = run_peers(ctx)
      assert third.status == "active"

      assert {:ok, %{sent: 2, applied: 0, remote: %{"skipped" => %{"duplicate" => 2}}}} =
               third.push

      assert routes(relay) == [
               {:get, "status"},
               {:post, "enable"},
               {:post, "push"},
               {:get, "status"},
               {:post, "push"},
               {:get, "status"},
               {:post, "push"}
             ]

      # Delivered three times, held once.
      assert relay |> received() |> Map.values() == [3, 3]
      local = Sync.replica_id()
      held = for %{"device_id" => ^local} = m <- cloud(relay), do: m["idempotency_key"]
      assert length(held) == 2
      assert held == Enum.uniq(held)
      assert [%{pending_push: 0}] = Sync.status(ctx.tenant, ctx.ws).peers
    end

    test "a pull that fails on its second page keeps the first page's cursor and resumes there",
         ctx do
      relay = fake_relay(ctx, cloud: cloud_ledger(ctx, 5), failed_pulls: ["2"])
      {:ok, _} = add_relay_peer(ctx, "relay-key", "pull")

      [first] = run_peers(ctx)
      assert first.status == "error"
      assert {:error, {:http_status, 502, _}} = first.pull
      assert [%{last_pulled_seq: 2, message: message}] = Sync.peers(ctx.tenant, ctx.ws)
      assert message =~ "502"
      assert relayed(ctx) == 2

      [second] = run_peers(ctx)
      assert second.status == "active"
      assert {:ok, %{applied: 3, cursor: 5, skipped: skipped}} = second.pull
      assert skipped == %{}
      assert for({:get, "pull", query} <- calls(relay), do: query["since"]) == ["0", "2", "2", "4"]
      assert relayed(ctx) == 5
      assert [%{last_pulled_seq: 5}] = Sync.peers(ctx.tenant, ctx.ws)
    end

    test "a page the relay finds too large is sent again as pages half its size", ctx do
      relay = fake_relay(ctx, max_batch: 1)
      {:ok, _} = add_relay_peer(ctx, "relay-key", "push")
      insert_context(ctx.tenant, ctx.ws, "large-a-#{ctx.n}", "Written offline")
      insert_context(ctx.tenant, ctx.ws, "large-b-#{ctx.n}", "Written offline")

      [result] = run_peers(ctx)
      assert result.status == "active"
      assert {:ok, %{sent: 2, applied: 2, pages: 2}} = result.push

      assert routes(relay) == [
               {:get, "status"},
               {:post, "enable"},
               {:post, "push"},
               {:post, "push"},
               {:post, "push"}
             ]

      assert relay |> received() |> Map.values() == [1, 1]
      assert [%{pending_push: 0}] = Sync.status(ctx.tenant, ctx.ws).peers
    end

    test "only an answer that says what it applied passes a page, whatever its 2xx status",
         ctx do
      fake_relay(ctx, push_answer: {200, %{"accepted" => true}})
      {:ok, _} = add_relay_peer(ctx, "relay-key", "push")
      insert_context(ctx.tenant, ctx.ws, "acknowledged-#{ctx.n}", "Written offline")

      [first] = run_peers(ctx)
      assert first.status == "error"
      assert {:error, {:push_not_acknowledged, ["accepted"]}} = first.push
      assert [%{pending_push: 1}] = Sync.status(ctx.tenant, ctx.ws).peers

      fake_relay(ctx, push_answer: {202, :ack})

      [second] = run_peers(ctx)
      assert second.status == "active"
      assert {:ok, %{sent: 1, applied: 1}} = second.push
      assert [%{pending_push: 0}] = Sync.status(ctx.tenant, ctx.ws).peers
    end

    test "paging stops when the cycle's time budget is spent and resumes on the next cycle",
         ctx do
      Application.put_env(:optimal_engine, :sync_cycle_budget_ms, 0)
      relay = fake_relay(ctx, cloud: cloud_ledger(ctx, 5), max_batch: 1)
      {:ok, _} = add_relay_peer(ctx, "relay-key", "both")
      insert_context(ctx.tenant, ctx.ws, "budget-a-#{ctx.n}", "Written offline")
      insert_context(ctx.tenant, ctx.ws, "budget-b-#{ctx.n}", "Written offline")

      # One page each way a cycle once the budget is spent.
      [first] = run_peers(ctx)
      assert first.status == "active"
      assert {:ok, %{pages: 1, cursor: 2, more: true}} = first.pull
      assert {:ok, %{sent: 1, pages: 1}} = first.push

      [second] = run_peers(ctx)
      assert second.status == "active"
      assert {:ok, %{pages: 1, cursor: 4, more: true}} = second.pull
      assert {:ok, %{sent: 1, pages: 1}} = second.push

      assert for({:get, "pull", query} <- calls(relay), do: query["since"]) == ["0", "2"]
      assert relay |> received() |> Map.values() == [1, 1]
      assert [%{pending_push: 0}] = Sync.status(ctx.tenant, ctx.ws).peers
    end

    test "the fake relay refuses a push that is not this Engine's own, and counts every delivery",
         ctx do
      relay = fake_relay(ctx, [])
      assert {200, _} = relay_call(ctx, :post, "enable", %{})

      change =
        mutation(ctx, %{
          "sequence" => 1,
          "payload_hash" => "h",
          "idempotency_key" => "key-#{ctx.n}",
          "payload" => context_row("contract-#{ctx.n}", "x", ctx.ws, ctx.tenant)
        })

      push = %{
        "workspace" => ctx.ws,
        "replica_id" => Sync.replica_id(),
        "engine" => Sync.engine_info(),
        "mutations" => [change]
      }

      for {code, body} <- [
            {"WORKSPACE_MISMATCH", Map.put(push, "workspace", "another")},
            {"NOT_THE_SENDER", Map.put(push, "replica_id", "rep_other")},
            {"NOT_THE_SENDER", put_in(push, ["engine", "replica_id"], "rep_cloud")},
            {"CURSOR_NOT_ALLOWED", Map.put(push, "cursor", 7)},
            {"CURSOR_NOT_ALLOWED", Map.put(push, "since", 7)}
          ] do
        assert {422, %{"error" => %{"code" => ^code}}} = relay_call(ctx, :post, "push", body)
      end

      assert received(relay) == %{}

      assert {200, %{"data" => %{"applied" => 1}}} = relay_call(ctx, :post, "push", push)

      assert {200, %{"data" => %{"applied" => 0, "skipped" => %{"duplicate" => 1}}}} =
               relay_call(ctx, :post, "push", push)

      assert received(relay) == %{"key-#{ctx.n}" => 2}
    end

    test "a relay url must still be http(s)", ctx do
      assert {:error, :invalid_url} =
               Sync.add_peer(
                 ctx.tenant,
                 %{"workspace_id" => ctx.ws, "url" => "relay+ftp://x", "api_key" => "k"},
                 "u"
               )
    end

    test "a peer on another schema version pauses sync with a message", ctx do
      Application.put_env(:optimal_engine, :http_mock, fn _url, _opts ->
        respond(200, %{
          "mutations" => [],
          "cursor" => 0,
          "engine" => %{"replica_id" => "rep_old", "migration" => 1}
        })
      end)

      {:ok, _} =
        Sync.add_peer(
          ctx.tenant,
          %{
            "workspace_id" => ctx.ws,
            "url" => "https://old.example",
            "api_key" => "k",
            "policy" => "pull"
          },
          "u"
        )

      [result] = Sync.run_all() |> Enum.filter(&(&1.workspace_id == ctx.ws))
      assert result.status == "paused_version"
      [peer] = Sync.peers(ctx.tenant, ctx.ws)
      assert peer.message =~ "same Engine version"
    end
  end

  # -- a fake MIOSA relay -------------------------------------------------------
  #
  # It enforces the contract the live relay speaks: a bearer key with the
  # engine:sync scope (403 naming it otherwise, and echoing the Authorization
  # header it was sent), routes
  # `/api/v1/engines/<id>/sync/{status,enable,pull,push}?workspace=`, success
  # wrapped in {"data": ...}, refusals as {"error": {"code", "message"}}, push
  # refused while sync is off or the sender's engine envelope is missing or on
  # another migration, a push only from this Engine (the body's workspace is
  # the query's, `replica_id` and `engine.replica_id` are this Engine's) with no
  # cursor, a non-empty mutation list in the full ledger shape, idempotency by
  # idempotency_key (every delivery is counted), and no x-optimal-replica
  # forwarding (pushed changes come back on the next pull). Pages are capped at
  # two rows whatever limit the client asks for, so a client that ignores
  # `more` falls behind.
  #
  # Options: `:cloud` (ledger mutations), `:migration` (the cloud's, checked on
  # push), `:status_migration` (what status reports; `:omit` for none),
  # `:status_error` ({status, code, message} status answers instead),
  # `:lost_acks` (answers given instead of the acknowledgement of a push it
  # applied, one per push: `:timeout` or an HTTP status), `:failed_pulls`
  # (`since` values whose pull fails once with a 502), `:max_batch` (a larger
  # push is refused with 413), `:push_answer` ({status, data} acknowledges a
  # push instead, `:ack` for the usual answer).

  @contract_keys ~w(sequence id device_id entity_type entity_id operation payload payload_hash
                    idempotency_key occurred_at)

  defp fake_relay(ctx, opts) do
    state = :ets.new(:fake_relay, [:public])
    migration = opts[:migration] || Sync.engine_info()["migration"]

    :ets.insert(state,
      enabled: false,
      calls: [],
      received: %{},
      cloud: opts[:cloud] || [],
      lost_acks: opts[:lost_acks] || [],
      failed_pulls: opts[:failed_pulls] || []
    )

    config = %{
      engine: %{"replica_id" => "rep_cloud", "migration" => migration, "version" => "0.0.0"},
      sender: Sync.replica_id(),
      status_migration: Keyword.get(opts, :status_migration, migration),
      status_error: opts[:status_error],
      max_batch: opts[:max_batch],
      push_answer: opts[:push_answer]
    }

    prefix = "/api/v1/engines/e1/sync/"

    Application.put_env(:optimal_engine, :http_mock, fn url, req ->
      uri = URI.parse(url)
      query = URI.decode_query(uri.query || "")
      route = String.replace_prefix(uri.path, prefix, "")
      {_, authorization} = List.keyfind(req[:headers], "authorization", 0, {nil, ""})

      # Peers left by earlier tests run too; only this test's are counted.
      if query["workspace"] == ctx.ws,
        do: update(state, :calls, &(&1 ++ [{req[:method], route, query}]))

      cond do
        authorization != "Bearer relay-key" ->
          refuse(403, "FORBIDDEN", "this key lacks the engine:sync scope (sent: #{authorization})")

        not String.starts_with?(uri.path, prefix) ->
          refuse(404, "NOT_FOUND", nil)

        query["workspace"] != ctx.ws ->
          refuse(400, "WORKSPACE_REQUIRED", nil)

        true ->
          relay_route(state, ctx, {req[:method], route}, query, req[:body], config)
      end
    end)

    state
  end

  defp relay_route(state, ctx, {:get, "status"}, _query, _body, config) do
    data = %{
      "workspace_id" => ctx.ws,
      "enabled" => lookup(state, :enabled),
      "replica_id" => "rep_cloud",
      "ledger_sequence" => length(lookup(state, :cloud)),
      "open_conflicts" => 0,
      "append_only_tables" => [],
      "peers" => [],
      "version" => "0.0.0"
    }

    case {config.status_error, config.status_migration} do
      {{status, code, message}, _} -> refuse(status, code, message)
      {nil, :omit} -> ok(data)
      {nil, migration} -> ok(Map.put(data, "migration", migration))
    end
  end

  defp relay_route(state, ctx, {:post, "enable"}, _query, body, _config) do
    if body == %{} do
      :ets.insert(state, enabled: true)

      ok(%{
        "workspace_id" => ctx.ws,
        "replica_id" => "rep_cloud",
        "ledger_sequence" => length(lookup(state, :cloud)),
        "triggers" => %{"tables" => 3, "skipped" => []}
      })
    else
      refuse(422, "INVALID", "enable takes an empty body")
    end
  end

  defp relay_route(state, ctx, {:get, "pull"}, query, _body, config) do
    since = String.to_integer(query["since"] || "0")
    limit = String.to_integer(query["limit"] || "500")

    cond do
      not lookup(state, :enabled) ->
        refuse(409, "SYNC_NOT_ENABLED", "sync_not_enabled")

      query["since"] in lookup(state, :failed_pulls) ->
        update(state, :failed_pulls, &List.delete(&1, query["since"]))
        refuse(502, "ENGINE_UNAVAILABLE", nil)

      limit not in 1..2_000 ->
        refuse(422, "INVALID", "limit must be 1..2000")

      true ->
        after_since = Enum.filter(lookup(state, :cloud), &(&1["sequence"] > since))
        page = Enum.take(after_since, min(limit, 2))
        cursor = if page == [], do: since, else: List.last(page)["sequence"]

        ok(%{
          "workspace_id" => ctx.ws,
          "mutations" => page,
          "cursor" => cursor,
          "more" => length(after_since) > length(page),
          "engine" => config.engine
        })
    end
  end

  defp relay_route(state, _ctx, {:post, "push"}, query, body, config) do
    sender = body["engine"]
    mutations = body["mutations"]

    cond do
      not lookup(state, :enabled) ->
        refuse(409, "SYNC_NOT_ENABLED", "sync_not_enabled")

      not (is_map(sender) and Enum.all?(~w(replica_id migration version), &Map.has_key?(sender, &1))) ->
        refuse(409, "VERSION_MISMATCH", "peer did not report its schema version")

      sender["migration"] != config.engine["migration"] ->
        refuse(
          409,
          "VERSION_MISMATCH",
          "peer #{sender["replica_id"]} runs schema #{sender["migration"]}, this Engine runs #{config.engine["migration"]}; sync pauses until both run the same Engine version"
        )

      body["workspace"] != query["workspace"] ->
        refuse(422, "WORKSPACE_MISMATCH", "the body names another workspace than ?workspace=")

      body["replica_id"] != config.sender or sender["replica_id"] != config.sender ->
        refuse(422, "NOT_THE_SENDER", "replica_id and engine.replica_id name the sending Engine")

      Enum.any?(~w(cursor since), &Map.has_key?(body, &1)) ->
        refuse(422, "CURSOR_NOT_ALLOWED", "a push carries no cursor")

      not (is_list(mutations) and mutations != []) ->
        refuse(422, "MUTATIONS_REQUIRED", "mutations_required")

      not Enum.all?(mutations, fn m -> Enum.all?(@contract_keys, &Map.has_key?(m, &1)) end) ->
        refuse(422, "INVALID", "a mutation is missing a contract field")

      config.max_batch && length(mutations) > config.max_batch ->
        refuse(413, "PAYLOAD_TOO_LARGE", "at most #{config.max_batch} mutations a push")

      true ->
        deliver(state, mutations, config)
    end
  end

  defp relay_route(_state, _ctx, _route, _query, _body, _config), do: refuse(404, "NOT_FOUND", nil)

  # Applies a push once per idempotency key, counts every delivery, then
  # acknowledges it, unless the acknowledgement is to be lost.
  defp deliver(state, mutations, config) do
    received = lookup(state, :received)

    {fresh, duplicates} =
      Enum.split_with(mutations, &(not Map.has_key?(received, &1["idempotency_key"])))

    update(state, :received, fn seen ->
      Enum.reduce(mutations, seen, fn m, acc ->
        Map.update(acc, m["idempotency_key"], 1, &(&1 + 1))
      end)
    end)

    update(state, :cloud, fn cloud ->
      Enum.reduce(fresh, cloud, &(&2 ++ [Map.put(&1, "sequence", length(&2) + 1)]))
    end)

    ack = %{
      "applied" => length(fresh),
      "conflicts" => 0,
      "failed" => [],
      "skipped" => %{"duplicate" => length(duplicates)},
      "engine" => config.engine
    }

    case {lookup(state, :lost_acks), config.push_answer} do
      {[:timeout | rest], _} ->
        :ets.insert(state, lost_acks: rest)
        {:error, :timeout}

      {[status | rest], _} ->
        :ets.insert(state, lost_acks: rest)
        refuse(status, "ENGINE_UNAVAILABLE", nil)

      {[], {status, :ack}} ->
        respond(status, %{"data" => ack})

      {[], {status, data}} ->
        respond(status, %{"data" => data})

      {[], nil} ->
        ok(ack)
    end
  end

  defp ok(data), do: respond(200, %{"data" => data})

  defp refuse(status, code, nil), do: respond(status, %{"error" => %{"code" => code}})

  defp refuse(status, code, message),
    do: respond(status, %{"error" => %{"code" => code, "message" => message}})

  defp lookup(state, key), do: :ets.lookup_element(state, key, 2)
  defp update(state, key, fun), do: :ets.insert(state, {key, fun.(lookup(state, key))})

  defp calls(state), do: lookup(state, :calls)
  defp routes(state), do: Enum.map(calls(state), fn {method, route, _query} -> {method, route} end)
  defp received(state), do: lookup(state, :received)
  defp cloud(state), do: lookup(state, :cloud)

  # Calls the fake relay as a client would, past the Engine's client.
  defp relay_call(ctx, method, route, body) do
    url =
      "https://api.example/api/v1/engines/e1/sync/#{route}?" <>
        URI.encode_query(%{"workspace" => ctx.ws})

    mock = Application.get_env(:optimal_engine, :http_mock)
    headers = [{"authorization", "Bearer relay-key"}]
    {:ok, {{_, status, _}, _, raw}} = mock.(url, method: method, headers: headers, body: body)
    {status, Jason.decode!(raw)}
  end

  # The cloud's ledger: `count` contexts written on the cloud Engine.
  defp cloud_ledger(ctx, count) do
    for seq <- 1..count do
      mutation(ctx, %{
        "sequence" => seq,
        "id" => "mut_cloud_#{ctx.n}_#{seq}",
        "device_id" => "rep_cloud",
        "payload" => context_row("relayed-#{ctx.n}-#{seq}", "From cloud", ctx.ws, ctx.tenant)
      })
    end
  end

  defp relayed(ctx) do
    {:ok, [[count]]} =
      Store.raw_query("SELECT count(*) FROM contexts WHERE id LIKE ?1", ["relayed-#{ctx.n}-%"])

    count
  end

  defp add_relay_peer(ctx, key, policy) do
    Sync.add_peer(
      ctx.tenant,
      %{
        "workspace_id" => ctx.ws,
        "url" => "relay+https://api.example/api/v1/engines/e1/sync",
        "api_key" => key,
        "policy" => policy
      },
      "u"
    )
  end

  defp run_peers(ctx), do: Sync.run_all() |> Enum.filter(&(&1.workspace_id == ctx.ws))

  test "bundles carry the ledger mark a seeded replica pulls from", ctx do
    insert_context(ctx.tenant, ctx.ws, "seed-#{ctx.n}", "Seeded")
    {:ok, _} = Capture.seal()
    path = Path.join(System.tmp_dir!(), "seed-#{ctx.n}.tar.gz")
    {:ok, manifest} = OptimalEngine.Portability.WorkspaceBundle.export(ctx.tenant, ctx.ws, path)
    assert manifest["ledger_sequence"] > 0
    refute Enum.any?(manifest["tables"], &(&1["name"] in ["sync_mutations", "sync_capture"]))
    File.rm(path)
  end
end
