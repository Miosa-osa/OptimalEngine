defmodule OptimalEngine.AtomHardeningTest do
  @moduledoc """
  No text a caller, a peer or a file supplies becomes an atom.

  Each test feeds text that no atom exists for through one code path that used
  to call `String.to_atom/1` (or decode JSON with atom keys), then proves with
  `refute_atom/1` that the atom still does not exist, and that the code still
  behaves: it keeps the text, falls back to a documented default, or rejects
  the input.

  `OptimalEngine.AtomGuardTest` keeps new `to_atom` calls out of `lib/`.
  """

  use ExUnit.Case, async: false

  import OptimalEngine.AtomProbe
  import Plug.Conn
  import Plug.Test

  alias OptimalEngine.API.Router
  alias OptimalEngine.Architecture
  alias OptimalEngine.Architecture.Architecture, as: ArchitectureSpec
  alias OptimalEngine.Connectors.PullScheduler
  alias OptimalEngine.Connectors.Registry, as: ConnectorRegistry
  alias OptimalEngine.DataContract
  alias OptimalEngine.Evaluation
  alias OptimalEngine.Insight.MemoryExtractor
  alias OptimalEngine.Knowledge
  alias OptimalEngine.Knowledge.SPARQL.Parser, as: SparqlParser
  alias OptimalEngine.Memory
  alias OptimalEngine.Memory.Session
  alias OptimalEngine.Operating.Loops
  alias OptimalEngine.Organization
  alias OptimalEngine.Render.Spec
  alias OptimalEngine.Store
  alias OptimalEngine.Telemetry
  alias OptimalEngine.Wiki.{Directives, Integrity, Page}
  alias OptimalEngine.Workspace.Config

  @router_opts Router.init([])

  # A process linked to the test is already gone when on_exit runs.
  defp stop_quietly(stop) do
    stop.()
  catch
    :exit, _reason -> :ok
  end

  describe "wiki directives" do
    test "an unknown verb stays text and is reported, not made an atom" do
      verb = never_seen("zz_verb")

      assert {:ok, [directive]} = Directives.parse("see {{#{verb}: some argument}}")

      assert directive.verb == verb
      assert directive.argument == "some argument"
      refute Directives.all_verbs_whitelisted?("{{#{verb}: x}}")
      refute_atom(verb)
    end

    test "a whitelisted verb is still an atom" do
      assert {:ok, [%{verb: :cite}, %{verb: :wikilink}]} =
               Directives.parse("{{cite: optimal://a}} and [[page]]")
    end

    test "integrity flags the unknown verb by its text" do
      verb = never_seen("zz_verb")

      report =
        Integrity.check(%Page{
          tenant_id: "default",
          slug: "atoms",
          audience: "default",
          version: 1,
          frontmatter: %{},
          body: "A page with {{#{verb}: x}} in it."
        })

      refute report.ok?
      assert Enum.any?(report.issues, &(&1.kind == :invalid_verb and &1.message =~ verb))
      refute_atom(verb)
    end

    test "rendering leaves an unknown directive as written" do
      verb = never_seen("zz_verb")
      body = "before {{#{verb}: x}} after"

      {rendered, warnings} =
        Directives.render(body, fn _directive, _opts -> {:error, :unresolved} end, format: :plain)

      assert rendered =~ "{{#{verb}: x}}"
      assert [_warning] = warnings
      refute_atom(verb)
    end
  end

  describe "optimal:// URIs" do
    test "an unknown namespace stays text" do
      namespace = never_seen("zz_namespace")

      assert {:ok, parsed} = OptimalEngine.URI.parse("optimal://#{namespace}/a/b")

      assert parsed.namespace == namespace
      assert parsed.segments == ["a", "b"]
      assert OptimalEngine.URI.namespace("optimal://#{namespace}/a") == namespace
      assert OptimalEngine.URI.context_type(parsed) == :resource
      assert {:error, {:unresolvable_namespace, ^namespace}} = OptimalEngine.URI.resolve(parsed)
      refute_atom(namespace)
    end

    test "a known namespace is still an atom" do
      assert {:ok, %{namespace: :nodes}} = OptimalEngine.URI.parse("optimal://nodes/a/b.md")

      assert {:ok, %{namespace: :user_memories}} =
               OptimalEngine.URI.parse("optimal://user/memories/x")
    end
  end

  describe "data contracts" do
    test "report the missing fields by name from string or atom keys" do
      assert {:error, {:contract_violation, %{missing: ["entity_kind", "canonical_name"]}}} =
               DataContract.validate(:entity, %{"workspace_id" => "w"})

      assert {:error, {:contract_violation, %{missing: ["surface_text"]}}} =
               DataContract.validate(:mention, %{workspace_id: "w"})

      assert {:ok, %{type: :mention}} =
               DataContract.validate(:mention, %{"workspace_id" => "w", surface_text: "s"})
    end
  end

  describe "telemetry" do
    test "an event that is not declared is ignored" do
      assert :ok = Telemetry.handle_event([:optimal_engine, :stray, :event], %{}, %{}, nil)

      refute Map.has_key?(Telemetry.snapshot().counters, :"optimal_engine.stray.event")
    end

    test "a declared event reaches its counter" do
      metric = :"optimal_engine.intake.ingested"
      before = Telemetry.snapshot().counters[metric]

      Telemetry.handle_event([:optimal_engine, :intake, :ingested], %{count: 1}, %{}, nil)

      assert Telemetry.snapshot().counters[metric] >= before + 1
    end
  end

  describe "exported memory files" do
    @describetag :tmp_dir

    defp entry_file(dir, name, nested, extra_metadata, extra_entry) do
      path = Path.join(dir, name)

      File.write!(
        path,
        Jason.encode!([
          %{
            "key" => "k1",
            "value" => %{nested => 1, "description" => "d"},
            "metadata" => %{
              "created_at" => "2026-01-01T00:00:00Z",
              "updated_at" => "2026-01-02T00:00:00Z",
              "tags" => ["a"],
              extra_metadata => true
            },
            extra_entry => "ignored"
          }
        ])
      )

      path
    end

    test "an entry is read by fixed tables, whatever keys the file holds", %{tmp_dir: dir} do
      nested = never_seen("zz_nested")
      extra_metadata = never_seen("zz_meta")
      extra_entry = never_seen("zz_entry")
      path = entry_file(dir, "export.json", nested, extra_metadata, extra_entry)

      collection = "atoms_import_#{System.unique_integer([:positive])}"
      assert :ok = Memory.import_collection(collection, path)

      assert {:ok, entry} = Memory.recall(collection, "k1")
      # Keys the engine's writers use are atoms; every other key stays text.
      assert entry.value == %{nested => 1, description: "d"}
      assert entry.metadata.tags == ["a"]
      assert entry.metadata.created_at == ~U[2026-01-01 00:00:00Z]
      assert entry.metadata[extra_metadata] == true
      assert is_integer(entry.metadata.access_count)

      for text <- [nested, extra_metadata, extra_entry], do: refute_atom(text)
    end

    test "decode_entry rejects a file that is not an entry" do
      assert_raise FunctionClauseError, fn ->
        Memory.Store.decode_entry(%{"nothing" => "here"})
      end
    end

    test "a collection keeps its shape through an export and an import", %{tmp_dir: dir} do
      collection = "atoms_roundtrip_#{System.unique_integer([:positive])}"
      imported = collection <> "_copy"
      path = Path.join(dir, "roundtrip.json")

      :ok =
        Memory.store(
          collection,
          "episode",
          %{description: "d", outcome: "o", tags: ["x"], custom: 1, nested: %{inner: 2}},
          tags: ["t"]
        )

      assert :ok = Memory.export(collection, path)
      assert :ok = Memory.import_collection(imported, path)
      assert {:ok, original} = Memory.recall(collection, "episode")
      assert {:ok, copy} = Memory.recall(imported, "episode")

      # The writers' own keys return as atoms; other keys return as text, and
      # their nested maps are plain JSON.
      assert copy.value == %{
               "custom" => 1,
               "nested" => %{"inner" => 2},
               description: "d",
               outcome: "o",
               tags: ["x"]
             }

      assert copy.metadata.tags == original.metadata.tags
      assert copy.metadata.created_at == original.metadata.created_at
    end

    test "a persisted collection loads at start without making atoms", %{tmp_dir: dir} do
      nested = never_seen("zz_nested")
      extra_metadata = never_seen("zz_meta")
      collection = "atoms_persisted_#{System.unique_integer([:positive])}"
      entry_file(dir, collection <> ".json", nested, extra_metadata, "ignored")

      original = Application.get_env(:optimal_engine, Memory.Store.ETS)
      Application.put_env(:optimal_engine, Memory.Store.ETS, persist: true, persist_path: dir)

      on_exit(fn ->
        if original,
          do: Application.put_env(:optimal_engine, Memory.Store.ETS, original),
          else: Application.delete_env(:optimal_engine, Memory.Store.ETS)

        :ets.match_delete(:optimal_engine_memory_store, {{collection, :_}, :_})
        :ets.delete(:optimal_engine_memory_collections, collection)
      end)

      assert {:ok, _state} = Memory.Store.ETS.init([])

      assert {:ok, entry} = Memory.Store.ETS.get(collection, "k1")
      assert entry.value == %{nested => 1, description: "d"}
      assert entry.metadata[extra_metadata] == true
      refute_atom(nested)
      refute_atom(extra_metadata)
    end
  end

  describe "session files" do
    @describetag :tmp_dir

    test "a message line with keys the session does not know loads", %{tmp_dir: dir} do
      Application.put_env(:optimal_engine, Session, session_path: dir)
      on_exit(fn -> Application.delete_env(:optimal_engine, Session) end)

      extra = never_seen("zz_session_key")
      id = "atoms_session_#{System.unique_integer([:positive])}"
      File.mkdir_p!(Path.join(dir, id))

      File.write!(
        Path.join([dir, id, "messages.jsonl"]),
        Jason.encode!(%{
          "role" => "assistant",
          "content" => "hello",
          "timestamp" => "2026-01-01T00:00:00Z",
          extra => 1
        }) <> "\n"
      )

      {:ok, _} = Session.load(id)
      on_exit(fn -> stop_quietly(fn -> Session.stop(id) end) end)

      assert [%{role: :assistant, content: "hello"}] = Session.messages(id)
      refute_atom(extra)
    end
  end

  describe "workspace config" do
    setup do
      root = Path.join(System.tmp_dir!(), "atoms_config_#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)
      on_exit(fn -> File.rm_rf!(root) end)
      %{root: root}
    end

    test "keys outside the schema stay text and survive a round trip", %{root: root} do
      section = never_seen("zz_section")
      nested = never_seen("zz_nested")

      assert :ok =
               Config.put(
                 "default",
                 %{
                   "memory" => %{"extract_from_wiki" => true, nested => 5},
                   section => %{"setting" => 3}
                 },
                 root
               )

      assert {:ok, cfg} = Config.get("default", root)

      assert cfg.memory.extract_from_wiki == true
      assert cfg.memory[nested] == 5
      assert cfg[section] == %{"setting" => 3}
      assert cfg.grep.max_results == 25

      for text <- [section, nested], do: refute_atom(text)
    end

    test "a config.yaml with unknown keys reads without creating atoms", %{root: root} do
      key = never_seen("zz_yaml_key")
      path = Path.join([root, ".optimal", "config.yaml"])
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "grep:\n  max_results: 7\n  #{key}: 1\n#{key}_top: 2\n")

      assert {:ok, cfg} = Config.get("default", root)
      assert cfg.grep.max_results == 7
      assert cfg.grep[key] == 1
      assert cfg[key <> "_top"] == 2
      refute_atom(key)
      refute_atom(key <> "_top")
    end
  end

  describe "render specs" do
    test "modalities outside the known ones are dropped" do
      modality = never_seen("zz_modality")

      assert {:ok, spec} =
               Spec.from_map(%{"name" => "s", "modalities" => ["text", modality, "image"]})

      assert spec.modalities == [:text, :image]
      refute_atom(modality)
    end

    test "only unknown modalities leave the default" do
      modality = never_seen("zz_modality")

      assert {:ok, %{modalities: [:text]}} =
               Spec.from_map(%{"name" => "s", "modalities" => [modality]})

      refute_atom(modality)
    end
  end

  describe "model output" do
    test "a memory category outside the known ones reads as context" do
      category = never_seen("zz_category")

      answer =
        Jason.encode!([
          %{"category" => category, "content" => "something", "confidence" => 0.9},
          %{"category" => " Decision ", "content" => "we chose", "confidence" => 0.9}
        ])

      assert [%{category: :context}, %{category: :decision}] =
               MemoryExtractor.parse_memories(answer)

      refute_atom(category)
    end
  end

  describe "SPARQL queries" do
    test "a function name outside the supported ones does not become an atom" do
      name = never_seen("zzfunc")

      _ =
        try do
          SparqlParser.parse("SELECT ?s WHERE { ?s <p> ?o . FILTER (#{name}(?o)) }")
        rescue
          _ -> :raised
        catch
          _, _ -> :thrown
        end

      refute_atom(name)
      refute_atom(String.upcase(name))
    end

    test "every accepted spelling of a function reads as its executor atom" do
      for {spelling, atom} <- [
            {"contains", :CONTAINS},
            {"CONTAINS", :CONTAINS},
            {"isIRI", :ISIRI},
            {"isiri", :ISIRI},
            {"isLiteral", :ISLITERAL},
            {"isBlank", :ISBLANK},
            {"bound", :BOUND},
            {"STR", :STR}
          ] do
        {:ok, ast} = SparqlParser.parse("SELECT ?s WHERE { ?s <p> ?o . FILTER (#{spelling}(?o)) }")
        assert [{^atom, _args}] = ast.filters, spelling
      end
    end

    test "comparison operators read as their atoms" do
      for {op, atom} <- [{"=", :=}, {"!=", :!=}, {"<", :<}, {">", :>}, {"<=", :<=}, {">=", :>=}] do
        {:ok, ast} = SparqlParser.parse("SELECT ?s WHERE { ?s <p> ?o . FILTER (?o #{op} 3) }")
        assert [{^atom, {:var, "o"}, {:literal, 3}}] = ast.filters, op
      end
    end
  end

  describe "POST /api/nodes" do
    test "a kind outside the known ones is refused and not made an atom" do
      kind = never_seen("zz_kind")

      conn = request(:post, "/api/nodes", %{name: "Atoms probe", kind: kind})

      assert conn.status == 400
      assert Jason.decode!(conn.resp_body)["error"] =~ "kind must be one of"
      refute_atom(kind)
    end

    test "a known kind is accepted" do
      slug = never_seen("zz_node")

      conn = request(:post, "/api/nodes", %{name: "Atoms probe", slug: slug, kind: "team"})

      assert conn.status == 200
      assert %{"ok" => true, "kind" => "team"} = Jason.decode!(conn.resp_body)
      Store.raw_execute("DELETE FROM nodes WHERE slug = ?1", [slug])
    end

    defp request(method, path, body) do
      conn(method, path, Jason.encode!(body))
      |> put_req_header("content-type", "application/json")
      |> Router.call(@router_opts)
    end
  end

  describe "operating loops" do
    test "a missing required field is named by a fixed error" do
      assert {:error, :workspace_id_required} = Loops.create("default", %{"title" => "t"}, "tester")

      assert {:error, :title_required} =
               Loops.create("default", %{"workspace_id" => "default", "title" => " "}, "tester")
    end
  end

  describe "knowledge stores" do
    test "the ETS backend names no table after the store id" do
      store_id = never_seen("zz_store")

      {:ok, store} = Knowledge.open(store_id)
      on_exit(fn -> stop_quietly(fn -> Knowledge.close(store) end) end)

      assert :ok = Knowledge.assert(store, {"s", "p", "o"})

      for table <- ~w(gspo gpos gosp posg), do: refute_atom("mk_#{table}_#{store_id}")
    end
  end

  describe "connectors" do
    test "the registry finds an adapter by the text of its kind" do
      assert {:ok, module} = ConnectorRegistry.fetch("slack")
      assert module == OptimalEngine.Connectors.Adapters.Slack
      assert {:ok, ^module} = ConnectorRegistry.fetch(:slack)
    end

    test "the registry rejects an unknown kind without creating it" do
      kind = never_seen("zz_kind")

      assert {:error, :unknown_kind} = ConnectorRegistry.fetch(kind)
      refute_atom(kind)
    end

    test "the pull scheduler reports a spec with an unknown kind and creates no atom" do
      kind = never_seen("zz_kind")

      # The spec is refused before anything is written, so it needs no tenant of its own.
      assert {:ok, summary} =
               PullScheduler.run_once(
                 tenant_id: "default",
                 defaults: [],
                 connectors: [%{"kind" => kind}]
               )

      assert inspect(summary) =~ "unknown_connector"
      assert inspect(summary) =~ kind
      refute_atom(kind)
    end
  end

  describe "stored architectures" do
    setup do
      id = "atoms-arch-#{System.unique_integer([:positive])}.v1"
      on_exit(fn -> Store.raw_execute("DELETE FROM architectures WHERE id = ?1", [id]) end)
      %{id: id}
    end

    defp store_architecture(id, primary_modality, spec) do
      {:ok, _} =
        Store.raw_query(
          """
          INSERT INTO architectures (id, tenant_id, name, version, description, modality_primary, spec)
          VALUES (?1, 'default', ?1, 1, 'atoms probe', ?2, ?3)
          """,
          [id, primary_modality, Jason.encode!(spec)]
        )
    end

    test "text the row holds is looked up, kept or defaulted, never made an atom", %{id: id} do
      field = never_seen("zz_field")
      modality = never_seen("zz_modality")
      primary = never_seen("zz_primary")
      processor = never_seen("zz_processor")
      granularity = never_seen("zz_granularity")
      retention = never_seen("zz_retention")

      store_architecture(id, primary, %{
        "fields" => [
          %{"name" => field, "modality" => modality, "processor" => processor, "required" => true},
          %{"name" => "title", "modality" => "text", "processor" => "text_embedder"}
        ],
        "granularity" => ["document", granularity],
        "retention" => retention
      })

      assert {:ok, arch} = Architecture.fetch(id)

      assert arch.modality_primary == :binary
      assert arch.granularity == [:document, granularity]
      assert arch.retention == retention
      assert [odd, known] = arch.fields
      assert odd.name == field
      assert odd.modality == :binary
      assert odd.processor == nil
      assert known.name == "title"
      assert known.modality == :text
      assert known.processor == :text_embedder

      assert Enum.any?(Architecture.list(), &(&1.id == id))

      for text <- [field, modality, primary, processor, granularity, retention] do
        refute_atom(text)
      end
    end

    test "a data point is checked against text field names from string keys", %{id: id} do
      field = never_seen("zz_field")
      extra_key = never_seen("zz_data_key")

      store_architecture(id, "text", %{
        "fields" => [%{"name" => field, "modality" => "binary", "required" => true}]
      })

      {:ok, arch} = Architecture.fetch(id)

      assert :ok = Architecture.validate(arch, %{field => "bytes", extra_key => 1})

      assert {:error, [{^field, :missing_required}]} =
               Architecture.validate(arch, %{extra_key => 1})

      assert {:error, [{^field, :incompatible}]} = Architecture.validate(arch, %{field => 1})

      refute_atom(extra_key)
      refute_atom(field)
    end

    test "a built-in architecture reads a request's keys without creating atoms" do
      extra_key = never_seen("zz_data_key")
      {:ok, arch} = Architecture.fetch("text_signal")

      assert :ok = Architecture.validate(arch, %{"title" => "t", "body" => "b", extra_key => 1})
      assert :ok = Architecture.validate(arch, %{title: "t", body: "b"})

      assert {:error, [{:title, :missing_required}, {:body, :missing_required}]} =
               Architecture.validate(arch, %{extra_key => 1})

      refute_atom(extra_key)
    end

    test "a field is found by atom or by text", %{id: id} do
      store_architecture(id, "text", %{"fields" => [%{"name" => "title", "modality" => "text"}]})
      {:ok, stored} = Architecture.fetch(id)
      {:ok, built_in} = Architecture.fetch("text_signal")

      assert %{name: "title"} = ArchitectureSpec.field(stored, :title)
      assert %{name: :title} = ArchitectureSpec.field(built_in, "title")
    end

    test "a spec written from stored text round-trips", %{id: id} do
      field = never_seen("zz_field")

      store_architecture(id, "text", %{
        "fields" => [%{"name" => field, "modality" => "binary"}],
        "retention" => "default"
      })

      {:ok, arch} = Architecture.fetch(id)

      assert %{"fields" => [%{"name" => ^field}], "retention" => "default"} =
               ArchitectureSpec.to_spec(arch)
    end
  end

  describe "organizations" do
    test "a stored status outside the known ones reads as dormant" do
      n = System.unique_integer([:positive])
      id = "atoms-org-#{n}"
      status = never_seen("zz_status")
      on_exit(fn -> Store.raw_execute("DELETE FROM organizations WHERE id = ?1", [id]) end)

      {:ok, _} =
        Store.raw_query(
          "INSERT INTO organizations (id, tenant_id, slug, name, status) VALUES (?1, 'default', ?1, 'Atoms', ?2)",
          [id, status]
        )

      assert {:ok, %{status: :dormant}} = Organization.get(id)
      refute_atom(status)
    end

    test "a known status is still an atom" do
      n = System.unique_integer([:positive])
      {:ok, org} = Organization.create(%{slug: "atoms-org-#{n}", name: "Atoms", status: :archived})
      on_exit(fn -> Store.raw_execute("DELETE FROM organizations WHERE id = ?1", [org.id]) end)

      assert {:ok, %{status: :archived}} = Organization.get(org.id)
    end
  end

  describe "evaluation cases" do
    test "retrieval options a dataset names are looked up in the options retrieval takes" do
      workspace_id = "atoms-eval-#{System.unique_integer([:positive])}"
      key = never_seen("zz_option")
      test_pid = self()

      on_exit(fn ->
        Store.raw_execute("DELETE FROM evaluation_runs WHERE workspace_id = ?1", [workspace_id])
      end)

      retriever = fn _question, opts ->
        send(test_pid, {:retrieval_opts, opts})
        {:ok, %{id: nil, returned_object_links: []}}
      end

      assert {:ok, result} =
               Evaluation.run_benchmark(
                 [
                   %{
                     case_id: "atoms-1",
                     question: "q",
                     expected_answer: "a",
                     retrieval_opts: %{
                       key => 1,
                       "limit" => 3,
                       "internal_refresh_allow_all" => true
                     }
                   }
                 ],
                 workspace_id: workspace_id,
                 benchmark_name: "atoms",
                 dataset_name: "atoms",
                 retriever: retriever
               )

      assert result.run.status == "completed"
      assert_received {:retrieval_opts, opts}
      assert opts[:limit] == 3
      refute Enum.any?(opts, fn {name, _} -> to_string(name) == key end)
      refute Keyword.has_key?(opts, :internal_refresh_allow_all)
      refute_atom(key)
    end
  end

  describe "mix optimal.wiki" do
    test "an unknown --format is refused and not made an atom" do
      format = never_seen("zz_format")

      assert_raise Mix.Error, ~r/Unknown format/, fn ->
        Mix.Tasks.Optimal.Wiki.run(["view", "some-page", "--format", format])
      end

      refute_atom(format)
    end
  end
end
