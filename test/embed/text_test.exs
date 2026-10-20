defmodule OptimalEngine.Embed.TextTest do
  @moduledoc """
  The text embedder against a stub embedding endpoint.

  `OPTIMAL_EMBED_URL` moves every text embedding (intake, chunks, search
  queries, memory projections, app data, backfill) to that endpoint, with the
  key as a bearer token. Unset keeps Ollama at `OLLAMA_HOST`, unchanged. The
  stub answers in the endpoint's dialect and reports every request it gets.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias OptimalEngine.Embed.{Backfill, Endpoint, Text}
  alias OptimalEngine.Memory.Versioned.Embeddings, as: MemoryEmbeddings
  alias OptimalEngine.Pipeline.Decomposer.{Chunk, ChunkTree}
  alias OptimalEngine.Pipeline.{Embedder, Intake}
  alias OptimalEngine.Retrieval.Search
  alias OptimalEngine.Store
  alias OptimalEngine.Store.{FileCache, Vectors}

  @key "embed-test-key-not-a-secret-0123"
  @auth "Bearer " <> @key
  @saved [:text_embedding, :ollama, :hybrid_search, :semantic_processing, :root_path, :embed]

  defmodule Stub do
    @moduledoc false
    @behaviour Plug

    import Plug.Conn

    @impl true
    def init(opts), do: opts

    @impl true
    def call(conn, opts) do
      {:ok, raw, conn} = read_body(conn)
      body = Jason.decode!(raw)
      authorization = get_req_header(conn, "authorization")
      send(opts[:test], {:embed_request, conn.request_path, authorization, body})

      {status, response, headers} =
        case opts[:respond].(conn.request_path, body) do
          {status, response} -> {status, response, []}
          {status, response, headers} -> {status, response, headers}
        end

      conn
      |> merge_resp_headers(headers)
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(response))
    end
  end

  setup do
    saved = Map.new(@saved, &{&1, Application.get_env(:optimal_engine, &1)})
    saved_key = System.get_env("OPTIMAL_EMBED_API_KEY")
    System.delete_env("OPTIMAL_EMBED_API_KEY")

    on_exit(fn ->
      Enum.each(saved, fn
        {name, nil} -> Application.delete_env(:optimal_engine, name)
        {name, value} -> Application.put_env(:optimal_engine, name, value)
      end)

      if saved_key,
        do: System.put_env("OPTIMAL_EMBED_API_KEY", saved_key),
        else: System.delete_env("OPTIMAL_EMBED_API_KEY")
    end)

    # The filesystem cache outlives a run, so every input carries a fresh tag.
    %{tag: Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)}
  end

  describe "OPTIMAL_EMBED_URL unset" do
    test "many texts are embedded one at a time, stopping at the first unreachable one",
         %{tag: tag} do
      Application.delete_env(:optimal_engine, :text_embedding)

      log =
        capture_log(fn ->
          assert [
                   {:error, :ollama_unavailable},
                   {:error, :ollama_unavailable},
                   {:error, :ollama_unavailable}
                 ] = Text.embed_many(["a #{tag}", "b #{tag}", "c #{tag}"], cache: false)
        end)

      # Ollama at OLLAMA_HOST is a closed port in tests: one call, not three.
      assert length(String.split(log, "Ollama HTTP POST /api/embed failed")) == 2
    end

    test "a tree's chunks are embedded one request each, and an unreachable one skips no other",
         %{tag: tag} do
      Application.delete_env(:optimal_engine, :text_embedding)
      tree = tree(tag, ~w(first second third))

      # Ollama at OLLAMA_HOST is a closed port in tests: every chunk is still tried.
      log =
        capture_log(fn ->
          assert {:ok, [], %{errors: [_, _, _]}} = Embedder.embed_tree(tree)
        end)

      assert length(String.split(log, "Ollama HTTP POST /api/embed failed")) == 4

      base = start_stub(fn _path, _body -> {200, %{"embeddings" => [[0.5, 0.25]]}} end)
      ollama = Application.get_env(:optimal_engine, :ollama, [])
      Application.put_env(:optimal_engine, :ollama, Keyword.put(ollama, :host, base))

      assert {:ok, [_, _, _], %{errors: []}} = Embedder.embed_tree(tree)

      for _chunk <- 1..3 do
        assert_received {:embed_request, "/api/embed", [], %{"input" => input}}
                        when is_binary(input)
      end

      refute_received {:embed_request, _, _, _}
    end

    test "text is embedded by Ollama at OLLAMA_HOST, without a key, as before", %{tag: tag} do
      base = start_stub(fn _path, _body -> {200, %{"embeddings" => [[0.5, 0.25]]}} end)
      ollama = Application.get_env(:optimal_engine, :ollama, [])
      Application.put_env(:optimal_engine, :ollama, Keyword.put(ollama, :host, base))
      Application.delete_env(:optimal_engine, :text_embedding)
      # The key only ever goes to OPTIMAL_EMBED_URL.
      System.put_env("OPTIMAL_EMBED_API_KEY", @key)

      refute Text.endpoint_configured?()
      assert {:ok, [0.5, 0.25]} = Text.embed("plain text #{tag}", cache: false)

      assert_received {:embed_request, "/api/embed", [],
                       %{"model" => "nomic-embed-text", "input" => "plain text " <> _}}

      # Only an unreachable Ollama stops a batch, as before.
      assert Text.unavailable?(:ollama_unavailable)
      refute Text.unavailable?({:http_error, 502})
    end
  end

  describe "OPTIMAL_EMBED_URL set" do
    test "an OpenAI-compatible endpoint gets the model, the input and the key as a bearer token",
         %{tag: tag} do
      base = start_stub(&openai_meaning/2)
      use_endpoint(base <> "/v1/embeddings")
      System.put_env("OPTIMAL_EMBED_API_KEY", @key)

      assert Text.endpoint_configured?()
      assert {:ok, [1.0, +0.0, +0.0, +0.0]} = Text.embed("hiring plan #{tag}", cache: false)

      assert_received {:embed_request, "/v1/embeddings", [@auth],
                       %{"model" => "nomic-embed-text", "input" => "hiring plan " <> _}}
    end

    test "the key can come from a file, read again on every request", %{tag: tag} do
      base = start_stub(&openai_meaning/2)
      file = Path.join(System.tmp_dir!(), "embed-key-#{tag}")
      File.write!(file, @key <> "\n")
      on_exit(fn -> File.rm(file) end)
      use_endpoint(base, api_key_file: file)

      assert {:ok, _} = Text.embed("first #{tag}", cache: false)
      assert_received {:embed_request, "/v1/embeddings", [@auth], _}

      File.write!(file, "rotated-test-key\n")
      assert {:ok, _} = Text.embed("second #{tag}", cache: false)
      assert_received {:embed_request, "/v1/embeddings", ["Bearer rotated-test-key"], _}
    end

    test "the dialect is inferred from the URL and the request path completed" do
      gateway = "https://gateway.example.com/v1/embeddings"

      assert Text.resolve("https://gateway.example.com", nil) == {:openai, gateway}
      assert Text.resolve("https://gateway.example.com/", nil) == {:openai, gateway}
      assert Text.resolve("https://gateway.example.com/v1", nil) == {:openai, gateway}
      assert Text.resolve(gateway, nil) == {:openai, gateway}

      assert Text.resolve("http://10.0.0.5:11434/api/embed", nil) ==
               {:ollama, "http://10.0.0.5:11434/api/embed"}

      assert Text.resolve("http://10.0.0.5:11434", :ollama) ==
               {:ollama, "http://10.0.0.5:11434/api/embed"}

      assert Text.resolve("http://10.0.0.5:11434", "openai") ==
               {:openai, "http://10.0.0.5:11434/v1/embeddings"}
    end

    test "Ollama's native dialect works at another host, with the key", %{tag: tag} do
      base = start_stub(fn _path, _body -> {200, %{"embeddings" => [[0.1, 0.2]]}} end)
      use_endpoint(base <> "/api/embed", dimensions: 2)
      System.put_env("OPTIMAL_EMBED_API_KEY", @key)

      assert {:ok, [0.1, 0.2]} = Text.embed("native #{tag}", cache: false)
      assert_received {:embed_request, "/api/embed", [@auth], %{"model" => "nomic-embed-text"}}
    end

    test "input over 6,000 characters is capped; blank input never calls the endpoint",
         %{tag: tag} do
      use_endpoint(start_stub(&openai_meaning/2))

      assert {:ok, _} = Text.embed(tag <> String.duplicate("a", 7_000), cache: false)
      assert_received {:embed_request, _path, _auth, %{"input" => sent}}
      assert String.length(sent) == Text.max_chars()
      assert Text.max_chars() == 6_000

      assert {:error, :empty_input} = Text.embed("  \n")
      refute_received {:embed_request, _, _, _}
    end

    test "an identical model and input is served from the filesystem cache", %{tag: tag} do
      use_endpoint(start_stub(&openai_meaning/2))

      assert {:ok, vector} = Text.embed("cached #{tag}")
      assert {:ok, ^vector} = Text.embed("cached #{tag}")
      assert_received {:embed_request, _, _, _}
      refute_received {:embed_request, _, _, _}
    end

    test "a refused key is a clear error, never cached and never logged", %{tag: tag} do
      System.put_env("OPTIMAL_EMBED_API_KEY", @key)

      for status <- [401, 403] do
        base =
          start_stub(fn _path, _body ->
            {status,
             %{
               "error" => %{
                 "message" => "Invalid API key " <> @key,
                 "type" => "authentication_error",
                 "code" => "invalid_api_key"
               }
             }}
          end)

        use_endpoint(base)

        log =
          capture_log(fn ->
            assert {:error, {:embed_unauthorized, ^status}} = Text.embed("refused #{tag}")
            assert {:error, {:embed_unauthorized, ^status}} = Text.embed("refused #{tag}")
          end)

        # Not cached: the second call went to the endpoint again.
        assert_received {:embed_request, _, [@auth], _}
        assert_received {:embed_request, _, [@auth], _}

        assert log =~ "refused the API key (HTTP #{status}: invalid_api_key)"
        assert log =~ "OPTIMAL_EMBED_API_KEY"
        refute log =~ @key
        refute log =~ "refused #{tag}"
        assert Text.unavailable?({:embed_unauthorized, status})

        # The refusal already marked the endpoint unhealthy here: no probe is sent.
        refute Text.healthy?()
        refute_received {:embed_request, _, _, %{"input" => "probe"}}

        # A process that has not seen it probes, and gets the same answer.
        capture_log(fn -> refute Task.await(Task.async(&Text.healthy?/0)) end)
        assert_received {:embed_request, _, [@auth], %{"input" => "probe"}}
      end

      health = capture_log(fn -> send(self(), {:health, OptimalEngine.Health.ready()}) end)
      assert_received {:health, %{checks: %{embedder: {:warn, {:embedder_unauthorized, 403}}}}}
      refute health =~ @key
    end

    test "no answer, no vector or a bad key file are errors, not empty embeddings", %{tag: tag} do
      use_endpoint("http://127.0.0.1:9/v1/embeddings")

      capture_log(fn ->
        assert {:error, :embed_endpoint_unavailable} = Text.embed("down #{tag}", cache: false)
      end)

      assert Text.unavailable?(:embed_endpoint_unavailable)

      use_endpoint(start_stub(fn _path, _body -> {200, %{"data" => []}} end))

      capture_log(fn ->
        assert {:error, :unexpected_response} = Text.embed("empty #{tag}", cache: false)
      end)

      use_endpoint(start_stub(&openai_meaning/2), api_key_file: "/nonexistent/embed-key-#{tag}")

      capture_log(fn ->
        assert {:error, {:embed_api_key, :enoent}} = Text.embed("no key #{tag}", cache: false)
      end)

      refute_received {:embed_request, "/v1/embeddings", _, %{"input" => "no key " <> _}}

      # A bearer key is visible ASCII: a space or a non-ASCII letter never reaches a header.
      use_endpoint(start_stub(&openai_meaning/2))

      for key <- ["two words", "cl\u00E9-#{tag}", "tab\tkey"] do
        System.put_env("OPTIMAL_EMBED_API_KEY", key)

        capture_log(fn ->
          assert {:error, {:embed_api_key, :invalid}} = Text.embed("bad key #{tag}", cache: false)
        end)
      end

      refute_received {:embed_request, _, _, %{"input" => "bad key " <> _}}
    end

    test "many texts go out in one request, in order, without the cached or blank ones",
         %{tag: tag} do
      use_endpoint(start_stub(&openai_meaning/2))
      assert {:ok, cached} = Text.embed("cached plant #{tag}")
      assert_received {:embed_request, _, _, %{"input" => "cached plant " <> _}}

      texts = ["hiring a #{tag}", "cached plant #{tag}", "  ", "plant b #{tag}", "hiring a #{tag}"]
      hiring = [1.0, +0.0, +0.0, +0.0]
      plant = [+0.0, 1.0, +0.0, +0.0]

      assert [
               {:ok, ^hiring},
               {:ok, ^cached},
               {:error, :empty_input},
               {:ok, ^plant},
               {:ok, ^hiring}
             ] = Text.embed_many(texts)

      assert_received {:embed_request, "/v1/embeddings", _, %{"input" => sent}}
      assert sent == ["hiring a #{tag}", "plant b #{tag}"]
      refute_received {:embed_request, _, _, _}

      # Now cached: no request at all.
      assert [{:ok, ^hiring}, {:ok, ^plant}] =
               Text.embed_many(["hiring a #{tag}", "plant b #{tag}"])

      refute_received {:embed_request, _, _, _}
      assert Text.embed_many([]) == []
    end

    test "a large batch is split, and a refused batch gives every text the error", %{tag: tag} do
      use_endpoint(start_stub(&openai_meaning/2))
      texts = for n <- 1..70, do: "note #{n} #{tag}"

      results = Text.embed_many(texts, cache: false)
      assert length(results) == 70 and Enum.all?(results, &match?({:ok, [_, _, _, _]}, &1))
      assert_received {:embed_request, _, _, %{"input" => first}}
      assert_received {:embed_request, _, _, %{"input" => second}}
      assert {length(first), length(second)} == {64, 6}
      assert first ++ second == texts

      use_endpoint(start_stub(fn _path, _body -> {401, %{"error" => %{"code" => "x"}}} end))

      capture_log(fn ->
        assert [{:error, {:embed_unauthorized, 401}}, {:error, {:embed_unauthorized, 401}}] =
                 Text.embed_many(["a #{tag}", "b #{tag}"], cache: false)
      end)
    end

    test "a tree's chunks go out in one request, governed as one call without the text",
         %{tag: tag} do
      use_endpoint(start_stub(&openai_meaning/2))
      workspace = "embed-governed-#{tag}"
      words = ~w(first second third)

      assert {:ok, [_, _, _], %{errors: []}} =
               Embedder.embed_tree(tree(tag, words), workspace_id: workspace)

      assert_received {:embed_request, _, _, %{"input" => [_, _, _]}}
      refute_received {:embed_request, _, _, _}

      assert [[input, output, metadata]] = model_runs(workspace, "embedder.embed_text_batch")
      chars = words |> Enum.map(&String.length("#{&1} chunk #{tag}")) |> Enum.sum()
      assert Jason.decode!(input) == %{"inputs" => 3, "chars" => chars}
      refute input =~ "chunk"

      assert %{"ok" => true, "embedded" => 3, "failed" => 0, "result_kind" => "vectors"} =
               Jason.decode!(output)

      assert %{"provider" => "embedding_endpoint", "call_status" => "completed"} =
               Jason.decode!(metadata)

      # The chunks were governed with the batch, not one row each.
      assert model_runs(workspace, "embedder.embed_text") == []

      # A refused batch is one failed call.
      use_endpoint(start_stub(fn _path, _body -> {502, %{"error" => %{"code" => "down"}}} end))

      capture_log(fn ->
        assert {:ok, [], %{errors: [_, _]}} =
                 Embedder.embed_tree(tree("down-#{tag}", ~w(one two)), workspace_id: workspace)
      end)

      assert [[_input, output, metadata] | _] = model_runs(workspace, "embedder.embed_text_batch")
      assert %{"ok" => false, "embedded" => 0, "failed" => 2} = Jason.decode!(output)
      assert %{"call_status" => "failed"} = Jason.decode!(metadata)
    end

    test "a cached vector of another width than the model now needs is fetched again",
         %{tag: tag} do
      {:ok, width} = Agent.start_link(fn -> 4 end)

      url =
        start_stub(fn _path, %{"input" => input} ->
          w = Agent.get(width, & &1)

          data =
            input
            |> List.wrap()
            |> Enum.with_index()
            |> Enum.map(fn {_text, index} ->
              %{"index" => index, "embedding" => List.duplicate(0.5, w)}
            end)

          {200, %{"data" => data}}
        end)

      use_endpoint(url, dimensions: 4)
      assert {:ok, [_, _, _, _]} = Text.embed("width #{tag}")
      assert_received {:embed_request, _, _, _}
      assert [{:ok, [_, _, _, _]}] = Text.embed_many(["width #{tag}"])
      refute_received {:embed_request, _, _, _}

      # The width setting changes: the stored vector no longer fits, so it is fetched again.
      Agent.update(width, fn _ -> 2 end)
      use_endpoint(url, dimensions: 2)
      assert [{:ok, [_, _]}] = Text.embed_many(["width #{tag}"])
      assert_received {:embed_request, _, _, %{"input" => ["width " <> _]}}
      assert {:ok, [_, _]} = Text.embed("width #{tag}")
      refute_received {:embed_request, _, _, _}
    end

    test "a batch answered 429 waits as asked and is retried once; a single embedding is not",
         %{tag: tag} do
      {:ok, answers} = Agent.start_link(fn -> [] end)

      use_endpoint(
        start_stub(fn path, body ->
          case Agent.get_and_update(answers, fn
                 [next | rest] -> {next, rest}
                 [] -> {:meaning, []}
               end) do
            :meaning ->
              openai_meaning(path, body)

            {:limited, wait} ->
              {429, %{"error" => %{"code" => "rate_limited"}}, [{"retry-after", wait}]}
          end
        end)
      )

      Agent.update(answers, fn _ -> [{:limited, "1"}] end)

      {elapsed, _log} =
        :timer.tc(
          fn ->
            capture_log(fn ->
              send(self(), {:results, Text.embed_many(["a #{tag}", "b #{tag}"])})
            end)
          end,
          :millisecond
        )

      assert_received {:results, [{:ok, _}, {:ok, _}]}
      assert elapsed >= 1_000
      assert_received {:embed_request, _, _, %{"input" => [_, _]}}
      assert_received {:embed_request, _, _, %{"input" => [_, _]}}

      # Once only, and never for a wait over a minute or a single embedding.
      for limited <- [[{:limited, "0"}, {:limited, "0"}], [{:limited, "61"}]] do
        Agent.update(answers, fn _ -> limited end)

        capture_log(fn ->
          assert [{:error, {:embed_unavailable, 429}}] =
                   Text.embed_many(["again #{tag} #{length(limited)}"], cache: false)
        end)
      end

      Agent.update(answers, fn _ -> [{:limited, "1"}] end)

      {elapsed, _log} =
        :timer.tc(
          fn ->
            capture_log(fn ->
              assert {:error, {:embed_unavailable, 429}} = Text.embed("query #{tag}", cache: false)
            end)
          end,
          :millisecond
        )

      assert elapsed < 1_000
    end

    test "the unhealthy mark lasts the health window, and a success clears it", %{tag: tag} do
      {:ok, mode} = Agent.start_link(fn -> :down end)

      url =
        start_stub(fn path, body ->
          case Agent.get(mode, & &1) do
            :up -> openai_meaning(path, body)
            :down -> {502, %{"error" => %{"code" => "embedding_backend_unavailable"}}}
          end
        end)

      use_endpoint(url, health_ttl_ms: 200)

      capture_log(fn ->
        assert {:error, {:embed_unavailable, 502}} = Text.embed("first #{tag}", cache: false)
      end)

      refute Text.healthy?()
      assert_received {:embed_request, _, _, %{"input" => "first " <> _}}
      refute_received {:embed_request, _, _, _}

      # The endpoint recovers: after the window the next question probes again.
      Agent.update(mode, fn _ -> :up end)
      Process.sleep(250)
      assert Text.healthy?()
      assert_received {:embed_request, _, _, %{"input" => "probe"}}

      # Down again, then a successful embedding: healthy at once, without a probe.
      Agent.update(mode, fn _ -> :down end)

      capture_log(fn ->
        assert {:error, {:embed_unavailable, 502}} = Text.embed("second #{tag}", cache: false)
      end)

      refute Text.healthy?()
      Agent.update(mode, fn _ -> :up end)
      assert {:ok, _vector} = Text.embed("third #{tag}", cache: false)
      assert Text.healthy?()
      assert_received {:embed_request, _, _, %{"input" => "second " <> _}}
      assert_received {:embed_request, _, _, %{"input" => "third " <> _}}
      refute_received {:embed_request, _, _, _}
    end

    test "an endpoint never serves Ollama's cached vectors, nor Ollama the endpoint's",
         %{tag: tag} do
      ollama_stub =
        start_stub(fn _path, _body -> {200, %{"embeddings" => [[0.5, 0.5, 0.5, 0.5]]}} end)

      ollama = Application.get_env(:optimal_engine, :ollama, [])
      Application.put_env(:optimal_engine, :ollama, Keyword.put(ollama, :host, ollama_stub))
      endpoint_stub = start_stub(&openai_meaning/2)
      from_ollama = [0.5, 0.5, 0.5, 0.5]
      from_endpoint = [+0.0, 1.0, +0.0, +0.0]

      # Ollama first: today's key, and the endpoint still asks its own server.
      Application.delete_env(:optimal_engine, :text_embedding)
      assert {:ok, ^from_ollama} = Text.embed("shared #{tag}")
      assert_received {:embed_request, "/api/embed", _, _}
      assert {:ok, ^from_ollama} = FileCache.get("embeddings", "nomic-embed-text\0shared #{tag}")

      use_endpoint(endpoint_stub)
      assert {:ok, ^from_endpoint} = Text.embed("shared #{tag}")
      assert_received {:embed_request, "/v1/embeddings", _, _}
      assert {:ok, ^from_endpoint} = Text.embed("shared #{tag}")
      refute_received {:embed_request, _, _, _}

      # The endpoint first: Ollama still asks Ollama.
      assert {:ok, ^from_endpoint} = Text.embed("endpoint first #{tag}")
      assert_received {:embed_request, "/v1/embeddings", _, _}
      Application.delete_env(:optimal_engine, :text_embedding)
      assert {:ok, ^from_ollama} = Text.embed("endpoint first #{tag}")
      assert_received {:embed_request, "/api/embed", _, _}
    end

    test "vectors of another width are refused, never cached, and stop a batch", %{tag: tag} do
      use_endpoint(start_stub(&openai_meaning/2), dimensions: nil)

      log =
        capture_log(fn ->
          assert {:error, {:embed_dimension_mismatch, 4, 768}} = Text.embed("width #{tag}")
          assert {:error, {:embed_dimension_mismatch, 4, 768}} = Text.embed("width #{tag}")
        end)

      assert_received {:embed_request, _, _, _}
      assert_received {:embed_request, _, _, _}
      assert log =~ "answered 4-dimension vectors; the model needs 768"
      refute log =~ "width #{tag}"
      assert Text.unavailable?({:embed_dimension_mismatch, 4, 768})

      texts = for n <- 1..70, do: "wide #{n} #{tag}"

      capture_log(fn ->
        results = Text.embed_many(texts, cache: false)
        assert Enum.uniq(results) == [{:error, {:embed_dimension_mismatch, 4, 768}}]
      end)

      # The first batch is refused; the second is not sent.
      assert_received {:embed_request, _, _, %{"input" => [_ | _]}}
      refute_received {:embed_request, _, _, _}

      use_endpoint(start_stub(&openai_meaning/2), dimensions: nil)
      Application.put_env(:optimal_engine, :ollama, embed_model: "another-model")
      assert {:ok, [_, _, _, _]} = Text.embed("other model #{tag}", cache: false)
    end

    test "an endpoint that accepts and never answers is unavailable within the timeouts",
         %{tag: tag} do
      use_endpoint(start_silent_listener(), timeout_ms: 300, probe_timeout_ms: 200)

      {elapsed, _log} =
        :timer.tc(
          fn -> capture_log(fn -> send(self(), Text.embed("hung #{tag}")) end) end,
          :millisecond
        )

      assert_received {:error, :embed_endpoint_unavailable}
      assert elapsed < 2_000

      # A fresh process probes, within the probe budget.
      {probe_ms, healthy} =
        Task.async(fn -> :timer.tc(fn -> Text.healthy?() end, :millisecond) end) |> Task.await()

      refute healthy
      assert probe_ms < 1_000

      # This process saw the failure: no new probe, an immediate no.
      {again_ms, healthy_again} = :timer.tc(fn -> Text.healthy?() end, :millisecond)
      refute healthy_again
      assert again_ms < 100

      # One connection for the embedding, one for the fresh process's probe.
      assert_receive :silent_connection, 1_000
      assert_receive :silent_connection, 1_000
      refute_received :silent_connection

      root = Path.join(System.tmp_dir!(), "embed_hung_root_#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)
      on_exit(fn -> File.rm_rf!(root) end)
      Application.put_env(:optimal_engine, :root_path, root)
      Application.put_env(:optimal_engine, :semantic_processing, enabled: true)
      Application.put_env(:optimal_engine, :embed, on_ingest: true)

      capture_log(fn ->
        send(
          self(),
          Intake.process(
            "Hung endpoint #{tag}: the first note. The second note. The third note.",
            workspace_id: "embed-hung-#{tag}",
            write_files: false,
            source_id: "embed-hung:#{tag}"
          )
        )

        # Chunks and the document are embedded after intake returns: one connection
        # for the chunks' batch and one for the document, each given up after the
        # timeout, never one per chunk.
        assert_receive :silent_connection, 5_000
        assert_receive :silent_connection, 5_000
        refute_receive :silent_connection, 1_500
      end)

      assert_received {:ok, %{context: %{id: _}}}
    end

    test "a failed query embedding marks the endpoint unhealthy for the probe window",
         %{tag: tag} do
      {:ok, mode} = Agent.start_link(fn -> :up end)

      use_endpoint(
        start_stub(fn path, body ->
          case Agent.get(mode, & &1) do
            :up -> openai_meaning(path, body)
            :down -> {502, %{"error" => %{"code" => "embedding_backend_unavailable"}}}
          end
        end)
      )

      assert Text.healthy?()
      assert_received {:embed_request, _, _, %{"input" => "probe"}}

      Agent.update(mode, fn _ -> :down end)

      capture_log(fn ->
        assert {:error, {:embed_unavailable, 502}} = Text.embed("query #{tag}", cache: false)
      end)

      refute Text.healthy?()
      assert_received {:embed_request, _, _, %{"input" => "query " <> _}}
      refute_received {:embed_request, _, _, %{"input" => "probe"}}
    end

    test "invalid UTF-8 is replaced instead of failing with the text in an error", %{tag: tag} do
      use_endpoint(start_stub(&openai_meaning/2))
      assert {:ok, _} = Text.embed("hiring " <> tag <> <<0xFF>>, cache: false)
      assert_received {:embed_request, _, _, %{"input" => sent}}
      assert sent == "hiring #{tag}\uFFFD"
    end

    test "a key bound for plain http on another machine is warned about once, without it" do
      refute Endpoint.plain_http_remote?("https://gateway.example.com/v1/embeddings")
      refute Endpoint.plain_http_remote?("http://127.0.0.1:8089/v1/embeddings")
      refute Endpoint.plain_http_remote?("http://localhost:8089/v1/embeddings")
      assert Endpoint.plain_http_remote?("http://10.0.0.5:8089/v1/embeddings")

      url = "http://10.0.0.5:8089/v1/embeddings-#{System.unique_integer([:positive])}"

      log =
        capture_log(fn ->
          Endpoint.warn_plain_http(url, true)
          Endpoint.warn_plain_http(url, true)
        end)

      assert length(String.split(log, "over plain http")) == 2
      assert capture_log(fn -> Endpoint.warn_plain_http(url <> "-nokey", false) end) == ""
    end

    test "the key never enters the application environment or a logged URL" do
      System.put_env("OPTIMAL_EMBED_API_KEY", @key)
      use_endpoint("https://gateway.example.com")

      refute inspect(Application.get_all_env(:optimal_engine)) =~ @key
      refute inspect(Text.endpoint()) =~ @key

      assert Endpoint.safe_url("https://user:secret@gateway.example.com/v1/embeddings?k=v") ==
               "https://gateway.example.com/v1/embeddings"
    end
  end

  describe "an endpoint whose backend is down" do
    setup %{tag: tag} do
      System.put_env("OPTIMAL_EMBED_API_KEY", @key)

      use_endpoint(
        start_stub(fn _path, _body ->
          {502,
           %{
             "error" => %{
               "message" => "The embedding backend is unavailable.",
               "type" => "server_error",
               "code" => "embedding_backend_unavailable"
             }
           }}
        end)
      )

      %{workspace: "embed-down-#{tag}"}
    end

    test "capture and intake never fail; search falls back to full text; batches stop",
         %{workspace: workspace, tag: tag} do
      root = Path.join(System.tmp_dir!(), "embed_down_root_#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)
      on_exit(fn -> File.rm_rf!(root) end)
      Application.put_env(:optimal_engine, :root_path, root)
      Application.put_env(:optimal_engine, :semantic_processing, enabled: true)
      Application.put_env(:optimal_engine, :embed, on_ingest: true)
      hybrid = Application.get_env(:optimal_engine, :hybrid_search, [])
      vectors_on = Keyword.put(hybrid, :vector_enabled, true)
      Application.put_env(:optimal_engine, :hybrid_search, vectors_on)
      text = "Pricing review #{tag}: two plans stay, the renewal moves to Thursday."

      log =
        capture_log(fn ->
          assert {:ok, result} =
                   Intake.process(text,
                     workspace_id: workspace,
                     write_files: false,
                     source_id: "embed-down:#{workspace}"
                   )

          send(self(), {:context, result.context.id})
          # The chunks went out as one batch during intake; the document's
          # embedding is attempted after intake returns.
          assert_receive {:embed_request, _, [@auth], %{"input" => [_ | _] = chunks}}, 5_000
          assert Enum.any?(chunks, &(&1 =~ "Pricing review"))

          assert_receive {:embed_request, _, [@auth], %{"input" => document}}
                         when is_binary(document),
                         5_000

          assert document =~ "Pricing review"
          Process.sleep(200)

          assert {:ok, hits} = Search.search("pricing review #{tag}", workspace_id: workspace)
          send(self(), {:hits, hits})

          assert {:error, {:embedder_unavailable, {:embed_unavailable, 502}}} =
                   Backfill.run(workspace_id: workspace)

          assert %{checks: %{embedder: {:warn, {:embedder_unavailable, 502}}}} =
                   OptimalEngine.Health.ready()
        end)

      assert_received {:context, id}
      assert_received {:hits, hits}
      assert vector_dimensions(id) == nil
      assert Enum.any?(hits, &(&1.id == id))
      assert Text.unavailable?({:embed_unavailable, 502})

      assert log =~ "answered HTTP 502: embedding_backend_unavailable"
      refute log =~ @key

      # No embedding log line carries the text it was asked to embed.
      embedding_lines =
        log |> String.split("\n") |> Enum.filter(&(&1 =~ ~r/\[Embed\]|embedding|Embedder/i))

      assert embedding_lines != []
      refute Enum.any?(embedding_lines, &(&1 =~ "two plans stay"))
    end
  end

  describe "every text embedding uses the endpoint" do
    setup %{tag: tag} do
      System.put_env("OPTIMAL_EMBED_API_KEY", @key)
      use_endpoint(start_stub(&openai_meaning/2))
      %{workspace: "embed-text-#{tag}"}
    end

    test "an ingested document is embedded through the endpoint and found by meaning",
         %{workspace: workspace, tag: tag} do
      root = Path.join(System.tmp_dir!(), "embed_text_root_#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)
      on_exit(fn -> File.rm_rf!(root) end)
      Application.put_env(:optimal_engine, :root_path, root)
      Application.put_env(:optimal_engine, :semantic_processing, enabled: true)

      hybrid = Application.get_env(:optimal_engine, :hybrid_search, [])
      vectors_on = Keyword.put(hybrid, :vector_enabled, true)
      Application.put_env(:optimal_engine, :hybrid_search, vectors_on)

      # No local model: Ollama at OLLAMA_HOST is a closed port in tests, so the
      # document vector can only come from the endpoint.
      {:ok, result} =
        Intake.process("Quarterly hiring plan #{tag}: two platform engineers by March.",
          workspace_id: workspace,
          write_files: false,
          source_id: "embed-text:#{workspace}"
        )

      id = result.context.id
      assert eventually(fn -> vector_dimensions(id) == 4 end)
      assert_received {:embed_request, "/v1/embeddings", [@auth], %{"input" => input}}
      assert input =~ "Quarterly hiring plan #{tag}"

      # No word of the query is in the document; only the vectors connect them.
      query = "who are we recruiting #{tag}"
      assert {:ok, hits} = Search.search(query, workspace_id: workspace)
      assert Enum.any?(hits, &(&1.id == id))
      assert_received {:embed_request, "/v1/embeddings", [@auth], %{"input" => ^query}}
    end

    test "backfill embeds through the endpoint, and a vector of another dimension is never scored",
         %{workspace: workspace, tag: tag} do
      hiring = document!(workspace, "hiring-#{tag}", "Hiring plan for the platform team")
      rota = document!(workspace, "rota-#{tag}", "Office plant watering rota")
      other = document!(workspace, "other-#{tag}", "Candidate pipeline review")
      :ok = Vectors.store(other, [1.0, 0.0, 0.0])

      assert {:ok, %{embedded: 2, failed: 0, remaining: 0}} =
               Backfill.run(workspace_id: workspace)

      # One request for the page, not one per document.
      assert_received {:embed_request, "/v1/embeddings", [@auth], %{"input" => [_, _] = sent}}
      assert Enum.any?(sent, &(&1 =~ "Hiring plan")) and Enum.any?(sent, &(&1 =~ "watering"))
      refute_received {:embed_request, _, _, _}

      assert vector_dimensions(hiring) == 4
      assert vector_dimensions(rota) == 4

      {:ok, query} = Text.embed("recruiting #{tag}", cache: false)
      assert {:ok, hits} = Vectors.search(query, workspace_id: workspace, min_similarity: 0.1)
      assert Enum.map(hits, &elem(&1, 0)) == [hiring]
    end

    test "a refused key stops a backfill instead of failing every document",
         %{workspace: workspace, tag: tag} do
      use_endpoint(start_stub(fn _path, _body -> {401, %{"error" => %{"code" => "x"}}} end))
      document!(workspace, "a-#{tag}", "First note")
      document!(workspace, "b-#{tag}", "Second note")

      capture_log(fn ->
        assert {:error, {:embedder_unavailable, {:embed_unauthorized, 401}}} =
                 Backfill.run(workspace_id: workspace)
      end)

      assert_received {:embed_request, _, _, _}
      refute_received {:embed_request, _, _, _}
      assert {:ok, %{missing: 2}} = Backfill.status(workspace_id: workspace)
    end

    test "chunks, durable memory queries and app data embed through the endpoint", %{tag: tag} do
      chunk = Chunk.new(id: "chunk-#{tag}", modality: :text, text: "hiring chunk #{tag}")
      assert {:ok, %{vector: [1.0, +0.0, +0.0, +0.0], dim: 4}} = Embedder.embed(chunk)
      assert_received {:embed_request, "/v1/embeddings", [@auth], %{"input" => "hiring " <> _}}

      assert {:ok, [_, _, _, _]} = MemoryEmbeddings.embed_query("memory query #{tag}")
      assert_received {:embed_request, "/v1/embeddings", [@auth], %{"input" => "memory " <> _}}

      assert OptimalEngine.AppData.Semantic.config().embedder == Text
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Accepts connections and never answers; reports each one to the test.
  defp start_silent_listener do
    parent = self()

    holder =
      spawn(fn ->
        {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
        {:ok, port} = :inet.port(listen)
        send(parent, {:silent_port, port})
        hold(listen, [], parent)
      end)

    on_exit(fn -> Process.exit(holder, :kill) end)
    assert_receive {:silent_port, port}, 1_000
    "http://127.0.0.1:#{port}"
  end

  defp hold(listen, held, parent) do
    {:ok, socket} = :gen_tcp.accept(listen)
    send(parent, :silent_connection)
    hold(listen, [socket | held], parent)
  end

  defp start_stub(respond) do
    ref = :"#{__MODULE__}.Stub#{System.unique_integer([:positive])}"
    {:ok, _pid} = Plug.Cowboy.http(Stub, [test: self(), respond: respond], port: 0, ref: ref)
    on_exit(fn -> Plug.Cowboy.shutdown(ref) end)
    "http://127.0.0.1:#{:ranch.get_port(ref)}"
  end

  # The stubs answer in a four-dimension space, so the width check is told so;
  # a test that wants the model's own width passes `dimensions: nil`.
  defp use_endpoint(url, extra \\ []) do
    config = Keyword.merge([url: url, dimensions: 4], extra)
    Application.put_env(:optimal_engine, :text_embedding, config)
  end

  # A four-dimension space: anything about hiring points one way, the rest another.
  # A batch is answered in reverse order with its indexes, as an endpoint may.
  defp openai_meaning(_path, %{"input" => input}) do
    data =
      input
      |> List.wrap()
      |> Enum.with_index()
      |> Enum.map(fn {text, index} ->
        %{"object" => "embedding", "index" => index, "embedding" => meaning(text)}
      end)
      |> Enum.reverse()

    {200,
     %{
       "object" => "list",
       "data" => data,
       "model" => "nomic-embed-text",
       "usage" => %{"prompt_tokens" => 4, "total_tokens" => 4}
     }}
  end

  defp meaning(text) do
    if text =~ ~r/hiring|recruit/i, do: [1.0, 0.0, 0.0, 0.0], else: [0.0, 1.0, 0.0, 0.0]
  end

  defp document!(workspace, id, title) do
    {:ok, _} =
      Store.raw_query(
        "INSERT INTO contexts (id, tenant_id, workspace_id, type, title, content, created_at) VALUES (?1, 'default', ?2, 'signal', ?3, ?4, datetime('now'))",
        [id, workspace, title, "Body of #{title}."]
      )

    id
  end

  defp tree(tag, words) do
    chunks =
      for word <- words do
        Chunk.new(id: "chunk-#{word}-#{tag}", modality: :text, text: "#{word} chunk #{tag}")
      end

    %ChunkTree{chunks: chunks}
  end

  defp model_runs(workspace, function_name) do
    {:ok, rows} =
      Store.raw_query(
        """
        SELECT input_payload, output_payload, metadata FROM model_call_runs
        WHERE workspace_id = ?1 AND function_name = ?2 ORDER BY rowid DESC
        """,
        [workspace, function_name]
      )

    rows
  end

  defp vector_dimensions(id) do
    case Store.raw_query("SELECT dimensions FROM vectors WHERE context_id = ?1", [id]) do
      {:ok, [[dimensions]]} -> dimensions
      _ -> nil
    end
  end

  defp eventually(fun, attempts \\ 50) do
    cond do
      fun.() -> true
      attempts == 0 -> false
      true -> Process.sleep(100) && eventually(fun, attempts - 1)
    end
  end
end
