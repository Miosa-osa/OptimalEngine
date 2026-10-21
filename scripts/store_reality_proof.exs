# Live store reality proof.
#
# Boots the engine (via `mix run`) and exercises every logical store in
# OptimalEngine.StorageCatalog once against the configured database, then
# prints a JSON report: one {store, status, evidence} entry per store plus the
# physical provider adapter inventory.
#
# The proof writes fixture rows. Run it only against a disposable store:
#
#     D=$(mktemp -d)
#     MIX_ENV=test OPTIMAL_API_ENABLED=true OPTIMAL_API_PORT=4310 \
#       OPTIMAL_ENGINE_ROOT=$D/root OPTIMAL_ENGINE_DB=$D/engine.db \
#       OPTIMAL_ENGINE_CACHE=$D/cache OPTIMAL_BACKUP_DIR=$D/backups \
#       OPTIMAL_KNOWLEDGE_ROCKSDB_PATH=$D/knowledge-rocksdb \
#       STORE_PROOF_OUT=$D/store-proof.json \
#       mix run scripts/store_reality_proof.exs
#
# When OPTIMAL_API_ENABLED=true the provider inventory is read back from the
# live HTTP API as well. Exit status is 0 only when every store passes.

defmodule StoreRealityProof do
  alias OptimalEngine.{Backup, Context, Graph, Jobs, Knowledge, Memory, StorageCatalog, Store}
  alias OptimalEngine.Auth.ApiKey
  alias OptimalEngine.Connectors.{Credential, Runner}
  alias OptimalEngine.Knowledge.Backend
  alias OptimalEngine.MemoryCore
  alias OptimalEngine.MemoryCore.SourcePackage
  alias OptimalEngine.Models.Registry
  alias OptimalEngine.Pipeline.DecompositionRuns
  alias OptimalEngine.Storage.{PolicyStore, Providers}
  alias OptimalEngine.Store.{FileCache, Vectors}
  alias OptimalEngine.Telemetry.History
  alias OptimalEngine.WorkspaceTopology

  def run do
    # Boot work on a fresh store (change capture triggers) finishes before any
    # independent connection reads the database.
    if Process.whereis(OptimalEngine.Sync.Scheduler), do: OptimalEngine.Sync.Scheduler.tick()

    suffix = System.unique_integer([:positive])
    scratch = Path.join(System.tmp_dir!(), "store-proof-#{suffix}")
    File.mkdir_p!(scratch)

    {:ok, workspace} =
      WorkspaceTopology.create_workspace(%{slug: "store-proof-#{suffix}", name: "Store Proof"})

    ctx = %{ws: workspace.id, slug: workspace.slug, suffix: suffix, scratch: scratch}

    checks = [
      {"relational", &relational/1},
      {"full_text", &full_text/1},
      {"vector", &vector/1},
      {"graph", &graph/1},
      {"assets", &assets/1},
      {"cache", &cache/1},
      {"jobs", &jobs/1},
      {"replication", &replication/1},
      {"metrics", &metrics/1},
      {"backups", &backups/1},
      {"decomposition", &decomposition/1},
      {"models", &models/1},
      {"secrets", &secrets/1}
    ]

    catalog_ids = StorageCatalog.list() |> Enum.map(& &1.id) |> Enum.sort()
    checked_ids = checks |> Enum.map(&elem(&1, 0)) |> Enum.sort()
    stores = Enum.map(checks, fn {id, fun} -> prove(id, fun, ctx) end)
    providers = providers()
    provider_proofs = Providers.proofs()

    report = %{
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      engine: %{
        version: OptimalEngine.Version.application_version(),
        git_sha: git_sha(),
        mix_env: to_string(Mix.env()),
        db_path: Application.get_env(:optimal_engine, :db_path),
        knowledge_backend:
          :optimal_engine |> Application.get_env(:knowledge, []) |> Keyword.get(:backend),
        rocksdb_nif_loaded: Code.ensure_loaded?(:rocksdb)
      },
      catalog_coverage: %{
        catalog_stores: catalog_ids,
        proven_stores: checked_ids,
        complete: catalog_ids == checked_ids
      },
      stores: stores,
      providers: providers,
      provider_proofs: provider_proofs,
      storage_audit: audit(),
      summary: %{
        stores: length(stores),
        passed: Enum.count(stores, &(&1.status == "pass")),
        failed: Enum.count(stores, &(&1.status == "fail")),
        providers: length(providers.inventory),
        providers_with_adapter: Enum.count(providers.inventory, & &1.adapter_implemented),
        providers_adapter_missing:
          providers.inventory |> Enum.reject(& &1.adapter_implemented) |> Enum.map(& &1.id),
        providers_proved: Enum.count(provider_proofs, &(&1.status == "pass")),
        providers_proof_failed: Enum.count(provider_proofs, &(&1.status == "fail")),
        providers_proof_skipped: Enum.count(provider_proofs, &(&1.status == "skipped"))
      }
    }

    json = Jason.encode!(report, pretty: true)
    IO.puts(json)

    case System.get_env("STORE_PROOF_OUT") do
      path when is_binary(path) and path != "" -> File.write!(path, json <> "\n")
      _ -> :ok
    end

    File.rm_rf(scratch)

    # A configured provider must prove itself. An unconfigured one is skipped
    # rather than failed, because nothing was attempted and nothing is claimed.
    ok? =
      report.summary.failed == 0 and report.catalog_coverage.complete and
        report.summary.providers_proof_failed == 0

    if ok?, do: 0, else: 1
  end

  defp prove(id, fun, ctx) do
    case fun.(ctx) do
      {:ok, evidence} -> %{store: id, status: "pass", evidence: evidence}
      {:error, reason} -> %{store: id, status: "fail", evidence: %{error: inspect(reason)}}
    end
  rescue
    error ->
      %{
        store: id,
        status: "fail",
        evidence: %{error: Exception.format(:error, error, __STACKTRACE__)}
      }
  catch
    kind, reason -> %{store: id, status: "fail", evidence: %{error: "#{kind}: #{inspect(reason)}"}}
  end

  # ─── stores ────────────────────────────────────────────────────────────────

  defp relational(%{ws: ws, slug: slug}) do
    {:ok, workspace} = OptimalEngine.Workspace.get(ws)
    [[^slug]] = on_disk("SELECT slug FROM workspaces WHERE id = ?1", [ws])
    {:error, duplicate} = WorkspaceTopology.create_workspace(%{slug: slug, name: "Duplicate"})
    {:ok, %{name: "Store Proof"}} = OptimalEngine.Workspace.get(ws)

    {:ok,
     %{
       write: "WorkspaceTopology.create_workspace #{ws}",
       read: "Workspace.get returned slug #{workspace.slug}",
       persistence: "independent read-only SQLite connection found the workspaces row",
       failure: "duplicate workspace refused (#{short(duplicate)}) and original row unchanged"
     }}
  end

  defp full_text(%{ws: ws, suffix: s}) do
    token = "proofterm#{s}"
    id = context!(ws, "proof-fts-#{s}", "Store proof note mentioning #{token}")

    {:ok, [[^id]]} =
      Store.raw_query("SELECT id FROM contexts_fts WHERE contexts_fts MATCH ?1", [token])

    {:ok, _memory} = Memory.create(%{content: "Proof memory about #{token}", workspace_id: ws})

    {:ok, [[1]]} =
      Store.raw_query("SELECT COUNT(*) FROM memories_fts WHERE memories_fts MATCH ?1", [token])

    [[^id]] = on_disk("SELECT id FROM contexts_fts WHERE contexts_fts MATCH ?1", [token])

    {:error, malformed} =
      Store.raw_query("SELECT id FROM contexts_fts WHERE contexts_fts MATCH ?1", ["\"open"])

    {:ok,
     %{
       write: "Store.insert_context and Memory.create with a unique term",
       read: "FTS5 MATCH found the context (contexts_fts) and the memory (memories_fts)",
       persistence: "independent connection matched the term in contexts_fts",
       failure: "malformed MATCH expression returned an error (#{short(malformed)})"
     }}
  end

  defp vector(%{ws: ws, suffix: s}) do
    near = context!(ws, "proof-vec-near-#{s}", "near")
    far = context!(ws, "proof-vec-far-#{s}", "far")
    :ok = Vectors.store(near, [1.0, 0.0, 0.0])
    :ok = Vectors.store(far, [0.0, 1.0, 0.0])
    {:ok, [{^near, top}, {^far, low}]} = Vectors.search([0.9, 0.1, 0.0], workspace_id: ws)
    [[blob, 3]] = on_disk("SELECT embedding, dimensions FROM vectors WHERE context_id = ?1", [near])
    [1.0, +0.0, +0.0] = for <<f::float-little-32 <- blob>>, do: f
    {:error, :invalid_embedding} = Vectors.store(near, [])

    {:ok,
     %{
       write: "Vectors.store for two 3-dimension embeddings",
       read: "cosine search ranked near=#{Float.round(top, 4)} above far=#{Float.round(low, 4)}",
       persistence: "independent connection decoded the stored float32 BLOB to the same vector",
       failure: "empty embedding rejected with invalid_embedding"
     }}
  end

  # The graph proof gets its own workspace: context inserts elsewhere in the
  # proof also write lineage edges, and the counts below must be exact.
  defp graph(%{suffix: s, scratch: scratch}) do
    {:ok, %{id: ws}} =
      WorkspaceTopology.create_workspace(%{slug: "store-proof-graph-#{s}", name: "Graph"})

    [ana, ben, cal, dee] = for name <- ~w(ana ben cal dee), do: "#{name}-#{s}"
    :ok = Graph.assert_edge(ana, ben, "knows", workspace_id: ws)
    :ok = Graph.assert_edge(ben, cal, "knows", workspace_id: ws)
    :ok = Graph.assert_edge(cal, dee, "knows", workspace_id: ws)
    [[3]] = on_disk("SELECT COUNT(*) FROM edges WHERE workspace_id = ?1", [ws])
    expected = MapSet.new([ben, cal, dee])

    rocksdb =
      if Code.ensure_loaded?(:rocksdb) do
        path = Path.join(scratch, "knowledge-rocksdb")
        opts = [backend: Backend.RocksDB, backend_opts: [path: path]]
        {:ok, store} = Knowledge.open("proof-rocks-#{s}", opts)
        {:ok, 3} = Graph.hydrate_triple_store(store, workspace_id: ws)
        ^expected = reachable(store, ws, ana, 3)
        :ok = Knowledge.close(store)
        {:ok, reopened} = Knowledge.open("proof-rocks-#{s}", opts)
        {:ok, 3} = Knowledge.count(reopened)
        ^expected = reachable(reopened, ws, ana, 3)

        {:ok, [%{"c" => ^cal}]} =
          Knowledge.sparql(reopened, "SELECT ?c WHERE { <#{ana}> <knows> ?b . ?b <knows> ?c }")

        :ok = Knowledge.close(reopened)
        blocker = Path.join(scratch, "rocks-blocker")
        File.write!(blocker, "file")
        {:error, _} = Backend.RocksDB.init("proof-blocked", path: blocker)

        %{
          status: "pass",
          traversal: "3-hop reachability #{ana} -> #{Enum.join([ben, cal, dee], ", ")}",
          persistence:
            "closed and reopened the RocksDB path; 3 quads and the traversal survived without rehydration",
          sparql: "two-hop SPARQL answered from the reopened store",
          failure: "init on a regular file path returned an error"
        }
      else
        %{status: "fail", reason: "rocksdb NIF is not loadable in this build"}
      end

    {:ok, ets} = Knowledge.open("proof-ets-#{s}", backend: Backend.ETS)
    {:ok, 3} = Graph.hydrate_triple_store(ets, workspace_id: ws)
    ^expected = reachable(ets, ws, ana, 3)
    :ok = Knowledge.close(ets)
    {:ok, rebuilt} = Knowledge.open("proof-ets-#{s}", backend: Backend.ETS)
    {:ok, 0} = Knowledge.count(rebuilt)
    {:ok, 3} = Graph.hydrate_triple_store(rebuilt, workspace_id: ws)
    ^expected = reachable(rebuilt, ws, ana, 3)
    {:error, _} = Knowledge.sparql(rebuilt, "NOT SPARQL")
    :ok = Knowledge.close(rebuilt)

    ets_evidence = %{
      status: "pass",
      traversal: "3-hop reachability after hydration from SQLite edges",
      persistence: "a fresh ETS store starts empty and is rebuilt from the durable edges table",
      failure: "invalid SPARQL returned an error"
    }

    if rocksdb.status == "pass",
      do: {:ok, %{rocksdb: rocksdb, ets: ets_evidence, lineage: "3 SQLite edges rows on disk"}},
      else: {:error, %{rocksdb: rocksdb, ets: ets_evidence}}
  end

  defp assets(%{ws: ws, scratch: scratch}) do
    bytes = "%PDF-1.7\nstore-proof-asset"
    source = Path.join(scratch, "evidence.pdf")
    File.write!(source, bytes)

    {:ok, %{asset: asset}} =
      MemoryCore.store_asset_file(source, workspace_id: ws, actor_id: "user:proof")

    {:ok, fetched} = MemoryCore.get_asset(asset.id, workspace_id: ws)
    ^bytes = File.read!(fetched.storage_path)

    {:ok, run} =
      MemoryCore.record_asset_adapter_run(asset.id,
        workspace_id: ws,
        actor_id: "user:proof",
        adapter_id: :docling,
        adapter_role: :document_intelligence,
        status: "completed",
        output_text: "extracted text"
      )

    {:ok, %{extraction: extraction}} =
      MemoryCore.record_asset_extraction(run.id,
        workspace_id: ws,
        actor_id: "user:proof",
        extraction_type: :transcript,
        content_text: "spoken words"
      )

    [[1]] = on_disk("SELECT COUNT(*) FROM asset_extractions WHERE id = ?1", [extraction.id])

    {:error, missing} =
      MemoryCore.store_asset_file(Path.join(scratch, "missing.pdf"), workspace_id: ws)

    {:ok,
     %{
       write: "AssetStore.store_file copied the file and wrote the assets row",
       read:
         "get_asset content_hash #{fetched.content_hash}; adapter run and transcript extraction recorded",
       persistence:
         "stored file bytes match the source; extraction row read by an independent connection",
       failure: "missing source file refused (#{short(missing)})"
     }}
  end

  defp cache(%{ws: ws, suffix: s}) do
    id = context!(ws, "proof-cache-#{s}", "cached context")
    [{^id, %Context{}}] = :ets.lookup(:optimal_engine_store_cache, id)
    :ets.delete(:optimal_engine_store_cache, id)
    {:ok, %Context{id: ^id}} = Store.get_context(id)
    [{^id, %Context{}}] = :ets.lookup(:optimal_engine_store_cache, id)
    {:error, :not_found} = Store.get_context("missing-#{s}")

    scope = {"default", "default:proof"}
    :ok = FileCache.put(scope, "proof", "key-#{s}", %{"value" => s})

    {:ok, %{"value" => ^s}} =
      Task.async(fn -> FileCache.get(scope, "proof", "key-#{s}") end) |> Task.await()

    [entry] =
      Path.wildcard(Path.join([FileCache.root(), "tenants", "*", "*", "proof", "*", "*.bin"]))

    File.write!(entry, "corrupt")
    :miss = FileCache.get(scope, "proof", "key-#{s}")
    :ok = FileCache.clear(scope, "proof")

    {:ok,
     %{
       ets:
         "insert_context populated the ETS hot cache; after eviction get_context reloaded from SQLite and re-cached",
       filesystem:
         "FileCache entry written under #{FileCache.root()} and read back by a separate process",
       failure: "missing context returned not_found; a corrupt cache file was discarded as a miss"
     }}
  end

  defp jobs(%{ws: ws, suffix: s}) do
    kind = "proof.job.#{s}"
    {:ok, ok_job} = Jobs.enqueue(ws, kind, %{"step" => "ok"}, priority: 2)
    {:ok, bad_job} = Jobs.enqueue(ws, kind, %{"step" => "bad"}, priority: 1, max_attempts: 2)

    handler = fn
      %{payload: %{"step" => "ok"}} -> :ok
      %{payload: %{"step" => "bad"}} -> {:error, :always_fails}
    end

    opts = [workspace_id: ws, kinds: [kind], retry_in: 0]
    {:ok, %{outcome: :completed}} = Jobs.run_next(handler, opts)
    {:ok, %{outcome: :retry}} = Jobs.run_next(handler, opts)
    {:ok, %{outcome: :dead}} = Jobs.run_next(handler, opts)
    [["completed"]] = on_disk("SELECT status FROM jobs WHERE id = ?1", [ok_job.id])

    [[letter_id]] =
      on_disk("SELECT id FROM dead_letter_jobs WHERE original_job_id = ?1", [bad_job.id])

    {:ok, replay} = Jobs.replay_dead_letter(letter_id, ws)
    {:ok, claimed} = Jobs.claim(workspace_id: ws, kinds: [kind], lease_owner: "worker-a")
    {:error, :lease_lost} = Jobs.complete(claimed.id, "worker-b")

    {:ok,
     %{
       write: "Jobs.enqueue for a succeeding and a failing job",
       run: "run_next completed one job, retried the other, then dead-lettered it after 2 attempts",
       persistence: "job statuses and the dead_letter_jobs row read by an independent connection",
       replay: "dead letter replayed once as #{replay.id}",
       failure: "completing another worker's lease returned lease_lost"
     }}
  end

  defp replication(%{ws: ws, suffix: s}) do
    attrs = %{
      workspace_id: ws,
      device_id: "device-a",
      entity_type: "memory_object",
      entity_id: "entity-#{s}",
      operation: :update,
      payload: %{"field" => "value"},
      idempotency_key: "proof-#{s}"
    }

    {:ok, mutation} = PolicyStore.append_mutation(attrs)
    {:ok, ^mutation} = PolicyStore.append_mutation(attrs)
    {:ok, [_]} = PolicyStore.mutations_after(ws, 0)
    :ok = PolicyStore.advance_cursor(ws, "replica-b", mutation.sequence)
    :ok = PolicyStore.advance_cursor(ws, "replica-b", 0)
    seq = mutation.sequence

    [[^seq]] =
      on_disk(
        "SELECT last_sequence FROM sync_cursors WHERE workspace_id = ?1 AND replica_id = 'replica-b'",
        [ws]
      )

    {:ok, other} =
      WorkspaceTopology.create_workspace(%{slug: "store-proof-other-#{s}", name: "Other"})

    {:error, :idempotency_key_conflict} =
      PolicyStore.append_mutation(%{attrs | workspace_id: other.id})

    {:ok,
     %{
       write:
         "append_mutation sequence #{seq}; replay with the same key returned the same mutation",
       read: "mutations_after(0) returned the workspace's mutation",
       persistence:
         "cursor stayed at #{seq} after an attempt to move it back, read by an independent connection",
       failure:
         "another workspace reusing the idempotency key got idempotency_key_conflict, not the payload"
     }}
  end

  defp metrics(%{ws: ws}) do
    {:ok, sample} = History.record(ws, "proof.depth", 4, labels: %{"queue" => "q"})
    {:ok, [%{id: id}]} = History.list(ws, metric_name: "proof.depth")
    ^id = sample.id
    {:ok, written} = History.snapshot_telemetry(ws)

    [["gauge", 4.0]] =
      on_disk("SELECT metric_kind, value FROM metric_samples WHERE id = ?1", [sample.id])

    {:error, {:invalid_metric_name, _}} = History.record(ws, "not a name", 1)

    {:ok,
     %{
       write: "History.record gauge sample and snapshot_telemetry wrote #{written} samples",
       read: "History.list returned the recorded sample",
       persistence: "metric_samples row read by an independent connection",
       failure: "invalid metric name rejected"
     }}
  end

  defp backups(%{ws: ws, scratch: scratch}) do
    {:ok, target} = Backup.resolve_target("store-proof-#{System.unique_integer([:positive])}.db")
    {:ok, info} = Backup.create(target)
    {:ok, :ok} = Backup.verify(target)
    restored = Path.join(scratch, "restored.db")
    {:ok, %{checksum_sha256: checksum}} = Backup.restore(target, target: restored)
    ^checksum = info.checksum_sha256
    [[1]] = read_db(restored, "SELECT COUNT(*) FROM workspaces WHERE id = ?1", [ws])
    tampered = Path.join(scratch, "tampered.db")
    File.cp!(target, tampered)
    File.write!(tampered, "tamper", [:append])
    {:error, uncataloged} = Backup.restore(tampered, target: Path.join(scratch, "never.db"))

    {:error, {:checksum_mismatch, _, _}} =
      Backup.restore(tampered, target: Path.join(scratch, "never.db"), checksum_sha256: checksum)

    {:error, {:outside_backup_dir, _}} = Backup.resolve_target("../escape.db")

    {:ok,
     %{
       write:
         "Backup.create #{Path.basename(target)} (#{info.size_bytes} bytes, #{info.integrity_status})",
       read: "verify passed; catalog checksum #{String.slice(checksum, 0, 16)}...",
       persistence:
         "restored into a new path; an independent connection found the proof workspace in the restored file",
       failure:
         "uncataloged copy refused (#{short(uncataloged)}); tampered bytes refused with checksum_mismatch; ../ path outside the backup dir refused"
     }}
  end

  defp decomposition(%{ws: ws, scratch: scratch}) do
    source =
      SourcePackage.from_text("# Proof\n\nOne paragraph.\n\nAnother paragraph.",
        workspace_id: ws,
        source_type: "store_proof"
      )

    _ = MemoryCore.Store.insert_source_package(source)
    {:ok, %{run: run}} = DecompositionRuns.run(ws, source.id)
    true = File.regular?(run.checkpoint_uri)

    {:ok, %{run: fallback, attempts: [failed, _]}} =
      DecompositionRuns.run(ws, source.id,
        strategy: :recursive,
        command: "exit 3",
        script: Path.join(scratch, "absent.py")
      )

    [[3]] =
      on_disk("SELECT COUNT(*) FROM decomposition_runs WHERE source_package_id = ?1", [source.id])

    {:ok,
     %{
       write: "deterministic run produced #{run.output_units} units with a JSON checkpoint",
       read: "DecompositionRuns.run returned the completed run",
       persistence:
         "3 decomposition_runs rows read by an independent connection; checkpoint file on disk",
       failure:
         "unavailable recursive sidecar recorded as #{failed.status} with fallback_strategy #{failed.fallback_strategy}; fallback attempt #{fallback.status}"
     }}
  end

  defp models(%{ws: ws, scratch: scratch}) do
    {:ok, example} =
      Registry.add_example(ws, %{
        input: "q",
        expected_output: "a",
        purpose: "proof",
        consent_basis: "fixture"
      })

    {:ok, _} = Registry.approve_example(ws, example.id)

    attrs = %{
      base_model: "base",
      trainer: "local",
      method: "lora",
      dataset_query: %{"purpose" => "proof"}
    }

    {:ok, run} = Registry.create_run(ws, attrs)
    {:ok, _} = Registry.start_run(ws, run.id)
    {:ok, run} = Registry.complete_run(ws, run.id, %{"loss" => 0.1})
    artifact = Path.join(scratch, "adapter.bin")
    File.write!(artifact, "weights")

    {:ok, adapter} =
      Registry.register_adapter(ws, %{
        training_run_id: run.id,
        adapter_type: "lora",
        artifact_uri: artifact,
        checksum_sha256: sha256("weights")
      })

    {:ok, %{status: "active"}} = Registry.activate_adapter(ws, adapter.id)

    [["active", 1]] =
      on_disk("SELECT status, version FROM model_adapters WHERE id = ?1", [adapter.id])

    {:error, :no_approved_examples} =
      Registry.create_run(ws, %{attrs | dataset_query: %{"purpose" => "other"}})

    {:ok,
     %{
       write:
         "approved training example, run queued -> running -> completed, adapter v1 registered",
       read: "active_adapter resolves #{adapter.id}",
       persistence: "model_adapters row (active, version 1) read by an independent connection",
       failure: "a run over unapproved data was refused with no_approved_examples"
     }}
  end

  defp secrets(%{ws: ws, suffix: s}) do
    original = System.get_env("CONNECTOR_KEY")
    System.put_env("CONNECTOR_KEY", Base.encode16(:crypto.strong_rand_bytes(32), case: :lower))

    try do
      id = "proof-connector-#{s}"

      {:ok, ^id} =
        Runner.upsert_row(%{
          id: id,
          kind: :slack,
          workspace_id: ws,
          config: %{credentials: %{bot_token: "xoxb-proof-#{s}"}}
        })

      [[json]] = on_disk("SELECT config FROM connectors WHERE id = ?1", [id])
      false = json =~ "xoxb-proof"
      %{"credentials_ciphertext" => envelope} = Jason.decode!(json)
      {:ok, %{"bot_token" => "xoxb-proof-" <> _}} = Credential.decrypt(envelope)

      {:ok, minted} =
        ApiKey.mint(%{tenant_id: "default", name: "store proof #{s}", workspace_scope: [ws]})

      {:ok, _} = ApiKey.verify(minted.key)
      [[hash]] = on_disk("SELECT hashed_secret FROM api_keys WHERE id = ?1", [minted.id])
      true = String.starts_with?(hash, "$2") and hash != minted.secret
      {:error, :invalid} = ApiKey.verify(minted.key <> "x")
      System.put_env("CONNECTOR_KEY", Base.encode16(:crypto.strong_rand_bytes(32), case: :lower))
      {:error, :auth_failed} = Credential.decrypt(envelope)

      {:ok,
       %{
         write:
           "atom-keyed connector credentials sealed into an AES-256-GCM envelope; API key minted",
         read: "envelope decrypted to the original token; API key verified",
         persistence:
           "stored connector config holds only credentials_ciphertext; api_keys holds a bcrypt hash",
         failure:
           "tampered API key rejected as invalid; envelope under a different master key failed authentication"
       }}
    after
      if original,
        do: System.put_env("CONNECTOR_KEY", original),
        else: System.delete_env("CONNECTOR_KEY")
    end
  end

  # ─── providers and audit ───────────────────────────────────────────────────

  defp providers do
    inventory =
      Providers.list(probe: true)
      |> Enum.map(
        &Map.take(&1, [:id, :kind, :adapter_implemented, :adapter_module, :lifecycle_state, :health])
      )

    api =
      with "true" <- System.get_env("OPTIMAL_API_ENABLED"),
           port when is_binary(port) <- System.get_env("OPTIMAL_API_PORT"),
           {:ok, body} <- http_get("http://127.0.0.1:#{port}/api/storage/providers"),
           {:ok, %{"providers" => listed}} <- Jason.decode(body) do
        %{
          source: "GET /api/storage/providers on port #{port}",
          adapter_missing:
            listed
            |> Enum.filter(&(&1["lifecycle_state"] == "adapter_missing"))
            |> Enum.map(& &1["id"]),
          matches_module_inventory:
            Enum.sort(Enum.map(listed, &{&1["id"], &1["adapter_implemented"]})) ==
              Enum.sort(Enum.map(inventory, &{&1.id, &1.adapter_implemented}))
        }
      else
        _ -> %{source: "HTTP API not enabled for this run"}
      end

    %{inventory: inventory, live_api: api}
  end

  defp audit do
    result = OptimalEngine.StorageAudit.run()

    %{
      ok: result.ok,
      checks: Enum.map(result.checks, &%{name: &1.name, ok: &1.ok})
    }
  end

  # ─── helpers ───────────────────────────────────────────────────────────────

  defp context!(ws, id, text) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    :ok =
      Store.insert_context(%Context{
        id: id,
        uri: "optimal://inbox/#{id}.md",
        type: :resource,
        path: "/store-proof/#{id}.md",
        title: text,
        content: text,
        l0_abstract: text,
        l1_overview: text,
        node: "inbox",
        created_at: now,
        modified_at: now,
        workspace_id: ws
      })

    id
  end

  defp on_disk(sql, params),
    do: read_db(Application.fetch_env!(:optimal_engine, :db_path), sql, params)

  defp read_db(path, sql, params) do
    {:ok, db} = Exqlite.Sqlite3.open(path, mode: :readonly)

    try do
      {:ok, stmt} = Exqlite.Sqlite3.prepare(db, sql)
      :ok = Exqlite.Sqlite3.bind(stmt, params)
      {:ok, rows} = Exqlite.Sqlite3.fetch_all(db, stmt)
      Exqlite.Sqlite3.release(db, stmt)
      rows
    after
      Exqlite.Sqlite3.close(db)
    end
  end

  defp reachable(store, graph, start, depth) do
    {seen, _} =
      Enum.reduce(1..depth, {MapSet.new(), [start]}, fn _hop, {seen, frontier} ->
        next =
          for node <- frontier,
              {:ok, triples} <- [
                Knowledge.query(store, graph: graph, subject: node, predicate: "knows")
              ],
              {_s, _p, object} <- triples,
              not MapSet.member?(seen, object),
              do: object

        {MapSet.union(seen, MapSet.new(next)), next}
      end)

    seen
  end

  defp http_get(url) do
    :inets.start()

    case :httpc.request(:get, {String.to_charlist(url), []}, [timeout: 5_000], body_format: :binary) do
      {:ok, {{_, 200, _}, _headers, body}} -> {:ok, body}
      other -> {:error, other}
    end
  end

  defp git_sha do
    case System.cmd("git", ["rev-parse", "HEAD"], stderr_to_stdout: true) do
      {sha, 0} -> String.trim(sha)
      _ -> "unknown"
    end
  rescue
    _ -> "unknown"
  end

  defp short(reason), do: reason |> inspect() |> String.slice(0, 120)

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end

System.halt(StoreRealityProof.run())
