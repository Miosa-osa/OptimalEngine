defmodule OptimalEngine.Stores.StoreRealityTest do
  @moduledoc """
  Proves every logical store in `OptimalEngine.StorageCatalog` against the
  real modules on the isolated test store.

  Each store is exercised the same way: a write through its public API, a
  read or query back, a persistence check (an independent read-only SQLite
  connection, a reopen of the backing files, or a rebuild from durable
  state), and one failure path. Adding a store to the catalog without a
  proof here fails the coverage test.
  """

  use ExUnit.Case, async: false

  alias OptimalEngine.{Backup, Context, Graph, Jobs, Knowledge, Memory, StorageCatalog, Store}
  alias OptimalEngine.Auth.ApiKey
  alias OptimalEngine.Connectors.{Credential, Runner}
  alias OptimalEngine.Knowledge.Backend
  alias OptimalEngine.MemoryCore
  alias OptimalEngine.MemoryCore.SourcePackage
  alias OptimalEngine.Models.Registry
  alias OptimalEngine.Pipeline.DecompositionRuns
  alias OptimalEngine.Storage.{PolicyStore, Providers}
  alias OptimalEngine.TestSupport.S3Stub
  alias OptimalEngine.Store.{FileCache, Vectors}
  alias OptimalEngine.Telemetry.History
  alias OptimalEngine.WorkspaceTopology

  @moduletag :tmp_dir

  @proven ~w(relational full_text vector graph assets cache jobs replication metrics backups decomposition models secrets)

  setup %{tmp_dir: tmp} do
    previous =
      for key <- [:root_path, :cache_path, :backup_dir],
          into: %{},
          do: {key, Application.get_env(:optimal_engine, key)}

    Application.put_env(:optimal_engine, :root_path, Path.join(tmp, "root"))
    Application.put_env(:optimal_engine, :cache_path, Path.join(tmp, "cache"))
    Application.put_env(:optimal_engine, :backup_dir, Path.join(tmp, "backups"))

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:optimal_engine, key)
        {key, value} -> Application.put_env(:optimal_engine, key, value)
      end)
    end)

    suffix = System.unique_integer([:positive])

    {:ok, workspace} =
      WorkspaceTopology.create_workspace(%{slug: "reality-#{suffix}", name: "Reality #{suffix}"})

    %{ws: workspace.id, slug: workspace.slug, suffix: suffix, tmp: tmp}
  end

  test "every catalog store has a proof and reports available" do
    stores = StorageCatalog.list()
    assert stores |> Enum.map(& &1.id) |> Enum.sort() == Enum.sort(@proven)

    for store <- stores do
      assert store.status == "available", "#{store.id} is #{store.status}"
    end
  end

  describe "relational" do
    test "workspace rows are written, read, durable, and unique", %{ws: ws, slug: slug} do
      assert {:ok, workspace} = OptimalEngine.Workspace.get(ws)
      assert workspace.slug == slug

      assert [[^slug, "active"]] =
               on_disk("SELECT slug, status FROM workspaces WHERE id = ?1", [ws])

      assert {:error, _} = WorkspaceTopology.create_workspace(%{slug: slug, name: "Duplicate"})
    end
  end

  describe "full_text" do
    test "contexts and memories are indexed by FTS5", %{ws: ws, suffix: suffix} do
      token = "zyqvortex#{suffix}"
      id = context!(ws, "fts-#{suffix}", "Launch note mentioning #{token}")

      assert {:ok, [[^id]]} =
               Store.raw_query("SELECT id FROM contexts_fts WHERE contexts_fts MATCH ?1", [token])

      {:ok, memory} = Memory.create(%{content: "Durable memory about #{token}", workspace_id: ws})
      assert memory.id

      assert {:ok, [[1]]} =
               Store.raw_query("SELECT COUNT(*) FROM memories_fts WHERE memories_fts MATCH ?1", [
                 token
               ])

      assert [[^id]] = on_disk("SELECT id FROM contexts_fts WHERE contexts_fts MATCH ?1", [token])

      :ok = Store.delete_context(id)

      assert {:ok, []} =
               Store.raw_query("SELECT id FROM contexts_fts WHERE contexts_fts MATCH ?1", [token])

      assert {:error, _} =
               Store.raw_query("SELECT id FROM contexts_fts WHERE contexts_fts MATCH ?1", [
                 "\"unbalanced"
               ])
    end
  end

  describe "vector" do
    test "embeddings are stored, cosine-searched, durable, and validated", %{ws: ws, suffix: s} do
      near = context!(ws, "vec-near-#{s}", "near")
      far = context!(ws, "vec-far-#{s}", "far")
      :ok = Vectors.store(near, [1.0, 0.0, 0.0])
      :ok = Vectors.store(far, [0.0, 1.0, 0.0])

      assert {:ok, [{^near, top}, {^far, low}]} = Vectors.search([0.9, 0.1, 0.0], workspace_id: ws)
      assert top > 0.99 and low < 0.2

      assert [[blob, 3]] =
               on_disk("SELECT embedding, dimensions FROM vectors WHERE context_id = ?1", [near])

      assert for(<<f::float-little-32 <- blob>>, do: f) == [1.0, 0.0, 0.0]

      assert {:error, :invalid_embedding} = Vectors.store(near, [])
      assert {:ok, []} = Vectors.search([1.0, 0.0, 0.0], workspace_id: "another-#{ws}")
    end
  end

  describe "graph" do
    setup %{ws: ws, suffix: s} do
      people = for name <- ~w(ana ben cal dee), do: "#{name}-#{s}"
      [ana, ben, cal, dee] = people

      :ok = Graph.assert_edge(ana, ben, "knows", workspace_id: ws)
      :ok = Graph.assert_edge(ben, cal, "knows", workspace_id: ws)
      :ok = Graph.assert_edge(cal, dee, "knows", workspace_id: ws)

      %{people: people}
    end

    @tag :rocksdb
    test "RocksDB persists edges across a reopen and traverses multiple hops", %{
      ws: ws,
      tmp: tmp,
      people: [ana, ben, cal, dee]
    } do
      path = Path.join(tmp, "knowledge-rocksdb")
      opts = [backend: Backend.RocksDB, backend_opts: [path: path]]

      {:ok, store} = Knowledge.open("reality-rocks-#{ws}", opts)
      assert {:ok, 3} = Graph.hydrate_triple_store(store, workspace_id: ws)
      assert MapSet.new([ben, cal, dee]) == reachable(store, ws, ana, 3)
      :ok = Knowledge.close(store)

      {:ok, reopened} = Knowledge.open("reality-rocks-#{ws}", opts)
      assert {:ok, 3} = Knowledge.count(reopened)
      assert MapSet.new([ben, cal, dee]) == reachable(reopened, ws, ana, 3)

      assert {:ok, [%{"c" => ^cal}]} =
               Knowledge.sparql(reopened, "SELECT ?c WHERE { <#{ana}> <knows> ?b . ?b <knows> ?c }")

      :ok = Knowledge.close(reopened)

      blocker = Path.join(tmp, "not-a-directory")
      File.write!(blocker, "file")
      assert {:error, _} = Backend.RocksDB.init("reality-blocked", path: blocker)
    end

    test "ETS traverses edges and is rebuilt from durable SQLite lineage", %{
      ws: ws,
      people: [ana, ben, cal, dee]
    } do
      assert {:ok, edges} = Graph.edges_for(ana, workspace_id: ws)
      assert [%{target_id: ^ben}] = Enum.map(edges, &Map.take(&1, [:target_id]))

      assert [[3]] = on_disk("SELECT COUNT(*) FROM graph_edges WHERE workspace_id = ?1", [ws])

      {:ok, store} = Knowledge.open("reality-ets-#{ws}", backend: Backend.ETS)
      assert {:ok, 3} = Graph.hydrate_triple_store(store, workspace_id: ws)
      assert MapSet.new([ben, cal, dee]) == reachable(store, ws, ana, 3)
      :ok = Knowledge.close(store)

      {:ok, rebuilt} = Knowledge.open("reality-ets-#{ws}", backend: Backend.ETS)
      assert {:ok, 0} = Knowledge.count(rebuilt)
      assert {:ok, 3} = Graph.hydrate_triple_store(rebuilt, workspace_id: ws)
      assert MapSet.new([ben, cal, dee]) == reachable(rebuilt, ws, ana, 3)

      assert {:error, _} = Knowledge.sparql(rebuilt, "NOT SPARQL")
      assert MapSet.new() == reachable(rebuilt, "another-#{ws}", ana, 3)
      :ok = Knowledge.close(rebuilt)
    end
  end

  describe "assets" do
    test "files are preserved with metadata and extraction rows", %{ws: ws, tmp: tmp} do
      bytes = "%PDF-1.7\nstore-reality-asset"
      source = Path.join(tmp, "evidence.pdf")
      File.write!(source, bytes)

      assert {:ok, %{asset: asset}} =
               MemoryCore.store_asset_file(source, workspace_id: ws, actor_id: "user:reality")

      assert {:ok, fetched} = MemoryCore.get_asset(asset.id, workspace_id: ws)
      assert fetched.content_hash == "sha256:" <> sha256(bytes)
      assert File.read!(fetched.storage_path) == bytes

      assert {:ok, run} =
               MemoryCore.record_asset_adapter_run(asset.id,
                 workspace_id: ws,
                 actor_id: "user:reality",
                 adapter_id: :docling,
                 adapter_role: :document_intelligence,
                 status: "completed",
                 output_text: "extracted text"
               )

      assert {:ok, %{extraction: extraction}} =
               MemoryCore.record_asset_extraction(run.id,
                 workspace_id: ws,
                 actor_id: "user:reality",
                 extraction_type: :transcript,
                 content_text: "spoken words"
               )

      assert {:ok, [listed]} = MemoryCore.list_asset_extractions(asset.id, workspace_id: ws)
      assert listed.id == extraction.id

      assert [[path, _hash]] =
               on_disk("SELECT storage_path, content_hash FROM assets WHERE id = ?1", [asset.id])

      assert File.regular?(path)

      assert [[1]] =
               on_disk("SELECT COUNT(*) FROM asset_extractions WHERE asset_id = ?1", [asset.id])

      assert {:error, _} =
               MemoryCore.store_asset_file(Path.join(tmp, "missing.pdf"), workspace_id: ws)

      assert {:error, :not_found} = MemoryCore.get_asset(asset.id, workspace_id: "another-#{ws}")
    end
  end

  describe "cache" do
    test "the ETS hot cache serves reads and is rebuilt from SQLite", %{ws: ws, suffix: s} do
      id = context!(ws, "cache-#{s}", "cached context")

      assert [{^id, %Context{}}] = :ets.lookup(:optimal_engine_store_cache, id)
      assert {:ok, %Context{id: ^id}} = Store.get_context(id)

      :ets.delete(:optimal_engine_store_cache, id)
      assert {:ok, %Context{id: ^id}} = Store.get_context(id)
      assert [{^id, %Context{}}] = :ets.lookup(:optimal_engine_store_cache, id)

      assert {:error, :not_found} = Store.get_context("missing-#{s}")
      assert [] == :ets.lookup(:optimal_engine_store_cache, "missing-#{s}")
    end

    test "the filesystem cache persists entries and discards corrupt ones", %{tmp: tmp} do
      scope = {"default", "default:reality"}
      assert :ok = FileCache.put(scope, "reality", "key", %{"value" => 1})
      assert {:ok, %{"value" => 1}} = FileCache.get(scope, "reality", "key")

      assert {:ok, %{"value" => 1}} =
               Task.async(fn -> FileCache.get(scope, "reality", "key") end) |> Task.await()

      assert [entry] =
               Path.wildcard(
                 Path.join([tmp, "cache", "tenants", "*", "*", "reality", "*", "*.bin"])
               )

      File.write!(entry, "corrupt")
      assert :miss = FileCache.get(scope, "reality", "key")
      refute File.exists?(entry)
    end
  end

  describe "jobs" do
    test "jobs enqueue, run, retry, and dead-letter durably", %{ws: ws, suffix: s} do
      kind = "reality.job.#{s}"
      {:ok, ok_job} = Jobs.enqueue(ws, kind, %{"step" => "ok"}, priority: 2)
      {:ok, bad_job} = Jobs.enqueue(ws, kind, %{"step" => "bad"}, priority: 1, max_attempts: 2)

      handler = fn
        %{payload: %{"step" => "ok"}} -> :ok
        %{payload: %{"step" => "bad"}} -> {:error, :always_fails}
      end

      opts = [workspace_id: ws, kinds: [kind], retry_in: 0]
      assert {:ok, %{outcome: :completed}} = Jobs.run_next(handler, opts)
      assert {:ok, %{outcome: :retry}} = Jobs.run_next(handler, opts)
      assert {:ok, %{outcome: :dead}} = Jobs.run_next(handler, opts)
      assert :empty = Jobs.run_next(handler, opts)

      assert [["completed"]] = on_disk("SELECT status FROM jobs WHERE id = ?1", [ok_job.id])

      assert [["dead", 2]] =
               on_disk("SELECT status, attempts FROM jobs WHERE id = ?1", [bad_job.id])

      assert [[letter_id]] =
               on_disk("SELECT id FROM dead_letter_jobs WHERE original_job_id = ?1", [bad_job.id])

      assert {:ok, replay} = Jobs.replay_dead_letter(letter_id, ws)
      assert replay.status == "available"

      {:ok, claimed} = Jobs.claim(workspace_id: ws, kinds: [kind], lease_owner: "worker-a")
      assert {:error, :lease_lost} = Jobs.complete(claimed.id, "worker-b")
    end
  end

  describe "replication" do
    test "the mutation ledger appends, replays, advances cursors, and stays scoped", %{
      ws: ws,
      suffix: s
    } do
      attrs = %{
        workspace_id: ws,
        device_id: "device-a",
        entity_type: "memory_object",
        entity_id: "entity-#{s}",
        operation: :update,
        payload: %{"field" => "value"},
        idempotency_key: "reality-#{s}"
      }

      assert {:ok, mutation} = PolicyStore.append_mutation(attrs)
      assert {:ok, ^mutation} = PolicyStore.append_mutation(attrs)
      assert {:ok, [replayed]} = PolicyStore.mutations_after(ws, 0)
      assert replayed.payload == %{"field" => "value"}

      :ok = PolicyStore.advance_cursor(ws, "replica-b", mutation.sequence)
      :ok = PolicyStore.advance_cursor(ws, "replica-b", 0)

      assert [[seq]] =
               on_disk(
                 "SELECT last_sequence FROM sync_cursors WHERE workspace_id = ?1 AND replica_id = 'replica-b'",
                 [ws]
               )

      assert seq == mutation.sequence

      assert [[_hash]] =
               on_disk("SELECT payload_hash FROM sync_mutations WHERE id = ?1", [mutation.id])

      {:ok, other} =
        WorkspaceTopology.create_workspace(%{slug: "reality-other-#{s}", name: "Other #{s}"})

      assert {:error, :idempotency_key_conflict} =
               PolicyStore.append_mutation(%{attrs | workspace_id: other.id})

      assert {:error, :invalid_operation} =
               PolicyStore.append_mutation(%{attrs | operation: :merge, idempotency_key: "x-#{s}"})
    end
  end

  describe "metrics" do
    test "samples are recorded, queried, durable, and validated", %{ws: ws} do
      assert {:ok, sample} = History.record(ws, "reality.depth", 4, labels: %{"queue" => "q"})
      assert {:ok, [%{id: id}]} = History.list(ws, metric_name: "reality.depth")
      assert id == sample.id

      assert {:ok, written} = History.snapshot_telemetry(ws)
      assert written > 0

      assert [["gauge", 4.0]] =
               on_disk("SELECT metric_kind, value FROM metric_samples WHERE id = ?1", [sample.id])

      assert {:error, {:invalid_metric_name, _}} = History.record(ws, "not a name", 1)
    end
  end

  describe "backups" do
    test "backups are created, verified, and restored into a new path", %{ws: ws, tmp: tmp} do
      {:ok, target} = Backup.resolve_target("reality.db")
      assert {:ok, info} = Backup.create(target)
      assert info.integrity_status == "verified"
      assert {:ok, :ok} = Backup.verify(target)

      restored = Path.join(tmp, "restored.db")
      assert {:ok, %{checksum_sha256: checksum}} = Backup.restore(target, target: restored)
      assert checksum == info.checksum_sha256
      assert [[1]] = read_db(restored, "SELECT COUNT(*) FROM workspaces WHERE id = ?1", [ws])

      assert [["verified"]] =
               on_disk("SELECT integrity_status FROM backup_records WHERE id = ?1", [info.id])

      File.write!(target, "tamper", [:append])

      assert {:error, {:checksum_mismatch, _, _}} =
               Backup.restore(target, target: Path.join(tmp, "never.db"))

      assert {:error, {:outside_backup_dir, _}} = Backup.resolve_target("../escape.db")
    end
  end

  describe "decomposition" do
    test "runs are checkpointed and fall back when the recursive sidecar fails", %{
      ws: ws,
      tmp: tmp
    } do
      source =
        SourcePackage.from_text("# Notes\n\nOne paragraph.\n\nAnother paragraph.",
          workspace_id: ws,
          source_type: "reality_note"
        )

      _ = MemoryCore.Store.insert_source_package(source)

      assert {:ok, %{run: run}} = DecompositionRuns.run(ws, source.id)
      assert run.status == "completed"
      assert run.output_units > 0
      assert File.regular?(run.checkpoint_uri)

      assert {:ok, %{run: fallback, attempts: [failed, fallback]}} =
               DecompositionRuns.run(ws, source.id,
                 strategy: :recursive,
                 command: "exit 3",
                 script: Path.join(tmp, "absent.py")
               )

      assert {failed.status, failed.fallback_strategy} == {"failed", "deterministic"}
      assert fallback.strategy == "fallback"

      assert [[3]] =
               on_disk("SELECT COUNT(*) FROM decomposition_runs WHERE source_package_id = ?1", [
                 source.id
               ])

      assert {:error, :source_package_not_found} = DecompositionRuns.run(ws, "missing-source")
    end
  end

  describe "models" do
    test "examples, runs, and adapters follow the governed lifecycle", %{ws: ws, tmp: tmp} do
      {:ok, example} =
        Registry.add_example(ws, %{
          input: "q",
          expected_output: "a",
          purpose: "reality",
          consent_basis: "test fixture"
        })

      {:ok, _} = Registry.approve_example(ws, example.id)

      attrs = %{
        base_model: "base",
        trainer: "local",
        method: "lora",
        dataset_query: %{"purpose" => "reality"}
      }

      {:ok, run} = Registry.create_run(ws, attrs)
      {:ok, _} = Registry.start_run(ws, run.id)
      {:ok, run} = Registry.complete_run(ws, run.id, %{"loss" => 0.1})

      artifact = Path.join(tmp, "adapter.bin")
      File.write!(artifact, "weights")

      {:ok, adapter} =
        Registry.register_adapter(ws, %{
          training_run_id: run.id,
          adapter_type: "lora",
          artifact_uri: artifact,
          checksum_sha256: sha256("weights")
        })

      {:ok, active} = Registry.activate_adapter(ws, adapter.id)
      assert active.status == "active"
      assert {:ok, %{id: id}} = Registry.active_adapter(ws, "base", "lora")
      assert id == adapter.id

      assert [["completed"]] = on_disk("SELECT status FROM training_runs WHERE id = ?1", [run.id])

      assert [["active", 1]] =
               on_disk("SELECT status, version FROM model_adapters WHERE id = ?1", [adapter.id])

      assert {:error, :no_approved_examples} =
               Registry.create_run(ws, %{attrs | dataset_query: %{"purpose" => "unapproved"}})

      assert {:error, {:checksum_mismatch, _, _}} =
               Registry.register_adapter(ws, %{
                 training_run_id: run.id,
                 adapter_type: "lora",
                 artifact_uri: artifact,
                 checksum_sha256: sha256("other weights")
               })
    end
  end

  describe "secrets" do
    setup do
      original = System.get_env("CONNECTOR_KEY")
      System.put_env("CONNECTOR_KEY", Base.encode16(:crypto.strong_rand_bytes(32), case: :lower))

      on_exit(fn ->
        if original,
          do: System.put_env("CONNECTOR_KEY", original),
          else: System.delete_env("CONNECTOR_KEY")
      end)

      :ok
    end

    test "connector credentials are sealed and API keys are hashed", %{ws: ws, suffix: s} do
      id = "reality-connector-#{s}"

      {:ok, ^id} =
        Runner.upsert_row(%{
          id: id,
          kind: :slack,
          workspace_id: ws,
          config: %{credentials: %{bot_token: "xoxb-reality-#{s}"}}
        })

      assert [[json]] = on_disk("SELECT config FROM connectors WHERE id = ?1", [id])
      refute json =~ "xoxb-reality"
      %{"credentials_ciphertext" => envelope} = Jason.decode!(json)
      assert {:ok, %{"bot_token" => "xoxb-reality-" <> _}} = Credential.decrypt(envelope)

      {:ok, minted} =
        ApiKey.mint(%{tenant_id: "default", name: "reality #{s}", workspace_scope: [ws]})

      assert {:ok, verified} = ApiKey.verify(minted.key)
      assert verified.id == minted.id

      assert [[hash]] = on_disk("SELECT hashed_secret FROM api_keys WHERE id = ?1", [minted.id])
      refute hash == minted.secret
      assert String.starts_with?(hash, "$2")

      assert {:error, :invalid} = ApiKey.verify(minted.key <> "x")
      System.put_env("CONNECTOR_KEY", Base.encode16(:crypto.strong_rand_bytes(32), case: :lower))
      assert {:error, :auth_failed} = Credential.decrypt(envelope)
    end
  end

  describe "s3 provider" do
    @s3_env ~w(OPTIMAL_S3_ENDPOINT OPTIMAL_S3_BUCKET OPTIMAL_S3_REGION OPTIMAL_S3_ACCESS_KEY_ID
               OPTIMAL_S3_SECRET_ACCESS_KEY)

    setup do
      previous = Map.new(@s3_env, &{&1, System.get_env(&1)})

      ref = S3Stub.ref()
      on_exit(fn -> S3Stub.stop(ref) end)
      {:ok, stub} = S3Stub.start(ref: ref, bucket: "engine-test")

      on_exit(fn ->
        Enum.each(previous, fn
          {name, nil} -> System.delete_env(name)
          {name, value} -> System.put_env(name, value)
        end)
      end)

      %{stub: stub}
    end

    defp point_at(stub) do
      System.put_env("OPTIMAL_S3_ENDPOINT", stub.endpoint)
      System.put_env("OPTIMAL_S3_BUCKET", stub.bucket)
      System.put_env("OPTIMAL_S3_ACCESS_KEY_ID", stub.access_key_id)
      System.put_env("OPTIMAL_S3_SECRET_ACCESS_KEY", stub.secret_access_key)
      System.put_env("OPTIMAL_S3_REGION", stub.region)
    end

    test "an unconfigured provider is skipped rather than claimed", %{stub: _stub} do
      Enum.each(@s3_env, &System.delete_env/1)

      proofs = Providers.proofs()

      assert %{provider: "s3", status: "skipped", reason: "not configured"} =
               Enum.find(proofs, &(&1.provider == "s3"))

      for proof <- proofs, proof.provider not in ["s3", "postgres"] do
        assert proof.status == "adapter_missing"
      end
    end

    test "a configured provider passes a real round trip and the rest stay adapter_missing", %{
      stub: stub
    } do
      point_at(stub)

      proofs = Providers.proofs()
      s3 = Enum.find(proofs, &(&1.provider == "s3"))

      assert s3.status == "pass"
      assert s3.evidence.deleted
      assert s3.evidence.listed
      assert byte_size(s3.evidence.checksum_sha256) == 64
      assert s3.evidence.size_bytes > 0
      assert s3.evidence.key =~ "health/"

      for proof <- proofs, proof.provider not in ["s3", "postgres"] do
        assert proof.status == "adapter_missing", "#{proof.provider} is #{proof.status}"
        assert proof.reason =~ "no adapter"
      end

      # The same configuration that passes the proof is reported as available,
      # and the object it wrote was cleaned up.
      assert {:ok, provider} = Providers.get("s3", probe: true)
      assert provider.lifecycle_state == "available"
      assert S3Stub.object_keys(stub.agent) == []
    end

    test "a configured but unreachable provider fails its proof", %{stub: stub} do
      point_at(stub)

      {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
      {:ok, port} = :inet.port(socket)
      :gen_tcp.close(socket)

      System.put_env("OPTIMAL_S3_ENDPOINT", "http://127.0.0.1:#{port}")
      System.put_env("OPTIMAL_S3_MAX_RETRIES", "0")

      assert %{provider: "s3", status: "fail"} =
               Providers.proofs() |> Enum.find(&(&1.provider == "s3"))

      assert {:ok, provider} = Providers.get("s3", probe: true)
      refute provider.lifecycle_state in ["active", "available"]
    end
  end

  # ─── helpers ───────────────────────────────────────────────────────────────
  defp context!(ws, id, text) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    :ok =
      Store.insert_context(%Context{
        id: id,
        uri: "optimal://inbox/#{id}.md",
        type: :resource,
        path: "/store-reality/#{id}.md",
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

  # Reads through a separate read-only SQLite connection, so a passing
  # assertion proves the row is in the database file, not in a process.
  defp on_disk(sql, params) do
    read_db(Application.fetch_env!(:optimal_engine, :db_path), sql, params)
  end

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
    {seen, _frontier} =
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

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
