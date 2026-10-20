defmodule OptimalEngine.SyncGateTest do
  @moduledoc """
  The data-class gate of replication, through a relay that records what it is
  sent.

  A row copied or derived from a labelled row is as classified as its source:
  the versioned memory the remember route projects from a restricted source
  package has no label column of its own, and neither do chunks, vectors,
  wiki pages or the other rows that hold a restricted document's text. The
  tests run a real push and look at everything the relay received.
  """

  use ExUnit.Case, async: false

  alias OptimalEngine.{Memory, Store, Sync, Workspace}
  alias OptimalEngine.Memory.Versioned

  alias OptimalEngine.MemoryCore.{
    AssociativeProjection,
    DerivationLedgerEntry,
    ScopeEnvelope,
    SourcePackage
  }

  alias OptimalEngine.MemoryCore.Store, as: CoreStore
  alias OptimalEngine.Pipeline.Intake
  alias OptimalEngine.Storage.PolicyStore
  alias OptimalEngine.Sync.{Capture, Gate, Lineage}
  alias OptimalEngine.Tenancy.Tenant

  @relay "relay+https://api.example/api/v1/engines/e1/sync"

  setup do
    n = System.unique_integer([:positive])
    tenant = "gate-#{n}"
    {:ok, _} = Tenant.create(%{id: tenant, name: "Gate #{n}"})

    {:ok, _} =
      OptimalEngine.Organization.create(%{
        id: "#{tenant}:org",
        tenant_id: tenant,
        slug: "org",
        name: "Org"
      })

    ws = create_workspace(tenant, "notes", %{})

    previous = System.get_env("CONNECTOR_KEY")
    System.put_env("CONNECTOR_KEY", Base.encode16(:crypto.strong_rand_bytes(32)))

    # The scheduler runs every peer on its own timer; held here so a tick never
    # interleaves with the cycles a test runs.
    scheduler = Process.whereis(OptimalEngine.Sync.Scheduler)
    if scheduler, do: :sys.suspend(scheduler, 60_000)

    on_exit(fn ->
      if scheduler && Process.alive?(scheduler), do: :sys.resume(scheduler)
      Application.delete_env(:optimal_engine, :http_mock)

      if previous,
        do: System.put_env("CONNECTOR_KEY", previous),
        else: System.delete_env("CONNECTOR_KEY")
    end)

    %{tenant: tenant, ws: ws, n: n}
  end

  # -- the P0: a remembered restricted memory --------------------------------------

  describe "versioned memories" do
    # The incident (WO-43 L9): the remember route writes a source package and a
    # claim labelled restricted, which the gate kept home, and a versioned
    # memory with the same text and no label column, which went to the relay.
    test "remembering a restricted memory puts none of its rows or text on the relay", ctx do
      secret = remember(ctx, "Wire 5530 to Harborview, routing 4407", ["restricted"])
      embed(ctx, secret.memory.id)

      {_result, sent} = push(ctx)

      refute sent?(sent, "memories", secret.memory.id)
      refute sent?(sent, "source_packages", secret.source_package.id)
      refute sent?(sent, "claims", secret.pending_claim.id)
      refute table_sent?(sent, "memory_embeddings", secret.memory.id)
      refute carries?(sent, "Harborview")
    end

    test "a restricted memory stays home with the source package and claim it was staged from",
         ctx do
      secret = remember(ctx, "Wire 9921 to Harborview, routing 4407", ["restricted"])
      open = remember(ctx, "The offsite is Thursday at noon", ["internal"])

      assert secret.action == :add
      assert secret.memory.metadata["security_labels"] == ["restricted"]

      # What indexing the memory leaves behind: its vector, its versions, its children.
      embed(ctx, secret.memory.id)
      {:ok, child} = Memory.extend(secret.memory.id, %{content: "Harborview wire confirmed Monday"})

      {:ok, newer} =
        Memory.update(secret.memory.id, %{content: "Wire 9921 to Harborview, routing 4408"})

      assert child.metadata["security_labels"] == ["restricted"]
      assert newer.metadata["security_labels"] == ["restricted"]

      {result, sent} = push(ctx)

      assert {:ok, %{sent: sent_count, gated: gated}} = result.push
      assert sent_count > 0 and gated > 0

      for id <- [
            secret.memory.id,
            secret.source_package.id,
            secret.pending_claim.id,
            child.id,
            newer.id
          ] do
        refute about?(sent, id), "a change about #{id} reached the relay"
      end

      refute carries?(sent, "Harborview")
      refute carries?(sent, "routing 4407")
      refute table_sent?(sent, "memory_embeddings", secret.memory.id)

      # The internal memory and what was staged from it still replicate.
      assert sent?(sent, "memories", open.memory.id)
      assert sent?(sent, "source_packages", open.source_package.id)
      assert sent?(sent, "claims", open.pending_claim.id)
    end

    test "a memory created with labels carries them and stays from a peer not cleared for them",
         ctx do
      {:ok, memory} =
        Memory.create(%{
          content: "Severance terms for the VP of sales",
          workspace_id: ctx.ws,
          tenant_id: ctx.tenant,
          security_labels: ["confidential"]
        })

      assert memory.metadata["security_labels"] == ["confidential"]

      {_result, internal_sent} = push(ctx, max_class: "internal")
      refute about?(internal_sent, memory.id)
      refute carries?(internal_sent, "Severance")
    end

    test "a memory written before labels travelled with it is still held by its source package",
         ctx do
      source = restricted_source(ctx, "Acquisition target is Zephyrcorp")

      # The row the remember route projected before this fix: staged from the
      # source package, no labels of its own.
      {:ok, memory} =
        Versioned.create(%{
          content: "Acquisition target is Zephyrcorp",
          workspace_id: ctx.ws,
          tenant_id: ctx.tenant,
          metadata: %{
            "memory_core_source_package_id" => source.id,
            "projection_kind" => "versioned_memory_staging"
          }
        })

      embed(ctx, memory.id)

      {:ok, plain} =
        Versioned.create(%{content: "Lunch is at one", workspace_id: ctx.ws, tenant_id: ctx.tenant})

      {_result, sent} = push(ctx)

      refute about?(sent, memory.id)
      refute carries?(sent, "Zephyrcorp")
      assert sent?(sent, "memories", plain.id)
    end

    test "a memory a restricted source package points at is held (Memory.create staging)", ctx do
      {:ok, memory} =
        Versioned.create(%{
          content: "Salary band for L7 is 310k",
          workspace_id: ctx.ws,
          tenant_id: ctx.tenant
        })

      _source =
        restricted_source(ctx, "Salary band for L7 is 310k",
          source_uri: "memory://#{memory.id}",
          metadata: %{"versioned_memory_id" => memory.id}
        )

      {_result, sent} = push(ctx)
      refute about?(sent, memory.id)
      refute carries?(sent, "Salary band")
    end

    test "a projection whose source cannot be found is held; a memory staged from nothing is not",
         ctx do
      {:ok, orphan} =
        Versioned.create(%{
          content: "Projected from a source that is gone",
          workspace_id: ctx.ws,
          tenant_id: ctx.tenant,
          metadata: %{"memory_core_source_package_id" => "sp_gone_#{ctx.n}"}
        })

      embed(ctx, orphan.id)

      {:ok, plain} =
        Versioned.create(%{
          content: "A note with no source",
          workspace_id: ctx.ws,
          tenant_id: ctx.tenant
        })

      {_result, sent} = push(ctx)

      refute about?(sent, orphan.id)
      refute carries?(sent, "Projected from a source that is gone")
      assert sent?(sent, "memories", plain.id)
    end
  end

  describe "recall" do
    test "a labelled memory is recalled through associations only by a caller granted its labels",
         ctx do
      secret = remember(ctx, "Northwind renewal discount is eighteen percent", ["restricted"])
      scope = ScopeEnvelope.resolve(%{tenant_id: ctx.tenant, workspace_id: ctx.ws})

      assert {:ok, _} = AssociativeProjection.rebuild(scope)
      assert {:ok, without} = AssociativeProjection.expand(["northwind"], scope)

      assert {:ok, granted} =
               AssociativeProjection.expand(["northwind"], scope,
                 allowed_security_labels: ["restricted"]
               )

      refute Enum.any?(without, &(&1.to.id == secret.memory.id))
      assert Enum.any?(granted, &(&1.to.id == secret.memory.id))
    end
  end

  # -- documents ----------------------------------------------------------------------

  describe "documents" do
    test "a restricted document stays home with its chunks, vectors, citations and the page citing them",
         ctx do
      {:ok, secret} =
        Intake.process("Zephyrcorp acquisition: the board approved an offer of 41 million",
          workspace_id: ctx.ws,
          tenant_id: ctx.tenant,
          node: "operator",
          security_labels: ["restricted"],
          write_files: false
        )

      {:ok, open} =
        Intake.process("Docs ship Friday and the changelog goes out Monday",
          workspace_id: ctx.ws,
          tenant_id: ctx.tenant,
          node: "operator",
          write_files: false
        )

      secret_id = secret.context.id
      open_id = open.context.id

      assert context_metadata(secret_id)["security_labels"] == ["restricted"]
      assert context_metadata(secret_id)["source_package_id"] == secret.source_package.id

      chunk = "chk-secret-#{ctx.n}"
      open_chunk = "chk-open-#{ctx.n}"
      insert_chunk(ctx, chunk, secret_id, "Zephyrcorp offer of 41 million")
      insert_chunk(ctx, open_chunk, open_id, "the changelog goes out Monday")

      for id <- [chunk, open_chunk] do
        {:ok, _} =
          Store.raw_query(
            "INSERT INTO chunk_embeddings (chunk_id, tenant_id, model, modality, dim, vector, workspace_id) VALUES (?1, ?2, 'm', 'text', 4, ?3, ?4)",
            [id, ctx.tenant, {:blob, <<1, 2, 3, 4>>}, ctx.ws]
          )

        {:ok, _} =
          Store.raw_query(
            "INSERT INTO intents (tenant_id, chunk_id, intent, confidence, evidence, workspace_id) VALUES (?1, ?2, 'inform', 0.9, ?3, ?4)",
            [ctx.tenant, id, "quoted from #{id}", ctx.ws]
          )
      end

      for id <- [secret_id, open_id] do
        {:ok, _} =
          Store.raw_query(
            "INSERT INTO vectors (context_id, embedding, model, dimensions, tenant_id, workspace_id) VALUES (?1, ?2, 'm', 4, ?3, ?4)",
            [id, {:blob, <<9, 9, 9, 9>>}, ctx.tenant, ctx.ws]
          )
      end

      wiki(ctx, "deal-room", "Offer notes {{cite: optimal://chunk/#{chunk}}}", [chunk])
      wiki(ctx, "docs-calendar", "Release notes", [open_chunk])
      wiki(ctx, "memory-link", "See optimal://contexts/#{secret_id} for the offer", [])

      wiki(
        ctx,
        "fragment-link",
        "Quoted from optimal://nodes/deal-room#" <> chunk <> " in full",
        []
      )

      # What the wiki bridge writes: a memory that cites the chunk by address.
      {:ok, cited} =
        Versioned.create(%{
          content: "The offer is 41 million",
          citation_uri: "optimal://chunk/" <> chunk,
          workspace_id: ctx.ws,
          tenant_id: ctx.tenant
        })

      {_result, sent} = push(ctx)

      for id <- [secret_id, secret.source_package.id, secret.pending_claim.id, chunk] do
        refute about?(sent, id), "a change about #{id} reached the relay"
      end

      refute carries?(sent, "Zephyrcorp")
      refute carries?(sent, "41 million")
      refute table_sent?(sent, "chunk_embeddings", chunk)
      refute table_sent?(sent, "vectors", secret_id)
      refute table_sent?(sent, "wiki_pages", ~s(["#{ctx.tenant}","deal-room","default",1]))
      refute table_sent?(sent, "wiki_pages", ~s(["#{ctx.tenant}","memory-link","default",1]))
      refute table_sent?(sent, "wiki_pages", ~s(["#{ctx.tenant}","fragment-link","default",1]))
      refute about?(sent, cited.id)

      assert sent?(sent, "contexts", open_id)
      assert sent?(sent, "chunks", open_chunk)
      assert table_sent?(sent, "chunk_embeddings", open_chunk)
      assert table_sent?(sent, "vectors", open_id)
      assert table_sent?(sent, "wiki_pages", ~s(["#{ctx.tenant}","docs-calendar","default",1]))
    end

    test "chunks of a labelled document are written at its class", ctx do
      {:ok, secret} =
        Intake.process("Quarterly layoffs list, not for circulation",
          workspace_id: ctx.ws,
          tenant_id: ctx.tenant,
          node: "operator",
          security_labels: ["confidential"],
          write_files: false
        )

      classes = chunk_classes(secret.context.id)
      assert Enum.all?(classes, &(&1 == "confidential"))
    end

    test "an entity resolved from a restricted source stays home; one with no sources does not",
         ctx do
      source = restricted_source(ctx, "Zephyrcorp is the acquisition target")

      for {id, name} <- [
            {"ent-secret-#{ctx.n}", "Zephyrcorp"},
            {"ent-plain-#{ctx.n}", "Acme Lunch Club"}
          ] do
        {:ok, _} =
          Store.raw_query(
            "INSERT INTO canonical_entities (id, tenant_id, workspace_id, entity_kind, canonical_name, normalized_name) VALUES (?1, ?2, ?3, 'organization', ?4, ?5)",
            [id, ctx.tenant, ctx.ws, name, String.downcase(name)]
          )
      end

      {:ok, _} =
        Store.raw_query(
          "INSERT INTO entity_mentions (id, workspace_id, source_package_id, surface_text, normalized_text, resolution_state, resolved_entity_id) VALUES (?1, ?2, ?3, 'Zephyrcorp', 'zephyrcorp', 'linked', ?4)",
          ["men-#{ctx.n}", ctx.ws, source.id, "ent-secret-#{ctx.n}"]
        )

      {_result, sent} = push(ctx)

      refute sent?(sent, "canonical_entities", "ent-secret-#{ctx.n}")
      refute sent?(sent, "entity_mentions", "men-#{ctx.n}")
      refute carries?(sent, "Zephyrcorp")
      assert sent?(sent, "canonical_entities", "ent-plain-#{ctx.n}")
    end

    test "documents written before they named their source are held through the ledger", ctx do
      first = restricted_source(ctx, "Legacy board minutes")
      second = restricted_source(ctx, "Legacy audit letter")

      # What intake left before this fix: a context with no metadata, found only
      # through the derivation ledger entry that produced it.
      legacy = "legacy-#{ctx.n}"
      from_unlabelled_entry = "legacy-link-#{ctx.n}"
      from_claim = "legacy-claim-#{ctx.n}"
      plain = "plain-#{ctx.n}"

      for {id, title} <- [
            {legacy, "Board minutes"},
            {from_unlabelled_entry, "Audit letter"},
            {from_claim, "Claim doc"},
            {plain, "Plain"}
          ] do
        insert_context(ctx, id, title)
      end

      ledger(ctx, first, legacy, ["restricted"])
      # An entry that lost its labels still lists the restricted package.
      ledger(ctx, second, from_unlabelled_entry, [])

      {:ok, _} =
        Store.raw_query(
          "INSERT INTO claims (id, tenant_id, workspace_id, source_package_id, signal_id, claim_text, security_labels) VALUES (?1, ?2, ?3, ?4, ?5, 'from the audit', '[\"restricted\"]')",
          ["clm-legacy-#{ctx.n}", ctx.tenant, ctx.ws, first.id, from_claim]
        )

      insert_chunk(ctx, "chk-legacy-#{ctx.n}", legacy, "Board minutes text")

      # A restricted document that was deleted before its chunk was pushed: the
      # ledger still remembers what it was.
      gone = "gone-#{ctx.n}"

      {:ok, _} =
        Store.raw_query(
          "INSERT INTO contexts (id, tenant_id, workspace_id, title, content, created_at, metadata) VALUES (?1, ?2, ?3, 'Gone', 'body', '2026-10-14T10:00:00Z', '{\"security_labels\":[\"restricted\"]}')",
          [gone, ctx.tenant, ctx.ws]
        )

      insert_chunk(ctx, "chk-gone-#{ctx.n}", gone, "Gone slice")
      {:ok, _} = Store.raw_query("DELETE FROM contexts WHERE id = ?1", [gone])

      # A public document that a restricted answer was assembled from stays public.
      cited = "cited-#{ctx.n}"
      insert_context(ctx, cited, "Cited")

      :ok =
        CoreStore.insert_derivation_entry(
          DerivationLedgerEntry.new(
            "retrieval.assemble",
            "assembly",
            [DerivationLedgerEntry.object_ref("context", cited)],
            [DerivationLedgerEntry.object_ref("context_package", "pkg-#{ctx.n}")],
            tenant_id: ctx.tenant,
            workspace_id: ctx.ws,
            security_labels: ["restricted"]
          )
        )

      {_result, sent} = push(ctx)

      refute sent?(sent, "contexts", legacy)
      refute sent?(sent, "contexts", from_unlabelled_entry)
      refute sent?(sent, "contexts", from_claim)
      refute sent?(sent, "chunks", "chk-legacy-#{ctx.n}")
      refute sent?(sent, "chunks", "chk-gone-#{ctx.n}")
      refute carries?(sent, "Board minutes")
      assert sent?(sent, "contexts", plain)
      assert sent?(sent, "contexts", cited)
    end
  end

  # -- the rule itself ------------------------------------------------------------------

  describe "the class a peer is cleared for" do
    test "a confidential row still syncs to a peer cleared for confidential", ctx do
      fact(ctx, "fact-conf-#{ctx.n}", "Renewal discount is 18 percent", ["confidential"])
      fact(ctx, "fact-open-#{ctx.n}", "Office closes at six", ["internal"])

      {_result, to_confidential} = push(ctx, max_class: "confidential")
      assert sent?(to_confidential, "facts", "fact-conf-#{ctx.n}")
      assert sent?(to_confidential, "facts", "fact-open-#{ctx.n}")
    end

    test "a confidential row stays home from a peer cleared for internal", ctx do
      fact(ctx, "fact-conf-#{ctx.n}", "Renewal discount is 18 percent", ["confidential"])
      fact(ctx, "fact-open-#{ctx.n}", "Office closes at six", ["internal"])

      {_result, to_internal} = push(ctx, max_class: "internal")
      refute sent?(to_internal, "facts", "fact-conf-#{ctx.n}")
      assert sent?(to_internal, "facts", "fact-open-#{ctx.n}")
    end

    test "a workspace above the peer's class sends nothing", ctx do
      secret_ws = create_workspace(ctx.tenant, "vault", %{"data_class" => "restricted"})
      {:ok, _} = Sync.enable(ctx.tenant, secret_ws, "user:owner")

      {:ok, _} =
        Versioned.create(%{content: "Vault note", workspace_id: secret_ws, tenant_id: ctx.tenant})

      {result, sent} = push(%{ctx | ws: secret_ws})
      assert {:ok, %{sent: 0, gated: gated}} = result.push
      assert gated > 0
      assert sent == []
    end

    test "an aggregate stays home while the workspace holds anything above the peer's class", ctx do
      report(ctx, "report-a-#{ctx.n}")
      snapshot(ctx, "snap-a-#{ctx.n}")
      {_result, before} = push(ctx)
      assert sent?(before, "analysis_reports", "report-a-#{ctx.n}")
      assert sent?(before, "data_quality_snapshots", "snap-a-#{ctx.n}")

      restricted_source(ctx, "Something nobody may copy")
      report(ctx, "report-b-#{ctx.n}")
      snapshot(ctx, "snap-b-#{ctx.n}")

      {_result, later} = push(ctx)
      refute sent?(later, "analysis_reports", "report-b-#{ctx.n}")
      refute sent?(later, "data_quality_snapshots", "snap-b-#{ctx.n}")
      refute carries?(later, "quoted claim text")
    end

    test "a wiki page that names nothing is held only while the workspace holds restricted data",
         ctx do
      wiki(ctx, "plain-a", "Nothing is cited here", [])
      {_result, before} = push(ctx)
      assert table_sent?(before, "wiki_pages", ~s(["#{ctx.tenant}","plain-a","default",1]))

      restricted_source(ctx, "Something nobody may copy")
      wiki(ctx, "plain-b", "Nothing is cited here either", [])

      {_result, later} = push(ctx)
      refute table_sent?(later, "wiki_pages", ~s(["#{ctx.tenant}","plain-b","default",1]))
    end

    test "a chunk written at a class above the peer's stays home; one at the default does not",
         ctx do
      insert_context(ctx, "ctx-class-#{ctx.n}", "Classed")

      insert_chunk(
        ctx,
        "chk-conf-#{ctx.n}",
        "ctx-class-#{ctx.n}",
        "Confidential slice",
        "confidential"
      )

      insert_chunk(ctx, "chk-plain-#{ctx.n}", "ctx-class-#{ctx.n}", "Ordinary slice")

      {_result, sent} = push(ctx, max_class: "internal")

      refute sent?(sent, "chunks", "chk-conf-#{ctx.n}")
      assert sent?(sent, "chunks", "chk-plain-#{ctx.n}")
      assert sent?(sent, "contexts", "ctx-class-#{ctx.n}")
    end

    test "the serving ceiling is the Engine's to set", ctx do
      secret = remember(ctx, "Wire 4471 to Harborview", ["restricted"])

      refute about?(Sync.changes(ctx.tenant, ctx.ws)["mutations"], secret.memory.id)

      Application.put_env(:optimal_engine, :sync_serve_max_class, "restricted")
      on_exit(fn -> Application.delete_env(:optimal_engine, :sync_serve_max_class) end)

      assert about?(Sync.changes(ctx.tenant, ctx.ws)["mutations"], secret.memory.id)
    end

    test "deleting a restricted row is not sent; deleting an ordinary one is", ctx do
      fact(ctx, "fact-del-#{ctx.n}", "Bank detail", ["restricted"])
      insert_context(ctx, "ctx-del-#{ctx.n}", "Ordinary")
      {:ok, _} = Store.raw_query("DELETE FROM facts WHERE id = ?1", ["fact-del-#{ctx.n}"])
      {:ok, _} = Store.raw_query("DELETE FROM contexts WHERE id = ?1", ["ctx-del-#{ctx.n}"])

      {_result, sent} = push(ctx)

      refute Enum.any?(
               sent,
               &(&1["entity_type"] == "facts" and &1["entity_id"] == "fact-del-#{ctx.n}")
             )

      assert Enum.any?(
               sent,
               &(&1["entity_type"] == "contexts" and &1["operation"] == "delete" and
                   &1["entity_id"] == "ctx-del-#{ctx.n}")
             )
    end

    test "serving changes applies the same gate", ctx do
      secret = remember(ctx, "Wire 4471 to Harborview", ["restricted"])
      open = remember(ctx, "Standup is at ten", ["internal"])

      page = Sync.changes(ctx.tenant, ctx.ws)
      served = page["mutations"]

      refute about?(served, secret.memory.id)
      refute carries?(served, "Harborview")
      assert sent?(served, "memories", open.memory.id)

      everything = Sync.changes(ctx.tenant, ctx.ws, max_class: "restricted")
      assert sent?(everything["mutations"], "memories", secret.memory.id)
    end

    test "the storage ledger reader applies the same gate and continues past what it skips", ctx do
      secret = remember(ctx, "Wire 4471 to Harborview", ["restricted"])
      open = remember(ctx, "Standup is at ten", ["internal"])
      {:ok, _} = Capture.seal()

      # The restricted memory's rows come first in the ledger: a reader asking
      # for one change at a time must be taken past them, not stopped by them.
      {read, last} = read_ledger(ctx.ws, 0, 1, [])

      refute about?(read, secret.memory.id)
      refute carries?(read, "Harborview")
      assert sent?(read, "memories", open.memory.id)
      assert last >= Enum.max(Enum.map(read, & &1["sequence"]))

      # A change of an entity type that is no replicated table is not ours to hold.
      {:ok, _} =
        PolicyStore.append_mutation(%{
          workspace_id: ctx.ws,
          device_id: "device-a",
          entity_type: "app_event",
          entity_id: "evt-#{ctx.n}",
          operation: :update,
          payload: %{"title" => "Updated"},
          idempotency_key: "evt-#{ctx.n}"
        })

      {:ok, later, _next} = PolicyStore.releasable_mutations_after(ctx.ws, last, 10)
      assert Enum.any?(later, &(&1.entity_id == "evt-#{ctx.n}"))
    end

    test "a peer that pulls GET /api/sync/changes is handed nothing restricted", ctx do
      # The route runs as the default tenant, so the workspace does too.
      {:ok, ws} = Workspace.create(%{slug: "pull-#{ctx.n}", name: "Pull #{ctx.n}"})
      {:ok, _} = Sync.enable("default", ws.id, "user:owner")
      pull = %{ctx | tenant: "default", ws: ws.id}

      secret = remember(pull, "Wire 7781 to Harborview, routing 4407", ["restricted"])
      open = remember(pull, "Standup is at ten", ["internal"])

      conn =
        Plug.Test.conn(
          :get,
          "/api/sync/changes?" <> URI.encode_query(%{"workspace" => ws.id, "since" => 0})
        )
        |> OptimalEngine.API.Router.call(OptimalEngine.API.Router.init([]))

      assert conn.status == 200
      page = Jason.decode!(conn.resp_body)

      refute about?(page["mutations"], secret.memory.id)
      refute about?(page["mutations"], secret.source_package.id)
      refute carries?(page["mutations"], "Harborview")
      assert sent?(page["mutations"], "memories", open.memory.id)

      # The cursor moves past what was held, so a puller is not stuck on it.
      assert page["cursor"] >= Enum.max(Enum.map(page["mutations"], & &1["sequence"]))
    end

    test "a restricted row the relay serves on a pull is not applied here", ctx do
      id = "mem_cloud_secret_#{ctx.n}"

      cloud = [
        %{
          "sequence" => 1,
          "id" => "mut_cloud_#{ctx.n}_1",
          "device_id" => "rep_cloud",
          "entity_type" => "memories",
          "entity_id" => id,
          "operation" => "create",
          "occurred_at" => "2026-10-20T12:00:00.000",
          "payload_hash" => "h",
          "idempotency_key" => "rep_cloud:1",
          "payload" => %{
            "row" => %{
              "id" => id,
              "tenant_id" => ctx.tenant,
              "workspace_id" => ctx.ws,
              "content" => "Cloud-side wire 5530 to Harborview",
              "metadata" => Jason.encode!(%{"security_labels" => ["restricted"]})
            },
            "blobs" => %{}
          }
        }
      ]

      {result, _sent} = push(ctx, cloud: cloud)

      assert {:ok, %{applied: 0, skipped: %{gated: 1}}} = result.pull
      assert {:error, :not_found} = Memory.get(id)
    end

    test "a received memory that carries restricted labels in its metadata is not applied", ctx do
      row = fn id, metadata ->
        %{
          "row" => %{
            "id" => id,
            "tenant_id" => ctx.tenant,
            "workspace_id" => ctx.ws,
            "content" => "remote memory #{id}",
            "metadata" => Jason.encode!(metadata)
          },
          "blobs" => %{}
        }
      end

      mutation = fn id, metadata ->
        %{
          "id" => "mut_remote_#{ctx.n}_#{id}",
          "device_id" => "rep_remote",
          "entity_type" => "memories",
          "entity_id" => id,
          "operation" => "create",
          "occurred_at" => "2026-10-20T12:00:00.000",
          "payload" => row.(id, metadata)
        }
      end

      mutations = [
        mutation.("mem_secret_#{ctx.n}", %{"security_labels" => ["restricted"]}),
        mutation.("mem_open_#{ctx.n}", %{})
      ]

      assert {:ok, %{applied: 1, skipped: %{gated: 1}}} =
               Sync.apply_changes(ctx.tenant, ctx.ws, mutations)
    end
  end

  # -- the map ----------------------------------------------------------------------------

  describe "the lineage map" do
    test "classifies every table the Engine replicates" do
      unclassified = Capture.eligible_tables() -- Lineage.tables()

      assert unclassified == [],
             "classify #{inspect(unclassified)} in OptimalEngine.Sync.Lineage before they replicate"
    end

    test "names only tables and columns that exist" do
      for table <- Lineage.tables() do
        spec = Lineage.spec(table)
        columns = table |> Capture.columns() |> Enum.map(& &1.name)

        assert columns != [], "#{table} is in the lineage map but not in the schema"

        for column <- Lineage.columns(spec) do
          assert column in columns, "#{table} has no column #{column}"
        end

        for target <- ref_targets(spec) do
          assert Lineage.spec(target), "#{table} points at #{target}, which the map does not know"
        end
      end
    end

    test "a mutation of an entity type that is no table is not held on the storage ledger", ctx do
      gate = Gate.open(ctx.tenant, ctx.ws, "confidential")

      try do
        other = %{
          "entity_type" => "app_event",
          "operation" => "update",
          "payload" => %{"title" => "x"}
        }

        refute Gate.hold_known?(gate, other)
        assert Gate.hold?(gate, other)
      after
        Gate.close(gate)
      end
    end

    test "an unclassified table stays home", ctx do
      gate = Gate.open(ctx.tenant, ctx.ws, "confidential")

      try do
        mutation = %{
          "entity_type" => "table_nobody_classified",
          "operation" => "create",
          "payload" => %{"row" => %{}}
        }

        assert Gate.hold?(gate, mutation)
      after
        Gate.close(gate)
      end
    end
  end

  # -- helpers ----------------------------------------------------------------------------

  # The ledger a page at a time, following `next_after`, as maps with string keys.
  defp read_ledger(ws, after_sequence, limit, acc) do
    {:ok, page, next_after} = PolicyStore.releasable_mutations_after(ws, after_sequence, limit)
    acc = acc ++ Enum.map(page, &Jason.decode!(Jason.encode!(&1)))

    if next_after > after_sequence and length(acc) < 500,
      do: read_ledger(ws, next_after, limit, acc),
      else: {acc, next_after}
  end

  defp ref_targets(spec) do
    Enum.flat_map(spec.refs, fn
      {:id, _column, table} -> [table]
      {:json_ids, _column, table} -> [table]
      {:meta_id, _key, table} -> [table]
      {:json_map, _column, mapping} -> Map.values(mapping)
      _other -> []
    end)
  end

  defp create_workspace(tenant, slug, metadata) do
    {:ok, ws} =
      Workspace.create(%{
        tenant_id: tenant,
        organization_id: "#{tenant}:org",
        slug: slug,
        name: String.capitalize(slug),
        metadata: metadata
      })

    {:ok, _} = Sync.enable(tenant, ws.id, "user:owner")
    ws.id
  end

  defp remember(ctx, content, labels) do
    {:ok, result} =
      Memory.remember(
        %{
          content: content,
          workspace_id: ctx.ws,
          tenant_id: ctx.tenant,
          security_labels: labels,
          actor_id: "user:tester"
        },
        force: true,
        versioned_projection: true
      )

    result
  end

  defp embed(ctx, memory_id) do
    {:ok, _} =
      Store.raw_query(
        "INSERT INTO memory_embeddings (memory_id, tenant_id, workspace_id, model, dimensions, embedding, content_hash) VALUES (?1, ?2, ?3, 'm', 4, ?4, 'h')",
        [memory_id, ctx.tenant, ctx.ws, {:blob, <<7, 7, 7, 7>>}]
      )
  end

  defp restricted_source(ctx, text, opts \\ []) do
    source =
      SourcePackage.from_text(
        text,
        [
          tenant_id: ctx.tenant,
          workspace_id: ctx.ws,
          source_type: "note",
          security_labels: ["restricted"]
        ] ++ opts
      )

    :ok = CoreStore.insert_source_package(source)
    source
  end

  defp ledger(ctx, source, context_id, labels) do
    source_ref = DerivationLedgerEntry.object_ref("source_package", source.id)

    entry =
      DerivationLedgerEntry.new(
        "intake.process",
        "source_to_signal_context",
        [source_ref],
        [
          DerivationLedgerEntry.object_ref("signal", context_id),
          DerivationLedgerEntry.object_ref("context", context_id)
        ],
        tenant_id: ctx.tenant,
        workspace_id: ctx.ws,
        source_package_links: [source_ref],
        evidence_links: [source_ref],
        security_labels: labels
      )

    :ok = CoreStore.insert_derivation_entry(entry)
  end

  defp insert_context(ctx, id, title) do
    {:ok, _} =
      Store.raw_query(
        "INSERT INTO contexts (id, tenant_id, workspace_id, title, content, created_at) VALUES (?1, ?2, ?3, ?4, 'body', '2026-10-14T10:00:00Z')",
        [id, ctx.tenant, ctx.ws, title]
      )
  end

  defp insert_chunk(ctx, id, context_id, text, class \\ "internal") do
    {:ok, _} =
      Store.raw_query(
        "INSERT INTO chunks (id, tenant_id, signal_id, scale, text, classification_level, workspace_id) VALUES (?1, ?2, ?3, 'document', ?4, ?5, ?6)",
        [id, ctx.tenant, context_id, text, class, ctx.ws]
      )
  end

  defp snapshot(ctx, id) do
    {:ok, _} =
      Store.raw_query(
        "INSERT INTO data_quality_snapshots (id, tenant_id, workspace_id, health_score, health_status, dashboard) VALUES (?1, ?2, ?3, 90, 'healthy', ?4)",
        [
          id,
          ctx.tenant,
          ctx.ws,
          Jason.encode!(%{"claim_clusters" => [%{"representative" => "quoted claim text"}]})
        ]
      )
  end

  defp context_metadata(id) do
    {:ok, [[json]]} = Store.raw_query("SELECT metadata FROM contexts WHERE id = ?1", [id])
    Jason.decode!(json)
  end

  # The decomposition runs in the background; chunks that exist by the time
  # it has had a moment are the ones whose class is checked.
  defp chunk_classes(context_id) do
    Process.sleep(1_500)

    {:ok, rows} =
      Store.raw_query("SELECT classification_level FROM chunks WHERE signal_id = ?1", [context_id])

    Enum.map(rows, fn [class] -> class end)
  end

  defp wiki(ctx, slug, body, chunk_ids) do
    {:ok, _} =
      Store.raw_query(
        "INSERT INTO wiki_pages (tenant_id, workspace_id, slug, audience, version, frontmatter, body) VALUES (?1, ?2, ?3, 'default', 1, '{}', ?4)",
        [ctx.tenant, ctx.ws, slug, body]
      )

    for chunk_id <- chunk_ids do
      {:ok, _} =
        Store.raw_query(
          "INSERT INTO citations (tenant_id, workspace_id, wiki_slug, wiki_audience, chunk_id, claim_hash) VALUES (?1, ?2, ?3, 'default', ?4, 'h')",
          [ctx.tenant, ctx.ws, slug, chunk_id]
        )
    end
  end

  defp fact(ctx, id, text, labels) do
    {:ok, _} =
      Store.raw_query(
        "INSERT INTO facts (id, tenant_id, workspace_id, fact_text, security_labels) VALUES (?1, ?2, ?3, ?4, ?5)",
        [id, ctx.tenant, ctx.ws, text, Jason.encode!(labels)]
      )
  end

  defp report(ctx, id) do
    {:ok, _} =
      Store.raw_query(
        "INSERT INTO analysis_reports (id, tenant_id, workspace_id, kind, status, summary, report) VALUES (?1, ?2, ?3, 'promises', 'ok', 'two open promises', '{}')",
        [id, ctx.tenant, ctx.ws]
      )
  end

  # -- the relay -----------------------------------------------------------------------------

  # Registers a push peer cleared up to `:max_class`, runs one cycle, and
  # returns the result with every mutation the relay received for this
  # workspace.
  defp push(ctx, opts \\ []) do
    pushed = :ets.new(:pushed, [:public, :bag])
    cloud = Keyword.get(opts, :cloud, [])
    relay(ctx, pushed, cloud)

    {:ok, _} =
      Sync.add_peer(
        ctx.tenant,
        %{
          "workspace_id" => ctx.ws,
          "url" => @relay,
          "api_key" => "relay-key",
          "policy" => if(cloud == [], do: "push", else: "both"),
          "max_class" => Keyword.get(opts, :max_class, "confidential")
        },
        "u"
      )

    [result] = Sync.run_all() |> Enum.filter(&(&1.workspace_id == ctx.ws))
    assert result.status == "active", "the cycle failed: #{inspect(result)}"

    {result, for({:mutations, mutations} <- :ets.tab2list(pushed), m <- mutations, do: m)}
  end

  defp relay(ctx, pushed, cloud) do
    engine = %{
      "replica_id" => "rep_cloud",
      "migration" => Sync.engine_info()["migration"],
      "version" => "0.0.0"
    }

    Application.put_env(:optimal_engine, :http_mock, fn url, req ->
      uri = URI.parse(url)
      query = URI.decode_query(uri.query || "")
      route = uri.path |> String.split("/") |> List.last()

      cond do
        # Peers left by other tests run in the same cycle; they get a refusal.
        query["workspace"] != ctx.ws ->
          answer(400, %{"error" => %{"code" => "WORKSPACE_REQUIRED"}})

        {req[:method], route} == {:get, "status"} ->
          answer(200, %{"data" => Map.merge(engine, %{"workspace_id" => ctx.ws, "enabled" => true})})

        {req[:method], route} == {:get, "pull"} ->
          answer(200, %{
            "data" => %{
              "workspace_id" => ctx.ws,
              "mutations" => if(query["since"] == "0", do: cloud, else: []),
              "cursor" =>
                if(query["since"] == "0",
                  do: length(cloud),
                  else: String.to_integer(query["since"] || "0")
                ),
              "more" => false,
              "engine" => engine
            }
          })

        {req[:method], route} == {:post, "push"} ->
          mutations = req[:body]["mutations"]
          :ets.insert(pushed, {:mutations, mutations})
          answer(200, %{"data" => %{"applied" => length(mutations), "engine" => engine}})

        true ->
          answer(404, %{"error" => %{"code" => "NOT_FOUND"}})
      end
    end)
  end

  defp answer(status, body) do
    {:ok,
     {{~c"HTTP/1.1", status, ~c"OK"}, [{~c"content-type", ~c"application/json"}],
      Jason.encode!(body)}}
  end

  defp sent?(mutations, table, id),
    do: Enum.any?(mutations, &(&1["entity_type"] == table and &1["entity_id"] == id))

  # Tables whose rows are named by a key that is not the row's id.
  defp table_sent?(mutations, table, key) do
    Enum.any?(mutations, fn mutation ->
      mutation["entity_type"] == table and
        (mutation["entity_id"] == key or
           get_in(mutation, ["payload", "row", "memory_id"]) == key or
           get_in(mutation, ["payload", "row", "chunk_id"]) == key or
           get_in(mutation, ["payload", "row", "context_id"]) == key)
    end)
  end

  defp carries?(mutations, text),
    do: Enum.any?(mutations, &String.contains?(Jason.encode!(&1), text))

  # Whether a change is about the row `id`: the row itself, or a row that
  # points at it. (Other rows may name it in free-form metadata: the encoding
  # gate records the memory a new one is most like, for instance. That is an
  # opaque id, not the row.)
  @links ~w(memory_id source_memory_id target_memory_id parent_memory_id root_memory_id
            source_package_id claim_id chunk_id context_id signal_id)

  defp about?(mutations, id) do
    Enum.any?(mutations, fn mutation ->
      mutation["entity_id"] == id or
        Enum.any?(@links, &(get_in(mutation, ["payload", "row", &1]) == id))
    end)
  end
end
