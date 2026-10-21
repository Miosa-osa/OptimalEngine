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
  alias OptimalEngine.Sync.{Capture, Gate, GateCache, Lineage}
  alias OptimalEngine.Tenancy.Tenant

  import ExUnit.CaptureLog

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

  # -- corners that must fail closed -----------------------------------------------------

  describe "fail-closed corners" do
    test "claims raised from a confidential fact conflict stay home from an internal peer", ctx do
      fact_conflict(ctx, ["confidential"], nil)

      claims = conflict_claims(ctx)
      assert length(claims) == 2

      {_result, sent} = push(ctx, max_class: "internal")

      for [claim_id, source_id] <- claims do
        refute sent?(sent, "claims", claim_id)
        refute sent?(sent, "source_packages", source_id)
      end

      # Every version of the fact stays home, the older one that came from the
      # other Engine unlabelled included: the row has labels now.
      refute carries?(sent, "Wire code")
    end

    test "the labels of the remote version reach the claims", ctx do
      fact_conflict(ctx, nil, ["confidential"])
      assert_conflict_labels(ctx, ["confidential"])
    end

    test "the labels of the local version reach the claims", ctx do
      fact_conflict(ctx, ["restricted"], nil)
      assert_conflict_labels(ctx, ["restricted"])
    end

    test "the claims follow the fact when it is classified higher later", ctx do
      fact_id = fact_conflict(ctx, ["internal"], nil)

      {:ok, _} =
        Store.raw_query("UPDATE facts SET security_labels = '[\"restricted\"]' WHERE id = ?1", [
          fact_id
        ])

      {_result, sent} = push(ctx)

      for [claim_id, source_id] <- conflict_claims(ctx) do
        refute sent?(sent, "claims", claim_id)
        refute sent?(sent, "source_packages", source_id)
      end
    end

    test "a workspace with a data class this Engine does not know is treated as restricted",
         ctx do
      odd = create_workspace(ctx.tenant, "odd", %{"data_class" => "secret"})
      {:ok, _} = Versioned.create(%{content: "Odd note", workspace_id: odd, tenant_id: ctx.tenant})

      {result, sent} = push(%{ctx | ws: odd})

      assert {:ok, %{sent: 0, gated: gated}} = result.push
      assert gated > 0
      assert sent == []
      assert {:error, :workspace_class_above_gate} = Sync.apply_changes(ctx.tenant, odd, [])
    end

    test "a workspace that cannot be read sends nothing, and is sent when it can", ctx do
      {:ok, plain} =
        Versioned.create(%{content: "A plain note", workspace_id: ctx.ws, tenant_id: ctx.tenant})

      {{failed, sent}, log} =
        ExUnit.CaptureLog.with_log(fn ->
          with_renamed_column("workspaces", "description", "description_x", fn ->
            cycle(ctx, [])
          end)
        end)

      assert failed.status == "error"
      assert {:error, {:gate_unreadable, _}} = failed.push
      assert sent == []

      # The log names the relay by scheme and host only: a peer URL's path can hold its secret.
      assert log =~ "[Sync] push to relay+https://api.example/... held back"
      refute log =~ "engines/e1"

      {_result, later} = push(ctx)
      assert sent?(later, "memories", plain.id)
    end

    test "a Store error while the gate reads a source holds the cycle, not the row", ctx do
      {:ok, memory} =
        Versioned.create(%{content: "A plain note", workspace_id: ctx.ws, tenant_id: ctx.tenant})

      embed(ctx, memory.id)

      {failed, sent} =
        with_renamed_column("memories", "source_chunk_id", "source_chunk_id_x", fn ->
          cycle(ctx, [])
        end)

      assert failed.status == "error"
      assert {:error, {:gate_unreadable, _}} = failed.push
      assert sent == []

      # The cursor did not pass the row: the next cycle sends it.
      {_result, later} = push(ctx)
      assert table_sent?(later, "memory_embeddings", memory.id)
      assert sent?(later, "memories", memory.id)
    end

    test "a label stored as a blob is read", ctx do
      {:ok, _} =
        Store.raw_query(
          "INSERT INTO facts (id, tenant_id, workspace_id, fact_text, security_labels) VALUES (?1, ?2, ?3, 'Blob labelled', ?4)",
          ["fact-blob-#{ctx.n}", ctx.tenant, ctx.ws, {:blob, ~s(["restricted"])}]
        )

      {_result, sent} = push(ctx)

      refute sent?(sent, "facts", "fact-blob-#{ctx.n}")
      refute carries?(sent, "Blob labelled")
    end

    test "a received row whose labels arrive as a blob is not applied", ctx do
      mutation = %{
        "id" => "mut_remote_blob_#{ctx.n}",
        "device_id" => "rep_remote",
        "entity_type" => "facts",
        "entity_id" => "fact-remote-blob-#{ctx.n}",
        "operation" => "create",
        "occurred_at" => "2026-10-20T12:00:00.000",
        "payload" => %{
          "row" => %{
            "id" => "fact-remote-blob-#{ctx.n}",
            "tenant_id" => ctx.tenant,
            "workspace_id" => ctx.ws,
            "fact_text" => "Remote blob labelled",
            "security_labels" => nil
          },
          "blobs" => %{"security_labels" => Base.encode16(~s(["restricted"]))}
        }
      }

      assert {:ok, %{applied: 0, skipped: %{gated: 1}}} =
               Sync.apply_changes(ctx.tenant, ctx.ws, [mutation])
    end
  end

  # -- changes written before a row was labelled -------------------------------------------

  describe "stale snapshots" do
    test "a change captured before the row was labelled is held with the row", ctx do
      id = "fact-late-#{ctx.n}"
      fact(ctx, id, "Wire code 5501", [])
      {:ok, _} = Capture.seal()

      {:ok, _} =
        Store.raw_query("UPDATE facts SET security_labels = '[\"restricted\"]' WHERE id = ?1", [id])

      {_result, sent} = push(ctx, max_class: "internal")

      refute sent?(sent, "facts", id)
      refute carries?(sent, "Wire code 5501")
    end

    test "a change captured before a memory was labelled is held with the memory", ctx do
      {:ok, memory} =
        Versioned.create(%{
          content: "Vault door code 9921",
          workspace_id: ctx.ws,
          tenant_id: ctx.tenant
        })

      {:ok, _} = Capture.seal()

      {:ok, _} =
        Store.raw_query(
          "UPDATE memories SET metadata = json_set(COALESCE(metadata, '{}'), '$.security_labels', json('[\"restricted\"]')) WHERE id = ?1",
          [memory.id]
        )

      {_result, sent} = push(ctx, max_class: "internal")

      refute sent?(sent, "memories", memory.id)
      refute carries?(sent, "Vault door code 9921")
    end

    test "a change to a row that is gone is classified as it was written", ctx do
      plain = "fact-gone-plain-#{ctx.n}"
      secret = "fact-gone-secret-#{ctx.n}"
      fact(ctx, plain, "Gone but public 5502", [])
      fact(ctx, secret, "Gone and secret 5503", ["restricted"])
      {:ok, _} = Capture.seal()
      {:ok, _} = Store.raw_query("DELETE FROM facts WHERE id IN (?1, ?2)", [plain, secret])

      {_result, sent} = push(ctx, max_class: "internal")

      assert carries?(sent, "Gone but public 5502")
      refute carries?(sent, "Gone and secret 5503")
    end

    test "a row labelled and then deleted holds every version it had", ctx do
      id = "fact-declass-#{ctx.n}"
      fact(ctx, id, "Declassified secret 5510", [])
      {:ok, _} = Capture.seal()

      {:ok, _} =
        Store.raw_query("UPDATE facts SET security_labels = '[\"restricted\"]' WHERE id = ?1", [id])

      {:ok, _} = Capture.seal()
      {:ok, _} = Store.raw_query("DELETE FROM facts WHERE id = ?1", [id])

      {_result, sent} = push(ctx, max_class: "internal")

      refute sent?(sent, "facts", id)
      refute carries?(sent, "Declassified secret 5510")
    end

    test "a deleted row's ledger is read to the end, not to its newest versions", ctx do
      # Declassified at the second version, edited many times, deleted. The
      # oldest version is restricted and the newest hundred are open.
      id = "fact-many-#{ctx.n}"
      fact(ctx, id, "Version 1 secret 5530", ["restricted"])
      {:ok, _} = Capture.seal()

      for n <- 2..130 do
        {:ok, _} =
          Store.raw_query(
            "UPDATE facts SET security_labels = '[]', fact_text = ?2 WHERE id = ?1",
            [id, "Version #{n} open 5530"]
          )

        {:ok, _} = Capture.seal()
      end

      {:ok, _} = Store.raw_query("DELETE FROM facts WHERE id = ?1", [id])

      {_result, sent} = push(ctx, max_class: "internal")

      refute sent?(sent, "facts", id)
      refute carries?(sent, "open 5530")
      refute carries?(sent, "Version 1 secret 5530")
    end

    test "a deleted row whose versions were all open is sent whole, however many there were",
         ctx do
      few = "fact-few-#{ctx.n}"
      many = "fact-open-many-#{ctx.n}"

      for {id, versions} <- [{few, 19}, {many, 120}] do
        fact(ctx, id, "#{id} version 1", [])
        {:ok, _} = Capture.seal()

        for n <- 2..versions do
          {:ok, _} =
            Store.raw_query("UPDATE facts SET fact_text = ?2 WHERE id = ?1", [
              id,
              "#{id} version #{n}"
            ])

          {:ok, _} = Capture.seal()
        end

        {:ok, _} = Store.raw_query("DELETE FROM facts WHERE id = ?1", [id])
      end

      {_result, sent} = push(ctx, max_class: "internal")

      for {id, versions} <- [{few, 19}, {many, 120}] do
        assert carries?(sent, "#{id} version 1")
        assert carries?(sent, "#{id} version #{versions}")

        assert Enum.any?(sent, &(&1["entity_id"] == id and &1["operation"] == "delete")),
               "the delete of #{id} was held"
      end
    end

    test "a version a peer sent without the labels does not release the row's other versions",
         ctx do
      id = "fact-peer-#{ctx.n}"
      fact(ctx, id, "Peer secret 5511", ["restricted"])
      {:ok, _} = Capture.seal()

      remote_change(ctx, "facts", id, %{"fact_text" => "Peer edit 5512", "security_labels" => "[]"})
      {:ok, _} = Store.raw_query("DELETE FROM facts WHERE id = ?1", [id])

      {_result, sent} = push(ctx, max_class: "internal")

      refute carries?(sent, "Peer secret 5511")
      refute carries?(sent, "Peer edit 5512")
    end

    test "a change to a row that stays unlabelled is still sent", ctx do
      id = "fact-open-#{ctx.n}"
      fact(ctx, id, "Open fact 5504", [])
      {:ok, _} = Capture.seal()

      {:ok, _} =
        Store.raw_query("UPDATE facts SET fact_text = 'Open fact 5505' WHERE id = ?1", [id])

      {_result, sent} = push(ctx, max_class: "internal")

      assert carries?(sent, "Open fact 5504")
      assert carries?(sent, "Open fact 5505")
    end
  end

  # -- applying a change to a row that is held here ----------------------------------------

  describe "labels only grow when a change is applied" do
    test "a fact keeps its labels when the other Engine sends it without them", ctx do
      id = "fact-grow-#{ctx.n}"
      fact(ctx, id, "Original 7701", ["restricted"])

      remote_change(ctx, "facts", id, %{"fact_text" => "Edited 7701", "security_labels" => "[]"})

      assert stored("facts", id, "fact_text") == "Edited 7701"
      assert label_list("facts", id) == ["restricted"]
    end

    test "the labels of both sides are kept", ctx do
      id = "fact-both-#{ctx.n}"
      fact(ctx, id, "Original 7702", ["restricted", "private"])

      remote_change(ctx, "facts", id, %{"security_labels" => ~s(["internal","team-a"])})

      assert Enum.sort(label_list("facts", id)) == ["internal", "private", "restricted", "team-a"]
    end

    test "labels held here that cannot be read count as restricted", ctx do
      id = "fact-bad-#{ctx.n}"

      {:ok, _} =
        Store.raw_query(
          "INSERT INTO facts (id, tenant_id, workspace_id, fact_text, security_labels) VALUES (?1, ?2, ?3, 'Original 7703', 'not a list')",
          [id, ctx.tenant, ctx.ws]
        )

      remote_change(ctx, "facts", id, %{"security_labels" => ~s(["private"])})

      assert Enum.sort(label_list("facts", id)) == ["private", "restricted"]
    end

    test "a memory keeps the labels in its metadata", ctx do
      %{memory: memory} = remember(ctx, "Secret 7704", ["restricted"])

      remote_change(ctx, "memories", memory.id, %{"content" => "Edited 7704", "metadata" => "{}"})

      assert stored("memories", memory.id, "content") == "Edited 7704"

      assert Jason.decode!(stored("memories", memory.id, "metadata"))["security_labels"] == [
               "restricted"
             ]
    end

    test "the other keys of the sender's metadata are kept beside the labels", ctx do
      %{memory: memory} = remember(ctx, "Secret 7705", ["restricted"])

      remote_change(ctx, "memories", memory.id, %{"metadata" => ~s({"source":"phone"})})

      metadata = Jason.decode!(stored("memories", memory.id, "metadata"))
      assert metadata["security_labels"] == ["restricted"]
      assert metadata["source"] == "phone"
    end

    test "partitions grow the same way", ctx do
      id = "fact-parts-#{ctx.n}"

      {:ok, _} =
        Store.raw_query(
          "INSERT INTO facts (id, tenant_id, workspace_id, fact_text, partition_ids) VALUES (?1, ?2, ?3, 'Original 7709', ?4)",
          [id, ctx.tenant, ctx.ws, ~s(["team-a"])]
        )

      remote_change(ctx, "facts", id, %{"partition_ids" => ~s(["team-b"])})
      assert Enum.sort(Jason.decode!(stored("facts", id, "partition_ids"))) == ["team-a", "team-b"]

      remote_change(ctx, "facts", id, %{"partition_ids" => "[]"})
      assert Enum.sort(Jason.decode!(stored("facts", id, "partition_ids"))) == ["team-a", "team-b"]
    end

    test "the partitions in a memory's metadata are kept beside its labels", ctx do
      %{memory: memory} = remember(ctx, "Atlas notes 7710", ["internal"])

      {:ok, _} =
        Store.raw_query(
          "UPDATE memories SET metadata = json_set(metadata, '$.partition_ids', json('[\"team-a\"]')) WHERE id = ?1",
          [memory.id]
        )

      remote_change(ctx, "memories", memory.id, %{"metadata" => ~s({"source":"phone"})})

      metadata = Jason.decode!(stored("memories", memory.id, "metadata"))
      assert metadata["partition_ids"] == ["team-a"]
      assert metadata["security_labels"] == ["internal"]
      assert metadata["source"] == "phone"
    end

    test "a chunk keeps the higher classification level", ctx do
      insert_context(ctx, "doc-grow-#{ctx.n}", "Doc")
      insert_chunk(ctx, "chk-grow-#{ctx.n}", "doc-grow-#{ctx.n}", "Text 7706", "restricted")
      insert_chunk(ctx, "chk-up-#{ctx.n}", "doc-grow-#{ctx.n}", "Text 7707", "internal")

      remote_change(ctx, "chunks", "chk-grow-#{ctx.n}", %{"classification_level" => "internal"})
      remote_change(ctx, "chunks", "chk-up-#{ctx.n}", %{"classification_level" => "confidential"})

      assert stored("chunks", "chk-grow-#{ctx.n}", "classification_level") == "restricted"
      assert stored("chunks", "chk-up-#{ctx.n}", "classification_level") == "confidential"
    end

    test "a peer that is not cleared for a row can neither delete nor rewrite it", ctx do
      id = "fact-del-#{ctx.n}"
      fact(ctx, id, "Original 7711", ["restricted"])

      log =
        capture_log([level: :warning], fn ->
          assert {:ok, %{applied: 0, skipped: %{gated: 1}}} =
                   remote_delete(ctx, "facts", id, max_class: "internal")
        end)

      # The log names the table, the key and the device, and nothing the row holds.
      assert log =~ "a delete of facts"
      assert log =~ id
      assert log =~ "rep_remote"
      refute log =~ "Original 7711"
      refute log =~ "restricted"

      assert {:ok, %{applied: 0, skipped: %{gated: 1}}} =
               remote_apply(
                 ctx,
                 "facts",
                 id,
                 %{"fact_text" => "Rewritten 7711", "security_labels" => "[]"},
                 max_class: "internal",
                 operation: "create"
               )

      assert stored("facts", id, "fact_text") == "Original 7711"
      assert label_list("facts", id) == ["restricted"]

      # A peer cleared for the row may rewrite it; the labels stay.
      remote_change(ctx, "facts", id, %{"fact_text" => "Rewritten 7711", "security_labels" => "[]"},
        operation: "create"
      )

      assert stored("facts", id, "fact_text") == "Rewritten 7711"
      assert label_list("facts", id) == ["restricted"]
    end

    test "a skipped change is logged with its key cut, and a batch logs a few lines", ctx do
      long = String.duplicate("k", 200) <> "-#{ctx.n}"
      fact(ctx, long, "Long key 7790", ["restricted"])

      log =
        capture_log([level: :warning], fn ->
          assert {:ok, %{skipped: %{gated: 1}}} =
                   remote_delete(ctx, "facts", long, max_class: "internal")
        end)

      assert log =~ "a delete of facts"
      assert log =~ String.duplicate("k", 64)
      refute log =~ String.duplicate("k", 65)

      ids = for i <- 1..14, do: "fact-many-gated-#{ctx.n}-#{i}"
      for id <- ids, do: fact(ctx, id, "Many #{id}", ["restricted"])

      mutations =
        for id <- ids do
          %{
            "id" => "mut_remote_many_#{id}",
            "device_id" => "rep_remote",
            "entity_type" => "facts",
            "entity_id" => id,
            "operation" => "delete",
            "occurred_at" => "2099-01-01T00:00:00.000",
            "payload" => %{"row" => %{"id" => id}, "blobs" => %{}}
          }
        end

      log =
        capture_log([level: :warning], fn ->
          assert {:ok, %{skipped: %{gated: 14}}} =
                   Sync.apply_changes(ctx.tenant, ctx.ws, mutations,
                     since: "2099-12-31T00:00:00",
                     max_class: "internal"
                   )
        end)

      assert length(Regex.scan(~r/a delete of facts/, log)) == 10
      assert log =~ "4 more changes were skipped the same way"
    end

    test "a delete of a row within the class the peer is cleared for is applied", ctx do
      open = "fact-del-open-#{ctx.n}"
      confidential = "fact-del-conf-#{ctx.n}"
      fact(ctx, open, "Open 7712", [])
      fact(ctx, confidential, "Confidential 7713", ["confidential"])

      assert {:ok, %{applied: 1}} = remote_delete(ctx, "facts", open, max_class: "internal")

      assert {:ok, %{applied: 1}} =
               remote_delete(ctx, "facts", confidential, max_class: "confidential")

      assert {:ok, []} =
               Store.raw_query("SELECT 1 FROM facts WHERE id IN (?1, ?2)", [open, confidential])
    end

    test "a create over a row this Engine holds keeps its labels", ctx do
      id = "fact-create-#{ctx.n}"
      fact(ctx, id, "Original 7714", ["restricted"])

      remote_change(ctx, "facts", id, %{"fact_text" => "Created 7714", "security_labels" => "[]"},
        operation: "create"
      )

      assert stored("facts", id, "fact_text") == "Created 7714"
      assert label_list("facts", id) == ["restricted"]
    end

    test "labels the sender wrote as a BLOB cannot lower the row either", ctx do
      id = "fact-blob-#{ctx.n}"
      fact(ctx, id, "Original 7715", ["restricted"])

      remote_change(ctx, "facts", id, %{"fact_text" => "Edited 7715"},
        blobs: %{"security_labels" => "[]"}
      )

      assert stored("facts", id, "fact_text") == "Edited 7715"
      assert label_list("facts", id) == ["restricted"]
    end

    test "metadata the sender wrote that is not an object keeps the labels held here", ctx do
      %{memory: memory} = remember(ctx, "Secret 7716", ["restricted"])

      for sent <- ["[1, 2]", "not json", "\"text\""] do
        remote_change(ctx, "memories", memory.id, %{"metadata" => sent})

        assert Jason.decode!(stored("memories", memory.id, "metadata"))["security_labels"] ==
                 ["restricted"],
               "sender metadata #{sent}"
      end
    end

    test "metadata held here that cannot be read as an object holds no labels to keep", ctx do
      %{memory: memory} = remember(ctx, "Odd 7717", ["restricted"])

      {:ok, _} =
        Store.raw_query("UPDATE memories SET metadata = 'not json' WHERE id = ?1", [memory.id])

      remote_change(ctx, "memories", memory.id, %{"metadata" => ~s({"security_labels":["private"]})})

      assert Jason.decode!(stored("memories", memory.id, "metadata"))["security_labels"] ==
               ["private"]
    end

    test "a source package keeps its labels and its metadata labels", ctx do
      source = restricted_source(ctx, "Escrow terms 7718")

      {:ok, _} =
        Store.raw_query(
          "UPDATE source_packages SET metadata = json_set(COALESCE(metadata, '{}'), '$.security_labels', json('[\"confidential\"]')) WHERE id = ?1",
          [source.id]
        )

      remote_change(ctx, "source_packages", source.id, %{
        "security_labels" => "[]",
        "metadata" => ~s({"origin":"phone"})
      })

      assert label_list("source_packages", source.id) == ["restricted"]
      metadata = Jason.decode!(stored("source_packages", source.id, "metadata"))
      assert metadata["security_labels"] == ["confidential"]
      assert metadata["origin"] == "phone"
    end

    test "a row that is held here keeps its labels when its links are repointed", ctx do
      insert_context(ctx, "doc-links-#{ctx.n}", "Doc")

      {:ok, _} =
        Store.raw_query(
          "UPDATE contexts SET metadata = ?2 WHERE id = ?1",
          ["doc-links-#{ctx.n}", ~s({"security_labels":["restricted"],"source_package_id":"sp-a"})]
        )

      remote_change(ctx, "contexts", "doc-links-#{ctx.n}", %{
        "metadata" => ~s({"source_package_id":"sp-b"})
      })

      metadata = Jason.decode!(stored("contexts", "doc-links-#{ctx.n}", "metadata"))
      assert metadata["security_labels"] == ["restricted"]
      # The link is the sender's: an edit may repoint it.
      assert metadata["source_package_id"] == "sp-b"
    end

    test "a value that cannot be stored is a failed change, not an error for the batch", ctx do
      id = "fact-unbindable-#{ctx.n}"
      fact(ctx, id, "Original 7719", ["private"])

      mutation = fn suffix, value ->
        %{
          "id" => "mut_remote_unbindable_#{ctx.n}_#{suffix}",
          "device_id" => "rep_remote",
          "entity_type" => "facts",
          "entity_id" => id,
          "operation" => "update",
          "occurred_at" => "2099-01-01T00:00:00.000",
          "payload" => %{
            "row" => Map.merge(row_of("facts", id), %{"fact_text" => value}),
            "blobs" => %{}
          }
        }
      end

      assert {:ok, %{applied: 1, failed: [%{id: failed, reason: :unsupported_value}]}} =
               Sync.apply_changes(
                 ctx.tenant,
                 ctx.ws,
                 [mutation.("object", %{"not" => "text"}), mutation.("text", "Edited 7719")],
                 since: "2099-12-31T00:00:00"
               )

      assert failed == "mut_remote_unbindable_#{ctx.n}_object"
      assert stored("facts", id, "fact_text") == "Edited 7719"
      assert label_list("facts", id) == ["private"]
    end

    test "a change that does not lower anything is stored as the sender wrote it", ctx do
      id = "fact-same-#{ctx.n}"
      fact(ctx, id, "Original 7708", ["private"])

      remote_change(ctx, "facts", id, %{
        "fact_text" => "Edited 7708",
        "security_labels" => ~s(["private"])
      })

      assert stored("facts", id, "security_labels") == ~s(["private"])
    end
  end

  # -- the cost of a pull ------------------------------------------------------------------

  describe "the lineage index is shared between gates" do
    setup ctx do
      OptimalEngine.Sync.GateCache.clear()

      for i <- 1..6 do
        {:ok, _} =
          Versioned.create(%{
            content: "Plain note #{i}",
            workspace_id: ctx.ws,
            tenant_id: ctx.tenant
          })
      end

      serve_max_class = Application.get_env(:optimal_engine, :sync_serve_max_class)

      on_exit(fn ->
        Application.delete_env(:optimal_engine, :sync_gate_cache_ttl_ms)

        if serve_max_class,
          do: Application.put_env(:optimal_engine, :sync_serve_max_class, serve_max_class),
          else: Application.delete_env(:optimal_engine, :sync_serve_max_class)
      end)

      :ok
    end

    test "a cached source relabelled in place hides what is derived from it", ctx do
      source = plain_source(ctx, "Board minutes 8811")

      {:ok, memory} =
        Versioned.create(%{
          content: "Board minutes 8811 summary",
          workspace_id: ctx.ws,
          tenant_id: ctx.tenant,
          metadata: %{"memory_core_source_package_id" => source.id}
        })

      first = Sync.changes(ctx.tenant, ctx.ws, limit: 2_000)
      assert sent?(first["mutations"], "memories", memory.id)

      {:ok, _} =
        Store.raw_query(
          "UPDATE source_packages SET security_labels = '[\"restricted\"]' WHERE id = ?1",
          [source.id]
        )

      second = Sync.changes(ctx.tenant, ctx.ws, limit: 2_000)

      refute sent?(second["mutations"], "memories", memory.id)
      refute carries?(second["mutations"], "Board minutes 8811 summary")
    end

    test "a source labelled while a page is on its way holds what the next page derives from it",
         ctx do
      source = plain_source(ctx, "Offer letter 8820")

      {:ok, first} =
        Versioned.create(%{
          content: "First page memory 8820",
          workspace_id: ctx.ws,
          tenant_id: ctx.tenant
        })

      {:ok, derived} =
        Versioned.create(%{
          content: "Derived memory 8820",
          workspace_id: ctx.ws,
          tenant_id: ctx.tenant,
          metadata: %{"memory_core_source_package_id" => source.id}
        })

      fired = :ets.new(:relabelled, [:public, :bag])

      relabel = fn mutations ->
        if Enum.any?(mutations, &(&1["entity_id"] == first.id)) do
          {:ok, _} =
            Store.raw_query(
              "UPDATE source_packages SET security_labels = '[\"restricted\"]' WHERE id = ?1",
              [source.id]
            )

          :ets.insert(fired, {:relabelled, source.id})
        end
      end

      # One change to a page, so the source is read on an earlier page than the
      # memory that derives from it, and labelled in between.
      {_result, sent} = push(ctx, max_class: "internal", max_batch: 1, on_push: relabel)

      # The relabel happened, and the cycle went past the memory that derives from it.
      assert :ets.lookup(fired, :relabelled) != []

      {:ok, [[derived_last]]} =
        Store.raw_query("SELECT MAX(sequence) FROM sync_mutations WHERE entity_id = ?1", [
          derived.id
        ])

      {:ok, [[cursor]]} =
        Store.raw_query(
          "SELECT last_pushed_seq FROM sync_peers WHERE tenant_id = ?1 AND workspace_id = ?2",
          [ctx.tenant, ctx.ws]
        )

      assert cursor >= derived_last

      assert sent?(sent, "memories", first.id)
      refute sent?(sent, "memories", derived.id)
      refute carries?(sent, "Derived memory 8820")
    end

    test "an aggregate is held after a memory was labelled by its metadata alone", ctx do
      report(ctx, "rep-late-#{ctx.n}")

      first = Sync.changes(ctx.tenant, ctx.ws, limit: 2_000)
      assert sent?(first["mutations"], "analysis_reports", "rep-late-#{ctx.n}")

      {:ok, _} =
        Store.raw_query(
          "UPDATE memories SET metadata = json_set(COALESCE(metadata, '{}'), '$.security_labels', json('[\"restricted\"]')) WHERE id = (SELECT id FROM memories WHERE workspace_id = ?1 LIMIT 1)",
          [ctx.ws]
        )

      second = Sync.changes(ctx.tenant, ctx.ws, limit: 2_000)

      refute sent?(second["mutations"], "analysis_reports", "rep-late-#{ctx.n}")
    end

    test "a change applied from a peer that raises the labels of a source is honoured", ctx do
      Application.put_env(:optimal_engine, :sync_serve_max_class, "internal")
      source = plain_source(ctx, "Escrow terms 8812")

      {:ok, memory} =
        Versioned.create(%{
          content: "Escrow terms 8812 summary",
          workspace_id: ctx.ws,
          tenant_id: ctx.tenant,
          metadata: %{"memory_core_source_package_id" => source.id}
        })

      first = Sync.changes(ctx.tenant, ctx.ws, limit: 2_000)
      assert sent?(first["mutations"], "memories", memory.id)

      remote_change(ctx, "source_packages", source.id, %{"security_labels" => ~s(["confidential"])})

      second = Sync.changes(ctx.tenant, ctx.ws, limit: 2_000)

      refute sent?(second["mutations"], "memories", memory.id)
      refute carries?(second["mutations"], "Escrow terms 8812 summary")
    end

    test "gates of two classes on one workspace do not share a scan", ctx do
      source = plain_source(ctx, "Offer letter 8813", ["confidential"])

      {:ok, memory} =
        Versioned.create(%{
          content: "Offer letter 8813 summary",
          workspace_id: ctx.ws,
          tenant_id: ctx.tenant,
          metadata: %{"memory_core_source_package_id" => source.id}
        })

      change = memory_change(memory.id)
      hold = fn class -> Gate.with_gate(ctx.tenant, ctx.ws, class, &Gate.hold?(&1, change)) end

      assert hold.("internal")
      refute hold.("confidential")

      GateCache.clear()

      refute hold.("confidential")
      assert hold.("internal")
    end

    test "workspaces of two tenants do not share a scan", ctx do
      other_tenant = "gate-other-#{ctx.n}"
      {:ok, _} = Tenant.create(%{id: other_tenant, name: "Other #{ctx.n}"})

      {:ok, _} =
        OptimalEngine.Organization.create(%{
          id: "#{other_tenant}:org",
          tenant_id: other_tenant,
          slug: "org",
          name: "Org"
        })

      other_ws = create_workspace(other_tenant, "notes", %{})

      {:ok, plain} =
        Versioned.create(%{
          content: "Other tenant note",
          workspace_id: other_ws,
          tenant_id: other_tenant
        })

      source = plain_source(ctx, "Offer letter 8814", ["restricted"])

      {:ok, memory} =
        Versioned.create(%{
          content: "Offer letter 8814 summary",
          workspace_id: ctx.ws,
          tenant_id: ctx.tenant,
          metadata: %{"memory_core_source_package_id" => source.id}
        })

      refute Gate.with_gate(
               other_tenant,
               other_ws,
               "internal",
               &Gate.hold?(&1, memory_change(plain.id))
             )

      assert Gate.with_gate(
               ctx.tenant,
               ctx.ws,
               "internal",
               &Gate.hold?(&1, memory_change(memory.id))
             )
    end

    test "an entry expires after the ttl", ctx do
      Application.put_env(:optimal_engine, :sync_gate_cache_ttl_ms, 400)

      {_, first} = counting_builds(ctx.ws, fn -> Sync.changes(ctx.tenant, ctx.ws, limit: 2_000) end)
      assert :index in first

      {_, again} = counting_builds(ctx.ws, fn -> Sync.changes(ctx.tenant, ctx.ws, limit: 2_000) end)
      assert again == []

      Process.sleep(450)

      {_, expired} =
        counting_builds(ctx.ws, fn -> Sync.changes(ctx.tenant, ctx.ws, limit: 2_000) end)

      assert :index in expired
    end

    test "a ttl that is not a non-negative integer turns the cache off", ctx do
      for ttl <- ["soon", -5, 1.5, nil, :forever] do
        Application.put_env(:optimal_engine, :sync_gate_cache_ttl_ms, ttl)

        {{_, builds}, _log} =
          with_log([level: :warning], fn ->
            counting_builds(ctx.ws, fn ->
              Sync.changes(ctx.tenant, ctx.ws, limit: 2_000)
              Sync.changes(ctx.tenant, ctx.ws, limit: 2_000)
            end)
          end)

        assert Enum.count(builds, &(&1 == :index)) == 2, "ttl #{inspect(ttl)} left the cache on"
      end
    end

    test "an invalid ttl is warned about once for each value", ctx do
      ttl = "soon-#{ctx.n}"
      Application.put_env(:optimal_engine, :sync_gate_cache_ttl_ms, ttl)

      first =
        capture_log([level: :warning], fn ->
          Sync.changes(ctx.tenant, ctx.ws, limit: 2_000)
          Sync.changes(ctx.tenant, ctx.ws, limit: 2_000)
        end)

      assert length(Regex.scan(~r/gate cache is off/, first)) == 1
      assert first =~ ttl

      again =
        capture_log([level: :warning], fn -> Sync.changes(ctx.tenant, ctx.ws, limit: 2_000) end)

      refute again =~ "gate cache is off"
    end

    test "gates build when the cache table is gone", ctx do
      owner = Process.whereis(GateCache)
      true = :ets.delete(:optimal_sync_gate_cache)

      on_exit(fn ->
        Process.exit(owner, :kill)
        wait_for_new_owner(owner)
      end)

      {pages, builds} = counting_builds(ctx.ws, fn -> pull_all(ctx, 2) end)

      assert pages >= 3
      assert Enum.count(builds, &(&1 == :index)) > 1
      assert :ok = GateCache.clear()
    end

    test "a scan needed late in a pass is stamped when it is needed", ctx do
      {:ok, plain} =
        Versioned.create(%{content: "Mid-pass note", workspace_id: ctx.ws, tenant_id: ctx.tenant})

      report(ctx, "rep-mid-#{ctx.n}")

      aggregate = %{
        "entity_type" => "analysis_reports",
        "entity_id" => "rep-mid-#{ctx.n}",
        "operation" => "update",
        "payload" => %{"row" => row_of("analysis_reports", "rep-mid-#{ctx.n}"), "blobs" => %{}}
      }

      # An earlier gate caches "nothing above internal" for the stamp as it is.
      refute Gate.with_gate(ctx.tenant, ctx.ws, "internal", &Gate.hold?(&1, aggregate))

      gate = Gate.open(ctx.tenant, ctx.ws, "internal")

      try do
        # The first scan of this gate (the index) reads the stamp.
        refute Gate.hold?(gate, memory_change(plain.id))

        # A restricted write lands in the middle of the pass.
        fact(ctx, "fact-mid-#{ctx.n}", "Mid-pass 8815", ["restricted"])

        assert Gate.hold?(gate, aggregate)
      after
        Gate.close(gate)
      end
    end

    test "a pull of many pages scans the workspace once", ctx do
      {pages, builds} = counting_builds(ctx.ws, fn -> pull_all(ctx, 2) end)

      assert pages >= 3
      assert Enum.count(builds, &(&1 == :index)) == 1
      assert Enum.count(builds, &(&1 == :holds_above)) <= 1
    end

    test "without the cache every page scans it again", ctx do
      Application.put_env(:optimal_engine, :sync_gate_cache_ttl_ms, 0)

      {pages, builds} = counting_builds(ctx.ws, fn -> pull_all(ctx, 2) end)

      assert pages >= 3
      assert Enum.count(builds, &(&1 == :index)) > 1
    end

    test "a second pull with nothing written in between scans nothing", ctx do
      pull_all(ctx, 2)

      {_pages, builds} = counting_builds(ctx.ws, fn -> pull_all(ctx, 2) end)

      assert builds == []
    end

    test "a source labelled after the index was cached is honoured", ctx do
      first = Sync.changes(ctx.tenant, ctx.ws, limit: 2_000)
      assert first["mutations"] != []

      source = restricted_source(ctx, "Board minutes 8801")
      insert_context(ctx, "doc-late-#{ctx.n}", "Board minutes")
      ledger(ctx, source, "doc-late-#{ctx.n}", ["restricted"])

      second = Sync.changes(ctx.tenant, ctx.ws, since: first["cursor"], limit: 2_000)

      refute sent?(second["mutations"], "contexts", "doc-late-#{ctx.n}")
      refute carries?(second["mutations"], "Board minutes 8801")
    end

    test "a workspace that does not sync is scanned by every gate", ctx do
      plain = "plain-#{ctx.n}"

      {:ok, workspace} =
        Workspace.create(%{
          tenant_id: ctx.tenant,
          organization_id: "#{ctx.tenant}:org",
          slug: plain,
          name: "Plain"
        })

      memory = %{
        "entity_type" => "memories",
        "entity_id" => "mem-x",
        "operation" => "create",
        "payload" => %{"row" => %{"id" => "mem-x", "metadata" => "{}"}, "blobs" => %{}}
      }

      {_, builds} =
        counting_builds(workspace.id, fn ->
          for _ <- 1..2 do
            Gate.with_gate(ctx.tenant, workspace.id, "internal", &Gate.hold?(&1, memory))
          end
        end)

      assert Enum.count(builds, &(&1 == :index)) == 2
    end
  end

  # -- the map ----------------------------------------------------------------------------

  describe "lineage that loops or runs deep" do
    test "a package that names a restricted package's pool is held with it", ctx do
      source = restricted_source(ctx, "Escrow terms 6612")
      pool = "pool-#{ctx.n}"
      first = "cp-first-#{ctx.n}"
      second = "cp-second-#{ctx.n}"

      # The pool lists the first package and the first package names the pool:
      # a loop. The first package is restricted by the source it quotes, the
      # second names the pool too.
      {:ok, _} =
        Store.raw_query(
          "INSERT INTO active_memory_pools (id, tenant_id, workspace_id, context_package_links) VALUES (?1, ?2, ?3, ?4)",
          [pool, ctx.tenant, ctx.ws, Jason.encode!([first])]
        )

      for {id, sources} <- [{first, [source.id]}, {second, []}] do
        {:ok, _} =
          Store.raw_query(
            "INSERT INTO context_packages (id, tenant_id, workspace_id, active_memory_pool_id, source_package_links) VALUES (?1, ?2, ?3, ?4, ?5)",
            [id, ctx.tenant, ctx.ws, pool, Jason.encode!(sources)]
          )
      end

      {_result, sent} = push(ctx, max_class: "internal")

      refute sent?(sent, "context_packages", first)
      refute sent?(sent, "active_memory_pools", pool)
      refute sent?(sent, "context_packages", second)
      refute carries?(sent, "Escrow terms 6612")
    end

    test "a memory with fifty versions replicates", ctx do
      ids = version_chain(ctx, 50)

      {_result, sent} = push(ctx, max_class: "internal")

      for id <- ids, do: assert(sent?(sent, "memories", id), "version #{id} was held")
    end

    test "the newest of fifty versions replicates when a pull starts at it", ctx do
      newest = ctx |> version_chain(50) |> List.last()

      assert sent?(page_from(ctx, newest), "memories", newest)
    end

    test "fifty versions are held with their root when it is labelled", ctx do
      [root | versions] = version_chain(ctx, 50)

      {:ok, _} =
        Store.raw_query(
          "UPDATE memories SET metadata = json_set(COALESCE(metadata, '{}'), '$.security_labels', json('[\"restricted\"]')) WHERE id = ?1",
          [root]
        )

      newest = List.last(versions)

      refute sent?(page_from(ctx, newest), "memories", newest)

      {_result, sent} = push(ctx, max_class: "internal")
      for id <- versions, do: refute(sent?(sent, "memories", id), "version #{id} was sent")
    end

    test "a version is held with a labelled version behind it, whatever its root says", ctx do
      source = restricted_source(ctx, "Escrow terms 6613")
      [first, second, third, fourth] = version_chain(ctx, 4)

      # The second version is labelled afterwards, by the source it was staged
      # from and not by value, so the later versions do not carry it.
      {:ok, _} =
        Store.raw_query(
          "UPDATE memories SET metadata = json_set(COALESCE(metadata, '{}'), '$.memory_core_source_package_id', ?2) WHERE id = ?1",
          [second, source.id]
        )

      refute sent?(page_from(ctx, fourth), "memories", fourth)

      {_result, sent} = push(ctx, max_class: "internal")

      # (The second version's own first change predates its label: a stale
      # snapshot, which a later change deals with.)
      for id <- [third, fourth], do: refute(sent?(sent, "memories", id), "#{id} was sent")
      assert sent?(sent, "memories", first)
    end

    test "a chain written before roots were recorded is read through its parents", ctx do
      id = fn n -> "legacy-v#{n}-#{ctx.n}" end

      for n <- 1..4 do
        labels = if n == 2, do: ~s({"security_labels":["restricted"]}), else: "{}"
        parent = if n == 1, do: nil, else: id.(n - 1)

        {:ok, _} =
          Store.raw_query(
            "INSERT INTO memories (id, tenant_id, workspace_id, content, parent_memory_id, version, metadata) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
            [id.(n), ctx.tenant, ctx.ws, "Legacy version #{n}", parent, n, labels]
          )
      end

      refute sent?(page_from(ctx, id.(4)), "memories", id.(4))

      {_result, sent} = push(ctx, max_class: "internal")

      for n <- [2, 3, 4], do: refute(sent?(sent, "memories", id.(n)))
      assert sent?(sent, "memories", id.(1))
    end

    test "a parent loop is held whole, whichever version is read first", ctx do
      id = fn n -> "loop-v#{n}-#{ctx.n}" end
      # v1 -> v3 -> v2 -> v1, with only v1 labelled and no roots recorded:
      # every version of the loop has v1 behind it, so none may be sent, even
      # when an earlier version's walk stopped at the loop.
      parents = %{1 => 3, 2 => 1, 3 => 2}

      {:ok, :written} =
        Store.transaction(fn txn ->
          {:ok, _} = Store.txn_execute(txn, "PRAGMA defer_foreign_keys = ON", [])

          for n <- 1..3 do
            labels = if n == 1, do: ~s({"security_labels":["restricted"]}), else: "{}"

            {:ok, _} =
              Store.txn_execute(
                txn,
                "INSERT INTO memories (id, tenant_id, workspace_id, content, parent_memory_id, root_memory_id, version, metadata) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
                [
                  id.(n),
                  ctx.tenant,
                  ctx.ws,
                  "Loop version #{n}",
                  id.(parents[n]),
                  nil,
                  n,
                  labels
                ]
              )
          end

          {:ok, :written}
        end)

      {_result, sent} = push(ctx, max_class: "internal")

      for n <- 1..3, do: refute(sent?(sent, "memories", id.(n)), "#{id.(n)} was sent")
    end

    test "a source package that already holds a conflict is given its labels and the fact", ctx do
      fact_id = fact_conflict(ctx, ["confidential"], nil)

      # As a package raised before the labels were written.
      {:ok, _} =
        Store.raw_query(
          "UPDATE source_packages SET security_labels = '[]', metadata = '{}' WHERE workspace_id = ?1 AND source_type = 'sync_conflict'",
          [ctx.ws]
        )

      older = %{
        "id" => "mut_remote_conflict_again_#{ctx.n}",
        "device_id" => "rep_remote",
        "entity_type" => "facts",
        "entity_id" => fact_id,
        "operation" => "update",
        "occurred_at" => "2000-01-01T00:00:01.000",
        "payload" => %{
          "row" => %{
            "id" => fact_id,
            "fact_text" => "Wire code 4470",
            "workspace_id" => ctx.ws,
            "tenant_id" => ctx.tenant
          },
          "blobs" => %{}
        }
      }

      assert {:ok, %{conflicts: 1}} = Sync.apply_changes(ctx.tenant, ctx.ws, [older])

      {:ok, [[labels, metadata]]} =
        Store.raw_query(
          "SELECT security_labels, metadata FROM source_packages WHERE workspace_id = ?1 AND source_type = 'sync_conflict'",
          [ctx.ws]
        )

      assert Jason.decode!(labels) == ["confidential"]
      assert Jason.decode!(metadata)["fact_id"] == fact_id
    end
  end

  # What the gate holds that it once let through, because it cannot vouch for
  # it: a link it cannot follow and a label it cannot read. Both fail closed,
  # for a peer and for a reader.
  describe "what the gate cannot vouch for" do
    test "a labels list with a blank or non-string element holds the row", ctx do
      gate = Gate.open(ctx.tenant, ctx.ws, "internal")

      try do
        package = fn labels ->
          %{
            "entity_type" => "source_packages",
            "operation" => "create",
            "payload" => %{
              "row" => %{
                "id" => "sp-labels-#{ctx.n}",
                "tenant_id" => ctx.tenant,
                "workspace_id" => ctx.ws,
                "security_labels" => Jason.encode!(labels)
              }
            }
          }
        end

        refute Gate.hold?(gate, package.([]))
        refute Gate.hold?(gate, package.(["internal"]))
        refute Gate.hold?(gate, package.(["Internal"]))
        assert Gate.hold?(gate, package.(["internal", ""]))
        assert Gate.hold?(gate, package.(["internal", 7]))
        assert Gate.hold?(gate, package.(["internal", nil]))
        assert Gate.hold?(gate, package.([["internal"]]))
      after
        Gate.close(gate)
      end
    end

    test "a chunk of a document the ledger never saw is held; one of a deleted document is judged by the ledger",
         ctx do
      {:ok, plain} =
        Intake.process("Docs ship Friday and the changelog goes out Monday",
          workspace_id: ctx.ws,
          tenant_id: ctx.tenant,
          node: "operator",
          write_files: false
        )

      insert_chunk(ctx, "chk-gone-#{ctx.n}", "ctx-never-seen-#{ctx.n}", "Dangling chunk 8841")
      insert_chunk(ctx, "chk-deleted-#{ctx.n}", plain.context.id, "Deleted document chunk 8842")

      {:ok, _} = Capture.seal()

      {:ok, _} =
        Store.raw_query("DELETE FROM contexts WHERE id = ?1", [plain.context.id])

      {_result, sent} = push(ctx, max_class: "internal")

      refute sent?(sent, "chunks", "chk-gone-#{ctx.n}")
      refute carries?(sent, "Dangling chunk 8841")
      assert sent?(sent, "chunks", "chk-deleted-#{ctx.n}")
    end
  end

  # A mesh of rows that link to each other has no result that can be kept (each
  # depends on the path that led to it), so reading it path by path is
  # exponential in the number of rows. The gate reads a bounded number of rows
  # for each classification and calls the rest unresolved.
  describe "a dense mesh of links" do
    @describetag timeout: 60_000

    setup ctx do
      ids = for i <- 1..12, do: "wt-mesh-#{ctx.n}-#{i}"

      for id <- ids do
        {:ok, _} =
          Store.raw_query(
            "INSERT INTO workflow_traces (id, tenant_id, workspace_id, step_links) VALUES (?1, ?2, ?3, ?4)",
            [id, ctx.tenant, ctx.ws, Jason.encode!(ids -- [id])]
          )
      end

      %{ids: ids}
    end

    test "is held from a peer instead of being walked path by path", ctx do
      gate = Gate.open(ctx.tenant, ctx.ws, "internal")

      try do
        mutation = %{
          "entity_type" => "workflow_traces",
          "operation" => "update",
          "payload" => %{
            "row" => %{
              "id" => hd(ctx.ids),
              "tenant_id" => ctx.tenant,
              "workspace_id" => ctx.ws,
              "step_links" => Jason.encode!(tl(ctx.ids))
            }
          }
        }

        {microseconds, held?} = :timer.tc(fn -> Gate.hold?(gate, mutation) end)

        assert held?
        assert microseconds < 20_000_000
      after
        Gate.close(gate)
      end
    end

    test "is read by no one, quickly", ctx do
      grants = OptimalEngine.MemoryCore.SecurityLabels.grants(["internal"], [])

      {microseconds, readable?} =
        :timer.tc(fn ->
          Gate.with_reader(ctx.tenant, ctx.ws, grants, fn gate ->
            Gate.readable_id?(gate, "workflow_traces", hd(ctx.ids))
          end)
        end)

      refute readable?
      assert microseconds < 20_000_000
    end

    test "does not stop a row that is not part of it", ctx do
      {:ok, plain} =
        Versioned.create(%{
          content: "A note outside the mesh",
          workspace_id: ctx.ws,
          tenant_id: ctx.tenant
        })

      {_result, sent} = push(ctx, max_class: "internal")

      assert sent?(sent, "memories", plain.id)
      refute sent?(sent, "workflow_traces", hd(ctx.ids))
    end
  end

  describe "a table the gate scans that stays on this Engine" do
    setup ctx do
      GateCache.clear()
      on_exit(fn -> Application.delete_env(:optimal_engine, :sync_gate_cache_ttl_ms) end)
      %{asset: "asset-#{ctx.n}", report: "rep-local-#{ctx.n}"}
    end

    test "an asset relabelled in place holds an aggregate within the ttl", ctx do
      report(ctx, ctx.report)
      asset(ctx, ctx.asset)

      first = Sync.changes(ctx.tenant, ctx.ws, limit: 2_000)
      assert sent?(first["mutations"], "analysis_reports", ctx.report)

      {:ok, _} =
        Store.raw_query("UPDATE assets SET security_labels = '[\"restricted\"]' WHERE id = ?1", [
          ctx.asset
        ])

      second = Sync.changes(ctx.tenant, ctx.ws, limit: 2_000)
      refute sent?(second["mutations"], "analysis_reports", ctx.report)
    end

    test "an asset written already labelled holds an aggregate within the ttl", ctx do
      report(ctx, ctx.report)

      first = Sync.changes(ctx.tenant, ctx.ws, limit: 2_000)
      assert sent?(first["mutations"], "analysis_reports", ctx.report)

      asset(ctx, ctx.asset, ~s(["restricted"]))

      second = Sync.changes(ctx.tenant, ctx.ws, limit: 2_000)
      refute sent?(second["mutations"], "analysis_reports", ctx.report)
    end

    test "deleting the asset that held an aggregate releases it within the ttl", ctx do
      report(ctx, ctx.report)
      asset(ctx, ctx.asset, ~s(["restricted"]))

      first = Sync.changes(ctx.tenant, ctx.ws, limit: 2_000)
      refute sent?(first["mutations"], "analysis_reports", ctx.report)

      {:ok, _} = Store.raw_query("DELETE FROM assets WHERE id = ?1", [ctx.asset])

      second = Sync.changes(ctx.tenant, ctx.ws, limit: 2_000)
      assert sent?(second["mutations"], "analysis_reports", ctx.report)
    end

    test "a write to a column the gate does not read leaves the scan cached", ctx do
      report(ctx, ctx.report)
      asset(ctx, ctx.asset)

      {_, first} =
        counting_builds(ctx.ws, fn -> Sync.changes(ctx.tenant, ctx.ws, limit: 2_000) end)

      assert :holds_above in first

      {:ok, _} =
        Store.raw_query(
          "UPDATE assets SET size_bytes = 2, metadata = '{\"seen\":true}', trust_label = 'reviewed' WHERE id = ?1",
          [ctx.asset]
        )

      {_, again} =
        counting_builds(ctx.ws, fn -> Sync.changes(ctx.tenant, ctx.ws, limit: 2_000) end)

      assert again == []

      {:ok, _} =
        Store.raw_query("UPDATE assets SET security_labels = '[\"internal\"]' WHERE id = ?1", [
          ctx.asset
        ])

      {_, relabelled} =
        counting_builds(ctx.ws, fn -> Sync.changes(ctx.tenant, ctx.ws, limit: 2_000) end)

      assert :holds_above in relabelled
    end

    test "a write in a workspace that does not sync moves nothing", ctx do
      {:ok, other} =
        Workspace.create(%{
          tenant_id: ctx.tenant,
          organization_id: "#{ctx.tenant}:org",
          slug: "quiet-#{ctx.n}",
          name: "Quiet"
        })

      before = local_stamp()

      {:ok, _} =
        Store.raw_query(
          "INSERT INTO assets (id, tenant_id, workspace_id, content_type, size_bytes, storage_path) VALUES (?1, ?2, ?3, 'text/plain', 1, 'x')",
          ["asset-quiet-#{ctx.n}", ctx.tenant, other.id]
        )

      {:ok, _} =
        Store.raw_query("UPDATE assets SET security_labels = '[\"restricted\"]' WHERE id = ?1", [
          "asset-quiet-#{ctx.n}"
        ])

      {:ok, _} = Store.raw_query("DELETE FROM assets WHERE id = ?1", ["asset-quiet-#{ctx.n}"])
      assert local_stamp() == before

      asset(ctx, ctx.asset)
      assert local_stamp() > before
    end
  end

  describe "the lineage map" do
    test "classifies every table the Engine replicates" do
      unclassified = replicated_tables() -- Lineage.tables()

      assert unclassified == [],
             "classify #{inspect(unclassified)} in OptimalEngine.Sync.Lineage before they replicate"
    end

    test "every replicated table the gate classifies by has a text key and capture triggers" do
      {:ok, rows} =
        Store.raw_query(
          "SELECT name FROM sqlite_master WHERE type = 'trigger' AND name LIKE 'sync_capture_%'",
          []
        )

      triggers = MapSet.new(List.flatten(rows))

      # The gate cache stands on the write sequence of the capture, which only a
      # keyed table with an insert, update and delete trigger moves. A table that
      # stays local is not captured; the triggers of the local stamp watch it
      # (the test below).
      replicated = replicated_tables()

      # The tables the index is built from (`build_index/1` reads them by SQL) are
      # pinned by name, whatever the lineage map says of their columns.
      indexed = ~w(source_packages claims derivation_ledger entity_mentions)

      for table <- indexed,
          do: assert(table in replicated, "#{table} is read by the index but does not replicate")

      for table <- Enum.uniq(indexed ++ Lineage.tables()),
          table in replicated,
          table in indexed or
            ((spec = Lineage.spec(table)) &&
               (spec.labels or is_binary(spec.meta) or is_binary(spec.class))) do
        columns = Capture.columns(table)

        assert Capture.key_columns(columns) != [], "#{table} has no primary key"
        refute Capture.rowid_key?(columns), "#{table} is keyed by a rowid"

        for operation <- ~w(ai au ad) do
          assert "sync_capture_#{operation}_#{table}" in triggers,
                 "#{table} has no #{operation} capture trigger"
        end
      end
    end

    test "every table the gate scans is captured or moves the local stamp" do
      replicated = replicated_tables()
      stamped = Capture.stamped_tables()

      # A scanned table either replicates (the capture triggers watch it, the test
      # above) or is stamped.
      assert stamped == Lineage.scanned_tables() -- replicated
      assert stamped != []

      for table <- ~w(assets active_memory_pools context_packages model_call_runs tool_call_runs
                      skill_packages mcp_tool_definitions),
          do: assert(table in stamped, "#{table} is not watched")

      {:ok, rows} =
        Store.raw_query(
          "SELECT name, sql FROM sqlite_master WHERE type = 'trigger' AND name LIKE 'sync_stamp_%'",
          []
        )

      triggers = Map.new(rows, fn [name, sql] -> {name, sql} end)

      for table <- stamped, operation <- ~w(ai au ad) do
        sql = Map.get(triggers, "sync_stamp_#{operation}_#{table}")
        assert sql, "#{table} has no #{operation} stamp trigger"
        assert sql =~ "sync_local_stamp"
      end

      # Nor is one left on a table that is not stamped.
      expected =
        for table <- stamped, operation <- ~w(ai au ad), do: "sync_stamp_#{operation}_#{table}"

      assert Enum.sort(Map.keys(triggers)) == Enum.sort(expected)

      # The counter keeps no row, only its sequence.
      assert {:ok, [[0]]} = Store.raw_query("SELECT COUNT(*) FROM sync_local_stamp", [])
    end

    test "installing again does no DDL" do
      assert {:ok, _} = Capture.install()
      {:ok, [[before]]} = Store.raw_query("PRAGMA schema_version", [])

      assert {:ok, _} = Capture.install()
      assert {:ok, [[^before]]} = Store.raw_query("PRAGMA schema_version", [])
    end

    test "a stamp trigger left on a table that is no longer scanned is dropped" do
      {:ok, _} =
        Store.raw_query(
          "CREATE TRIGGER IF NOT EXISTS sync_stamp_ai_events AFTER INSERT ON events BEGIN SELECT 1; END",
          []
        )

      refute "events" in Capture.stamped_tables()
      assert {:ok, _} = Capture.install()

      assert {:ok, [[0]]} =
               Store.raw_query(
                 "SELECT COUNT(*) FROM sqlite_master WHERE type = 'trigger' AND name = 'sync_stamp_ai_events'",
                 []
               )
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

    test "an entry of an unknown entity type is held by the labels of the row it carries", ctx do
      entry = fn row ->
        %{"entity_type" => "app_note", "operation" => "create", "payload" => %{"row" => row}}
      end

      gate = Gate.open(ctx.tenant, ctx.ws, "internal")

      try do
        refute Gate.hold_known?(gate, entry.(%{"id" => "n1", "text" => "open"}))
        refute Gate.hold_known?(gate, entry.(%{"id" => "n1", "security_labels" => ["internal"]}))
        refute Gate.hold_known?(gate, %{entry.(%{}) | "payload" => %{"title" => "no row"}})

        assert Gate.hold_known?(
                 gate,
                 entry.(%{"id" => "n1", "security_labels" => ["confidential"]})
               )

        assert Gate.hold_known?(
                 gate,
                 entry.(%{"id" => "n1", "metadata" => ~s({"security_labels":["restricted"]})})
               )

        assert Gate.hold_known?(gate, entry.(%{"id" => "n1", "security_labels" => "{not json"}))
      after
        Gate.close(gate)
      end

      # A peer cleared for restricted is sent everything.
      restricted = Gate.open(ctx.tenant, ctx.ws, "restricted")

      try do
        refute Gate.hold_known?(
                 restricted,
                 entry.(%{"id" => "n1", "security_labels" => ["restricted"]})
               )
      after
        Gate.close(restricted)
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

  # The tables the Engine replicates (Capture's allow-list). The map is checked
  # against that set, never against a count.
  defp replicated_tables, do: Capture.replicated_tables()

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

  # A fact written here and edited concurrently on the other Engine: the newer
  # (local) version wins and both versions become claims in the review queue.
  # Returns the fact id.
  defp fact_conflict(ctx, local_labels, remote_labels) do
    fact_id = "fact-conflict-#{ctx.n}"

    {:ok, _} =
      Store.raw_query(
        "INSERT INTO facts (id, tenant_id, workspace_id, fact_text, security_labels) VALUES (?1, ?2, ?3, 'Wire code 4471', ?4)",
        [fact_id, ctx.tenant, ctx.ws, Jason.encode!(local_labels || [])]
      )

    {:ok, _} =
      Store.raw_query("UPDATE facts SET fact_text = 'Wire code 4472' WHERE id = ?1", [fact_id])

    {:ok, _} = Capture.seal()

    remote_row =
      %{
        "id" => fact_id,
        "fact_text" => "Wire code 4470",
        "workspace_id" => ctx.ws,
        "tenant_id" => ctx.tenant
      }
      |> then(
        &if(remote_labels,
          do: Map.put(&1, "security_labels", Jason.encode!(remote_labels)),
          else: &1
        )
      )

    older_remote = %{
      "id" => "mut_remote_conflict_#{ctx.n}",
      "device_id" => "rep_remote",
      "entity_type" => "facts",
      "entity_id" => fact_id,
      "operation" => "update",
      "occurred_at" => "2000-01-01T00:00:00.000",
      "payload" => %{"row" => remote_row, "blobs" => %{}}
    }

    assert {:ok, %{conflicts: 1}} = Sync.apply_changes(ctx.tenant, ctx.ws, [older_remote])
    fact_id
  end

  defp assert_conflict_labels(ctx, expected) do
    claims = conflict_claims(ctx)
    assert length(claims) == 2

    for [claim_id, source_id] <- claims do
      assert {:ok, [[labels]]} =
               Store.raw_query("SELECT security_labels FROM claims WHERE id = ?1", [claim_id])

      assert Jason.decode!(labels) == expected

      assert {:ok, [[source_labels]]} =
               Store.raw_query("SELECT security_labels FROM source_packages WHERE id = ?1", [
                 source_id
               ])

      assert Jason.decode!(source_labels) == expected
    end
  end

  # [claim id, source package id] of the claims a fact conflict raised.
  defp conflict_claims(ctx) do
    {:ok, rows} =
      Store.raw_query(
        "SELECT id, source_package_id FROM claims WHERE workspace_id = ?1 AND json_extract(metadata, '$.sync_conflict') = 1 ORDER BY id",
        [ctx.ws]
      )

    rows
  end

  # Runs `fun` while `column` of `table` has another name: every read of it
  # fails, as a read of the Store does when it errors.
  defp with_renamed_column(table, column, renamed, fun) do
    {:ok, _} = Store.raw_query("ALTER TABLE #{table} RENAME COLUMN #{column} TO #{renamed}", [])

    try do
      fun.()
    after
      {:ok, _} = Store.raw_query("ALTER TABLE #{table} RENAME COLUMN #{renamed} TO #{column}", [])
    end
  end

  # What a puller that starts at the change which created `memory_id` is
  # served: a gate that has not classified the versions before it.
  defp page_from(ctx, memory_id) do
    {:ok, _} = Capture.seal()

    {:ok, [[sequence]]} =
      Store.raw_query(
        "SELECT MIN(sequence) FROM sync_mutations WHERE tenant_id = ?1 AND workspace_id = ?2 AND entity_type = 'memories' AND entity_id = ?3",
        [ctx.tenant, ctx.ws, memory_id]
      )

    Sync.changes(ctx.tenant, ctx.ws, since: sequence - 1, limit: 2_000)["mutations"]
  end

  # A memory and `count - 1` newer versions of it, oldest first.
  defp version_chain(ctx, count) do
    {:ok, first} =
      Versioned.create(%{content: "Version 1", workspace_id: ctx.ws, tenant_id: ctx.tenant})

    2..count
    |> Enum.reduce([first.id], fn number, [latest | _] = ids ->
      {:ok, next} = Versioned.update(latest, %{content: "Version #{number}"})
      [next.id | ids]
    end)
    |> Enum.reverse()
  end

  # A change to the row `id` of `table` as the other Engine would send it: the
  # row as stored here with `changes`, written after anything done here. The
  # peer is cleared for every class unless `:max_class` says otherwise, so what
  # is exercised is how the labels are joined, not the gate.
  defp remote_change(ctx, table, id, changes, opts \\ []) do
    assert {:ok, %{applied: 1}} = remote_apply(ctx, table, id, changes, opts)
  end

  defp remote_apply(ctx, table, id, changes, opts) do
    blobs = Keyword.get(opts, :blobs, %{})

    row =
      table
      |> row_of(id)
      |> Map.merge(changes)
      |> Map.drop(Map.keys(blobs))

    mutation = %{
      "id" => "mut_remote_#{table}_#{System.unique_integer([:positive])}",
      "device_id" => "rep_remote",
      "entity_type" => table,
      "entity_id" => id,
      "operation" => Keyword.get(opts, :operation, "update"),
      "occurred_at" => "2099-01-01T00:00:00.000",
      "payload" => %{
        "row" => row,
        "blobs" =>
          Map.new(blobs, fn {name, bytes} -> {name, Base.encode16(bytes, case: :lower)} end)
      }
    }

    Sync.apply_changes(ctx.tenant, ctx.ws, [mutation],
      since: "2099-12-31T00:00:00",
      max_class: Keyword.get(opts, :max_class, "restricted")
    )
  end

  # The row `id` of `table` as a map with string keys, the way a change carries it.
  defp row_of(table, id) do
    names = table |> Capture.columns() |> Enum.map(& &1.name)

    {:ok, [values]} =
      Store.raw_query(
        "SELECT #{Enum.map_join(names, ", ", &~s("#{&1}"))} FROM #{table} WHERE id = ?1",
        [id]
      )

    names |> Enum.zip(values) |> Map.new()
  end

  # A change that carries the memory as it is stored, as the ledger holds it.
  defp memory_change(memory_id) do
    %{
      "entity_type" => "memories",
      "entity_id" => memory_id,
      "operation" => "update",
      "payload" => %{"row" => row_of("memories", memory_id), "blobs" => %{}}
    }
  end

  # A delete from the other Engine: the key only.
  defp remote_delete(ctx, table, id, opts) do
    mutation = %{
      "id" => "mut_remote_del_#{table}_#{System.unique_integer([:positive])}",
      "device_id" => "rep_remote",
      "entity_type" => table,
      "entity_id" => id,
      "operation" => "delete",
      "occurred_at" => "2099-01-01T00:00:00.000",
      "payload" => %{"row" => %{"id" => id}, "blobs" => %{}}
    }

    Sync.apply_changes(ctx.tenant, ctx.ws, [mutation],
      since: "2099-12-31T00:00:00",
      max_class: Keyword.get(opts, :max_class, "confidential")
    )
  end

  defp stored(table, id, column) do
    {:ok, [[value]]} = Store.raw_query("SELECT #{column} FROM #{table} WHERE id = ?1", [id])
    value
  end

  defp label_list(table, id), do: table |> stored(id, "security_labels") |> Jason.decode!()

  # Pulls a workspace a page of `limit` mutations at a time, as a peer does.
  # Returns the number of pages.
  defp pull_all(ctx, limit, since \\ 0, pages \\ 1) do
    page = Sync.changes(ctx.tenant, ctx.ws, since: since, limit: limit)

    if page["more"],
      do: pull_all(ctx, limit, page["cursor"], pages + 1),
      else: pages
  end

  # Runs `fun`, returning its result and what the gate scanned the workspace
  # `workspace_id` for while it ran (`:index`, `:holds_above`).
  defp counting_builds(workspace_id, fun) do
    id = {:gate_builds, System.unique_integer([:positive])}
    parent = self()

    :ok =
      :telemetry.attach(
        id,
        [:optimal_engine, :sync, :gate_build],
        fn _event, _measurements, %{what: what, workspace_id: scanned}, _config ->
          if scanned == workspace_id, do: send(parent, {:gate_build, what})
        end,
        nil
      )

    result =
      try do
        fun.()
      after
        :telemetry.detach(id)
      end

    {result, drain_builds([])}
  end

  defp drain_builds(acc) do
    receive do
      {:gate_build, what} -> drain_builds([what | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp plain_source(ctx, text, labels \\ []) do
    source =
      SourcePackage.from_text(text,
        tenant_id: ctx.tenant,
        workspace_id: ctx.ws,
        source_type: "note",
        security_labels: labels
      )

    :ok = CoreStore.insert_source_package(source)
    source
  end

  # Waits for the supervisor to start a new owner of the gate cache.
  defp wait_for_new_owner(old, attempts \\ 50) do
    case Process.whereis(GateCache) do
      pid when is_pid(pid) and pid != old ->
        :ok

      _ when attempts > 0 ->
        Process.sleep(20)
        wait_for_new_owner(old, attempts - 1)

      _ ->
        :timeout
    end
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

  defp asset(ctx, id, labels \\ "[]") do
    {:ok, _} =
      Store.raw_query(
        "INSERT INTO assets (id, tenant_id, workspace_id, content_type, size_bytes, storage_path, security_labels) VALUES (?1, ?2, ?3, 'text/plain', 1, ?4, ?5)",
        [id, ctx.tenant, ctx.ws, "assets/#{id}", labels]
      )
  end

  # The sequence of the local stamp (0 before any write moved it).
  defp local_stamp do
    {:ok, rows} =
      Store.raw_query("SELECT seq FROM sqlite_sequence WHERE name = 'sync_local_stamp'", [])

    case rows do
      [[seq]] -> seq
      [] -> 0
    end
  end

  # -- the relay -----------------------------------------------------------------------------

  # Registers a push peer cleared up to `:max_class`, runs one cycle, and
  # returns the result with every mutation the relay received for this
  # workspace.
  defp push(ctx, opts \\ []) do
    {result, sent} = cycle(ctx, opts)
    assert result.status == "active", "the cycle failed: #{inspect(result)}"
    {result, sent}
  end

  # One cycle, whatever its outcome.
  defp cycle(ctx, opts) do
    pushed = :ets.new(:pushed, [:public, :bag])
    cloud = Keyword.get(opts, :cloud, [])
    relay(ctx, pushed, cloud, opts)

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

    {result, for({:mutations, mutations} <- :ets.tab2list(pushed), m <- mutations, do: m)}
  end

  # `opts`: `:max_batch` refuses a push of more mutations than that with a 413
  # (the sender then sends smaller pages), `:on_push` is called with the
  # mutations of every push the relay accepts.
  defp relay(ctx, pushed, cloud, opts) do
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

          if opts[:max_batch] && length(mutations) > opts[:max_batch] do
            answer(413, %{"error" => %{"code" => "TOO_LARGE"}})
          else
            :ets.insert(pushed, {:mutations, mutations})
            if opts[:on_push], do: opts[:on_push].(mutations)
            answer(200, %{"data" => %{"applied" => length(mutations), "engine" => engine}})
          end

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
