defmodule OptimalEngine.RuntimeConfigTest do
  use ExUnit.Case, async: false

  @runtime_env %{
    "OPTIMAL_AUTH_REQUIRED" => "true",
    "OPTIMAL_ENGINE_ROOT" => "/tmp/optimal-runtime/workspaces",
    "OPTIMAL_ENGINE_DB" => "/tmp/optimal-runtime/index.db",
    "OPTIMAL_ENGINE_CACHE" => "/tmp/optimal-runtime/cache",
    "OPTIMAL_ENGINE_TOPOLOGY" => "/tmp/optimal-runtime/config.yaml",
    "OPTIMAL_ENGINE_TOPOLOGY_FULL" => "/tmp/optimal-runtime/topology.yaml",
    "OPTIMAL_KNOWLEDGE_BACKEND" => "rocksdb",
    "OPTIMAL_KNOWLEDGE_ROCKSDB_PATH" => "/tmp/optimal-runtime/knowledge-rocksdb",
    "OLLAMA_HOST" => "http://127.0.0.1:21434"
  }

  setup do
    original_auth = Application.get_env(:optimal_engine, :auth, [])
    on_exit(fn -> Application.put_env(:optimal_engine, :auth, original_auth) end)
    original = Map.new(@runtime_env, fn {name, _value} -> {name, System.get_env(name)} end)
    Enum.each(@runtime_env, fn {name, value} -> System.put_env(name, value) end)

    on_exit(fn ->
      Enum.each(original, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)
  end

  test "release runtime reads per-user storage, graph, and model paths from the environment" do
    config = Config.Reader.read!("config/runtime.exs", env: :prod, target: :host)
    engine = Keyword.fetch!(config, :optimal_engine)

    assert engine[:root_path] == @runtime_env["OPTIMAL_ENGINE_ROOT"]
    assert engine[:db_path] == @runtime_env["OPTIMAL_ENGINE_DB"]
    assert engine[:cache_path] == @runtime_env["OPTIMAL_ENGINE_CACHE"]
    assert engine[:topology_path] == @runtime_env["OPTIMAL_ENGINE_TOPOLOGY"]
    assert engine[:topology_full_path] == @runtime_env["OPTIMAL_ENGINE_TOPOLOGY_FULL"]
    assert engine[:knowledge][:backend] == "rocksdb"

    assert engine[:knowledge][:rocksdb_path] ==
             @runtime_env["OPTIMAL_KNOWLEDGE_ROCKSDB_PATH"]

    assert engine[:ollama][:host] == @runtime_env["OLLAMA_HOST"]
  end

  test "runtime preserves environment-specific config when overrides are absent" do
    Enum.each(@runtime_env, fn {name, _value} -> System.delete_env(name) end)

    expected = %{
      root_path: Application.fetch_env!(:optimal_engine, :root_path),
      db_path: Application.fetch_env!(:optimal_engine, :db_path),
      cache_path: Application.fetch_env!(:optimal_engine, :cache_path),
      topology_path: Application.fetch_env!(:optimal_engine, :topology_path),
      topology_full_path: Application.fetch_env!(:optimal_engine, :topology_full_path)
    }

    config = Config.Reader.read!("config/runtime.exs", env: :test, target: :host)
    engine = Keyword.fetch!(config, :optimal_engine)

    Enum.each(expected, fn {key, value} -> assert engine[key] == value end)
  end

  test "environment enables HTTP authentication without losing existing auth settings" do
    Application.put_env(:optimal_engine, :auth, auth_required: false, bcrypt_cost: 4)
    config = Config.Reader.read!("config/runtime.exs", env: :prod, target: :host)
    auth = get_in(config, [:optimal_engine, :auth])
    assert auth[:auth_required] == true
    assert auth[:bcrypt_cost] == 4
    Application.put_env(:optimal_engine, :auth, auth)

    response =
      Plug.Test.conn(:get, "/api/workspaces")
      |> OptimalEngine.API.Router.call(OptimalEngine.API.Router.init([]))

    assert response.status == 401
    assert Jason.decode!(response.resp_body)["error"] == "missing_api_key"
  end

  test "explicit false selects trusted local mode and absence preserves configured auth" do
    Application.put_env(:optimal_engine, :auth, auth_required: true, bcrypt_cost: 4)
    System.put_env("OPTIMAL_AUTH_REQUIRED", "false")
    config = Config.Reader.read!("config/runtime.exs", env: :prod, target: :host)
    assert get_in(config, [:optimal_engine, :auth, :auth_required]) == false
    System.delete_env("OPTIMAL_AUTH_REQUIRED")
    config = Config.Reader.read!("config/runtime.exs", env: :prod, target: :host)
    assert get_in(config, [:optimal_engine, :auth, :auth_required]) == true
  end

  test "the open-network refusal is read from the environment and rejects other values" do
    original = System.get_env("OPTIMAL_REFUSE_OPEN_NETWORK")

    on_exit(fn ->
      if original,
        do: System.put_env("OPTIMAL_REFUSE_OPEN_NETWORK", original),
        else: System.delete_env("OPTIMAL_REFUSE_OPEN_NETWORK")
    end)

    for {value, expected} <- [{"1", true}, {"true", true}, {"0", false}, {"false", false}] do
      System.put_env("OPTIMAL_REFUSE_OPEN_NETWORK", value)
      config = Config.Reader.read!("config/runtime.exs", env: :prod, target: :host)
      assert get_in(config, [:optimal_engine, :refuse_open_network]) == expected
    end

    System.delete_env("OPTIMAL_REFUSE_OPEN_NETWORK")
    config = Config.Reader.read!("config/runtime.exs", env: :prod, target: :host)
    refute Keyword.has_key?(Keyword.fetch!(config, :optimal_engine), :refuse_open_network)

    System.put_env("OPTIMAL_REFUSE_OPEN_NETWORK", "yes")

    assert_raise ArgumentError, ~r/OPTIMAL_REFUSE_OPEN_NETWORK must be 1 or 0/, fn ->
      Config.Reader.read!("config/runtime.exs", env: :prod, target: :host)
    end
  end

  test "invalid authentication flags fail configuration rather than disabling protection" do
    for value <- ["", "TRUE", "1", "false ", "yes"] do
      System.put_env("OPTIMAL_AUTH_REQUIRED", value)

      assert_raise ArgumentError, ~r/OPTIMAL_AUTH_REQUIRED must be true or false/, fn ->
        Config.Reader.read!("config/runtime.exs", env: :prod, target: :host)
      end
    end
  end

  test "claim promotion mode comes from the environment, keeps the memory settings, and rejects typos" do
    original = System.get_env("OPTIMAL_CLAIM_PROMOTION_MODE")

    on_exit(fn ->
      if original,
        do: System.put_env("OPTIMAL_CLAIM_PROMOTION_MODE", original),
        else: System.delete_env("OPTIMAL_CLAIM_PROMOTION_MODE")
    end)

    System.put_env("OPTIMAL_CLAIM_PROMOTION_MODE", "manual")
    config = Config.Reader.read!("config/runtime.exs", env: :prod, target: :host)
    memory = get_in(config, [:optimal_engine, :memory])
    assert memory[:claim_promotion_mode] == :manual
    assert memory[:auto_extract_claims] == true

    System.delete_env("OPTIMAL_CLAIM_PROMOTION_MODE")
    config = Config.Reader.read!("config/runtime.exs", env: :prod, target: :host)
    refute Keyword.has_key?(get_in(config, [:optimal_engine, :memory]) || [], :claim_promotion_mode)

    System.put_env("OPTIMAL_CLAIM_PROMOTION_MODE", "auto")

    assert_raise ArgumentError,
                 ~r/OPTIMAL_CLAIM_PROMOTION_MODE must be auto_threshold, manual, or agent_review/,
                 fn -> Config.Reader.read!("config/runtime.exs", env: :prod, target: :host) end
  end

  test "release channel comes from the environment and rejects unknown channels" do
    original = System.get_env("OPTIMAL_RELEASE_CHANNEL")

    on_exit(fn ->
      if original do
        System.put_env("OPTIMAL_RELEASE_CHANNEL", original)
      else
        System.delete_env("OPTIMAL_RELEASE_CHANNEL")
      end
    end)

    System.put_env("OPTIMAL_RELEASE_CHANNEL", "beta")
    config = Config.Reader.read!("config/runtime.exs", env: :prod, target: :host)
    assert get_in(config, [:optimal_engine, :release_channel]) == "beta"

    System.delete_env("OPTIMAL_RELEASE_CHANNEL")
    config = Config.Reader.read!("config/runtime.exs", env: :prod, target: :host)
    assert get_in(config, [:optimal_engine])[:release_channel] == nil

    System.put_env("OPTIMAL_RELEASE_CHANNEL", "nightly")

    assert_raise ArgumentError,
                 ~r/OPTIMAL_RELEASE_CHANNEL must be dev, stable, beta, or pinned/,
                 fn -> Config.Reader.read!("config/runtime.exs", env: :prod, target: :host) end
  end

  test "an embedding endpoint comes from the environment, keeps its key out of the config, and rejects typos" do
    names = [
      "OPTIMAL_EMBED_URL",
      "OPTIMAL_EMBED_DIALECT",
      "OPTIMAL_EMBED_API_KEY",
      "OPTIMAL_EMBED_API_KEY_FILE",
      "OPTIMAL_EMBED_DIMENSIONS"
    ]

    original = Map.new(names, &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(original, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    Enum.each(names, &System.delete_env/1)
    config = Config.Reader.read!("config/runtime.exs", env: :prod, target: :host)
    assert get_in(config, [:optimal_engine, :text_embedding, :url]) == nil

    System.put_env("OPTIMAL_EMBED_URL", "https://gateway.example.com/v1/embeddings")
    System.put_env("OPTIMAL_EMBED_DIALECT", "openai")
    System.put_env("OPTIMAL_EMBED_API_KEY", "runtime-test-key-0123456789")
    System.put_env("OPTIMAL_EMBED_API_KEY_FILE", "/run/secrets/embed-key")
    System.put_env("OPTIMAL_EMBED_DIMENSIONS", "1024")
    config = Config.Reader.read!("config/runtime.exs", env: :prod, target: :host)
    embedding = get_in(config, [:optimal_engine, :text_embedding])

    assert embedding[:url] == "https://gateway.example.com/v1/embeddings"
    assert embedding[:dialect] == :openai
    assert embedding[:api_key_file] == "/run/secrets/embed-key"
    assert embedding[:dimensions] == 1024
    refute inspect(config) =~ "runtime-test-key-0123456789"

    System.put_env("OPTIMAL_EMBED_DIMENSIONS", "768d")

    assert_raise ArgumentError, ~r/OPTIMAL_EMBED_DIMENSIONS must be a positive whole number/, fn ->
      Config.Reader.read!("config/runtime.exs", env: :prod, target: :host)
    end

    System.delete_env("OPTIMAL_EMBED_DIMENSIONS")
    System.put_env("OPTIMAL_EMBED_URL", "")
    System.put_env("OPTIMAL_EMBED_DIALECT", "")
    config = Config.Reader.read!("config/runtime.exs", env: :prod, target: :host)
    assert get_in(config, [:optimal_engine, :text_embedding, :url]) == nil

    System.put_env("OPTIMAL_EMBED_DIALECT", "cohere")

    assert_raise ArgumentError, ~r/OPTIMAL_EMBED_DIALECT must be openai or ollama/, fn ->
      Config.Reader.read!("config/runtime.exs", env: :prod, target: :host)
    end

    System.delete_env("OPTIMAL_EMBED_DIALECT")
    System.put_env("OPTIMAL_EMBED_URL", "gateway.example.com/v1/embeddings")

    assert_raise ArgumentError, ~r/OPTIMAL_EMBED_URL must be an http or https URL/, fn ->
      Config.Reader.read!("config/runtime.exs", env: :prod, target: :host)
    end
  end
end
