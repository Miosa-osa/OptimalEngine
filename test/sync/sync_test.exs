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

      on_exit(fn ->
        Application.delete_env(:optimal_engine, :http_mock)

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

    test "a relay peer pulls from <base>/pull and pushes to <base>/push, and repeating it changes nothing",
         ctx do
      remote_id = "relayed-#{ctx.n}"
      engine = Sync.engine_info() |> Map.put("replica_id", "rep_cloud")
      calls = :ets.new(:relay_calls, [:public, :bag])
      base = "https://api.example/api/v1/engines/e1/sync"

      Application.put_env(:optimal_engine, :http_mock, fn url, opts ->
        :ets.insert(calls, {opts[:method], url})
        assert {"authorization", "Bearer relay-key"} in opts[:headers]

        case opts[:method] do
          :get ->
            respond(200, %{
              "mutations" => [
                mutation(ctx, %{
                  "id" => "mut_relay_#{ctx.n}",
                  "device_id" => "rep_cloud",
                  "payload" => context_row(remote_id, "Through the relay", ctx.ws, ctx.tenant)
                })
              ],
              "cursor" => 7,
              "engine" => engine
            })

          :post ->
            respond(200, %{"applied" => length(opts[:body]["mutations"])})
        end
      end)

      assert {:ok, _} =
               Sync.add_peer(
                 ctx.tenant,
                 %{"workspace_id" => ctx.ws, "url" => "relay+" <> base, "api_key" => "relay-key"},
                 "u"
               )

      insert_context(ctx.tenant, ctx.ws, "offline-#{ctx.n}", "Written offline")

      [first] = Sync.run_all() |> Enum.filter(&(&1.workspace_id == ctx.ws))
      assert first.status == "active"
      assert {:ok, %{applied: 1}} = first.pull
      assert {:ok, %{sent: 1}} = first.push

      [second] = Sync.run_all() |> Enum.filter(&(&1.workspace_id == ctx.ws))
      assert {:ok, %{sent: 0}} = second.push

      urls = :ets.tab2list(calls)
      assert Enum.all?(urls, fn {_m, u} -> String.starts_with?(u, base) end)
      assert Enum.any?(urls, fn {m, u} -> m == :get and u =~ base <> "/pull?" end)
      assert Enum.any?(urls, fn {m, u} -> m == :post and u == base <> "/push" end)
      refute Enum.any?(urls, fn {_m, u} -> u =~ "/api/sync/changes" end)

      # Exactly once: the pulled context exists once, the offline one was sent once.
      assert {:ok, [[1]]} =
               Store.raw_query("SELECT count(*) FROM contexts WHERE id = ?1", [remote_id])
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
