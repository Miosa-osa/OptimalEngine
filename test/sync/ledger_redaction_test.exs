defmodule OptimalEngine.Sync.LedgerRedactionTest do
  @moduledoc """
  Erased content leaves the replication ledger (`OptimalEngine.Sync.Redaction`):
  after an erasure, the text is in no `sync_mutations` payload, no unsealed
  `sync_capture` row and no `sync_conflicts` payload; what replaced it still
  hashes as the ledger hashes; a peer that applies the erasure redacts its own
  copies; and the backfill does the same for what an Engine erased before.
  """

  use ExUnit.Case, async: false

  alias OptimalEngine.Compliance.{DerivedData, Retention}
  alias OptimalEngine.Memory
  alias OptimalEngine.Pipeline.Decomposer.Chunk
  alias OptimalEngine.{Store, Sync, Workspace}
  alias OptimalEngine.Sync.{Capture, Redaction}
  alias OptimalEngine.Tenancy.Tenant
  alias OptimalEngine.Test.StoreGrep
  alias OptimalEngine.TestSupport.EmbedStub

  setup do
    n = System.unique_integer([:positive])
    tenant = "ledger-redact-#{n}"
    saved = Application.get_env(:optimal_engine, :text_embedding)
    {url, stop} = EmbedStub.start()
    Application.put_env(:optimal_engine, :text_embedding, url: url, dimensions: 4)

    on_exit(fn ->
      stop.()

      if saved,
        do: Application.put_env(:optimal_engine, :text_embedding, saved),
        else: Application.delete_env(:optimal_engine, :text_embedding)
    end)

    {:ok, _} = Tenant.create(%{id: tenant, name: "Ledger redact #{n}"})

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

    %{
      n: n,
      tenant: tenant,
      ws: ws.id,
      token: "secret-token-#{n}-#{System.unique_integer([:positive])}"
    }
  end

  # What memory forget and delete redact here are the memory's own changes. The
  # source package and claim the create bridge staged the text in are erased by
  # the forget of #245, and with them their changes (they are deletes).
  @memory_tables ~w(memories memory_embeddings memory_relations)

  describe "memory forget" do
    test "takes the text out of every change of the memory, sealed or not", ctx do
      {:ok, memory} = Memory.create(%{content: "first #{ctx.token}", workspace_id: ctx.ws})
      seal!()

      # A change still in the capture when the forget runs goes too.
      {:ok, _} =
        Store.raw_query("UPDATE memories SET content = ?1 WHERE id = ?2", [
          "second #{ctx.token}",
          memory.id
        ])

      assert memory_hits(ctx.token) != []
      assert :ok = Memory.forget(memory.id)
      seal!()

      assert memory_hits(ctx.token) == []
      assert_hashes_hold(ctx.ws)

      # The ledger keeps every change in place, rewritten.
      redacted = redacted_rows(ctx.ws, "memories", memory.id)
      assert redacted != []

      for [payload, _hash] <- redacted do
        assert %{"row" => %{"id" => id}, "blobs" => %{}, "redacted" => true} =
                 Jason.decode!(payload)

        assert id == memory.id
      end

      # Peers are told: a redaction request is in the ledger, and nothing
      # served names the memory with its text.
      served = Sync.changes(ctx.tenant, ctx.ws, since: 0, limit: 2_000)["mutations"]

      assert Enum.all?(
               for(m <- served, m["entity_type"] in @memory_tables, do: m),
               &(not (Jason.encode!(&1) =~ ctx.token))
             )

      assert [request] =
               for(
                 %{"entity_type" => "ledger_redactions", "payload" => %{"row" => row}} <- served,
                 row["entity_id"] == memory.id,
                 do: row
               )

      # The request names the row and nothing it held, and carries no values:
      # the peer erases by its own rules for the table.
      assert request["target_type"] == "memory"
      assert request["reason"] == "memory_forget"
      assert is_binary(request["version"])
      refute Map.has_key?(request, "erased")
      refute Enum.any?(served, &(&1["entity_type"] == "memories" and &1["entity_id"] == memory.id))
    end

    test "takes the memory's embeddings out of the ledger with it", ctx do
      {:ok, memory} = Memory.create(%{content: "embedded #{ctx.token}", workspace_id: ctx.ws})

      {:ok, _} =
        Store.raw_query(
          "INSERT INTO memory_embeddings (memory_id, tenant_id, workspace_id, model, dimensions, embedding, content_hash) VALUES (?1, ?2, ?3, 'm', 4, ?4, ?5)",
          [memory.id, ctx.tenant, ctx.ws, {:blob, <<1::128>>}, "hash-#{ctx.token}"]
        )

      seal!()
      assert memory_hits(ctx.token) != []
      assert :ok = Memory.forget(memory.id)
      seal!()
      assert memory_hits(ctx.token) == []
      assert redacted_rows(ctx.ws, "memory_embeddings", Jason.encode!([memory.id, "m"])) != []
    end

    test "a hard delete takes the memory's earlier changes out and replicates as a delete", ctx do
      {:ok, memory} = Memory.create(%{content: "deleted #{ctx.token}", workspace_id: ctx.ws})
      seal!()

      assert :ok = Memory.delete(memory.id)
      seal!()

      assert memory_hits(ctx.token) == []
      assert_hashes_hold(ctx.ws)

      served = Sync.changes(ctx.tenant, ctx.ws, since: 0, limit: 2_000)["mutations"]

      assert [%{"operation" => "delete"}] =
               Enum.filter(
                 served,
                 &(&1["entity_type"] == "memories" and &1["entity_id"] == memory.id)
               )
    end
  end

  describe "context erasure" do
    test "an erased context and what cascaded from it leave the ledger and go out as deletes",
         ctx do
      id = "ctx-#{ctx.n}"
      seed_context!(ctx, id, "notes about #{ctx.token}")
      seal!()
      assert ledger_hits(ctx.token) != []

      assert {:ok, _removed} = DerivedData.erase_contexts(ctx.tenant, [id])

      # Before any seal: the erasure's own transaction redacted.
      assert ledger_hits(ctx.token) == []
      seal!()
      assert ledger_hits(ctx.token) == []
      assert_hashes_hold(ctx.ws)

      served = Sync.changes(ctx.tenant, ctx.ws, since: 0, limit: 2_000)["mutations"]
      deleted = for %{"operation" => "delete"} = m <- served, do: {m["entity_type"], m["entity_id"]}

      for row <- [
            {"contexts", id},
            {"source_packages", "pkg-#{id}"},
            {"claims", "claim-#{id}"},
            {"chunks", "#{id}:seeded-0"}
          ],
          do: assert(row in deleted, "#{inspect(row)} did not replicate as a delete")
    end

    test "a context erased before its creation was sealed leaves nothing in the capture", ctx do
      id = "ctx-unsealed-#{ctx.n}"
      seed_context!(ctx, id, "unsealed #{ctx.token}")
      assert capture_hits(ctx.token) != []

      assert {:ok, _} = DerivedData.erase_contexts(ctx.tenant, [id])
      assert capture_hits(ctx.token) == []
      seal!()
      assert ledger_hits(ctx.token) == []
    end

    test "a workspace that stopped replicating still has its ledger redacted", ctx do
      id = "ctx-off-#{ctx.n}"
      seed_context!(ctx, id, "off #{ctx.token}")
      seal!()
      :ok = disable!(ctx)

      assert {:ok, _} = DerivedData.erase_contexts(ctx.tenant, [id])
      assert ledger_hits(ctx.token) == []
      assert_hashes_hold(ctx.ws)
    end

    test "a retention redact replaces the text in the ledger and replicates the redacted context",
         ctx do
      email = "jane.#{ctx.n}@example.com"
      id = "ctx-red-#{ctx.n}"
      seed_context!(ctx, id, "write to #{email}")
      seal!()

      {:ok, _} =
        Retention.add_policy(
          tenant_id: ctx.tenant,
          scope_type: "tenant",
          ttl_days: 1,
          action: "redact"
        )

      assert {:ok, %{actions_taken: 1, errors: 0}} = Retention.sweep(tenant_id: ctx.tenant)
      seal!()

      assert ledger_hits(email) == []
      assert_hashes_hold(ctx.ws)

      served = Sync.changes(ctx.tenant, ctx.ws, since: 0, limit: 2_000)["mutations"]

      assert Enum.any?(served, fn m ->
               m["entity_type"] == "ledger_redactions" and m["payload"]["row"]["entity_id"] == id
             end)

      # The redacted text is what replicates now.
      assert [latest | _] =
               served
               |> Enum.filter(&(&1["entity_type"] == "contexts" and &1["entity_id"] == id))
               |> Enum.reverse()

      assert latest["payload"]["row"]["content"] =~ "<REDACTED:email>"
    end
  end

  describe "conflicts" do
    test "the payloads a conflict kept of an erased row are redacted", ctx do
      id = "ctx-conflict-#{ctx.n}"
      seed_context!(ctx, id, "conflicted #{ctx.token}")
      seal!()

      {:ok, _} =
        Store.raw_query(
          """
          INSERT INTO sync_conflicts (id, tenant_id, workspace_id, table_name, entity_key, kind, resolution,
                                      local_payload, remote_payload, remote_device, detail)
          VALUES (?1, ?2, ?3, 'contexts', ?4, 'concurrent_edit', 'kept_local_newer', ?5, ?5, 'peer', '{}')
          """,
          [
            "sc_t#{ctx.n}",
            ctx.tenant,
            ctx.ws,
            id,
            Jason.encode!(%{"row" => %{"content" => ctx.token}})
          ]
        )

      assert {:ok, _} = DerivedData.erase_contexts(ctx.tenant, [id])
      assert ledger_hits(ctx.token) == []
    end
  end

  describe "a peer" do
    test "applying a delete redacts its copies of the row's earlier changes", ctx do
      id = "peer-ctx-#{ctx.n}"

      create =
        mutation("create", "contexts", id, %{
          "id" => id,
          "title" => "t",
          "content" => "from a peer #{ctx.token}",
          "created_at" => "2026-10-14T10:00:00Z"
        })

      assert {:ok, %{applied: 1}} = Sync.apply_changes(ctx.tenant, ctx.ws, [create])
      assert ledger_hits(ctx.token) != []

      delete = mutation("delete", "contexts", id, %{"id" => id}, 2)
      assert {:ok, %{applied: 1}} = Sync.apply_changes(ctx.tenant, ctx.ws, [delete])

      assert ledger_hits(ctx.token) == []
      assert_hashes_hold(ctx.ws)
    end

    test "applying a redaction request redacts its copies and marks the row forgotten", ctx do
      id = "peer-mem-#{ctx.n}"

      create =
        mutation("create", "memories", id, %{
          "id" => id,
          "content" => "peer memory #{ctx.token}",
          "content_hash" => "h#{ctx.n}",
          "citation_uri" => "optimal://memory/#{ctx.n}",
          "metadata" =>
            Jason.encode!(%{"security_labels" => ["internal"], "note" => "note #{ctx.token}"}),
          "is_forgotten" => 0,
          "created_at" => "2026-10-14T10:00:00Z",
          "updated_at" => "2026-10-14T10:00:00Z"
        })

      assert {:ok, %{applied: 1}} = Sync.apply_changes(ctx.tenant, ctx.ws, [create])
      assert ledger_hits(ctx.token) != []

      request =
        mutation(
          "create",
          "ledger_redactions",
          "lr_peer#{ctx.n}",
          request_row("lr_peer#{ctx.n}", "memory", id, "2026-10-14T11:00:00.000"),
          2
        )

      assert {:ok, %{applied: 1, failed: []}} = Sync.apply_changes(ctx.tenant, ctx.ws, [request])

      assert ledger_hits(ctx.token) == []
      assert_hashes_hold(ctx.ws)

      # The row as a forget leaves it at the origin (`Memory.Versioned.Erasure`):
      # flagged, no text, no hash or address of it, only the governed keys of
      # its metadata.
      {:ok, [[forgotten, content, hash, uri, metadata]]} =
        Store.raw_query(
          "SELECT is_forgotten, content, content_hash, citation_uri, metadata FROM memories WHERE id = ?1",
          [id]
        )

      assert forgotten == 1
      assert content == ""
      assert hash == nil
      assert uri == nil
      assert Jason.decode!(metadata) == %{"security_labels" => ["internal"]}
      assert StoreGrep.find(ctx.token) == []
    end

    test "a forget erased on the origin leaves no trace anywhere in the peer's store", ctx do
      # What Engine A sends when it forgets a memory and erases its text (with
      # #245): the memory, its embedding, and the package and claim it was
      # staged in reached this Engine first; then the deletes of the derived
      # rows and the redaction request that empties the memory.
      id = "peer-fts-#{ctx.n}"
      text = "peer memory #{ctx.token}"
      package = "pkg-peer-#{ctx.n}"
      claim = "claim-peer-#{ctx.n}"

      created = [
        mutation("create", "memories", id, %{
          "id" => id,
          "content" => text,
          "content_hash" => "h#{ctx.n}",
          "is_forgotten" => 0,
          "created_at" => "2026-10-14T10:00:00Z",
          "updated_at" => "2026-10-14T10:00:00Z"
        }),
        mutation("create", "source_packages", package, %{
          "id" => package,
          "content_hash" => "hp#{ctx.n}",
          "raw_text" => text
        }),
        mutation("create", "claims", claim, %{
          "id" => claim,
          "source_package_id" => package,
          "claim_text" => text
        }),
        %{
          mutation(
            "create",
            "memory_embeddings",
            Jason.encode!([id, "m"]),
            %{
              "memory_id" => id,
              "model" => "m",
              "dimensions" => 4,
              "content_hash" => "h#{ctx.n}"
            }
          )
          | "payload" => %{
              "row" => %{
                "memory_id" => id,
                "model" => "m",
                "dimensions" => 4,
                "content_hash" => "h#{ctx.n}"
              },
              "blobs" => %{"embedding" => Base.encode16(<<0::128>>)}
            }
        }
      ]

      assert {:ok, %{applied: 4, failed: []}} = Sync.apply_changes(ctx.tenant, ctx.ws, created)
      assert StoreGrep.find(ctx.token) != []

      erased = [
        mutation(
          "delete",
          "memory_embeddings",
          Jason.encode!([id, "m"]),
          %{"memory_id" => id, "model" => "m"},
          2
        ),
        mutation("delete", "claims", claim, %{"id" => claim}, 2),
        mutation("delete", "source_packages", package, %{"id" => package}, 2),
        mutation(
          "create",
          "ledger_redactions",
          "lr_fts#{ctx.n}",
          request_row("lr_fts#{ctx.n}", "memory", id, "2026-10-14T12:00:00.000"),
          3
        )
      ]

      assert {:ok, %{applied: 4, failed: []}} = Sync.apply_changes(ctx.tenant, ctx.ws, erased)

      # Every table and column, the full-text index (FTS5 and its shadow tables
      # on SQLite, the posting lists on PostgreSQL) and the ledger included.
      assert StoreGrep.find(ctx.token) == []
      assert_hashes_hold(ctx.ws)
    end

    test "a request names a row and sets nothing a peer chose: values it carries are refused",
         ctx do
      # A memory and a context this Engine holds, with labels and a path.
      mem = "peer-guard-mem-#{ctx.n}"
      doc = "peer-guard-ctx-#{ctx.n}"

      assert {:ok, %{applied: 2, failed: []}} =
               Sync.apply_changes(ctx.tenant, ctx.ws, [
                 mutation("create", "memories", mem, %{
                   "id" => mem,
                   "content" => "kept memory",
                   "content_hash" => "hg#{ctx.n}",
                   "is_forgotten" => 0,
                   "metadata" => ~s({"security_labels":["confidential"]}),
                   "created_at" => "2026-10-14T10:00:00Z",
                   "updated_at" => "2026-10-14T10:00:00Z"
                 }),
                 mutation("create", "contexts", doc, %{
                   "id" => doc,
                   "title" => "t",
                   "content" => "kept context",
                   "path" => "notes/kept.md",
                   "metadata" => ~s({"security_labels":["confidential"]}),
                   "created_at" => "2026-10-14T10:00:00Z"
                 })
               ])

      before = rows_of(mem, doc)

      # A request that carries values beside the row it names: refused, whatever
      # the values (labels, a classification, a path, content).
      hostile = [
        mutation(
          "create",
          "ledger_redactions",
          "lr_h1#{ctx.n}",
          request_row("lr_h1#{ctx.n}", "memory", mem, "2026-10-14T11:00:00.000", %{
            "erased" => ~s({"metadata":"{}","content":"rewritten"})
          }),
          2
        ),
        mutation(
          "create",
          "ledger_redactions",
          "lr_h2#{ctx.n}",
          request_row("lr_h2#{ctx.n}", "context", doc, "2026-10-14T11:00:00.000", %{
            "security_labels" => "[]",
            "classification_level" => "public",
            "path" => "../../outside.md"
          }),
          2
        ),
        mutation(
          "create",
          "ledger_redactions",
          "lr_h3#{ctx.n}",
          request_row("lr_h3#{ctx.n}", "workspace_member", "user:x", "2026-10-14T11:00:00.000"),
          2
        ),
        mutation(
          "create",
          "ledger_redactions",
          "lr_h4#{ctx.n}",
          request_row("lr_h4#{ctx.n}", "claim", "claim-x", "2026-10-14T11:00:00.000"),
          2
        ),
        mutation(
          "create",
          "ledger_redactions",
          "lr_h5#{ctx.n}",
          request_row("lr_h5#{ctx.n}", "context", doc, "2026-10-14T11:00:00.000", %{
            "reason" => "free text a peer wrote"
          }),
          2
        )
      ]

      assert {:ok, %{applied: 0, failed: failed}} =
               Sync.apply_changes(ctx.tenant, ctx.ws, hostile)

      assert length(failed) == 5
      assert rows_of(mem, doc) == before

      # A well-formed request for the context redacts the ledger and leaves the
      # row as it is: a context's erasure travels as its own rewrite.
      assert {:ok, %{applied: 1, failed: []}} =
               Sync.apply_changes(ctx.tenant, ctx.ws, [
                 mutation(
                   "create",
                   "ledger_redactions",
                   "lr_ok#{ctx.n}",
                   request_row("lr_ok#{ctx.n}", "context", doc, "2026-10-14T11:00:00.000"),
                   3
                 )
               ])

      assert rows_of(mem, doc) == before
      assert redacted_rows(ctx.ws, "contexts", doc) != []
    end

    test "a request redacts only changes at or before the version it erased", ctx do
      id = "peer-bound-#{ctx.n}"

      assert {:ok, %{applied: 1}} =
               Sync.apply_changes(ctx.tenant, ctx.ws, [
                 mutation("create", "memories", id, %{
                   "id" => id,
                   "content" => "from the peer #{ctx.token}",
                   "content_hash" => "hb#{ctx.n}",
                   "is_forgotten" => 0,
                   "created_at" => "2026-10-14T10:00:00Z",
                   "updated_at" => "2026-10-14T10:00:00Z"
                 })
               ])

      # An edit made here after the version the peer erased.
      local = "edited here later #{ctx.n}"

      {:ok, _} =
        Store.raw_query("UPDATE memories SET content = ?1 WHERE id = ?2", [local, id])

      seal!()

      assert {:ok, %{applied: 1, failed: []}} =
               Sync.apply_changes(ctx.tenant, ctx.ws, [
                 mutation(
                   "create",
                   "ledger_redactions",
                   "lr_bound#{ctx.n}",
                   request_row("lr_bound#{ctx.n}", "memory", id, "2026-10-14T11:00:00.000"),
                   2
                 )
               ])

      # The peer's version is gone; the later local edit stands, in the ledger
      # (it is still pushed) and in the row (the newer change wins).
      assert ledger_hits(ctx.token) == []

      {:ok, kept} =
        Store.raw_query(
          "SELECT COUNT(*) FROM sync_mutations WHERE entity_id = ?1 AND redacted_at IS NULL AND payload LIKE ?2",
          [id, "%" <> local <> "%"]
        )

      assert kept == [[1]]

      assert {:ok, [[^local, 0]]} =
               Store.raw_query("SELECT content, is_forgotten FROM memories WHERE id = ?1", [id])
    end

    test "applying a context's delete removes what this Engine derived from it and redacts it",
         ctx do
      id = "peer-derived-#{ctx.n}"
      chunk = "#{id}:0"
      excerpt = "derived excerpt #{ctx.token}"

      created = [
        mutation("create", "contexts", id, %{
          "id" => id,
          "title" => "t",
          "content" => "c",
          "created_at" => "2026-10-14T10:00:00Z"
        }),
        mutation("create", "chunks", chunk, %{
          "id" => chunk,
          "signal_id" => id,
          "text" => "chunk text",
          "scale" => "document",
          "offset_bytes" => 0,
          "length_bytes" => 10
        }),
        mutation("create", "intents", "row:91#{ctx.n}", %{
          "id" => 91,
          "chunk_id" => chunk,
          "intent" => "inform",
          "confidence" => 0.9,
          "evidence" => excerpt
        }),
        mutation("create", "decisions", "row:92#{ctx.n}", %{
          "id" => 92,
          "context_id" => id,
          "title" => "decided #{excerpt}",
          "decision" => "yes"
        }),
        mutation("create", "graph_edges", "row:93#{ctx.n}", %{
          "id" => 93,
          "source_id" => id,
          "target_id" => "elsewhere-#{ctx.n}",
          "relation" => "related"
        })
      ]

      assert {:ok, %{applied: 5, failed: []}} = Sync.apply_changes(ctx.tenant, ctx.ws, created)
      assert ledger_hits(ctx.token) != []

      assert {:ok, %{applied: 2, failed: []}} =
               Sync.apply_changes(ctx.tenant, ctx.ws, [
                 mutation("delete", "chunks", chunk, %{"id" => chunk}, 2),
                 mutation("delete", "contexts", id, %{"id" => id}, 2)
               ])

      assert ledger_hits(ctx.token) == []

      for {table, column} <- [
            {"intents", "chunk_id"},
            {"decisions", "context_id"},
            {"graph_edges", "source_id"}
          ] do
        value = if column == "chunk_id", do: chunk, else: id

        assert {:ok, [[0]]} =
                 Store.raw_query("SELECT COUNT(*) FROM #{table} WHERE #{column} = ?1", [value]),
               "#{table} still holds a row of the deleted context"
      end
    end
  end

  describe "append-only rows at the origin" do
    test "an erased context's intents, citations, classifications and decisions leave the ledger",
         ctx do
      id = "ctx-ao-#{ctx.n}"
      excerpt = "excerpt #{ctx.token}"
      seed_context!(ctx, id, "body")
      seed_derived!(ctx, id, excerpt)
      seal!()
      assert ledger_hits(ctx.token) != []

      assert {:ok, _} = DerivedData.erase_contexts(ctx.tenant, [id])
      seal!()
      assert ledger_hits(ctx.token) == []
      assert_hashes_hold(ctx.ws)
    end
  end

  describe "the append-only links" do
    test "name every append-only table the Engine replicates, by a link the gate also reads" do
      linked =
        for {parent, links} <- Redaction.append_only_links(),
            {table, column} <- links,
            do: {table, column, parent}

      tables = linked |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.sort()
      assert tables == Enum.sort(Capture.append_only_tables())

      for {table, column, parent} <- linked do
        assert {:id, column, parent} in OptimalEngine.Sync.Lineage.spec(table).refs,
               "#{table}.#{column} is not a link to #{parent} in Sync.Lineage"
      end
    end
  end

  describe "tombstones" do
    test "keep class ranks and ids, never free text, link payloads or natural text keys" do
      row = %{
        "id" => "pkg-1",
        "raw_text" => "secret body",
        "security_labels" => ~s(["restricted","Project Falcon codename"]),
        "partition_ids" => ~s(["part-1","has spaces in it"]),
        "metadata" => ~s({"security_labels":"Falcon","note":"Falcon","partition_ids":["p2"]})
      }

      kept = Redaction.tombstone_row("source_packages", %{"id" => "pkg-1"}, row)
      encoded = Jason.encode!(kept)
      refute encoded =~ "Falcon"
      refute encoded =~ "spaces"
      refute encoded =~ "secret body"
      assert kept["id"] == "pkg-1"
      assert kept["security_labels"] == ~s(["restricted"])

      # A labels value that is not a list cannot be read: it is kept as a class
      # the gate holds, not as the text.
      odd =
        Redaction.tombstone_row("source_packages", %{"id" => "pkg-2"}, %{
          "security_labels" => "Falcon"
        })

      refute Jason.encode!(odd) =~ "Falcon"
      assert odd["security_labels"] == ~s(["restricted"])

      # Null labels and partitions in metadata stay null.
      nulls =
        Redaction.tombstone_row("memories", %{"id" => "m-1"}, %{
          "metadata" => ~s({"security_labels":null,"partition_ids":null,"note":"x"})
        })

      assert Jason.decode!(nulls["metadata"]) == %{"security_labels" => nil, "partition_ids" => nil}

      # A natural text key is kept as a keyed hash.
      alias_key = %{"canonical_entity_id" => "ce-1", "alias" => "Jane Q Public"}
      hashed = Redaction.tombstone_row("entity_aliases", alias_key, alias_key)
      refute Jason.encode!(hashed) =~ "Jane"
      assert hashed["canonical_entity_id"] == "ce-1"
    end
  end

  describe "the policy store" do
    test "does not hand out redacted changes", ctx do
      id = "ctx-policy-#{ctx.n}"
      seed_context!(ctx, id, "policy #{ctx.token}")
      seal!()
      assert {:ok, _} = DerivedData.erase_contexts(ctx.tenant, [id])
      seal!()

      {:ok, entries} = OptimalEngine.Storage.PolicyStore.mutations_after(ctx.ws, 0, 1_000)
      refute Enum.any?(entries, &(Jason.encode!(&1) =~ ctx.token))
      refute Enum.any?(entries, &(&1[:entity_id] == id and &1[:operation] in ["create", "update"]))
    end
  end

  describe "the gate" do
    test "a request is held from a peer not cleared for the row it names", ctx do
      {:ok, memory} = Memory.create(%{content: "gated #{ctx.token}", workspace_id: ctx.ws})

      {:ok, _} =
        Store.raw_query("UPDATE memories SET metadata = ?1 WHERE id = ?2", [
          ~s({"security_labels":["restricted"]}),
          memory.id
        ])

      seal!()
      assert :ok = Memory.forget(memory.id)

      names_it? = fn max_class ->
        Sync.changes(ctx.tenant, ctx.ws, since: 0, limit: 2_000, max_class: max_class)["mutations"]
        |> Enum.any?(
          &(&1["entity_type"] == "ledger_redactions" and
              &1["payload"]["row"]["entity_id"] == memory.id)
        )
      end

      refute names_it?.("internal")
      assert names_it?.("restricted")
    end
  end

  describe "backfill" do
    test "a dry run changes no row", ctx do
      {:ok, memory} = Memory.create(%{content: "dry #{ctx.token}", workspace_id: ctx.ws})
      id = "ctx-dry-#{ctx.n}"
      seed_context!(ctx, id, "dry erase #{ctx.token}")
      seal!()
      old_erasure!(memory.id, id)

      # A change captured and not sealed yet.
      {:ok, _} = Store.raw_query("UPDATE memories SET content = 'later' WHERE id = ?1", [memory.id])
      {:ok, [[captured]]} = Store.raw_query("SELECT COUNT(*) FROM sync_capture", [])
      assert captured > 0

      snapshot = fn ->
        {:ok, ledger} =
          Store.raw_query(
            "SELECT id, payload, payload_hash, redacted_at FROM sync_mutations ORDER BY sequence",
            []
          )

        {:ok, capture} = Store.raw_query("SELECT seq, row_data FROM sync_capture ORDER BY seq", [])
        {:ok, requests} = Store.raw_query("SELECT id FROM ledger_redactions ORDER BY id", [])
        {ledger, capture, requests}
      end

      before = snapshot.()
      assert {:ok, %{dry_run: true}} = Redaction.backfill(dry_run: true)
      assert snapshot.() == before
    end

    test "redacts what an Engine erased before it redacted, once, and the dry run says only counts",
         ctx do
      # What v0.3.14 left: the ledger holds the text of rows erased since.
      forgotten = "forgotten-memory-#{ctx.n}-#{System.unique_integer([:positive])}"
      {:ok, memory} = Memory.create(%{content: "old forget #{forgotten}", workspace_id: ctx.ws})
      id = "ctx-old-#{ctx.n}"
      seed_context!(ctx, id, "old erase #{ctx.token}")
      seed_derived!(ctx, id, "old derived #{ctx.token}")
      seal!()
      old_erasure!(memory.id, id)
      assert ledger_hits(ctx.token) != []
      assert memory_hits(forgotten) != []

      assert {:ok, dry} = Redaction.backfill(dry_run: true)
      assert dry.dry_run
      assert dry.sync_enabled_workspaces >= 1
      assert is_integer(dry.registered_peers)
      assert %{rows: rows, changes: changes} = dry.exposed["memories"]
      assert rows >= 1 and changes >= 1
      assert dry.exposed["contexts"].rows >= 1
      refute inspect(dry) =~ "secret-token"
      refute inspect(dry) =~ memory.id
      # Nothing changed.
      assert ledger_hits(ctx.token) != []

      assert {:ok, done} = Redaction.backfill()
      assert done.ledger_rows_redacted >= 2
      assert done.peer_requests >= 1
      assert ledger_hits(ctx.token) == []
      assert memory_hits(forgotten) == []
      assert_hashes_hold(ctx.ws)

      # Idempotent.
      assert {:ok, again} = Redaction.backfill()
      assert again.ledger_rows_redacted == 0
      assert again.peer_requests == 0
      refute Map.has_key?(again.exposed, "memories")
    end
  end

  # ---------------------------------------------------------------------------

  # The erasures as v0.3.14 ran them, with no redaction: the memory marked
  # forgotten by its own statement, the context and its rows deleted while
  # nothing captured (as a delete applied from a peer, or one made while the
  # workspace did not replicate).
  defp old_erasure!(memory_id, context_id) do
    Store.transaction(fn txn ->
      {:ok, _} = Store.txn_execute(txn, "UPDATE sync_identity SET applying = 1 WHERE id = 1", [])

      {:ok, _} =
        Store.txn_execute(txn, "UPDATE memories SET is_forgotten = 1 WHERE id = ?1", [memory_id])

      {:ok, _} = Store.txn_execute(txn, "DELETE FROM claims WHERE id = ?1", ["claim-#{context_id}"])

      {:ok, _} =
        Store.txn_execute(txn, "DELETE FROM decisions WHERE context_id = ?1", [context_id])

      {:ok, _} =
        Store.txn_execute(txn, "DELETE FROM chunk_embeddings WHERE chunk_id = ?1", [
          "#{context_id}:seeded-0"
        ])

      {:ok, _} = Store.txn_execute(txn, "DELETE FROM chunks WHERE signal_id = ?1", [context_id])

      {:ok, _} =
        Store.txn_execute(txn, "DELETE FROM source_packages WHERE id = ?1", ["pkg-#{context_id}"])

      {:ok, _} = Store.txn_execute(txn, "DELETE FROM contexts WHERE id = ?1", [context_id])
      {:ok, _} = Store.txn_execute(txn, "UPDATE sync_identity SET applying = 0 WHERE id = 1", [])
      {:ok, :done}
    end)
  end

  defp request_row(id, type, entity, version, extra \\ %{}) do
    Map.merge(
      %{
        "id" => id,
        "target_type" => type,
        "entity_id" => entity,
        "reason" => "memory_forget",
        "version" => version
      },
      extra
    )
  end

  defp rows_of(mem, doc) do
    {:ok, m} =
      Store.raw_query("SELECT content, is_forgotten, metadata FROM memories WHERE id = ?1", [mem])

    {:ok, c} =
      Store.raw_query("SELECT content, path, metadata FROM contexts WHERE id = ?1", [doc])

    {m, c}
  end

  # What derived rows a context's chunk gets: an intent with an excerpt of the
  # text, a citation, a classification and a decision about the context.
  defp seed_derived!(ctx, id, excerpt) do
    chunk = "#{id}:seeded-0"

    sql!(
      "INSERT INTO intents (tenant_id, workspace_id, chunk_id, intent, confidence, evidence) VALUES (?1, ?2, ?3, 'inform', 0.9, ?4)",
      [ctx.tenant, ctx.ws, chunk, excerpt]
    )

    sql!(
      "INSERT INTO citations (tenant_id, workspace_id, wiki_slug, chunk_id, claim_hash) VALUES (?1, ?2, ?3, ?4, ?5)",
      [ctx.tenant, ctx.ws, "page-#{ctx.n}", chunk, "cite #{excerpt}"]
    )

    sql!(
      "INSERT INTO classifications (tenant_id, workspace_id, chunk_id, genre, structure) VALUES (?1, ?2, ?3, 'note', ?4)",
      [ctx.tenant, ctx.ws, chunk, "struct #{excerpt}"]
    )

    sql!(
      "INSERT INTO decisions (tenant_id, workspace_id, context_id, title, decision) VALUES (?1, ?2, ?3, ?4, 'yes')",
      [ctx.tenant, ctx.ws, id, "decided #{excerpt}"]
    )
  end

  defp seal!, do: {:ok, _} = Capture.seal()

  defp disable!(ctx) do
    {:ok, _} = Store.raw_query("DELETE FROM sync_workspaces WHERE workspace_id = ?1", [ctx.ws])
    :ok
  end

  # Where the ledger, the capture and the conflicts still hold `token`.
  defp ledger_hits(token) do
    like = "%" <> token <> "%"

    {:ok, ledger} =
      Store.raw_query("SELECT 'sync_mutations', id FROM sync_mutations WHERE payload LIKE ?1", [
        like
      ])

    {:ok, conflicts} =
      Store.raw_query(
        "SELECT 'sync_conflicts', id FROM sync_conflicts WHERE local_payload LIKE ?1 OR remote_payload LIKE ?1",
        [like]
      )

    ledger ++ capture_hits(token) ++ conflicts
  end

  # The memory's own changes, in the ledger or the capture, that hold `token`.
  defp memory_hits(token) do
    {:ok, rows} =
      Store.raw_query(
        "SELECT entity_type, id FROM sync_mutations WHERE payload LIKE ?1 " <>
          "UNION ALL SELECT table_name, CAST(seq AS TEXT) FROM sync_capture WHERE row_data LIKE ?1",
        ["%" <> token <> "%"]
      )

    for [table, _id] = hit <- rows, table in @memory_tables, do: hit
  end

  defp capture_hits(token) do
    {:ok, rows} =
      Store.raw_query(
        "SELECT 'sync_capture', CAST(seq AS TEXT) FROM sync_capture WHERE row_data LIKE ?1",
        ["%" <> token <> "%"]
      )

    rows
  end

  defp redacted_rows(ws, table, id) do
    {:ok, rows} =
      Store.raw_query(
        """
        SELECT payload, payload_hash FROM sync_mutations
        WHERE workspace_id = ?1 AND entity_type = ?2 AND entity_id = ?3 AND redacted_at IS NOT NULL
        """,
        [ws, table, id]
      )

    rows
  end

  # Every row's hash is the SHA-256 of its payload, as the ledger computes it.
  defp assert_hashes_hold(ws) do
    {:ok, rows} =
      Store.raw_query("SELECT payload, payload_hash FROM sync_mutations WHERE workspace_id = ?1", [
        ws
      ])

    for [payload, hash] <- rows, do: assert(Redaction.hash(payload) == hash)
  end

  defp mutation(op, table, id, row, n \\ 1) do
    %{
      "id" => "mut_peerdev_#{System.unique_integer([:positive])}_#{n}",
      "device_id" => "peerdev",
      "entity_type" => table,
      "entity_id" => id,
      "operation" => op,
      "occurred_at" => "2026-10-14T1#{n}:00:00.000",
      "idempotency_key" => nil,
      "payload" => %{"row" => row, "blobs" => %{}}
    }
  end

  defp seed_context!(ctx, id, text) do
    sql!(
      """
      INSERT INTO contexts (id, tenant_id, workspace_id, uri, title, content, l0_abstract, l1_overview, genre, node, created_at)
      VALUES (?1, ?2, ?3, ?4, 't', ?5, ?5, ?5, 'note', 'person-operator', '2020-01-01T00:00:00Z')
      """,
      [id, ctx.tenant, ctx.ws, "optimal://redact/#{id}", text]
    )

    sql!(
      "INSERT INTO source_packages (id, tenant_id, workspace_id, content_hash, raw_text) VALUES (?1, ?2, ?3, ?4, ?5)",
      ["pkg-#{id}", ctx.tenant, ctx.ws, "hash-#{id}", text]
    )

    sql!("UPDATE contexts SET metadata = json_object('source_package_id', ?1) WHERE id = ?2", [
      "pkg-#{id}",
      id
    ])

    sql!(
      "INSERT INTO claims (id, tenant_id, workspace_id, source_package_id, signal_id, claim_text) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
      ["claim-#{id}", ctx.tenant, ctx.ws, "pkg-#{id}", id, text]
    )

    :ok =
      Store.insert_chunks([
        Chunk.new(
          id: "#{id}:seeded-0",
          signal_id: id,
          tenant_id: ctx.tenant,
          workspace_id: ctx.ws,
          text: text
        )
      ])

    :ok =
      Store.insert_embeddings([
        %{
          chunk_id: "#{id}:seeded-0",
          tenant_id: ctx.tenant,
          model: "test",
          modality: :text,
          dim: 4,
          vector: [1.0, 0.0, 0.0, 0.0],
          workspace_id: ctx.ws
        }
      ])
  end

  defp sql!(sql, params) do
    {:ok, _} = Store.raw_query(sql, params)
    :ok
  end
end
