defmodule OptimalEngine.SyncTest do
  @moduledoc """
  Replication: capture in the write's transaction, ordered ledger, idempotent
  apply with no echo, conflicts (facts become claims), data-class gates,
  peers with version safety, and seeding marks.

  One test database stands in for two Engines, so "remote" changes are
  synthetic mutations from another device with their own ids.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias OptimalEngine.{Store, Sync, Workspace}
  alias OptimalEngine.Portability.WorkspaceBundle
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

  # The sequence of this Engine's latest change to a row, after sealing.
  defp local_seq(ctx, table, id) do
    {:ok, _} = Capture.seal()

    {:ok, [[sequence]]} =
      Store.raw_query(
        """
        SELECT MAX(sequence) FROM sync_mutations
        WHERE workspace_id = ?1 AND entity_type = ?2 AND entity_id = ?3 AND device_id = ?4
        """,
        [ctx.ws, table, id, Sync.replica_id()]
      )

    sequence
  end

  defp title(id) do
    {:ok, [[title]]} = Store.raw_query("SELECT title FROM contexts WHERE id = ?1", [id])
    title
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

    test "the job queue stays on its Engine: not captured, not applied, old triggers dropped",
         ctx do
      # An Engine before the queue was excluded had capture triggers on it.
      :ok =
        Store.raw_execute(
          "CREATE TRIGGER IF NOT EXISTS sync_capture_jobs_legacy AFTER INSERT ON jobs BEGIN SELECT 1; END",
          []
        )

      {:ok, _} = Capture.install()

      assert {:ok, []} =
               Store.raw_query(
                 "SELECT name FROM sqlite_master WHERE type = 'trigger' AND tbl_name = 'jobs' AND name LIKE 'sync_capture_%'",
                 []
               )

      # Both Engines enqueue the same daily job under the same key, each with
      # its own id.
      key = "analysis:daily:#{ctx.n}"
      {:ok, _job} = OptimalEngine.Jobs.enqueue(ctx.ws, "sync.test", %{}, idempotency_key: key)

      refute Enum.any?(
               Sync.changes(ctx.tenant, ctx.ws)["mutations"],
               &(&1["entity_type"] in ["jobs", "dead_letter_jobs"])
             )

      remote =
        mutation(ctx, %{
          "entity_type" => "jobs",
          "entity_id" => "job_remote_#{ctx.n}",
          "payload" => %{
            "row" => %{
              "id" => "job_remote_#{ctx.n}",
              "kind" => "sync.test",
              "idempotency_key" => key,
              "workspace_id" => ctx.ws,
              "tenant_id" => ctx.tenant
            },
            "blobs" => %{}
          }
        })

      assert {:ok, %{applied: 0, failed: [], skipped: %{local_only: 1}}} =
               Sync.apply_changes(ctx.tenant, ctx.ws, [remote])

      assert {:ok, []} = Store.raw_query("SELECT 1 FROM jobs WHERE id = ?1", [remote["entity_id"]])
      assert Sync.conflicts(ctx.tenant, ctx.ws) == []
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

      # The sender had pulled nothing from this Engine (base 0).
      assert {:ok, %{conflicts: 1, applied: 0}} =
               Sync.apply_changes(ctx.tenant, ctx.ws, [older_remote], base_seq: 0)

      assert {:ok, [["Launch is on Tuesday"]]} =
               Store.raw_query("SELECT fact_text FROM facts WHERE id = ?1", [fact_id])

      assert [
               %{resolution: "kept_local_newer", table: "facts", kind: "fact_divergence"} =
                 conflict
             ] = Sync.conflicts(ctx.tenant, ctx.ws)

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
        Store.raw_query("SELECT MAX(id) FROM graph_edges WHERE workspace_id = ?1", [ctx.ws])

      {:ok, _} = Capture.seal()

      # An append-only row is named by its capture sequence on the Engine that
      # wrote it, so the other Engine's unrelated edge can carry the same name.
      {:ok, [[local_key]]} =
        Store.raw_query(
          "SELECT entity_id FROM sync_mutations WHERE workspace_id = ?1 AND entity_type = 'graph_edges' ORDER BY sequence DESC LIMIT 1",
          [ctx.ws]
        )

      remote =
        mutation(ctx, %{
          "entity_type" => "graph_edges",
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
               Store.raw_query("SELECT COUNT(*) FROM graph_edges WHERE workspace_id = ?1", [ctx.ws])

      assert Sync.conflicts(ctx.tenant, ctx.ws) == []
    end

    test "an edge sealed before the upgrade as an edges row is applied to graph_edges", ctx do
      remote =
        mutation(ctx, %{
          "entity_type" => "edges",
          "entity_id" => "rep_remote:#{ctx.n}",
          "payload" => %{
            "row" => %{
              "id" => 1,
              "source_id" => "OldA-#{ctx.n}",
              "target_id" => "OldB-#{ctx.n}",
              "relation" => "knows",
              "workspace_id" => ctx.ws,
              "tenant_id" => "default"
            },
            "blobs" => %{}
          }
        })

      assert {:ok, %{applied: 1, failed: []}} = Sync.apply_changes(ctx.tenant, ctx.ws, [remote])

      assert {:ok, [[tenant]]} =
               Store.raw_query(
                 "SELECT tenant_id FROM graph_edges WHERE workspace_id = ?1 AND source_id = ?2",
                 [ctx.ws, "OldA-#{ctx.n}"]
               )

      assert tenant == ctx.tenant
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

    test "the receiver's own earlier change is no conflict when the sender's base covers it",
         ctx do
      id = "seen-#{ctx.n}"
      insert_context(ctx.tenant, ctx.ws, id, "Written here before the sender pulled")
      seen = local_seq(ctx, "contexts", id)

      edit =
        mutation(ctx, %{
          "operation" => "update",
          "occurred_at" => "2999-01-01T00:00:00.000",
          "payload" => context_row(id, "Edited after pulling it", ctx.ws, ctx.tenant)
        })

      assert {:ok, %{applied: 1, conflicts: 0, base: "seq"}} =
               Sync.apply_changes(ctx.tenant, ctx.ws, [edit],
                 base_seq: seen,
                 base_replica_id: Sync.replica_id()
               )

      assert title(id) == "Edited after pulling it"
      assert Sync.conflicts(ctx.tenant, ctx.ws) == []
    end

    test "a change made here after the sender's base still conflicts, and the conflict says why",
         ctx do
      id = "concurrent-#{ctx.n}"
      insert_context(ctx.tenant, ctx.ws, id, "Before the sender pulled")
      seen = local_seq(ctx, "contexts", id)

      {:ok, _} =
        Store.raw_query("UPDATE contexts SET title = 'Changed here after' WHERE id = ?1", [id])

      after_base = local_seq(ctx, "contexts", id)
      assert after_base > seen

      edit =
        mutation(ctx, %{
          "operation" => "update",
          "occurred_at" => "2000-01-01T00:00:00.000",
          "payload" => context_row(id, "Changed on the sender", ctx.ws, ctx.tenant)
        })

      assert {:ok, %{applied: 0, conflicts: 1}} =
               Sync.apply_changes(ctx.tenant, ctx.ws, [edit],
                 base_seq: seen,
                 base_replica_id: Sync.replica_id()
               )

      assert title(id) == "Changed here after"

      assert [%{kind: "concurrent_edit", resolution: "kept_local_newer", detail: detail}] =
               Sync.conflicts(ctx.tenant, ctx.ws)

      assert %{
               "local_seq" => ^after_base,
               "base_seq" => ^seen,
               "local_floor" => nil,
               "remote_occurred_at" => "2000-01-01T00:00:00.000",
               "resolution" => "kept_local_newer"
             } = detail

      assert is_binary(detail["local_occurred_at"])
    end

    test "an edit made after seeing the change here wins even when its clock is older", ctx do
      id = "causal-#{ctx.n}"
      insert_context(ctx.tenant, ctx.ws, id, "Written here, clock ahead")
      seen = local_seq(ctx, "contexts", id)

      # The sender pulled that change, then edited it; its clock is far behind.
      later_in_cause =
        mutation(ctx, %{
          "operation" => "update",
          "occurred_at" => "2000-01-01T00:00:00.000",
          "payload" => context_row(id, "Edited after reading it", ctx.ws, ctx.tenant)
        })

      assert {:ok, %{applied: 1, conflicts: 0, base: "seq"}} =
               Sync.apply_changes(ctx.tenant, ctx.ws, [later_in_cause],
                 base_seq: seen,
                 base_replica_id: Sync.replica_id()
               )

      assert title(id) == "Edited after reading it"
      assert Sync.conflicts(ctx.tenant, ctx.ws) == []
    end

    test "a push without a base keeps the conservative check and records unknown_base", ctx do
      id = "unknown-#{ctx.n}"
      insert_context(ctx.tenant, ctx.ws, id, "Written here")
      local = local_seq(ctx, "contexts", id)

      edit =
        mutation(ctx, %{
          "operation" => "update",
          "occurred_at" => "2999-01-01T00:00:00.000",
          "payload" => context_row(id, "From an older client", ctx.ws, ctx.tenant)
        })

      assert {:ok, %{applied: 1, conflicts: 1}} = Sync.apply_changes(ctx.tenant, ctx.ws, [edit])
      assert title(id) == "From an older client"

      assert [
               %{
                 kind: "unknown_base",
                 resolution: "applied_remote_newer",
                 detail: %{"local_seq" => ^local, "base_seq" => nil, "local_floor" => nil}
               }
             ] = Sync.conflicts(ctx.tenant, ctx.ws)
    end

    test "POST /api/sync/changes judges conflicts against the body's base, and says which it used",
         ctx do
      id = "routed-#{ctx.n}"
      insert_context(ctx.tenant, ctx.ws, id, "Written here before the sender pulled")
      seen = local_seq(ctx, "contexts", id)
      here = Sync.replica_id()

      push = fn extra ->
        edit =
          mutation(ctx, %{
            "operation" => "update",
            "occurred_at" => "2999-01-01T00:00:00.000",
            "payload" => context_row(id, "Pushed", ctx.ws, ctx.tenant)
          })

        body =
          Map.merge(
            %{"workspace" => ctx.ws, "engine" => Sync.engine_info(), "mutations" => [edit]},
            extra
          )

        conn =
          Plug.Test.conn(:post, "/api/sync/changes", body)
          |> Plug.Conn.assign(:current_tenant, ctx.tenant)
          |> OptimalEngine.API.SyncAPI.apply()

        {conn.status, Jason.decode!(conn.resp_body)}
      end

      assert {200, %{"applied" => 1, "conflicts" => 0, "base" => "seq"} = ok} =
               push.(%{"base_seq" => seen, "base_replica_id" => here, "replica_id" => "rep_remote"})

      refute Map.has_key?(ok, "base_rejected")

      # Not a base: refused, and nothing is applied.
      for bad <- ["seen", -1, 5.0, 3.5, true, %{}, []] do
        assert {422, %{"error" => "invalid_base_seq"}} = push.(%{"base_seq" => bad})
      end

      assert {422, %{"error" => "invalid_base_replica_id"}} =
               push.(%{"base_seq" => seen, "base_replica_id" => 7})

      assert {422, %{"error" => "invalid_replica_id"}} = push.(%{"replica_id" => 7})

      # No base at all (absent or null): the conservative check.
      assert {200, %{"base" => "unknown"} = none} = push.(%{})
      refute Map.has_key?(none, "base_rejected")
      assert {200, %{"base" => "unknown"}} = push.(%{"base_seq" => nil})

      # A base that cannot be this ledger's is no base: past its head, from another replica, or unsigned.
      head = Sync.status(ctx.tenant, ctx.ws).ledger_sequence

      assert {200, %{"base" => "unknown", "base_rejected" => "above_head"}} =
               push.(%{"base_seq" => head + 1000, "base_replica_id" => here})

      assert {200, %{"base" => "unknown", "base_rejected" => "replica_mismatch"}} =
               push.(%{"base_seq" => seen, "base_replica_id" => "rep_someone_else"})

      assert {200, %{"base" => "unknown", "base_rejected" => "replica_mismatch"}} =
               push.(%{"base_seq" => seen})

      # Zero claims nothing seen, so it needs no replica to vouch for it.
      assert {200, %{"base" => "seq"}} = push.(%{"base_seq" => 0})
    end

    test "status counts open conflicts per table", ctx do
      insert_context(ctx.tenant, ctx.ws, "counted-#{ctx.n}", "Written here")

      {:ok, _} =
        Store.raw_query(
          "INSERT INTO facts (id, tenant_id, workspace_id, fact_text) VALUES (?1, ?2, ?3, 'Opens at nine')",
          ["counted-fact-#{ctx.n}", ctx.tenant, ctx.ws]
        )

      {:ok, _} = Capture.seal()

      changes = [
        mutation(ctx, %{
          "operation" => "update",
          "occurred_at" => "2999-01-01T00:00:00.000",
          "payload" => context_row("counted-#{ctx.n}", "Remote", ctx.ws, ctx.tenant)
        }),
        mutation(ctx, %{
          "entity_type" => "facts",
          "operation" => "update",
          "occurred_at" => "2999-01-01T00:00:00.000",
          "payload" => %{
            "row" => %{
              "id" => "counted-fact-#{ctx.n}",
              "fact_text" => "Opens at ten",
              "workspace_id" => ctx.ws,
              "tenant_id" => ctx.tenant
            },
            "blobs" => %{}
          }
        }),
        mutation(ctx, %{
          "entity_type" => "no_such_table",
          "entity_id" => "x",
          "payload" => %{"row" => %{"id" => "x"}}
        })
      ]

      assert {:ok, %{conflicts: 2}} = Sync.apply_changes(ctx.tenant, ctx.ws, changes, base_seq: 0)

      status = Sync.status(ctx.tenant, ctx.ws)
      assert status.conflicts_by_table == %{"contexts" => 1, "facts" => 1, "no_such_table" => 1}
      assert status.open_conflicts == 3

      [first | _] = Sync.conflicts(ctx.tenant, ctx.ws)
      :ok = Sync.resolve_conflict(ctx.tenant, first.id, "user:owner")
      assert Sync.status(ctx.tenant, ctx.ws).open_conflicts == 2
      refute Map.has_key?(Sync.status(ctx.tenant, ctx.ws).conflicts_by_table, first.table)
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

  describe "what a peer may write" do
    # The table is named by the sender, so a peer holding only the `sync` scope
    # could otherwise write credentials, roles or API keys into this Engine.
    defp probe_count(sql, params) do
      {:ok, [[count]]} = Store.raw_query(sql, params)
      count
    end

    defp pushed(ctx, table, row, attrs \\ %{}) do
      mutation(
        ctx,
        Map.merge(
          %{
            "entity_type" => table,
            "entity_id" => to_string(row["id"] || row["jti"] || row["url"] || row["version"]),
            "payload" => %{"row" => row, "blobs" => %{}}
          },
          attrs
        )
      )
    end

    defp refused_cases(ctx) do
      n = ctx.n

      [
        {"api_keys",
         %{
           "id" => "key_evil_#{n}",
           "tenant_id" => ctx.tenant,
           "hashed_secret" => "$2b$12$abcdefghijklmnopqrstuuabcdefghijklmnopqrstuvwxyz0123",
           "prefix" => "evil",
           "name" => "root",
           "scopes" => ~s(["*"])
         }, "SELECT COUNT(*) FROM api_keys WHERE id = ?1", "key_evil_#{n}"},
        {"principals",
         %{
           "id" => "prin_evil_#{n}",
           "tenant_id" => ctx.tenant,
           "kind" => "human",
           "display_name" => "Evil"
         }, "SELECT COUNT(*) FROM principals WHERE id = ?1", "prin_evil_#{n}"},
        {"roles", %{"id" => "role_evil_#{n}", "tenant_id" => ctx.tenant, "name" => "evil"},
         "SELECT COUNT(*) FROM roles WHERE id = ?1", "role_evil_#{n}"},
        {"tenants", %{"id" => "tenant_evil_#{n}", "name" => "Evil"},
         "SELECT COUNT(*) FROM tenants WHERE id = ?1", "tenant_evil_#{n}"},
        {"schema_migrations", %{"version" => 7_000_000 + n, "description" => "evil #{n}"},
         "SELECT COUNT(*) FROM schema_migrations WHERE description = ?1", "evil #{n}"}
      ]
    end

    defp local_only_cases(ctx) do
      n = ctx.n

      [
        {"workspaces",
         %{"id" => "ws_evil_#{n}", "tenant_id" => ctx.tenant, "slug" => "evil", "name" => "Evil"},
         "SELECT COUNT(*) FROM workspaces WHERE id = ?1", "ws_evil_#{n}"},
        {"sync_peers",
         %{
           "tenant_id" => ctx.tenant,
           "workspace_id" => ctx.ws,
           "url" => "https://evil-#{n}.example",
           "credential" => "x"
         }, "SELECT COUNT(*) FROM sync_peers WHERE url = ?1", "https://evil-#{n}.example"},
        {"authority_grants",
         %{
           "jti" => "jti_evil_#{n}",
           "tenant_id" => ctx.tenant,
           "issuer" => "evil",
           "audience" => "evil",
           "subject" => "evil",
           "action" => "*",
           "resource" => "*",
           "data_class" => "restricted",
           "status" => "active",
           "not_before" => 0,
           "expires_at" => 99_999_999_999,
           "claims" => "{}",
           "token_hash" => "x",
           "kid" => "k"
         }, "SELECT COUNT(*) FROM authority_grants WHERE jti = ?1", "jti_evil_#{n}"},
        {"jobs",
         %{
           "id" => "job_evil_#{n}",
           "tenant_id" => ctx.tenant,
           "workspace_id" => ctx.ws,
           "kind" => "evil"
         }, "SELECT COUNT(*) FROM jobs WHERE id = ?1", "job_evil_#{n}"},
        {"dead_letter_jobs",
         %{
           "id" => "dlj_evil_#{n}",
           "original_job_id" => "j",
           "tenant_id" => ctx.tenant,
           "workspace_id" => ctx.ws,
           "kind" => "evil",
           "attempts" => 1,
           "final_error" => "x"
         }, "SELECT COUNT(*) FROM dead_letter_jobs WHERE id = ?1", "dlj_evil_#{n}"},
        {"connectors",
         %{
           "id" => "conn_evil_#{n}",
           "tenant_id" => ctx.tenant,
           "workspace_id" => ctx.ws,
           "kind" => "gmail",
           "config" => "{}"
         }, "SELECT COUNT(*) FROM connectors WHERE id = ?1", "conn_evil_#{n}"}
      ]
    end

    test "credentials, roles, API keys, tenants and migrations are refused, never written", ctx do
      for {table, row, probe, value} <- refused_cases(ctx) do
        assert {:ok, result} = Sync.apply_changes(ctx.tenant, ctx.ws, [pushed(ctx, table, row)])
        assert result.applied == 0, "#{table} was applied"

        assert [%{reason: :table_not_replicated}] = result.failed,
               "#{table} was not refused as table_not_replicated: #{inspect(result)}"

        assert probe_count(probe, [value]) == 0, "#{table} row was written"
      end

      refused =
        Sync.conflicts(ctx.tenant, ctx.ws)
        |> Enum.filter(&(&1.kind == "apply_failed"))
        |> Enum.map(& &1.table)
        |> Enum.sort()

      assert refused == refused_cases(ctx) |> Enum.map(&elem(&1, 0)) |> Enum.sort()
    end

    test "tables that belong to one Engine are skipped as local-only, never written", ctx do
      for {table, row, probe, value} <- local_only_cases(ctx) do
        assert {:ok, result} = Sync.apply_changes(ctx.tenant, ctx.ws, [pushed(ctx, table, row)])
        assert result.applied == 0, "#{table} was applied"
        assert result.skipped == %{local_only: 1}, "#{table} was not skipped as local_only"
        assert result.failed == []
        assert probe_count(probe, [value]) == 0, "#{table} row was written"
      end

      # Skipped changes are not recorded in the ledger, so a hub never forwards them.
      assert probe_count(
               "SELECT COUNT(*) FROM sync_mutations WHERE workspace_id = ?1 AND entity_type IN ('connectors', 'jobs', 'dead_letter_jobs')",
               [ctx.ws]
             ) == 0
    end

    test "an existing row of a table that is not replicated is left as it was", ctx do
      {:ok, [[name]]} = Store.raw_query("SELECT name FROM tenants WHERE id = ?1", [ctx.tenant])

      rename = pushed(ctx, "tenants", %{"id" => ctx.tenant, "name" => "Taken over"})

      assert {:ok, %{applied: 0, failed: [%{reason: :table_not_replicated}]}} =
               Sync.apply_changes(ctx.tenant, ctx.ws, [rename])

      assert {:ok, [[^name]]} =
               Store.raw_query("SELECT name FROM tenants WHERE id = ?1", [ctx.tenant])

      delete = pushed(ctx, "tenants", %{"id" => ctx.tenant}, %{"operation" => "delete"})

      assert {:ok, %{applied: 0, failed: [%{reason: :table_not_replicated}]}} =
               Sync.apply_changes(ctx.tenant, ctx.ws, [delete])

      assert probe_count("SELECT COUNT(*) FROM tenants WHERE id = ?1", [ctx.tenant]) == 1
    end

    test "the replicated set is the captured tables, and none of the sensitive ones" do
      replicated = Capture.replicated_tables()
      assert "contexts" in replicated and "facts" in replicated

      for table <-
            ~w(api_keys principals roles role_grants tenants schema_migrations workspaces sync_peers
               sync_mutations sync_capture connectors connector_runs jobs dead_letter_jobs) do
        refute table in replicated, "#{table} would replicate"
      end

      refute Enum.any?(replicated, &String.starts_with?(&1, "authority_"))

      for table <- ~w(connectors jobs dead_letter_jobs connector_runs workspaces sync_peers) do
        assert Capture.local_only?(table)
        assert Capture.known_local?(table)
        assert Capture.bundle_excluded?(table)
      end

      assert Capture.local_only?("authority_grants")
      assert Capture.known_local?("authority_grants")
      assert Capture.bundle_excluded?("authority_grants")
      refute Capture.local_only?("contexts")
      refute Capture.replicated?(nil)

      # A table nobody has classified is local, and refused rather than skipped by name.
      assert Capture.local_only?("a_table_added_tomorrow")
      refute Capture.known_local?("a_table_added_tomorrow")
    end

    test "a row is written into the target tenant and workspace whatever it claims", ctx do
      {:ok, other} =
        Workspace.create(%{
          tenant_id: ctx.tenant,
          organization_id: "#{ctx.tenant}:org",
          slug: "elsewhere",
          name: "Elsewhere"
        })

      claimed = "claimed-#{ctx.n}"
      bare = "bare-#{ctx.n}"

      claiming =
        mutation(ctx, %{
          "payload" => context_row(claimed, "Claims another workspace", other.id, "someone-else")
        })

      bare_row =
        mutation(ctx, %{
          "payload" => %{
            "row" => %{"id" => bare, "title" => "No scope at all", "content" => "x"},
            "blobs" => %{}
          }
        })

      assert {:ok, %{applied: 2, failed: []}} =
               Sync.apply_changes(ctx.tenant, ctx.ws, [claiming, bare_row])

      for id <- [claimed, bare] do
        assert {:ok, [[tenant, workspace]]} =
                 Store.raw_query("SELECT tenant_id, workspace_id FROM contexts WHERE id = ?1", [id])

        assert {tenant, workspace} == {ctx.tenant, ctx.ws}
      end
    end

    test "a key that exists in another workspace or tenant is refused for an upsert", ctx do
      {:ok, other} =
        Workspace.create(%{
          tenant_id: ctx.tenant,
          organization_id: "#{ctx.tenant}:org",
          slug: "elsewhere",
          name: "Elsewhere"
        })

      stranger = "stranger-#{ctx.n}"
      {:ok, _} = Tenant.create(%{id: stranger, name: "Stranger"})

      {:ok, _} =
        OptimalEngine.Organization.create(%{
          id: "#{stranger}:org",
          tenant_id: stranger,
          slug: "org",
          name: "Org"
        })

      {:ok, foreign} =
        Workspace.create(%{
          tenant_id: stranger,
          organization_id: "#{stranger}:org",
          slug: "notes",
          name: "Notes"
        })

      insert_context(ctx.tenant, other.id, "same-tenant-#{ctx.n}", "Theirs")
      insert_context(stranger, foreign.id, "other-tenant-#{ctx.n}", "Theirs too")

      attempts =
        for id <- ["same-tenant-#{ctx.n}", "other-tenant-#{ctx.n}"],
            op <- ["create", "update"] do
          mutation(ctx, %{
            "operation" => op,
            "payload" => context_row(id, "Hijacked", ctx.ws, ctx.tenant)
          })
        end

      assert {:ok, result} = Sync.apply_changes(ctx.tenant, ctx.ws, attempts)
      assert result.applied == 0
      assert Enum.map(result.failed, & &1.reason) == List.duplicate(:cross_scope, 4)

      assert {:ok, [["Theirs", workspace]]} =
               Store.raw_query("SELECT title, workspace_id FROM contexts WHERE id = ?1", [
                 "same-tenant-#{ctx.n}"
               ])

      assert workspace == other.id

      assert {:ok, [["Theirs too", tenant]]} =
               Store.raw_query("SELECT title, tenant_id FROM contexts WHERE id = ?1", [
                 "other-tenant-#{ctx.n}"
               ])

      assert tenant == stranger
      assert Enum.all?(Sync.conflicts(ctx.tenant, ctx.ws), &(&1.detail == ":cross_scope"))
    end

    test "a delete of another workspace's row is refused, of this workspace's row is applied",
         ctx do
      {:ok, other} =
        Workspace.create(%{
          tenant_id: ctx.tenant,
          organization_id: "#{ctx.tenant}:org",
          slug: "elsewhere",
          name: "Elsewhere"
        })

      insert_context(ctx.tenant, other.id, "victim-#{ctx.n}", "Not yours")
      insert_context(ctx.tenant, ctx.ws, "mine-#{ctx.n}", "Yours")

      # Newer than anything written here: a delete is judged by its time like any change.
      delete = fn id, extra ->
        mutation(ctx, %{
          "operation" => "delete",
          "entity_id" => id,
          "occurred_at" => "2999-01-01T00:00:00.000",
          "payload" => %{"row" => Map.merge(%{"id" => id}, extra), "blobs" => %{}}
        })
      end

      claimed = %{"workspace_id" => other.id, "tenant_id" => ctx.tenant}

      assert {:ok, result} =
               Sync.apply_changes(ctx.tenant, ctx.ws, [
                 delete.("victim-#{ctx.n}", %{}),
                 delete.("victim-#{ctx.n}", claimed),
                 delete.("mine-#{ctx.n}", %{})
               ])

      assert result.applied == 1
      assert Enum.map(result.failed, & &1.reason) == [:cross_scope, :cross_scope]
      assert probe_count("SELECT COUNT(*) FROM contexts WHERE id = ?1", ["victim-#{ctx.n}"]) == 1
      assert probe_count("SELECT COUNT(*) FROM contexts WHERE id = ?1", ["mine-#{ctx.n}"]) == 0
    end

    test "a delete or an upsert without its key is refused", ctx do
      no_key_delete =
        mutation(ctx, %{
          "operation" => "delete",
          "entity_id" => "nokey",
          "payload" => %{"row" => %{}, "blobs" => %{}}
        })

      no_key_upsert =
        mutation(ctx, %{
          "entity_id" => "nokey",
          "payload" => %{"row" => %{"title" => "no id"}, "blobs" => %{}}
        })

      assert {:ok, %{applied: 0} = result} =
               Sync.apply_changes(ctx.tenant, ctx.ws, [no_key_delete, no_key_upsert])

      assert Enum.map(result.failed, & &1.reason) == [:missing_key, :missing_key]
    end

    test "a mutation without a time or another required field fails alone, not the batch", ctx do
      good =
        mutation(ctx, %{"payload" => context_row("good-#{ctx.n}", "Fine", ctx.ws, ctx.tenant)})

      row = context_row("bad-#{ctx.n}", "Bad", ctx.ws, ctx.tenant)
      nested = %{"row" => %{"id" => %{"nested" => 1}}, "blobs" => %{}}
      bad_hex = %{"row" => %{"id" => "x"}, "blobs" => %{"embedding" => "zz"}}

      # Built by hand: the helper reads the payload, which is what is wrong here.
      raw = fn attrs ->
        Map.merge(
          %{
            "id" => "mut_raw_#{System.unique_integer([:positive])}",
            "device_id" => "rep_remote",
            "entity_type" => "contexts",
            "entity_id" => "bad-#{ctx.n}",
            "operation" => "create",
            "occurred_at" => "2026-10-14T12:00:00.000",
            "payload" => row
          },
          attrs
        )
      end

      bad = [
        {:invalid_occurred_at, raw.(%{"occurred_at" => nil})},
        {:invalid_occurred_at, raw.(%{"occurred_at" => 1_760_000_000})},
        {:invalid_mutation, raw.(%{"operation" => "obliterate"})},
        {:invalid_mutation, raw.(%{"entity_id" => nil})},
        {:invalid_mutation, raw.(%{"device_id" => nil})},
        {:invalid_mutation, raw.(%{"entity_type" => %{"a" => 1}})},
        {:invalid_payload, raw.(%{"payload" => nil})},
        {:invalid_payload, raw.(%{"payload" => %{"row" => "nope"}})},
        {:unsupported_value, raw.(%{"payload" => nested})},
        {:invalid_payload, raw.(%{"payload" => bad_hex})}
      ]

      batch = [good, "garbage", 42, nil | Enum.map(bad, &elem(&1, 1))]

      assert {:ok, result} = Sync.apply_changes(ctx.tenant, ctx.ws, batch)
      assert result.applied == 1
      assert result.skipped == %{invalid: 3}
      assert Enum.map(result.failed, & &1.reason) == Enum.map(bad, &elem(&1, 0))
      assert probe_count("SELECT COUNT(*) FROM contexts WHERE id = ?1", ["bad-#{ctx.n}"]) == 0
      assert probe_count("SELECT COUNT(*) FROM contexts WHERE id = ?1", ["good-#{ctx.n}"]) == 1
    end
  end

  describe "what a peer cannot slip past the checks" do
    test "a blob named for a confined column cannot stand in for the checked value", ctx do
      hex = Base.encode16("../../x")

      blobbed = fn table, id, row, column ->
        mutation(ctx, %{
          "entity_type" => table,
          "entity_id" => id,
          "payload" => %{"row" => row, "blobs" => %{column => hex}}
        })
      end

      changes = [
        blobbed.(
          "nodes",
          "bn-#{ctx.n}",
          %{"id" => "bn-#{ctx.n}", "slug" => "fine", "name" => "x", "kind" => "folder"},
          "slug"
        ),
        blobbed.(
          "nodes",
          "bp-#{ctx.n}",
          %{"id" => "bp-#{ctx.n}", "slug" => "fine", "name" => "x", "kind" => "folder"},
          "path"
        ),
        blobbed.(
          "wiki_pages",
          "bw-#{ctx.n}",
          %{"slug" => "bw-#{ctx.n}", "body" => "x", "tenant_id" => ctx.tenant},
          "slug"
        ),
        blobbed.("contexts", "bc-#{ctx.n}", %{"id" => "bc-#{ctx.n}", "title" => "x"}, "path")
      ]

      assert {:ok, result} = Sync.apply_changes(ctx.tenant, ctx.ws, changes)
      assert result.applied == 0
      assert Enum.map(result.failed, & &1.reason) == List.duplicate(:invalid_path, 4)
      assert probe_count("SELECT COUNT(*) FROM nodes WHERE id LIKE ?1", ["b_-#{ctx.n}"]) == 0
      assert probe_count("SELECT COUNT(*) FROM wiki_pages WHERE slug = ?1", ["bw-#{ctx.n}"]) == 0
      assert probe_count("SELECT COUNT(*) FROM contexts WHERE id = ?1", ["bc-#{ctx.n}"]) == 0
    end

    test "a change cannot delete or downgrade a row above the gate", ctx do
      id = "sp-#{ctx.n}"

      {:ok, _} =
        Store.raw_query(
          "INSERT INTO source_packages (id, tenant_id, workspace_id, content_hash, raw_text, security_labels) VALUES (?1, ?2, ?3, ?4, 'secret', '[\"restricted\"]')",
          [id, ctx.tenant, ctx.ws, "hash-#{ctx.n}"]
        )

      row = fn attrs ->
        Map.merge(
          %{
            "id" => id,
            "tenant_id" => ctx.tenant,
            "workspace_id" => ctx.ws,
            "content_hash" => "hash-#{ctx.n}"
          },
          attrs
        )
      end

      change = fn operation, attrs ->
        mutation(ctx, %{
          "entity_type" => "source_packages",
          "entity_id" => id,
          "operation" => operation,
          "occurred_at" => "2999-01-01T00:00:00.000",
          "payload" => %{"row" => row.(attrs), "blobs" => %{}}
        })
      end

      stored = fn ->
        {:ok, [[raw, labels]]} =
          Store.raw_query("SELECT raw_text, security_labels FROM source_packages WHERE id = ?1", [
            id
          ])

        {raw, labels}
      end

      # A delete carries no labels, and an overwrite carries lower ones.
      delete = change.("delete", %{})
      overwrite = change.("update", %{"raw_text" => "leaked", "security_labels" => ~s(["public"])})

      assert {:ok, %{applied: 0, failed: [], skipped: %{gated: 2}}} =
               Sync.apply_changes(ctx.tenant, ctx.ws, [delete, overwrite])

      assert stored.() == {"secret", ~s(["restricted"])}

      # A peer cleared for the row's class may change it, and its labels only grow.
      assert {:ok, %{applied: 1, failed: []}} =
               Sync.apply_changes(ctx.tenant, ctx.ws, [overwrite], max_class: "restricted")

      assert stored.() == {"leaked", ~s(["public","restricted"])}
    end

    test "a context with a mode, signal type or format this Engine does not write is refused",
         ctx do
      weird = "zzz_never_an_atom_#{ctx.n}"

      with_values = fn id, values ->
        change = mutation(ctx, %{"payload" => context_row(id, "Signal", ctx.ws, ctx.tenant)})
        update_in(change, ["payload", "row"], &Map.merge(&1, values))
      end

      bad =
        for column <- ~w(mode signal_type format),
            do: with_values.("bad-#{column}-#{ctx.n}", %{column => weird})

      good =
        with_values.("good-signal-#{ctx.n}", %{
          "mode" => "code",
          "signal_type" => "decide",
          "format" => "json"
        })

      assert {:ok, %{applied: 1} = result} = Sync.apply_changes(ctx.tenant, ctx.ws, bad ++ [good])
      assert Enum.map(result.failed, & &1.reason) == List.duplicate(:invalid_signal_value, 3)
      assert probe_count("SELECT COUNT(*) FROM contexts WHERE id LIKE ?1", ["bad-%-#{ctx.n}"]) == 0
      assert title("good-signal-#{ctx.n}") == "Signal"
      assert_raise ArgumentError, fn -> String.to_existing_atom(weird) end
    end

    test "a stored mode, type or format never becomes an atom on a read path", ctx do
      weird = fn name -> "zzz_never_an_atom_#{name}_#{ctx.n}" end
      node = "atoms-#{ctx.n}"

      # Written without going through apply (an Engine of an earlier version, a bundle).
      {:ok, _} =
        Store.raw_query(
          """
          INSERT INTO contexts (id, uri, tenant_id, workspace_id, type, title, node, mode, genre, signal_type, format, structure)
          VALUES (?1, ?10, ?2, ?3, 'signal', 'Weird', ?4, ?5, ?6, ?7, ?8, ?9)
          """,
          [
            "atoms-#{ctx.n}",
            ctx.tenant,
            ctx.ws,
            node,
            weird.("mode"),
            weird.("genre"),
            weird.("type"),
            weird.("format"),
            weird.("structure"),
            "optimal://atoms/#{ctx.n}"
          ]
        )

      assert {:ok, [context]} = Store.get_by_node(node, type: :signal)
      assert %{mode: :linguistic, type: :inform, format: :markdown} = context.signal

      for name <- ~w(mode genre type format structure) do
        assert_raise ArgumentError, fn -> String.to_existing_atom(weird.(name)) end
      end
    end

    test "a child that comes before its parent in a page still lands, an orphan fails alone",
         ctx do
      chunk = "chunk-#{ctx.n}"

      orphan =
        mutation(ctx, %{
          "entity_type" => "memory_relations",
          "entity_id" => "row:1",
          "payload" => %{
            "row" => %{
              "source_memory_id" => "gone-a-#{ctx.n}",
              "target_memory_id" => "gone-b-#{ctx.n}",
              "relation" => "relates"
            },
            "blobs" => %{}
          }
        })

      child =
        mutation(ctx, %{
          "entity_type" => "classifications",
          "entity_id" => "row:2",
          "payload" => %{
            "row" => %{"id" => 7, "tenant_id" => ctx.tenant, "chunk_id" => chunk, "mode" => "code"},
            "blobs" => %{}
          }
        })

      parent =
        mutation(ctx, %{
          "entity_type" => "chunks",
          "entity_id" => chunk,
          "payload" => %{
            "row" => %{
              "id" => chunk,
              "tenant_id" => ctx.tenant,
              "signal_id" => "signal-#{ctx.n}",
              "scale" => "document"
            },
            "blobs" => %{}
          }
        })

      # The orphan breaks the deferred commit, so the page runs again with every key
      # checked as its row is written: the child meets no parent the first time.
      assert {:ok, %{applied: 2, failed: [%{reason: reason}]}} =
               Sync.apply_changes(ctx.tenant, ctx.ws, [orphan, child, parent])

      assert reason =~ "FOREIGN KEY"
      assert probe_count("SELECT COUNT(*) FROM chunks WHERE id = ?1", [chunk]) == 1
      assert probe_count("SELECT COUNT(*) FROM classifications WHERE chunk_id = ?1", [chunk]) == 1
    end

    test "the boot purge works in batches, logs what it removes from sensitive tables, and not their payload",
         ctx do
      {:ok, _} =
        Store.raw_query(
          """
          WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 5100)
          INSERT INTO sync_mutations
            (id, tenant_id, workspace_id, device_id, entity_type, entity_id, operation, payload,
             payload_hash, idempotency_key, occurred_at)
          SELECT 'bulk_' || ?1 || '_' || i, ?2, ?3, 'rep_remote', 'jobs', 'j' || i, 'create',
                 '{"row":{},"blobs":{}}', 'h', 'bulk:' || ?1 || ':' || i, '2026-10-14T12:00:00.000'
          FROM n
          """,
          [ctx.n, ctx.tenant, ctx.ws]
        )

      {:ok, _} =
        Store.raw_query(
          """
          INSERT INTO sync_mutations
            (id, tenant_id, workspace_id, device_id, entity_type, entity_id, operation, payload,
             payload_hash, idempotency_key, occurred_at)
          VALUES (?1, ?2, ?3, 'rep_evil', 'api_keys', 'key-evil', 'create', '{"row":{"hashed_secret":"SECRET-PAYLOAD"}}',
                  'h', ?4, '2026-10-14T12:00:01.000')
          """,
          ["evidence_#{ctx.n}", ctx.tenant, ctx.ws, "evidence:#{ctx.n}"]
        )

      log =
        capture_log(fn ->
          assert {:ok, purged} = Sync.purge_unreplicated()
          assert purged["jobs"] >= 5100 and purged["api_keys"] >= 1
        end)

      assert log =~ "purged ledger row evidence_#{ctx.n}: create api_keys key-evil"
      assert log =~ "device rep_evil"
      refute log =~ "SECRET-PAYLOAD"
      refute log =~ "bulk_#{ctx.n}"

      assert probe_count("SELECT COUNT(*) FROM sync_mutations WHERE workspace_id = ?1", [ctx.ws]) ==
               0
    end

    test "the purge runs once for each version of the replicated list", ctx do
      stale = fn suffix ->
        {:ok, _} =
          Store.raw_query(
            """
            INSERT INTO sync_mutations
              (id, tenant_id, workspace_id, device_id, entity_type, entity_id, operation, payload,
               payload_hash, idempotency_key, occurred_at)
            VALUES (?1, ?2, ?3, 'rep_remote', 'roles', 'r1', 'create', '{"row":{},"blobs":{}}', 'h', ?4,
                    '2026-10-14T12:00:00.000')
            """,
            ["once_#{ctx.n}_#{suffix}", ctx.tenant, ctx.ws, "once:#{ctx.n}:#{suffix}"]
          )
      end

      remaining = fn ->
        probe_count("SELECT COUNT(*) FROM sync_mutations WHERE workspace_id = ?1", [ctx.ws])
      end

      {:ok, _} = Store.raw_query("PRAGMA user_version = 0", [])
      stale.("a")

      capture_log(fn ->
        assert {:ok, %{"roles" => roles}} = Sync.purge_unreplicated_once()
        assert roles >= 1
      end)

      assert remaining.() == 0
      assert {:ok, [[version]]} = Store.raw_query("PRAGMA user_version", [])
      assert version > 0

      # Same list, same version: no scan, so a row that appears now is left alone.
      stale.("b")
      assert {:ok, %{}} = Sync.purge_unreplicated_once()
      assert remaining.() == 1

      # A different list is a different version.
      {:ok, _} = Store.raw_query("PRAGMA user_version = #{version + 1}", [])

      capture_log(fn ->
        assert {:ok, %{"roles" => roles}} = Sync.purge_unreplicated_once()
        assert roles >= 1
      end)

      assert remaining.() == 0
      assert {:ok, [[^version]]} = Store.raw_query("PRAGMA user_version", [])
    end
  end

  describe "an explicit list of what replicates" do
    test "every table with a workspace_id is on the replicated list or classified local" do
      {:ok, rows} =
        Store.raw_query(
          "SELECT DISTINCT m.name FROM sqlite_master m, pragma_table_info(m.name) p WHERE m.type = 'table' AND p.name = 'workspace_id'",
          []
        )

      {:ok, collections} = Store.raw_query("SELECT table_name FROM data_collections", [])
      collection_tables = MapSet.new(List.flatten(collections))
      classified = MapSet.new(Capture.replicated_tables() ++ Capture.local_tables())

      unclassified =
        for [name] <- rows,
            not MapSet.member?(classified, name),
            not MapSet.member?(collection_tables, name),
            not String.starts_with?(name, "authority_"),
            do: name

      assert unclassified == [],
             "tables with a workspace_id that are on neither list (add each to @replicated or to @engine_state / @per_engine in Capture): #{inspect(unclassified)}"
    end

    test "every foreign key of a replicated table points at a replicated table or at a scope table" do
      allowed = MapSet.new(Capture.replicated_tables() ++ ~w(workspaces tenants organizations))

      dangling =
        for table <- Capture.replicated_tables(),
            {:ok, targets} =
              Store.raw_query("SELECT \"table\" FROM pragma_foreign_key_list(?1)", [table]),
            [target] <- targets,
            not MapSet.member?(allowed, target),
            do: {table, target}

      assert dangling == [],
             "a replicated table that points at a table that stays on its Engine breaks its batch at commit: #{inspect(dangling)}"
    end

    defp workspace_scoped?(table),
      do: Enum.any?(Capture.columns(table), &(&1.name == "workspace_id"))

    test "every replicated table exists, is workspace-scoped, fits the capture limit and is captured" do
      replicated = Capture.replicated_tables()
      assert replicated == Enum.sort(replicated)
      assert MapSet.disjoint?(MapSet.new(replicated), MapSet.new(Capture.local_tables()))

      unscoped = for table <- replicated, not workspace_scoped?(table), do: table
      assert unscoped == [], "replicated tables without a workspace_id: #{inspect(unscoped)}"

      wide = for table <- replicated, length(Capture.columns(table)) > 60, do: table

      assert wide == [],
             "replicated tables with more columns than capture handles: #{inspect(wide)}"

      assert {:ok, %{tables: tables, skipped: []}} = Capture.install()
      assert tables == length(replicated)
    end

    test "workspace_handles stays local: not replicated, skipped on apply, left out of a bundle" do
      refute "workspace_handles" in Capture.replicated_tables()
      assert "workspace_handles" in Capture.local_tables()
      assert Capture.local_only?("workspace_handles")
      assert Capture.bundle_excluded?("workspace_handles")
    end

    test "tables that grant a capability, name a path or an identifier, or decode into atoms are skipped",
         ctx do
      tables =
        ~w(data_collections data_changes data_files data_schema_migrations assets
           asset_adapter_runs asset_extractions asset_transcripts surfacing_subscriptions
           mcp_tool_definitions skill_packages skills model_call_operations model_adapters
           storage_provider_configs workspace_storage_policies workspace_members node_members
           principal_skills routing_rules evaluation_cases workspace_handles)

      changes =
        for table <- tables do
          id = "x-#{table}-#{ctx.n}"

          mutation(ctx, %{
            "entity_type" => table,
            "entity_id" => id,
            "payload" => %{
              "row" => %{
                "id" => id,
                "name" => "evil-#{ctx.n}",
                "table_name" => ~s(evil"; DELETE FROM contexts; --),
                "storage_path" => "/etc/passwd",
                "role" => "owner"
              },
              "blobs" => %{}
            }
          })
        end

      assert {:ok, result} = Sync.apply_changes(ctx.tenant, ctx.ws, changes)
      assert result.applied == 0
      assert result.failed == []
      assert result.skipped == %{local_only: length(tables)}

      for {sql, params} <- [
            {"SELECT COUNT(*) FROM data_collections WHERE name = ?1", ["evil-#{ctx.n}"]},
            {"SELECT COUNT(*) FROM assets WHERE id LIKE ?1", ["x-assets-%"]},
            {"SELECT COUNT(*) FROM workspace_members WHERE workspace_id = ?1", [ctx.ws]},
            {"SELECT COUNT(*) FROM mcp_tool_definitions WHERE id LIKE ?1", ["x-mcp%-#{ctx.n}"]},
            {"SELECT COUNT(*) FROM storage_provider_configs WHERE id LIKE ?1", ["x-storage%"]}
          ] do
        assert probe_count(sql, params) == 0, sql
      end

      # Not recorded in the ledger either, so nothing forwards them.
      assert probe_count("SELECT COUNT(*) FROM sync_mutations WHERE workspace_id = ?1", [ctx.ws]) ==
               0
    end

    test "paths that reach the disk are confined to the workspace", ctx do
      id = fn name -> "#{name}-#{ctx.n}" end

      bad = [
        {"nodes", %{"id" => id.("n1"), "slug" => "../../etc", "name" => "x", "kind" => "folder"}},
        {"nodes", %{"id" => id.("n2"), "slug" => "/etc/cron.d", "name" => "x", "kind" => "folder"}},
        {"nodes",
         %{"id" => id.("n3"), "slug" => "fine", "path" => "a/../../b", "name" => "x", "kind" => "f"}},
        {"nodes",
         %{"id" => id.("n4"), "slug" => "a" <> <<0>> <> "b", "name" => "x", "kind" => "folder"}},
        {"nodes", %{"id" => id.("n5"), "slug" => "C:\\Windows", "name" => "x", "kind" => "folder"}},
        {"node_types", %{"id" => id.("t1"), "slug" => "../x", "name" => "x"}},
        {"wiki_pages", %{"slug" => "/abs", "body" => "x", "tenant_id" => ctx.tenant}},
        {"contexts", %{"id" => id.("c1"), "path" => "../../etc/passwd"}},
        {"contexts", %{"id" => id.("c2"), "path" => "a/../../b"}},
        {"contexts", %{"id" => id.("c3"), "path" => "x" <> <<0>>}}
      ]

      changes =
        for {table, row} <- bad do
          mutation(ctx, %{
            "entity_type" => table,
            "entity_id" => to_string(row["id"] || row["slug"]),
            "payload" => %{"row" => row, "blobs" => %{}}
          })
        end

      assert {:ok, result} = Sync.apply_changes(ctx.tenant, ctx.ws, changes)
      assert result.applied == 0
      assert Enum.map(result.failed, & &1.reason) == List.duplicate(:invalid_path, length(bad))
      assert probe_count("SELECT COUNT(*) FROM nodes WHERE id LIKE ?1", ["n%-#{ctx.n}"]) == 0
      assert probe_count("SELECT COUNT(*) FROM contexts WHERE id LIKE ?1", ["c_-#{ctx.n}"]) == 0
    end

    test "a relative path applies as it is; an absolute context path names a file elsewhere and is dropped",
         ctx do
      relative =
        mutation(ctx, %{"payload" => context_row("rel-#{ctx.n}", "Relative", ctx.ws, ctx.tenant)})

      with_path = fn id, path ->
        put_in(
          mutation(ctx, %{"payload" => context_row(id, "With a path", ctx.ws, ctx.tenant)}),
          ["payload", "row", "path"],
          path
        )
      end

      node =
        mutation(ctx, %{
          "entity_type" => "nodes",
          "entity_id" => "node-#{ctx.n}",
          "payload" => %{
            "row" => %{
              "id" => "node-#{ctx.n}",
              "slug" => "inbox-#{ctx.n}",
              "name" => "Inbox",
              "kind" => "folder",
              "path" => "nodes/inbox-#{ctx.n}"
            },
            "blobs" => %{}
          }
        })

      assert {:ok, %{applied: 4, failed: []}} =
               Sync.apply_changes(ctx.tenant, ctx.ws, [
                 relative,
                 with_path.("p-rel-#{ctx.n}", "notes/a.md"),
                 with_path.("p-abs-#{ctx.n}", "/Users/someone/notes/a.md"),
                 node
               ])

      assert {:ok, [["notes/a.md"]]} =
               Store.raw_query("SELECT path FROM contexts WHERE id = ?1", ["p-rel-#{ctx.n}"])

      assert {:ok, [[nil]]} =
               Store.raw_query("SELECT path FROM contexts WHERE id = ?1", ["p-abs-#{ctx.n}"])

      assert title("p-abs-#{ctx.n}") == "With a path"

      slug = "inbox-#{ctx.n}"
      path = "nodes/inbox-#{ctx.n}"

      assert {:ok, [[^slug, ^path]]} =
               Store.raw_query("SELECT slug, path FROM nodes WHERE id = ?1", ["node-#{ctx.n}"])
    end

    test "a delete on a table keyed by a row id is refused", ctx do
      :ok =
        OptimalEngine.Graph.assert_edge("DelA-#{ctx.n}", "DelB-#{ctx.n}", "knows",
          workspace_id: ctx.ws
        )

      {:ok, [[edge_id]]} =
        Store.raw_query("SELECT MAX(id) FROM graph_edges WHERE workspace_id = ?1", [ctx.ws])

      delete =
        mutation(ctx, %{
          "entity_type" => "graph_edges",
          "operation" => "delete",
          "entity_id" => "row:1",
          "payload" => %{"row" => %{"id" => edge_id}, "blobs" => %{}}
        })

      assert {:ok, %{applied: 0, failed: [%{reason: :operation_not_supported}]}} =
               Sync.apply_changes(ctx.tenant, ctx.ws, [delete])

      assert probe_count("SELECT COUNT(*) FROM graph_edges WHERE id = ?1", [edge_id]) == 1
    end

    test "a blob named for no column fails that change, not the batch", ctx do
      bad =
        mutation(ctx, %{
          "payload" => %{
            "row" => %{"id" => "blob-#{ctx.n}", "workspace_id" => ctx.ws},
            "blobs" => %{~s(nope" ; x) => "00"}
          }
        })

      good =
        mutation(ctx, %{"payload" => context_row("blob-ok-#{ctx.n}", "Fine", ctx.ws, ctx.tenant)})

      assert {:ok, %{applied: 1, failed: [%{reason: :unknown_columns}]}} =
               Sync.apply_changes(ctx.tenant, ctx.ws, [bad, good])

      assert title("blob-ok-#{ctx.n}") == "Fine"
    end

    test "a change that names a row this Engine lacks fails alone, and the rest of the page applies",
         ctx do
      orphan =
        mutation(ctx, %{
          "entity_type" => "memory_relations",
          "entity_id" => "row:1",
          "payload" => %{
            "row" => %{
              "source_memory_id" => "gone-a-#{ctx.n}",
              "target_memory_id" => "gone-b-#{ctx.n}",
              "relation" => "relates"
            },
            "blobs" => %{}
          }
        })

      good =
        mutation(ctx, %{"payload" => context_row("fk-ok-#{ctx.n}", "Fine", ctx.ws, ctx.tenant)})

      assert {:ok, %{applied: 1, failed: [%{reason: reason}]}} =
               Sync.apply_changes(ctx.tenant, ctx.ws, [orphan, good])

      assert reason =~ "FOREIGN KEY"
      assert title("fk-ok-#{ctx.n}") == "Fine"

      assert probe_count("SELECT COUNT(*) FROM memory_relations WHERE source_memory_id = ?1", [
               "gone-a-#{ctx.n}"
             ]) == 0
    end

    test "the boot purge removes the ledger rows of tables that do not replicate", ctx do
      types = ["api_keys", "workspace_members", "principals", "contexts", "authority_grants"]

      for {type, i} <- Enum.with_index(types) do
        {:ok, _} =
          Store.raw_query(
            """
            INSERT INTO sync_mutations
              (id, tenant_id, workspace_id, device_id, entity_type, entity_id, operation, payload,
               payload_hash, idempotency_key, occurred_at)
            VALUES (?1, ?2, ?3, 'rep_remote', ?4, 'e1', 'create', '{"row":{"id":"e1"},"blobs":{}}', 'h', ?5,
                    '2026-10-14T12:00:00.000')
            """,
            [
              "purge_#{ctx.n}_#{i}",
              ctx.tenant,
              ctx.ws,
              type,
              "purge:#{ctx.n}:#{i}"
            ]
          )
      end

      # The storage replication ledger shares the table; its entity types are
      # free-form and name no table, so its entries are not the purge's.
      assert {:ok, _} =
               OptimalEngine.Storage.PolicyStore.append_mutation(%{
                 workspace_id: ctx.ws,
                 device_id: "device-a",
                 entity_type: "memory_object",
                 entity_id: "entity-#{ctx.n}",
                 operation: :update,
                 payload: %{"field" => "value"}
               })

      assert {:ok, purged} = Sync.purge_unreplicated()
      assert purged["api_keys"] >= 1 and purged["workspace_members"] >= 1
      assert purged["principals"] >= 1 and purged["authority_grants"] >= 1
      refute Map.has_key?(purged, "contexts")
      refute Map.has_key?(purged, "memory_object")

      assert {:ok, rows} =
               Store.raw_query(
                 "SELECT entity_type FROM sync_mutations WHERE workspace_id = ?1 ORDER BY entity_type",
                 [ctx.ws]
               )

      assert rows == [["contexts"], ["memory_object"]]

      assert {:ok, again} = Sync.purge_unreplicated()
      assert again == %{}
    end

    test "a stored role, scope or status never becomes an atom", ctx do
      principal = "principal-#{ctx.n}"

      {:ok, _} =
        Store.raw_query(
          "INSERT INTO principals (id, tenant_id, kind, display_name) VALUES (?1, ?2, 'human', 'P')",
          [principal, ctx.tenant]
        )

      {:ok, _} =
        Store.raw_query(
          "INSERT INTO workspace_members (tenant_id, workspace_id, principal_id, role) VALUES (?1, ?2, ?3, ?4)",
          [ctx.tenant, ctx.ws, principal, "weird-role-#{ctx.n}"]
        )

      assert {:ok, members} = Workspace.members_of(ctx.ws)
      assert {principal, :viewer} in members

      {:ok, _} =
        Store.raw_query(
          """
          INSERT INTO surfacing_subscriptions (id, tenant_id, workspace_id, scope, categories, status)
          VALUES (?1, ?2, ?3, ?4, ?5, ?6)
          """,
          [
            "sub-#{ctx.n}",
            ctx.tenant,
            ctx.ws,
            "weird-scope-#{ctx.n}",
            ~s(["recent_actions", "weird-category-#{ctx.n}"]),
            "weird-status-#{ctx.n}"
          ]
        )

      assert {:ok, [subscription]} =
               OptimalEngine.Memory.Subscription.list(workspace_id: ctx.ws, status: :all)

      assert subscription.scope == :workspace
      assert subscription.status == :paused
      assert subscription.categories == [:recent_actions]

      for name <- ["role", "scope", "category", "status"] do
        assert_raise ArgumentError, fn -> String.to_existing_atom("weird-#{name}-#{ctx.n}") end
      end
    end

    test "a stored signal dimension never becomes an atom", ctx do
      alias OptimalEngine.Signal

      assert Signal.known_atom("code", Signal.valid_modes(), :linguistic) == :code

      assert Signal.known_atom("weird-mode-#{ctx.n}", Signal.valid_modes(), :linguistic) ==
               :linguistic

      assert Signal.known_atom(nil, Signal.valid_types(), :inform) == :inform

      assert_raise ArgumentError, fn -> String.to_existing_atom("weird-mode-#{ctx.n}") end
    end
  end

  describe "over HTTP, with a key that holds only the sync scope" do
    setup ctx do
      {:ok, %{key: key}} =
        OptimalEngine.Auth.ApiKey.mint(%{
          tenant_id: ctx.tenant,
          name: "replica",
          scopes: ["sync"],
          workspace_scope: [ctx.ws]
        })

      {:ok, %{key: reader}} =
        OptimalEngine.Auth.ApiKey.mint(%{
          tenant_id: ctx.tenant,
          name: "reader",
          scopes: ["read"],
          workspace_scope: [ctx.ws]
        })

      %{key: key, reader: reader}
    end

    defp http(method, path, token, body \\ nil) do
      conn =
        if body,
          do:
            Plug.Test.conn(method, path, Jason.encode!(body))
            |> Plug.Conn.put_req_header("content-type", "application/json"),
          else: Plug.Test.conn(method, path)

      conn =
        conn
        |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)
        |> OptimalEngine.API.Router.call(OptimalEngine.API.Router.init([]))

      {conn.status, Jason.decode!(conn.resp_body)}
    end

    test "mutations that are not a list are refused with 422, not a server error", ctx do
      body = %{"workspace" => ctx.ws, "engine" => Sync.engine_info()}

      for mutations <- ["nope", %{"a" => 1}, 7] do
        assert {422, %{"error" => "mutations_required"}} =
                 http(:post, "/api/sync/changes", ctx.key, Map.put(body, "mutations", mutations))
      end

      assert {422, %{"error" => "mutations_required"}} =
               http(:post, "/api/sync/changes", ctx.key, body)
    end

    test "GET /api/sync/tables names what replicates and what stays, from the same list as apply",
         ctx do
      assert {200, body} = http(:get, "/api/sync/tables", ctx.key)
      assert body["replicated"] == Capture.replicated_tables()
      assert body["migration"] == Sync.engine_info()["migration"]

      for table <-
            ~w(workspace_members workspace_handles connectors jobs mcp_tool_definitions
               storage_provider_configs data_collections assets authority_grants) do
        assert table in body["local_only"], "#{table} is not reported local"
      end

      assert MapSet.disjoint?(MapSet.new(body["replicated"]), MapSet.new(body["local_only"]))

      # A key without the sync scope may not read it.
      assert {403, _} = http(:get, "/api/sync/tables", ctx.reader)
    end

    test "a page with allowed, skipped and refused changes answers 200 with the counts", ctx do
      good =
        mutation(ctx, %{"payload" => context_row("http-#{ctx.n}", "Over HTTP", ctx.ws, ctx.tenant)})

      member =
        mutation(ctx, %{
          "entity_type" => "workspace_members",
          "entity_id" => "row:1",
          "payload" => %{
            "row" => %{"principal_id" => "someone", "role" => "owner"},
            "blobs" => %{}
          }
        })

      key =
        mutation(ctx, %{
          "entity_type" => "api_keys",
          "entity_id" => "key-#{ctx.n}",
          "payload" => %{
            "row" => %{
              "id" => "key-#{ctx.n}",
              "tenant_id" => ctx.tenant,
              "hashed_secret" => "x",
              "prefix" => "evil",
              "name" => "root",
              "scopes" => ~s(["*"])
            },
            "blobs" => %{}
          }
        })

      orphan =
        mutation(ctx, %{
          "entity_type" => "memory_relations",
          "entity_id" => "row:2",
          "payload" => %{
            "row" => %{
              "source_memory_id" => "gone-#{ctx.n}",
              "target_memory_id" => "gone-too-#{ctx.n}",
              "relation" => "relates"
            },
            "blobs" => %{}
          }
        })

      late =
        mutation(ctx, %{
          "occurred_at" => nil,
          "payload" => context_row("late-#{ctx.n}", "x", ctx.ws, ctx.tenant)
        })

      body = %{
        "workspace" => ctx.ws,
        "engine" => Sync.engine_info(),
        "replica_id" => "rep_remote",
        "mutations" => [member, good, key, orphan, late]
      }

      assert {200, reply} = http(:post, "/api/sync/changes", ctx.key, body)
      assert reply["applied"] == 1
      assert reply["skipped"] == %{"local_only" => 1}

      reasons = Enum.map(reply["failed"], & &1["reason"])
      assert "table_not_replicated" in reasons
      assert "invalid_occurred_at" in reasons
      assert Enum.any?(reasons, &(&1 =~ "FOREIGN KEY"))
      assert length(reasons) == 3

      assert title("http-#{ctx.n}") == "Over HTTP"
      assert probe_count("SELECT COUNT(*) FROM api_keys WHERE id = ?1", ["key-#{ctx.n}"]) == 0
    end
  end

  describe "causality: what the sender had seen decides, the clock only breaks a tie" do
    defp ledger_seq(id) do
      {:ok, [[sequence]]} =
        Store.raw_query("SELECT sequence FROM sync_mutations WHERE id = ?1", [id])

      sequence
    end

    defp pushed_from(ctx, device, attrs) do
      mutation(ctx, Map.merge(%{"device_id" => device}, attrs))
    end

    test "equal times are broken by device id, the same way on both Engines", ctx do
      local = Sync.replica_id()

      for {label, device, remote_wins} <- [
            {"greater", "rep_~~~~", true},
            {"smaller", "rep_!", false}
          ] do
        id = "tie-#{label}-#{ctx.n}"
        insert_context(ctx.tenant, ctx.ws, id, "Written here")
        _ = local_seq(ctx, "contexts", id)

        {:ok, [[at]]} =
          Store.raw_query(
            "SELECT occurred_at FROM sync_mutations WHERE entity_id = ?1 AND device_id = ?2",
            [id, local]
          )

        edit =
          pushed_from(ctx, device, %{
            "operation" => "update",
            "occurred_at" => at,
            "payload" => context_row(id, "Same instant from #{label}", ctx.ws, ctx.tenant)
          })

        assert {:ok, %{conflicts: 1} = result} =
                 Sync.apply_changes(ctx.tenant, ctx.ws, [edit], base_seq: 0)

        assert result.applied == if(remote_wins, do: 1, else: 0)
        assert title(id) == if(remote_wins, do: "Same instant from #{label}", else: "Written here")
      end
    end

    test "a delete says nothing of the row: an older delete does not beat a newer update here",
         ctx do
      id = "del-#{ctx.n}"
      insert_context(ctx.tenant, ctx.ws, id, "Written here")
      {:ok, _} = Store.raw_query("UPDATE contexts SET title = 'Updated here' WHERE id = ?1", [id])
      _ = local_seq(ctx, "contexts", id)

      older_delete =
        mutation(ctx, %{
          "operation" => "delete",
          "entity_id" => id,
          "occurred_at" => "2000-01-01T00:00:00.000",
          "payload" => %{"row" => %{"id" => id}, "blobs" => %{}}
        })

      assert {:ok, %{applied: 0, conflicts: 1}} =
               Sync.apply_changes(ctx.tenant, ctx.ws, [older_delete], base_seq: 0)

      assert title(id) == "Updated here"

      assert [%{kind: "concurrent_edit", resolution: "kept_local_newer"}] =
               Sync.conflicts(ctx.tenant, ctx.ws)
    end

    test "a delete is the same change only as another delete", ctx do
      gone = "del-gone-#{ctx.n}"
      insert_context(ctx.tenant, ctx.ws, gone, "Written here")
      {:ok, _} = Store.raw_query("DELETE FROM contexts WHERE id = ?1", [gone])
      _ = local_seq(ctx, "contexts", gone)

      delete = fn id ->
        mutation(ctx, %{
          "operation" => "delete",
          "entity_id" => id,
          "occurred_at" => "2000-01-01T00:00:00.000",
          "payload" => %{"row" => %{"id" => id}, "blobs" => %{}}
        })
      end

      assert {:ok, %{applied: 1, conflicts: 0}} =
               Sync.apply_changes(ctx.tenant, ctx.ws, [delete.(gone)], base_seq: 0)

      # An older update over a newer delete here is a conflict, and the delete stands.
      deleted = "del-kept-#{ctx.n}"
      insert_context(ctx.tenant, ctx.ws, deleted, "Written here")
      {:ok, _} = Store.raw_query("DELETE FROM contexts WHERE id = ?1", [deleted])
      _ = local_seq(ctx, "contexts", deleted)

      update =
        mutation(ctx, %{
          "operation" => "update",
          "occurred_at" => "2000-01-01T00:00:00.000",
          "payload" => context_row(deleted, "Back from the dead", ctx.ws, ctx.tenant)
        })

      assert {:ok, %{applied: 0, conflicts: 1}} =
               Sync.apply_changes(ctx.tenant, ctx.ws, [update], base_seq: 0)

      assert {:ok, []} = Store.raw_query("SELECT 1 FROM contexts WHERE id = ?1", [deleted])
    end

    test "a change from a third replica counts, the sender's own earlier changes do not", ctx do
      id = "three-#{ctx.n}"

      from_c =
        pushed_from(ctx, "rep_c", %{
          "occurred_at" => "2026-10-14T12:00:00.000",
          "payload" => context_row(id, "C's version", ctx.ws, ctx.tenant)
        })

      assert {:ok, %{applied: 1}} =
               Sync.apply_changes(ctx.tenant, ctx.ws, [from_c], sender: "rep_c")

      c_seq = ledger_seq(from_c["id"])
      here = Sync.replica_id()

      older_from_a =
        pushed_from(ctx, "rep_a", %{
          "operation" => "update",
          "occurred_at" => "2000-01-01T00:00:00.000",
          "payload" => context_row(id, "A's older version", ctx.ws, ctx.tenant)
        })

      # A had pulled up to just before C's change: concurrent, C's is newer, A's is not taken.
      push = fn mutation, base ->
        Sync.apply_changes(ctx.tenant, ctx.ws, [mutation],
          sender: "rep_a",
          base_seq: base,
          base_replica_id: here
        )
      end

      assert {:ok, %{applied: 0, conflicts: 1}} = push.(older_from_a, c_seq - 1)
      assert title(id) == "C's version"

      assert [%{kind: "concurrent_edit", resolution: "kept_local_newer", detail: detail}] =
               Sync.conflicts(ctx.tenant, ctx.ws)

      assert %{"local_device" => "rep_c", "local_seq" => ^c_seq} = detail

      # Not taken, so not in the ledger: a hub does not forward it, and a repeat
      # is judged again but recorded once.
      refute older_from_a["id"] in Enum.map(
               Sync.changes(ctx.tenant, ctx.ws)["mutations"],
               & &1["id"]
             )

      assert {:ok, [[0]]} =
               Store.raw_query("SELECT COUNT(*) FROM sync_mutations WHERE id = ?1", [
                 older_from_a["id"]
               ])

      assert {:ok, %{applied: 0, conflicts: 1}} = push.(older_from_a, c_seq - 1)
      assert length(Sync.conflicts(ctx.tenant, ctx.ws)) == 1

      # A had seen C's change: its edit follows C's whatever its clock says.
      seen = push.(older_from_a, c_seq)
      assert {:ok, %{applied: 1, conflicts: 0}} = seen
      assert title(id) == "A's older version"

      # The sender's own earlier change is ordered by its ledger, never a conflict.
      own = "own-#{ctx.n}"

      first =
        pushed_from(ctx, "rep_a", %{
          "occurred_at" => "2026-10-14T12:00:00.000",
          "payload" => context_row(own, "A, first", ctx.ws, ctx.tenant)
        })

      second =
        pushed_from(ctx, "rep_a", %{
          "operation" => "update",
          "occurred_at" => "1999-01-01T00:00:00.000",
          "payload" => context_row(own, "A, once more", ctx.ws, ctx.tenant)
        })

      assert {:ok, %{applied: 1, conflicts: 0}} = push.(first, 0)
      assert {:ok, %{applied: 1, conflicts: 0}} = push.(second, 0)
      assert title(own) == "A, once more"
    end

    test "a base from another ledger is no base", ctx do
      id = "foreign-#{ctx.n}"
      insert_context(ctx.tenant, ctx.ws, id, "Written here")
      seen = local_seq(ctx, "contexts", id)
      here = Sync.replica_id()

      edit = fn ->
        mutation(ctx, %{
          "operation" => "update",
          "occurred_at" => "2999-01-01T00:00:00.000",
          "payload" => context_row(id, "Pushed", ctx.ws, ctx.tenant)
        })
      end

      head = Sync.status(ctx.tenant, ctx.ws).ledger_sequence

      for {opts, rejected} <- [
            {[base_seq: head + 1, base_replica_id: here], "above_head"},
            {[base_seq: seen, base_replica_id: "rep_other"], "replica_mismatch"},
            {[base_seq: seen], "replica_mismatch"}
          ] do
        assert {:ok, %{base: "unknown", base_rejected: ^rejected, conflicts: 1}} =
                 Sync.apply_changes(ctx.tenant, ctx.ws, [edit.()], opts)
      end

      assert {:ok, %{base: "floor"}} = Sync.apply_changes(ctx.tenant, ctx.ws, [], local_floor: 0)

      assert {:ok, %{base: "unknown"} = bare} = Sync.apply_changes(ctx.tenant, ctx.ws, [])
      refute Map.has_key?(bare, :base_rejected)
    end

    test "seal works through a backlog larger than one batch", ctx do
      {:ok, _} = Capture.seal()

      # More rows than one batch (5000), written by one statement.
      {:ok, _} =
        Store.raw_query(
          """
          WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 5100)
          INSERT INTO contexts (id, tenant_id, workspace_id, title, content, created_at)
          SELECT ?1 || i, ?2, ?3, 'Bulk', 'body', '2026-10-14T10:00:00Z' FROM n
          """,
          ["bulk-#{ctx.n}-", ctx.tenant, ctx.ws]
        )

      assert probe_count("SELECT COUNT(*) FROM sync_capture WHERE workspace_id = ?1", [ctx.ws]) ==
               5100

      assert {:ok, sealed} = Capture.seal()
      assert sealed >= 5100
      assert probe_count("SELECT COUNT(*) FROM sync_capture WHERE workspace_id = ?1", [ctx.ws]) == 0

      assert probe_count(
               "SELECT COUNT(*) FROM sync_mutations WHERE workspace_id = ?1 AND entity_type = 'contexts'",
               [ctx.ws]
             ) == 5100
    end
  end

  describe "what a sender names is checked against the row and the scope" do
    defp other_workspace(ctx, slug) do
      {:ok, other} =
        Workspace.create(%{
          tenant_id: ctx.tenant,
          organization_id: "#{ctx.tenant}:org",
          slug: slug,
          name: slug
        })

      {:ok, _} = Sync.enable(ctx.tenant, other.id, "user:owner")
      other.id
    end

    test "a mutation id another workspace used is refused, and a repeat in its own is skipped",
         ctx do
      other = other_workspace(ctx, "other")
      shared = "mut_shared_#{ctx.n}"

      first =
        mutation(ctx, %{
          "id" => shared,
          "payload" => context_row("in-a-#{ctx.n}", "In A", ctx.ws, ctx.tenant)
        })

      assert {:ok, %{applied: 1}} = Sync.apply_changes(ctx.tenant, ctx.ws, [first])

      assert {:ok, %{applied: 0, skipped: %{duplicate: 1}}} =
               Sync.apply_changes(ctx.tenant, ctx.ws, [first])

      second =
        mutation(ctx, %{
          "id" => shared,
          "payload" => context_row("in-b-#{ctx.n}", "In B", other, ctx.tenant)
        })

      assert {:ok, %{applied: 0, skipped: skipped, failed: [failure]}} =
               Sync.apply_changes(ctx.tenant, other, [second])

      assert skipped == %{}
      assert failure == %{id: shared, reason: :mutation_id_in_use}
      assert probe_count("SELECT COUNT(*) FROM contexts WHERE id = ?1", ["in-b-#{ctx.n}"]) == 0
    end

    test "a conflict is recorded in each workspace when the same mutation id is judged in both",
         ctx do
      other = other_workspace(ctx, "another")
      shared = "mut_conflicting_#{ctx.n}"

      for {ws, id} <- [{ctx.ws, "row-a-#{ctx.n}"}, {other, "row-b-#{ctx.n}"}] do
        insert_context(ctx.tenant, ws, id, "Written here")

        old =
          mutation(ctx, %{
            "id" => shared,
            "operation" => "update",
            "occurred_at" => "2000-01-01T00:00:00.000",
            "payload" => context_row(id, "Old", ws, ctx.tenant)
          })

        # Not taken, so not in the ledger: only the conflict row could be lost.
        assert {:ok, %{applied: 0, conflicts: 1}} = Sync.apply_changes(ctx.tenant, ws, [old])
      end

      assert [%{entity_key: "row-a-" <> _}] = Sync.conflicts(ctx.tenant, ctx.ws)
      assert [%{entity_key: "row-b-" <> _}] = Sync.conflicts(ctx.tenant, other)
    end

    test "the row's key comes from its payload, not from the entity_id the sender names", ctx do
      id = "keyed-#{ctx.n}"
      insert_context(ctx.tenant, ctx.ws, id, "Written here")

      named = fn at ->
        mutation(ctx, %{
          "entity_id" => "something-else",
          "operation" => "update",
          "occurred_at" => at,
          "payload" => context_row(id, "Pushed", ctx.ws, ctx.tenant)
        })
      end

      # Named after another row, it would escape the check on this one.
      assert {:ok, %{applied: 0, conflicts: 1}} =
               Sync.apply_changes(ctx.tenant, ctx.ws, [named.("2000-01-01T00:00:00.000")])

      assert title(id) == "Written here"

      newer = named.("2999-01-01T00:00:00.000")
      assert {:ok, %{applied: 1, conflicts: 1}} = Sync.apply_changes(ctx.tenant, ctx.ws, [newer])
      assert title(id) == "Pushed"

      assert {:ok, [[^id]]} =
               Store.raw_query("SELECT entity_id FROM sync_mutations WHERE id = ?1", [newer["id"]])
    end

    test "a sender that names this Engine does not take its changes out of the check", ctx do
      id = "own-sender-#{ctx.n}"
      insert_context(ctx.tenant, ctx.ws, id, "Written here")

      old =
        mutation(ctx, %{
          "operation" => "update",
          "occurred_at" => "2000-01-01T00:00:00.000",
          "payload" => context_row(id, "Pushed", ctx.ws, ctx.tenant)
        })

      assert {:ok, %{applied: 0, conflicts: 1}} =
               Sync.apply_changes(ctx.tenant, ctx.ws, [old], sender: Sync.replica_id())

      assert title(id) == "Written here"
    end

    test "changes at or below the floor were seen by the peer, the clock does not decide", ctx do
      seen = "floor-seen-#{ctx.n}"
      unseen = "floor-unseen-#{ctx.n}"
      insert_context(ctx.tenant, ctx.ws, seen, "Written here")
      floor = local_seq(ctx, "contexts", seen)
      insert_context(ctx.tenant, ctx.ws, unseen, "Written here")

      # The peer's clock is far behind ours, as under skew.
      pulled = fn id ->
        mutation(ctx, %{
          "device_id" => "rep_remote",
          "operation" => "update",
          "occurred_at" => "2000-01-01T00:00:00.000",
          "payload" => context_row(id, "Peer's", ctx.ws, ctx.tenant)
        })
      end

      assert {:ok, %{applied: 1, conflicts: 1, base: "floor"}} =
               Sync.apply_changes(ctx.tenant, ctx.ws, [pulled.(seen), pulled.(unseen)],
                 local_floor: floor,
                 direction: :pull
               )

      assert title(seen) == "Peer's"
      assert title(unseen) == "Written here"

      assert [%{entity_key: ^unseen, detail: %{"local_floor" => ^floor}}] =
               Sync.conflicts(ctx.tenant, ctx.ws)
    end

    test "an id from this Engine's own id space is refused, and its next local change still seals",
         ctx do
      local = Sync.replica_id()

      {:ok, [[next]]} =
        Store.raw_query(
          "SELECT COALESCE((SELECT seq FROM sqlite_sequence WHERE name = 'sync_capture'), 0) + 1",
          []
        )

      # What a peer would send to take the ids of the changes this Engine makes next.
      spoofs =
        for seq <- next..(next + 5) do
          mutation(ctx, %{
            "id" => "mut_#{local}_#{seq}",
            "payload" => context_row("spoof-#{seq}-#{ctx.n}", "Spoofed", ctx.ws, ctx.tenant)
          })
        end

      assert {:ok, %{applied: 0, failed: failed}} = Sync.apply_changes(ctx.tenant, ctx.ws, spoofs)
      assert Enum.map(failed, & &1.reason) == List.duplicate(:mutation_id_in_use, 6)

      insert_context(ctx.tenant, ctx.ws, "mine-#{ctx.n}", "Mine")
      {:ok, _} = Capture.seal()

      assert {:ok, [[^local]]} =
               Store.raw_query(
                 "SELECT device_id FROM sync_mutations WHERE entity_type = 'contexts' AND entity_id = ?1",
                 ["mine-#{ctx.n}"]
               )

      keyed =
        mutation(ctx, %{
          "idempotency_key" => "#{local}:99",
          "payload" => context_row("keyed-#{ctx.n}", "Keyed", ctx.ws, ctx.tenant)
        })

      assert {:ok, %{applied: 0, failed: [%{reason: :mutation_id_in_use}]}} =
               Sync.apply_changes(ctx.tenant, ctx.ws, [keyed])
    end

    test "an id shaped like this Engine's next capture key is refused, and the local change it would shadow still seals",
         ctx do
      local = Sync.replica_id()

      {:ok, [[next]]} =
        Store.raw_query(
          "SELECT COALESCE((SELECT seq FROM sqlite_sequence WHERE name = 'sync_capture'), 0) + 1",
          []
        )

      # `<replica>:<capture sequence>` is the key `Capture.seal/0` gives this
      # Engine's next changes; as an id, the ledger would have stored it as the key.
      spoofs =
        for seq <- next..(next + 5) do
          mutation(ctx, %{
            "id" => "#{local}:#{seq}",
            "idempotency_key" => "harmless-#{seq}-#{ctx.n}",
            "payload" => context_row("shadow-#{seq}-#{ctx.n}", "Shadow", ctx.ws, ctx.tenant)
          })
        end

      assert {:ok, %{applied: 0, failed: failed}} = Sync.apply_changes(ctx.tenant, ctx.ws, spoofs)
      assert Enum.map(failed, & &1.reason) == List.duplicate(:mutation_id_in_use, 6)

      insert_context(ctx.tenant, ctx.ws, "unshadowed-#{ctx.n}", "Mine")
      {:ok, _} = Capture.seal()

      assert {:ok, [[^local, key]]} =
               Store.raw_query(
                 "SELECT device_id, idempotency_key FROM sync_mutations WHERE entity_type = 'contexts' AND entity_id = ?1",
                 ["unshadowed-#{ctx.n}"]
               )

      assert String.starts_with?(key, local <> ":")

      assert "unshadowed-#{ctx.n}" in Enum.map(
               Sync.changes(ctx.tenant, ctx.ws)["mutations"],
               & &1["entity_id"]
             )

      # Any id with a colon is in the shape of some replica's capture keys.
      other =
        mutation(ctx, %{
          "id" => "rep_other:#{ctx.n}",
          "payload" => context_row("colon-#{ctx.n}", "x", ctx.ws, ctx.tenant)
        })

      assert {:ok, %{applied: 0, failed: [%{reason: :invalid_mutation_id}]}} =
               Sync.apply_changes(ctx.tenant, ctx.ws, [other])
    end

    test "the key and the hash of a change in the ledger are this Engine's, not the sender's",
         ctx do
      lie = fn id, key ->
        mutation(ctx, %{
          "payload_hash" => "not-the-hash",
          "idempotency_key" => key,
          "payload" => context_row(id, "Claimed", ctx.ws, ctx.tenant)
        })
      end

      first = lie.("lie-a-#{ctx.n}", "claimed-key-#{ctx.n}")
      second = lie.("lie-b-#{ctx.n}", "claimed-key-#{ctx.n}")

      # The same key claimed twice: not a duplicate, because the key is not stored.
      assert {:ok, %{applied: 2, failed: []}} =
               Sync.apply_changes(ctx.tenant, ctx.ws, [first, second])

      assert {:ok, [[hash, key, payload]]} =
               Store.raw_query(
                 "SELECT payload_hash, idempotency_key, payload FROM sync_mutations WHERE id = ?1",
                 [first["id"]]
               )

      assert key == "peer:" <> first["id"]
      assert hash == :crypto.hash(:sha256, payload) |> Base.encode16(case: :lower)

      numeric =
        mutation(ctx, %{
          "idempotency_key" => 5,
          "payload" => context_row("num-#{ctx.n}", "x", ctx.ws, ctx.tenant)
        })

      assert {:ok, %{applied: 0, failed: [%{reason: :invalid_mutation}]}} =
               Sync.apply_changes(ctx.tenant, ctx.ws, [numeric])
    end

    test "the key capture gives a row is the key computed from its values, for every replicated table" do
      sample = fn
        %{type: "INTEGER"}, i -> 40 + i
        %{type: "REAL"}, i -> 1.5 + i
        %{name: name}, i -> "k#{i}/ü \"q\" \\ \t #{name}"
      end

      for table <- Capture.replicated_tables() do
        columns = Capture.columns(table)
        keys = Capture.key_columns(columns)

        unless keys == [] or Capture.rowid_key?(columns) do
          key_columns = for name <- keys, do: Enum.find(columns, &(&1.name == name))

          values =
            key_columns |> Enum.with_index(1) |> Enum.map(fn {column, i} -> sample.(column, i) end)

          selected =
            key_columns
            |> Enum.with_index(1)
            |> Enum.map_join(", ", fn {column, i} -> ~s(?#{i} AS "#{column.name}") end)

          {:ok, [[sqlite_key]]} =
            Store.raw_query(
              "SELECT #{Capture.key_expr(keys, "r", false)} FROM (SELECT #{selected}) r",
              values
            )

          row = keys |> Enum.zip(values) |> Map.new()

          assert Sync.entity_key(keys, row) == sqlite_key,
                 "#{table}: capture writes #{inspect(sqlite_key)}, the payload gives #{inspect(Sync.entity_key(keys, row))}"
        end
      end
    end

    test "the schema version a pushed page reports is the highest migration, whatever order they are listed in" do
      highest = OptimalEngine.Store.Migrations.all() |> Enum.map(&elem(&1, 0)) |> Enum.max()
      assert Sync.engine_info()["migration"] == highest
    end
  end

  describe "tables that belong to one Engine" do
    test "writes to them are not captured, and a trigger an earlier version left is removed",
         ctx do
      {:ok, _} = Capture.seal()

      # What an Engine before this change had installed on the table.
      {:ok, _} =
        Store.raw_query(
          """
          CREATE TRIGGER IF NOT EXISTS sync_capture_ai_jobs AFTER INSERT ON jobs
          BEGIN
            INSERT INTO sync_capture (table_name, operation, workspace_id, entity_key, row_data)
            VALUES ('jobs', 'create', NEW.workspace_id, NEW.id, json_object('id', NEW.id));
          END
          """,
          []
        )

      on_exit(fn -> Store.raw_query("DROP TRIGGER IF EXISTS sync_capture_ai_jobs", []) end)

      insert_job = fn id ->
        {:ok, _} =
          Store.raw_query(
            "INSERT INTO jobs (id, tenant_id, workspace_id, kind, status) VALUES (?1, ?2, ?3, 'noop', 'completed')",
            [id, ctx.tenant, ctx.ws]
          )
      end

      insert_job.("job-old-#{ctx.n}")
      assert probe_count("SELECT COUNT(*) FROM sync_capture WHERE table_name = 'jobs'", []) >= 1

      # The old trigger's capture is dropped at seal, not sealed into the ledger.
      assert {:ok, _} = Capture.seal()
      assert probe_count("SELECT COUNT(*) FROM sync_capture WHERE table_name = 'jobs'", []) == 0

      assert probe_count(
               "SELECT COUNT(*) FROM sync_mutations WHERE workspace_id = ?1 AND entity_type = 'jobs'",
               [ctx.ws]
             ) == 0

      assert {:ok, _} = Capture.install()

      assert probe_count(
               "SELECT COUNT(*) FROM sqlite_master WHERE type = 'trigger' AND name LIKE 'sync_capture_%' AND tbl_name IN ('jobs', 'dead_letter_jobs', 'connectors')",
               []
             ) == 0

      insert_job.("job-new-#{ctx.n}")
      assert probe_count("SELECT COUNT(*) FROM sync_capture WHERE table_name = 'jobs'", []) == 0

      assert Enum.all?(
               Sync.changes(ctx.tenant, ctx.ws)["mutations"],
               &(&1["entity_type"] != "jobs")
             )
    end

    test "ledger rows written for them before this change are not served", ctx do
      for {type, i} <-
            Enum.with_index([
              "connectors",
              "jobs",
              "authority_grants",
              "api_keys",
              "workspace_members",
              "contexts"
            ]) do
        {:ok, _} =
          Store.raw_query(
            """
            INSERT INTO sync_mutations
              (id, tenant_id, workspace_id, device_id, entity_type, entity_id, operation, payload,
               payload_hash, idempotency_key, occurred_at)
            VALUES (?1, ?2, ?3, ?4, ?5, 'e1', 'create', '{"row":{"id":"e1"},"blobs":{}}', 'h', ?6,
                    '2026-10-14T12:00:00.000')
            """,
            # Captured by an earlier version: a capture id and key, far past any
            # sequence this test's own changes take.
            [
              "mut_#{Sync.replica_id()}_#{900_000_000 + ctx.n * 10 + i}",
              ctx.tenant,
              ctx.ws,
              Sync.replica_id(),
              type,
              "#{Sync.replica_id()}:#{900_000_000 + ctx.n * 10 + i}"
            ]
          )
      end

      types = Sync.changes(ctx.tenant, ctx.ws)["mutations"] |> Enum.map(& &1["entity_type"])
      assert types == ["contexts"]
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

    test "ledger rows for tables that belong to one Engine are never pushed", ctx do
      sent = :ets.new(:sent, [:public])

      Application.put_env(:optimal_engine, :http_mock, fn _url, opts ->
        :ets.insert(sent, {:body, opts[:body]})
        respond(200, %{"applied" => length(opts[:body]["mutations"])})
      end)

      {:ok, _} =
        Sync.add_peer(
          ctx.tenant,
          %{
            "workspace_id" => ctx.ws,
            "url" => "https://cloud.example",
            "api_key" => "replica-key",
            "policy" => "push"
          },
          "u"
        )

      {:ok, _} =
        Store.raw_query(
          """
          INSERT INTO sync_mutations
            (id, tenant_id, workspace_id, device_id, entity_type, entity_id, operation, payload,
             payload_hash, idempotency_key, occurred_at)
          VALUES (?1, ?2, ?3, ?4, 'connectors', 'c1', 'create', '{"row":{"id":"c1"},"blobs":{}}', 'h', ?5,
                  '2026-10-14T12:00:00.000')
          """,
          ["legacy_#{ctx.n}", ctx.tenant, ctx.ws, Sync.replica_id(), "legacy:#{ctx.n}"]
        )

      insert_context(ctx.tenant, ctx.ws, "pushed-#{ctx.n}", "Goes")
      assert [%{pending_push: 1}] = Sync.status(ctx.tenant, ctx.ws).peers

      [result] = Sync.run_all() |> Enum.filter(&(&1.workspace_id == ctx.ws))
      assert result.status == "active"

      [{:body, body}] = :ets.lookup(sent, :body)
      assert Enum.map(body["mutations"], & &1["entity_type"]) == ["contexts"]
      assert [%{pending_push: 0}] = Sync.status(ctx.tenant, ctx.ws).peers
    end

    test "a change this Engine lost to the peer's is not pushed, one it won is", ctx do
      sent = :ets.new(:sent, [:public, :ordered_set])

      Application.put_env(:optimal_engine, :http_mock, fn _url, opts ->
        :ets.insert(sent, {System.unique_integer([:monotonic]), opts[:body]})
        respond(200, %{"applied" => length(opts[:body]["mutations"])})
      end)

      {:ok, _} =
        Sync.add_peer(
          ctx.tenant,
          %{
            "workspace_id" => ctx.ws,
            "url" => "https://cloud.example",
            "api_key" => "replica-key",
            "policy" => "push"
          },
          "u"
        )

      {:ok, _} =
        Store.raw_query(
          "UPDATE sync_peers SET peer_replica_id = 'rep_cloud' WHERE workspace_id = ?1",
          [ctx.ws]
        )

      lost = "lost-#{ctx.n}"
      won = "won-#{ctx.n}"
      insert_context(ctx.tenant, ctx.ws, lost, "Written here")
      insert_context(ctx.tenant, ctx.ws, won, "Written here")
      _ = local_seq(ctx, "contexts", won)

      # The peer changed both while apart: its change to one is newer than ours, to the other older.
      newer =
        mutation(ctx, %{
          "device_id" => "rep_cloud",
          "operation" => "update",
          "occurred_at" => "2999-01-01T00:00:00.000",
          "payload" => context_row(lost, "Peer's, newer", ctx.ws, ctx.tenant)
        })

      older =
        mutation(ctx, %{
          "device_id" => "rep_cloud",
          "operation" => "update",
          "occurred_at" => "2000-01-01T00:00:00.000",
          "payload" => context_row(won, "Peer's, older", ctx.ws, ctx.tenant)
        })

      assert {:ok, %{applied: 1, conflicts: 2}} =
               Sync.apply_changes(ctx.tenant, ctx.ws, [newer, older],
                 local_floor: 0,
                 direction: :pull
               )

      assert title(lost) == "Peer's, newer"
      assert title(won) == "Written here"

      # What the peer holds already wins for the first; the second is ours to send.
      assert [%{pending_push: 1}] = Sync.status(ctx.tenant, ctx.ws).peers

      [result] = Sync.run_all() |> Enum.filter(&(&1.workspace_id == ctx.ws))
      assert {:ok, %{sent: 1, superseded: 1}} = result.push

      [{_, body}] = :ets.tab2list(sent)
      assert Enum.map(body["mutations"], & &1["entity_id"]) == [won]
      assert [%{pending_push: 0}] = Sync.status(ctx.tenant, ctx.ws).peers

      # The change that was not sent leaves a record that it lost, once, and it is
      # not an open conflict.
      assert [
               %{resolution: "not_sent_peer_has_newer", state: "resolved", entity_key: ^lost} =
                 record
             ] =
               ctx.tenant
               |> Sync.conflicts(ctx.ws, "all")
               |> Enum.filter(&(&1.kind == "superseded"))

      assert %{"later_device" => "rep_cloud"} = record.detail
    end

    test "last_sync_at moves only when a pull reached the end of the peer's ledger", ctx do
      engine = Sync.engine_info() |> Map.put("replica_id", "rep_cloud")
      state = :ets.new(:pull_state, [:public])
      :ets.insert(state, {:more, true})

      Application.put_env(:optimal_engine, :http_mock, fn _url, _opts ->
        [{:more, more}] = :ets.lookup(state, :more)

        respond(200, %{
          "mutations" => [],
          "cursor" => if(more, do: 10, else: 11),
          "more" => more,
          "engine" => engine
        })
      end)

      {:ok, _} =
        Sync.add_peer(
          ctx.tenant,
          %{
            "workspace_id" => ctx.ws,
            "url" => "https://cloud.example",
            "api_key" => "replica-key",
            "policy" => "pull"
          },
          "u"
        )

      last_sync = fn ->
        {:ok, [[at]]} =
          Store.raw_query("SELECT last_sync_at FROM sync_peers WHERE workspace_id = ?1", [ctx.ws])

        at
      end

      # The page budget is spent after one page that says there is more.
      Application.put_env(:optimal_engine, :sync_cycle_budget_ms, 0)
      [first] = Sync.run_all() |> Enum.filter(&(&1.workspace_id == ctx.ws))
      assert first.status == "active"
      assert {:ok, %{more: true, cursor: 10}} = first.pull
      assert last_sync.() == nil

      Application.delete_env(:optimal_engine, :sync_cycle_budget_ms)
      :ets.insert(state, {:more, false})
      [second] = Sync.run_all() |> Enum.filter(&(&1.workspace_id == ctx.ws))
      assert {:ok, %{more: false, cursor: 11}} = second.pull
      assert is_binary(last_sync.())
    end

    test "a peer that answers as another replica gets both cursors reset and is pulled from the start",
         ctx do
      requests = :ets.new(:requests, [:public, :ordered_set])
      state = :ets.new(:replica_state, [:public])
      :ets.insert(state, {:replica, "rep_one"})

      Application.put_env(:optimal_engine, :http_mock, fn url, _opts ->
        since = url |> URI.parse() |> Map.get(:query) |> URI.decode_query() |> Map.get("since")
        :ets.insert(requests, {System.unique_integer([:monotonic]), since})
        [{:replica, replica}] = :ets.lookup(state, :replica)
        engine = Sync.engine_info() |> Map.put("replica_id", replica)

        respond(200, %{
          "mutations" => [],
          "cursor" => if(since == "0", do: 5, else: 50),
          "more" => false,
          "engine" => engine
        })
      end)

      {:ok, _} =
        Sync.add_peer(
          ctx.tenant,
          %{
            "workspace_id" => ctx.ws,
            "url" => "https://cloud.example",
            "api_key" => "replica-key",
            "policy" => "pull",
            "since" => 41
          },
          "u"
        )

      peer = fn -> hd(Sync.peers(ctx.tenant, ctx.ws)) end
      Sync.run_all()
      assert %{peer_replica_id: "rep_one", last_pulled_seq: 50} = peer.()

      {:ok, _} =
        Store.raw_query("UPDATE sync_peers SET last_pushed_seq = 77 WHERE workspace_id = ?1", [
          ctx.ws
        ])

      # The Engine behind the URL was replaced: its sequences are another ledger's.
      :ets.insert(state, {:replica, "rep_two"})
      [result] = Sync.run_all() |> Enum.filter(&(&1.workspace_id == ctx.ws))
      assert result.status == "active"
      assert %{peer_replica_id: "rep_two", last_pulled_seq: 5, last_pushed_seq: 0} = peer.()

      assert for({_, since} <- :ets.tab2list(requests), do: since) == ["41", "50", "0"]

      assert [
               %{
                 kind: "peer_replaced",
                 resolution: "cursors_reset",
                 state: "resolved",
                 remote_device: "rep_two",
                 detail: %{
                   "previous_replica_id" => "rep_one",
                   "previous_pulled_seq" => 50,
                   "previous_pushed_seq" => 77
                 }
               }
             ] = Sync.conflicts(ctx.tenant, ctx.ws, "all")

      # It is not an open conflict.
      assert Sync.status(ctx.tenant, ctx.ws).open_conflicts == 0
    end

    test "a peer whose replica id keeps changing is reset once in a run, then reported", ctx do
      requests = :ets.new(:requests, [:public, :ordered_set])
      turn = :ets.new(:turn, [:public])
      :ets.insert(turn, {:n, 0})

      # Two Engines behind one URL: every answer names the other one.
      Application.put_env(:optimal_engine, :http_mock, fn url, _opts ->
        since = url |> URI.parse() |> Map.get(:query) |> URI.decode_query() |> Map.get("since")
        :ets.insert(requests, {System.unique_integer([:monotonic]), since})
        replica = if rem(:ets.update_counter(turn, :n, 1), 2) == 1, do: "rep_b", else: "rep_a"
        engine = Sync.engine_info() |> Map.put("replica_id", replica)
        respond(200, %{"mutations" => [], "cursor" => 5, "more" => false, "engine" => engine})
      end)

      add_pull_peer(ctx, since: 9, replica: "rep_a")
      [result] = Sync.run_all() |> Enum.filter(&(&1.workspace_id == ctx.ws))

      # The first change of identity resets the cursors; the second, in the same
      # run, is not followed: two requests and an error, not a loop.
      assert result.status == "error"
      assert {:error, :peer_identity_unstable} = result.pull
      assert for({_, since} <- :ets.tab2list(requests), do: since) == ["9", "0"]
      assert [%{kind: "peer_replaced"}] = Sync.conflicts(ctx.tenant, ctx.ws, "all")

      assert %{status: "error", message: message, last_pulled_seq: 0} =
               hd(Sync.peers(ctx.tenant, ctx.ws))

      assert message =~ "more than one replica id"
    end

    test "a reset is not repeated within the window, however many cycles ask for one", ctx do
      turn = :ets.new(:turn, [:public])
      :ets.insert(turn, {:n, 0})

      # Every answer is a replica this Engine has not seen.
      Application.put_env(:optimal_engine, :http_mock, fn _url, _opts ->
        n = :ets.update_counter(turn, :n, 1)
        engine = Sync.engine_info() |> Map.put("replica_id", "rep_new_#{n}")
        respond(200, %{"mutations" => [], "cursor" => 3, "more" => false, "engine" => engine})
      end)

      add_pull_peer(ctx, since: 9, replica: "rep_start")
      for _cycle <- 1..3, do: Sync.run_all()

      # The first cycle resets once and meets a second identity (two requests);
      # the next two meet a new identity each and reset nothing.
      assert [{:n, 4}] = :ets.lookup(turn, :n)
      assert [%{kind: "peer_replaced"}] = Sync.conflicts(ctx.tenant, ctx.ws, "all")

      # After the window, the next change of identity is followed once more.
      {:ok, _} =
        Store.raw_query(
          "UPDATE sync_conflicts SET created_at = '2000-01-01T00:00:00Z' WHERE workspace_id = ?1 AND kind = 'peer_replaced'",
          [ctx.ws]
        )

      Sync.run_all()
      assert length(Sync.conflicts(ctx.tenant, ctx.ws, "all")) == 2
    end

    test "a change page that does not say which replica sent it is refused, the known id stays",
         ctx do
      Application.put_env(:optimal_engine, :http_mock, fn _url, _opts ->
        engine = Sync.engine_info() |> Map.delete("replica_id")
        respond(200, %{"mutations" => [], "cursor" => 20, "more" => false, "engine" => engine})
      end)

      add_pull_peer(ctx, since: 9, replica: "rep_one")
      [result] = Sync.run_all() |> Enum.filter(&(&1.workspace_id == ctx.ws))

      assert result.status == "error"
      assert {:error, :peer_replica_unreported} = result.pull

      assert %{peer_replica_id: "rep_one", last_pulled_seq: 9, message: message} =
               hd(Sync.peers(ctx.tenant, ctx.ws))

      assert message =~ "does not say which replica"
    end

    test "a peer whose ledger ends before the cursor is reset once and pulled from the start",
         ctx do
      requests = :ets.new(:requests, [:public, :ordered_set])

      # The same Engine restored from an older copy: its ledger holds four changes.
      Application.put_env(:optimal_engine, :http_mock, fn url, _opts ->
        since = url |> URI.parse() |> Map.get(:query) |> URI.decode_query() |> Map.get("since")
        :ets.insert(requests, {System.unique_integer([:monotonic]), since})
        engine = Sync.engine_info() |> Map.put("replica_id", "rep_one")

        respond(200, %{
          "mutations" => [],
          "cursor" => if(since == "0", do: 4, else: String.to_integer(since)),
          "more" => false,
          "head" => 4,
          "engine" => engine
        })
      end)

      add_pull_peer(ctx, since: 50, replica: "rep_one")
      [result] = Sync.run_all() |> Enum.filter(&(&1.workspace_id == ctx.ws))

      assert result.status == "active"
      assert {:ok, %{cursor: 4}} = result.pull
      assert for({_, since} <- :ets.tab2list(requests), do: since) == ["50", "0"]

      assert [
               %{
                 kind: "peer_replaced",
                 state: "resolved",
                 detail: %{"reason" => "ledger_behind", "peer_head" => 4, "cursor" => 50}
               }
             ] = Sync.conflicts(ctx.tenant, ctx.ws, "all")
    end

    test "the pull floor moves to the ledger head only after a cycle that pulled and pushed everything",
         ctx do
      state = :ets.new(:floor_state, [:public])
      :ets.insert(state, more: true, push: :too_large)
      engine = Sync.engine_info() |> Map.put("replica_id", "rep_cloud")

      Application.put_env(:optimal_engine, :http_mock, fn _url, opts ->
        [{:more, more}] = :ets.lookup(state, :more)
        [{:push, push}] = :ets.lookup(state, :push)

        case opts[:method] do
          :get ->
            respond(200, %{
              "mutations" => [],
              "cursor" => 3,
              "more" => more,
              "head" => 3,
              "engine" => engine
            })

          :post ->
            sent = length(opts[:body]["mutations"])

            if push == :too_large and sent > 1,
              do: respond(413, %{"error" => "too large"}),
              else: respond(200, %{"applied" => sent})
        end
      end)

      add_pull_peer(ctx, policy: "both", replica: "rep_cloud")
      for n <- 1..25, do: insert_context(ctx.tenant, ctx.ws, "floor-#{n}-#{ctx.n}", "Written here")
      floor = fn -> hd(Sync.peers(ctx.tenant, ctx.ws)).pulled_local_seq end
      assert floor.() == 0

      # The cycle's time is spent after a page each way, with pages to come on
      # both sides: nothing is taken as seen.
      Application.put_env(:optimal_engine, :sync_cycle_budget_ms, 0)
      [first] = Sync.run_all() |> Enum.filter(&(&1.workspace_id == ctx.ws))
      assert {:ok, %{more: true}} = first.pull
      assert {:ok, %{more: true}} = first.push
      assert floor.() == 0

      # The pull is complete, the push stops with rows left (a peer that takes one
      # change at a time and a cycle of twenty pages).
      Application.delete_env(:optimal_engine, :sync_cycle_budget_ms)
      :ets.insert(state, more: false, push: :too_large)
      [second] = Sync.run_all() |> Enum.filter(&(&1.workspace_id == ctx.ws))
      assert {:ok, %{sent: 20, more: true}} = second.push
      assert second.status == "active"
      assert floor.() == 0

      # Both reached the end: the floor is the head the cycle started from.
      :ets.insert(state, more: false, push: :ack)
      [third] = Sync.run_all() |> Enum.filter(&(&1.workspace_id == ctx.ws))
      assert {:ok, %{more: false}} = third.push
      head = Sync.status(ctx.tenant, ctx.ws).ledger_sequence
      assert head > 0
      assert floor.() == head
      assert is_binary(hd(Sync.peers(ctx.tenant, ctx.ws)).last_sync_at)
    end

    test "after a complete cycle, only changes made since it are concurrent with what a pull brings",
         ctx do
      engine = Sync.engine_info() |> Map.put("replica_id", "rep_cloud")
      state = :ets.new(:floor_pull, [:public])
      :ets.insert(state, mutations: [])

      Application.put_env(:optimal_engine, :http_mock, fn _url, opts ->
        case opts[:method] do
          :get ->
            [{:mutations, mutations}] = :ets.lookup(state, :mutations)

            respond(200, %{
              "mutations" => mutations,
              "cursor" => 3,
              "more" => false,
              "head" => 3,
              "engine" => engine
            })

          :post ->
            respond(200, %{"applied" => length(opts[:body]["mutations"])})
        end
      end)

      add_pull_peer(ctx, policy: "both", replica: "rep_cloud")
      before = "before-#{ctx.n}"
      insert_context(ctx.tenant, ctx.ws, before, "Written before the cycle")
      [cycle] = Sync.run_all() |> Enum.filter(&(&1.workspace_id == ctx.ws))
      assert {:ok, %{more: false}} = cycle.push
      assert hd(Sync.peers(ctx.tenant, ctx.ws)).pulled_local_seq > 0

      # A change after the cycle, and then the peer's edits to both rows. Its clock
      # is far behind ours, as under skew, so the clock alone would keep ours.
      later = "later-#{ctx.n}"
      insert_context(ctx.tenant, ctx.ws, later, "Written after the cycle")

      peer_edit = fn id ->
        mutation(ctx, %{
          "device_id" => "rep_cloud",
          "operation" => "update",
          "occurred_at" => "2000-01-01T00:00:00.000",
          "payload" => context_row(id, "Peer's edit", ctx.ws, ctx.tenant)
        })
      end

      :ets.insert(state, mutations: [peer_edit.(before), peer_edit.(later)])
      [next] = Sync.run_all() |> Enum.filter(&(&1.workspace_id == ctx.ws))

      # The first row was pushed in the cycle: the peer saw it before it edited it,
      # so its edit stands. The second was not: concurrent, and the clock decides.
      assert {:ok, %{applied: 1, conflicts: 1}} = next.pull
      assert title(before) == "Peer's edit"
      assert title(later) == "Written after the cycle"
      assert [%{table: "contexts", entity_key: ^later}] = Sync.conflicts(ctx.tenant, ctx.ws)
    end

    test "a push reply that did not trust the base is shown in the peer's message", ctx do
      engine = Sync.engine_info() |> Map.put("replica_id", "rep_cloud")

      Application.put_env(:optimal_engine, :http_mock, fn _url, opts ->
        case opts[:method] do
          :get ->
            respond(200, %{"mutations" => [], "cursor" => 3, "more" => false, "engine" => engine})

          :post ->
            respond(200, %{
              "applied" => 1,
              "base" => "unknown",
              "base_rejected" => "replica_mismatch"
            })
        end
      end)

      add_pull_peer(ctx, policy: "both", replica: "rep_cloud")
      insert_context(ctx.tenant, ctx.ws, "rejected-#{ctx.n}", "Written here")
      [result] = Sync.run_all() |> Enum.filter(&(&1.workspace_id == ctx.ws))

      assert result.status == "active"
      assert %{status: "active", message: message} = hd(Sync.peers(ctx.tenant, ctx.ws))
      assert message =~ "did not accept the base"
      assert message =~ "replica_mismatch"
    end

    test "no push follows a pull that could not settle the peer's identity", ctx do
      posts = :ets.new(:posts, [:public, :ordered_set])
      turn = :ets.new(:turn, [:public])
      :ets.insert(turn, {:n, 0})

      Application.put_env(:optimal_engine, :http_mock, fn _url, opts ->
        case opts[:method] do
          :get ->
            replica = if rem(:ets.update_counter(turn, :n, 1), 2) == 1, do: "rep_b", else: "rep_a"
            engine = Sync.engine_info() |> Map.put("replica_id", replica)
            respond(200, %{"mutations" => [], "cursor" => 5, "more" => false, "engine" => engine})

          :post ->
            :ets.insert(posts, {System.unique_integer([:monotonic]), opts[:body]})
            respond(200, %{"applied" => length(opts[:body]["mutations"])})
        end
      end)

      add_pull_peer(ctx, policy: "both", since: 9, replica: "rep_a")
      insert_context(ctx.tenant, ctx.ws, "held-#{ctx.n}", "Not sent")
      [result] = Sync.run_all() |> Enum.filter(&(&1.workspace_id == ctx.ws))

      assert {:error, :peer_identity_unstable} = result.pull
      assert {:ok, %{skipped: :identity}} = result.push
      assert :ets.tab2list(posts) == []
      assert hd(Sync.peers(ctx.tenant, ctx.ws)).last_pushed_seq == 0
    end

    test "a push reply from another replica than the peer's does not move the push cursor",
         ctx do
      engine = Sync.engine_info() |> Map.put("replica_id", "rep_cloud")

      Application.put_env(:optimal_engine, :http_mock, fn _url, opts ->
        case opts[:method] do
          :get ->
            respond(200, %{"mutations" => [], "cursor" => 3, "more" => false, "engine" => engine})

          :post ->
            other = Map.put(engine, "replica_id", "rep_other")
            respond(200, %{"applied" => length(opts[:body]["mutations"]), "engine" => other})
        end
      end)

      add_pull_peer(ctx, policy: "both", replica: "rep_cloud")
      insert_context(ctx.tenant, ctx.ws, "elsewhere-#{ctx.n}", "Sent to another Engine")
      [result] = Sync.run_all() |> Enum.filter(&(&1.workspace_id == ctx.ws))

      assert result.status == "error"
      assert {:error, :peer_identity_unstable} = result.push

      assert %{last_pushed_seq: 0, pending_push: pending} =
               hd(Sync.status(ctx.tenant, ctx.ws).peers)

      assert pending >= 1
    end

    test "a third change of identity in a day halts the peer until it is added again", ctx do
      turn = :ets.new(:turn, [:public])
      :ets.insert(turn, {:n, 0})

      Application.put_env(:optimal_engine, :http_mock, fn _url, _opts ->
        n = :ets.update_counter(turn, :n, 1)
        engine = Sync.engine_info() |> Map.put("replica_id", "rep_new_#{n}")
        respond(200, %{"mutations" => [], "cursor" => 3, "more" => false, "engine" => engine})
      end)

      add_pull_peer(ctx, since: 9, replica: "rep_start")
      run = fn -> Sync.run_all() |> Enum.filter(&(&1.workspace_id == ctx.ws)) end

      age = fn ->
        {:ok, _} =
          Store.raw_query(
            "UPDATE sync_conflicts SET created_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-1 hour') WHERE workspace_id = ?1 AND kind = 'peer_replaced'",
            [ctx.ws]
          )
      end

      # Two resets, an hour apart, each followed by another new identity in the run.
      [first] = run.()
      assert first.status == "error"
      age.()
      [second] = run.()
      assert second.status == "error"
      age.()
      assert [{:n, 4}] = :ets.tab2list(turn)

      # The third is not followed: the peer is halted and no longer run.
      [third] = run.()
      assert third.status == "halted"
      assert {:error, :peer_halted} = third.pull
      assert %{status: "halted", message: message} = hd(Sync.peers(ctx.tenant, ctx.ws))
      assert message =~ "added again"
      assert run.() == []
      assert [{:n, 5}] = :ets.tab2list(turn)
      assert length(Sync.conflicts(ctx.tenant, ctx.ws, "all")) == 2

      # Adding it again is the operator's word that it is settled.
      add_pull_peer(ctx, since: 9)
      assert hd(Sync.peers(ctx.tenant, ctx.ws)).status == "active"
      [again] = run.()
      assert again.status == "error"
      assert length(Sync.conflicts(ctx.tenant, ctx.ws, "all")) == 3
    end

    test "a peer this Engine only pulls from keeps the pull floor at zero", ctx do
      engine = Sync.engine_info() |> Map.put("replica_id", "rep_cloud")

      Application.put_env(:optimal_engine, :http_mock, fn _url, _opts ->
        respond(200, %{"mutations" => [], "cursor" => 3, "more" => false, "engine" => engine})
      end)

      add_pull_peer(ctx, policy: "pull", replica: "rep_cloud")
      insert_context(ctx.tenant, ctx.ws, "never-sent-#{ctx.n}", "Stays here")
      [result] = Sync.run_all() |> Enum.filter(&(&1.workspace_id == ctx.ws))

      # The cycle is complete, and none of this Engine's changes reached the peer.
      assert result.status == "active"
      assert %{pulled_local_seq: 0, last_sync_at: at} = hd(Sync.peers(ctx.tenant, ctx.ws))
      assert is_binary(at)
    end

    test "a peer is run by one process at a time", ctx do
      gets = :ets.new(:gets, [:public])
      inner = :ets.new(:inner, [:public])
      :ets.insert(gets, {:n, 0})
      engine = Sync.engine_info() |> Map.put("replica_id", "rep_cloud")

      Application.put_env(:optimal_engine, :http_mock, fn _url, _opts ->
        :ets.update_counter(gets, :n, 1)

        # The scheduler's tick and `POST /api/sync/run`: a second run while one is in progress.
        second = Task.async(fn -> Sync.run_all() |> Enum.filter(&(&1.workspace_id == ctx.ws)) end)
        :ets.insert(inner, {:result, Task.await(second, 30_000)})

        respond(200, %{"mutations" => [], "cursor" => 3, "more" => false, "engine" => engine})
      end)

      add_pull_peer(ctx, policy: "pull", replica: "rep_cloud")
      [result] = Sync.run_all() |> Enum.filter(&(&1.workspace_id == ctx.ws))

      assert result.status == "active"

      assert [{:result, [%{status: "busy", reason: :already_running}]}] =
               :ets.lookup(inner, :result)

      assert [{:n, 1}] = :ets.lookup(gets, :n)
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

      # The push names how much of the cloud's ledger the laptop had pulled, and
      # whose ledger that is.
      assert bases(relay) == [5]
      assert base_replicas(relay) == ["rep_cloud"]

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

    test "a relay that reports another replica gets both cursors reset and is pulled from the start",
         ctx do
      relay = fake_relay(ctx, cloud: cloud_ledger(ctx, 3))
      {:ok, _} = add_relay_peer(ctx, "relay-key", "both")

      [first] = run_peers(ctx)
      assert {:ok, %{applied: 3, cursor: 3}} = first.pull

      assert %{peer_replica_id: "rep_cloud", last_pulled_seq: 3} =
               hd(Sync.peers(ctx.tenant, ctx.ws))

      # The managed Engine was restored under another identity: its ledger starts again.
      :ets.insert(relay, replica: "rep_restored")
      [second] = run_peers(ctx)
      assert second.status == "active"
      assert {:ok, %{applied: 0, skipped: %{duplicate: 3}}} = second.pull

      assert %{peer_replica_id: "rep_restored", last_pulled_seq: 3} =
               hd(Sync.peers(ctx.tenant, ctx.ws))

      assert for({:get, "pull", query} <- calls(relay), do: query["since"]) == ["0", "2", "0", "2"]

      assert [%{kind: "peer_replaced", state: "resolved", remote_device: "rep_restored"}] =
               Sync.conflicts(ctx.tenant, ctx.ws, "all")
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

      # Delivered three times, held once; a push-only peer has pulled nothing.
      assert relay |> received() |> Map.values() == [3, 3]
      assert bases(relay) == [0, 0, 0]
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
        "base_seq" => 3,
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
      assert bases(relay) == [3, 3]
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
  # idempotency_key (every delivery is counted), `base_seq` forwarded to the
  # cloud unchanged (recorded per delivery), and no x-optimal-replica
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
      failed_pulls: opts[:failed_pulls] || [],
      bases: [],
      base_replicas: [],
      replica: "rep_cloud"
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
      "replica_id" => lookup(state, :replica),
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
          "engine" => Map.put(config.engine, "replica_id", lookup(state, :replica))
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
        update(state, :bases, &(&1 ++ [body["base_seq"]]))
        update(state, :base_replicas, &(&1 ++ [body["base_replica_id"]]))
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
      "engine" => Map.put(config.engine, "replica_id", lookup(state, :replica))
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
  defp bases(state), do: lookup(state, :bases)
  defp base_replicas(state), do: lookup(state, :base_replicas)

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

  # A peer on the test mock, with the replica id its cursors were kept for.
  defp add_pull_peer(ctx, opts) do
    attrs = %{
      "workspace_id" => ctx.ws,
      "url" => "https://cloud.example",
      "api_key" => "replica-key",
      "policy" => Keyword.get(opts, :policy, "pull")
    }

    attrs = if opts[:since], do: Map.put(attrs, "since", opts[:since]), else: attrs
    {:ok, _} = Sync.add_peer(ctx.tenant, attrs, "u")

    if opts[:replica] do
      {:ok, _} =
        Store.raw_query("UPDATE sync_peers SET peer_replica_id = ?2 WHERE workspace_id = ?1", [
          ctx.ws,
          opts[:replica]
        ])
    end

    :ok
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

  test "a bundle's mark covers changes captured but not yet sealed", ctx do
    insert_context(ctx.tenant, ctx.ws, "sealed-#{ctx.n}", "Sealed")
    {:ok, _} = Capture.seal()
    insert_context(ctx.tenant, ctx.ws, "pending-#{ctx.n}", "Pending")

    path = Path.join(System.tmp_dir!(), "mark-#{ctx.n}.tar.gz")
    {:ok, manifest} = OptimalEngine.Portability.WorkspaceBundle.export(ctx.tenant, ctx.ws, path)
    File.rm(path)

    # Both rows are in the bundle, so a replica seeded from it must find neither
    # above the mark; nothing written before the export is pulled again.
    after_mark = Sync.changes(ctx.tenant, ctx.ws, since: manifest["ledger_sequence"])
    assert after_mark["mutations"] == []

    insert_context(ctx.tenant, ctx.ws, "later-#{ctx.n}", "Later")
    later = Sync.changes(ctx.tenant, ctx.ws, since: manifest["ledger_sequence"])
    ids = Enum.map(later["mutations"], & &1["entity_id"])
    assert "later-#{ctx.n}" in ids
    refute "pending-#{ctx.n}" in ids
  end

  describe "a bundle taken while its workspace is written" do
    # The export reads one row per page here, and `write` runs once, right after
    # the first page of `table` is read: a write that lands while it pages.
    defp export_while_writing(table, write, export) do
      previous = Application.fetch_env(:optimal_engine, :bundle_export_page_rows)
      Application.put_env(:optimal_engine, :bundle_export_page_rows, 1)
      handler = "between-pages-#{System.unique_integer([:positive])}"

      :ok =
        :telemetry.attach(
          handler,
          [:optimal_engine, :bundle, :export_page],
          &__MODULE__.between_pages/4,
          %{table: table, write: write, ref: handler, test: self()}
        )

      try do
        result = export.()
        assert_received {^handler, :written}
        result
      after
        :telemetry.detach(handler)

        case previous do
          {:ok, rows} -> Application.put_env(:optimal_engine, :bundle_export_page_rows, rows)
          :error -> Application.delete_env(:optimal_engine, :bundle_export_page_rows)
        end
      end
    end

    @doc false
    def between_pages(_event, _measurements, %{table: table}, %{table: table} = config) do
      unless Process.get(config.ref) do
        Process.put(config.ref, true)
        config.write.()
        send(config.test, {config.ref, :written})
      end
    end

    def between_pages(_event, _measurements, _metadata, _config), do: :ok

    defp bundle_rows(path, table) do
      {:ok, [{_name, jsonl}]} =
        :erl_tar.extract(String.to_charlist(path), [
          :compressed,
          :memory,
          {:files, [String.to_charlist("tables/#{table}.jsonl")]}
        ])

      jsonl |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    end

    defp edge(ctx, target) do
      {:ok, _} =
        Store.raw_query(
          "INSERT INTO edges (source_id, target_id, relation, tenant_id, workspace_id) VALUES (?1, ?2, 'related', ?3, ?4)",
          ["edge-source-#{ctx.n}", target, ctx.tenant, ctx.ws]
        )
    end

    test "a context re-written while the export pages is in the bundle once, and the bundle imports",
         ctx do
      for i <- 1..3, do: insert_context(ctx.tenant, ctx.ws, "paged-#{ctx.n}-#{i}", "Paged #{i}")
      first = "paged-#{ctx.n}-1"
      path = Path.join(System.tmp_dir!(), "rewritten-#{ctx.n}.tar.gz")
      on_exit(fn -> File.rm(path) end)

      {:ok, manifest} =
        export_while_writing(
          "contexts",
          fn ->
            # A re-ingest replaces the row, which gives it a new rowid after
            # every row the export has read so far.
            {:ok, _} =
              Store.raw_query(
                "INSERT OR REPLACE INTO contexts (id, tenant_id, workspace_id, title, content, created_at) VALUES (?1, ?2, ?3, 'Paged 1 again', 'body', '2026-10-14T10:00:00Z')",
                [first, ctx.tenant, ctx.ws]
              )
          end,
          fn -> WorkspaceBundle.export(ctx.tenant, ctx.ws, path) end
        )

      ids = path |> bundle_rows("contexts") |> Enum.map(& &1["id"])
      assert Enum.sort(ids) == ids |> Enum.uniq() |> Enum.sort()
      assert first in ids

      # The re-write came after the snapshot, so a replica seeded from the
      # bundle pulls it from above the mark.
      after_mark = Sync.changes(ctx.tenant, ctx.ws, since: manifest["ledger_sequence"])
      assert first in Enum.map(after_mark["mutations"], & &1["entity_id"])

      :ok = WorkspaceBundle.prepare_move(ctx.tenant, ctx.ws, manifest["bundle_sha256"])

      {:ok, _} =
        WorkspaceBundle.finalize_move(ctx.tenant, ctx.ws, manifest["bundle_sha256"], %{
          "target_url" => "https://other.example"
        })

      target = "#{ctx.tenant}-copy"
      {:ok, _} = Tenant.create(%{id: target, name: "Copy"})
      assert {:ok, summary} = WorkspaceBundle.import(path, target, cross_tenant: true)
      assert summary.rows["contexts"] == length(ids)
    end

    test "an append-only row written while the export pages is above the mark, not in the bundle",
         ctx do
      late = "edge-target-#{ctx.n}-late"
      targets = for i <- 1..3, do: "edge-target-#{ctx.n}-#{i}"

      # Edges between contexts the workspace holds, so replication sends them.
      for id <- ["edge-source-#{ctx.n}", late | targets],
          do: insert_context(ctx.tenant, ctx.ws, id, id)

      Enum.each(targets, &edge(ctx, &1))
      path = Path.join(System.tmp_dir!(), "appended-#{ctx.n}.tar.gz")
      on_exit(fn -> File.rm(path) end)

      {:ok, manifest} =
        export_while_writing("edges", fn -> edge(ctx, late) end, fn ->
          WorkspaceBundle.export(ctx.tenant, ctx.ws, path)
        end)

      exported = path |> bundle_rows("edges") |> Enum.map(& &1["target_id"])
      assert Enum.sort(exported) == Enum.sort(targets)
      refute late in exported

      # Its insert is pulled exactly once, from above the mark: a replica that
      # also had it from the bundle would hold the edge twice.
      after_mark = Sync.changes(ctx.tenant, ctx.ws, since: manifest["ledger_sequence"])

      pulled =
        for %{"entity_type" => "edges", "payload" => %{"row" => row}} <- after_mark["mutations"],
            do: row["target_id"]

      assert pulled == [late]
    end
  end
end
