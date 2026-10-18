defmodule OptimalEngine.Store.FileCacheTest do
  use ExUnit.Case, async: false

  alias OptimalEngine.Embed.Ollama
  alias OptimalEngine.Store.FileCache

  setup do
    original = Application.get_env(:optimal_engine, :cache_path)
    dir = Path.join(System.tmp_dir!(), "file-cache-#{System.unique_integer([:positive])}")
    Application.put_env(:optimal_engine, :cache_path, dir)

    on_exit(fn ->
      Application.put_env(:optimal_engine, :cache_path, original)
      File.rm_rf(dir)
    end)

    %{dir: dir}
  end

  test "put and get round-trip a term through the filesystem", %{dir: dir} do
    assert :miss = FileCache.get("tests", "key-a")
    assert :ok = FileCache.put("tests", "key-a", %{"vector" => [0.1, 0.2]})
    assert {:ok, %{"vector" => [0.1, 0.2]}} = FileCache.get("tests", "key-a")
    assert [path] = Path.wildcard(Path.join(dir, "tests/*/*.bin"))
    assert File.regular?(path)
    assert %{"tests" => %{entries: 1}} = FileCache.stats()
  end

  test "entries survive a fresh reader because they live on disk" do
    :ok = FileCache.put("tests", "durable", [1, 2, 3])

    task = Task.async(fn -> FileCache.get("tests", "durable") end)
    assert {:ok, [1, 2, 3]} = Task.await(task)
  end

  test "corrupt or foreign entries are discarded as misses", %{dir: dir} do
    :ok = FileCache.put("tests", "victim", :value)
    [path] = Path.wildcard(Path.join(dir, "tests/*/*.bin"))

    File.write!(path, "not an erlang term")
    assert :miss = FileCache.get("tests", "victim")
    refute File.exists?(path)

    File.write!(path, :erlang.term_to_binary({1, "another-key", :value}))
    assert :miss = FileCache.get("tests", "victim")
  end

  test "fetch caches successes and never caches errors" do
    parent = self()

    compute = fn ->
      send(parent, :computed)
      {:ok, :fresh}
    end

    assert {:ok, :fresh} = FileCache.fetch("tests", "lazy", compute)
    assert {:ok, :fresh} = FileCache.fetch("tests", "lazy", compute)
    assert_received :computed
    refute_received :computed

    assert {:error, :down} = FileCache.fetch("tests", "failing", fn -> {:error, :down} end)
    assert :miss = FileCache.get("tests", "failing")
  end

  test "invalid namespaces are rejected and clear removes a namespace" do
    assert {:error, {:invalid_namespace, "../escape"}} = FileCache.put("../escape", "k", 1)
    :ok = FileCache.put("tests", "k", 1)
    assert :ok = FileCache.clear("tests")
    assert :miss = FileCache.get("tests", "k")
  end

  test "text embeddings are served from the cache for the same model and input" do
    model = "cache-test-model"
    vector = [0.25, 0.5, 0.75]
    :ok = FileCache.put("embeddings", "#{model}\0cached sentence", vector)

    assert {:ok, ^vector} = Ollama.embed_text("cached sentence", model: model)
  end
end
