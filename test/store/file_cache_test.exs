defmodule OptimalEngine.Store.FileCacheTest do
  use ExUnit.Case, async: false

  import Bitwise
  import ExUnit.CaptureLog

  alias OptimalEngine.Embed.Ollama
  alias OptimalEngine.Store.FileCache

  @scope {"default", "default:file-cache-test"}

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
    assert :miss = FileCache.get(@scope, "tests", "key-a")
    assert :ok = FileCache.put(@scope, "tests", "key-a", %{"vector" => [0.1, 0.2]})
    assert {:ok, %{"vector" => [0.1, 0.2]}} = FileCache.get(@scope, "tests", "key-a")
    assert [path] = Path.wildcard(Path.join(dir, "tenants/*/*/tests/*/*.bin"))
    assert File.regular?(path)
    assert %{"tests" => %{entries: 1}} = FileCache.stats()
  end

  test "entries survive a fresh reader because they live on disk" do
    :ok = FileCache.put(@scope, "tests", "durable", [1, 2, 3])

    task = Task.async(fn -> FileCache.get(@scope, "tests", "durable") end)
    assert {:ok, [1, 2, 3]} = Task.await(task)
  end

  test "an entry is named by a keyed digest of its key and holds nothing of the key", %{dir: dir} do
    key = "plain text that must not be stored"
    :ok = FileCache.put(@scope, "tests", key, [0.5])

    assert [path] = Path.wildcard(Path.join(dir, "tenants/*/*/tests/*/*.bin"))
    name = Path.basename(path, ".bin")
    assert name =~ ~r/\A[0-9a-f]{64}\z/

    # A guess at the text cannot be confirmed from the file name: the name is not its hash.
    refute name == :crypto.hash(:sha256, key) |> Base.encode16(case: :lower)
    assert :binary.match(File.read!(path), "plain text") == :nomatch
    assert {:ok, ^path} = FileCache.entry_file(@scope, "tests", key)
  end

  describe "the install's key" do
    setup %{dir: dir} do
      saved = Application.get_env(:optimal_engine, :embed_cache_key_path)
      key = Path.join(dir, "keys/embed_cache.key")
      Application.put_env(:optimal_engine, :embed_cache_key_path, key)

      on_exit(fn ->
        if saved,
          do: Application.put_env(:optimal_engine, :embed_cache_key_path, saved),
          else: Application.delete_env(:optimal_engine, :embed_cache_key_path)
      end)

      %{key: key}
    end

    test "the same key is named differently under another install's secret", %{dir: dir} do
      :ok = FileCache.put(@scope, "tests", "k", 1)
      {:ok, here} = FileCache.entry_file(@scope, "tests", "k")

      Application.put_env(:optimal_engine, :embed_cache_key_path, Path.join(dir, "keys/other.key"))
      {:ok, there} = FileCache.entry_file(@scope, "tests", "k")

      refute Path.basename(here) == Path.basename(there)

      refute Path.relative_to(here, dir) |> Path.split() |> Enum.at(1) ==
               Path.relative_to(there, dir) |> Path.split() |> Enum.at(1)
    end

    test "creating it removes entries nothing can attribute any more", %{dir: dir} do
      # Entries an earlier digest scheme (or a lost key) left: no purge could find them.
      stale = Path.join([dir, "tenants", String.duplicate("a", 64), String.duplicate("b", 64)])
      File.mkdir_p!(Path.join(stale, "embeddings/ab"))
      File.write!(Path.join(stale, "embeddings/ab/#{String.duplicate("c", 64)}.bin"), "old")

      log = capture_log(fn -> assert :ok = FileCache.ensure_key() end)

      assert log =~ "cannot be attributed to a workspace"
      refute File.exists?(stale)
      assert File.regular?(FileCache.key_path())
    end

    test "creating it removes only what has the shape of a cache entry", %{dir: dir} do
      # `<cache_path>/tenants` can be a directory of something else (a cache path that is
      # also an Engine root holds its tenants' workspaces there).
      stale = Path.join([dir, "tenants", String.duplicate("a", 64), String.duplicate("b", 64)])
      File.mkdir_p!(Path.join(stale, "embeddings/ab"))
      File.write!(Path.join(stale, "embeddings/ab/#{String.duplicate("c", 64)}.bin"), "old")

      workspace_note = Path.join([dir, "tenants", "acme", "sales", "nodes", "deal.md"])
      File.mkdir_p!(Path.dirname(workspace_note))
      File.write!(workspace_note, "a signal of a workspace")

      lookalike = Path.join([stale, "embeddings", "ab", "notes.txt"])
      File.write!(lookalike, "not a cache entry")

      capture_log(fn -> assert :ok = FileCache.ensure_key() end)

      refute File.exists?(Path.join(stale, "embeddings/ab/#{String.duplicate("c", 64)}.bin"))
      assert File.read!(workspace_note) == "a signal of a workspace"
      assert File.read!(lookalike) == "not a cache entry"
    end

    test "callers that start together end up with one key", %{key: key} do
      :persistent_term.erase({FileCache, key})
      parent = self()

      tasks =
        for _ <- 1..16 do
          Task.async(fn ->
            send(parent, {:ready, self()})

            receive do
              :go -> FileCache.entry_file(@scope, "tests", "same key")
            end
          end)
        end

      for _ <- tasks do
        receive do
          {:ready, _pid} -> :ok
        end
      end

      Enum.each(tasks, &send(&1.pid, :go))
      names = tasks |> Task.await_many(30_000) |> Enum.uniq()

      assert [{:ok, _path}] = names
      assert byte_size(Base.decode16!(String.trim(File.read!(key)), case: :mixed)) == 32
    end

    test "an existing key is kept, and so are the entries made under it", %{key: key} do
      :ok = FileCache.put(@scope, "tests", "durable", [1])
      before = File.read!(key)

      assert :ok = FileCache.ensure_key()
      :persistent_term.erase({FileCache, key})

      assert File.read!(key) == before
      assert {:ok, [1]} = FileCache.get(@scope, "tests", "durable")
    end

    test "a key file that is not a key is replaced, with the entries under it", %{key: key} do
      :ok = FileCache.put(@scope, "tests", "orphaned", [1])
      File.write!(key, "not a key")
      :persistent_term.erase({FileCache, key})

      capture_log(fn -> assert :ok = FileCache.ensure_key() end)

      assert :miss = FileCache.get(@scope, "tests", "orphaned")
    end

    test "a key that cannot be created means nothing is cached, not a crash", %{dir: dir} do
      File.mkdir_p!(dir)
      blocker = Path.join(dir, "blocker")
      File.write!(blocker, "a file where a directory has to be")

      Application.put_env(
        :optimal_engine,
        :embed_cache_key_path,
        Path.join(blocker, "embed_cache.key")
      )

      assert {:error, {:cache_key_unavailable, _}} = FileCache.put(@scope, "tests", "k", 1)
      assert {:error, {:cache_key_unavailable, _}} = FileCache.get(@scope, "tests", "k")
      assert {:error, {:cache_key_unavailable, _}} = FileCache.purge_workspace("default:ws")
    end
  end

  test "files are readable by the Engine's user only", %{dir: dir} do
    :ok = FileCache.put(@scope, "tests", "private", [0.5])

    [path] = Path.wildcard(Path.join(dir, "tenants/*/*/tests/*/*.bin"))
    assert mode(path) == 0o600

    # Every directory the cache made on the way down.
    dirs =
      path
      |> Path.relative_to(dir)
      |> Path.split()
      |> Enum.drop(-1)
      |> Enum.scan(dir, &Path.join(&2, &1))

    assert length(dirs) == 5
    for directory <- dirs, do: assert(mode(directory) == 0o700, "#{directory} is not private")

    assert mode(FileCache.key_path()) == 0o600
  end

  test "tenant and workspace reach the filesystem as digests, never as names", %{dir: dir} do
    :ok = FileCache.put({"acme", "acme:../escape"}, "tests", "k", 1)

    [path] = Path.wildcard(Path.join(dir, "tenants/*/*/tests/*/*.bin"))
    relative = Path.relative_to(path, dir)
    refute relative =~ "acme"
    refute relative =~ ".."

    assert [_tenants, <<_::binary-size(64)>>, <<_::binary-size(64)>>, "tests", _, _] =
             Path.split(relative)
  end

  test "a key is only found in the tenant and workspace that stored it" do
    :ok = FileCache.put({"acme", "acme:one"}, "tests", "k", :one)

    assert {:ok, :one} = FileCache.get({"acme", "acme:one"}, "tests", "k")
    assert :miss = FileCache.get({"acme", "acme:two"}, "tests", "k")
    assert :miss = FileCache.get({"beta", "acme:one"}, "tests", "k")
  end

  test "corrupt, foreign or older-format entries are discarded as misses", %{dir: dir} do
    :ok = FileCache.put(@scope, "tests", "victim", :value)
    [path] = Path.wildcard(Path.join(dir, "tenants/*/*/tests/*/*.bin"))

    File.write!(path, "not an erlang term")
    assert :miss = FileCache.get(@scope, "tests", "victim")
    refute File.exists?(path)

    # Another digest, or the earlier format that carried the key itself.
    for body <- [{2, "another-digest", :value}, {1, "victim", :value}] do
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, :erlang.term_to_binary(body))
      assert :miss = FileCache.get(@scope, "tests", "victim")
      refute File.exists?(path)
    end
  end

  test "fetch caches successes and never caches errors" do
    parent = self()

    compute = fn ->
      send(parent, :computed)
      {:ok, :fresh}
    end

    assert {:ok, :fresh} = FileCache.fetch(@scope, "tests", "lazy", compute)
    assert {:ok, :fresh} = FileCache.fetch(@scope, "tests", "lazy", compute)
    assert_received :computed
    refute_received :computed

    assert {:error, :down} = FileCache.fetch(@scope, "tests", "failing", fn -> {:error, :down} end)
    assert :miss = FileCache.get(@scope, "tests", "failing")
  end

  test "invalid scopes and namespaces are rejected" do
    assert {:error, {:invalid_namespace, "../escape"}} =
             FileCache.put(@scope, "../escape", "k", 1)

    assert {:error, {:invalid_scope, {"", "w"}}} = FileCache.put({"", "w"}, "tests", "k", 1)
    assert {:error, {:invalid_scope, {"t", nil}}} = FileCache.get({"t", nil}, "tests", "k")
    assert {:error, {:invalid_scope, nil}} = FileCache.put(nil, "tests", "k", 1)
  end

  test "clear removes one namespace of one scope" do
    other = {"default", "default:file-cache-other"}
    :ok = FileCache.put(@scope, "tests", "k", 1)
    :ok = FileCache.put(@scope, "keep", "k", 2)
    :ok = FileCache.put(other, "tests", "k", 3)

    assert :ok = FileCache.clear(@scope, "tests")

    assert :miss = FileCache.get(@scope, "tests", "k")
    assert {:ok, 2} = FileCache.get(@scope, "keep", "k")
    assert {:ok, 3} = FileCache.get(other, "tests", "k")
  end

  describe "purge_workspace/1" do
    test "removes the workspace under every tenant and counts what went", %{dir: dir} do
      :ok = FileCache.put({"acme", "shared-id"}, "tests", "a", [1.0])
      :ok = FileCache.put({"acme", "shared-id"}, "other", "b", [2.0])
      :ok = FileCache.put({"beta", "shared-id"}, "tests", "a", [3.0])
      :ok = FileCache.put({"acme", "kept-id"}, "tests", "a", [4.0])

      assert {:ok, %{files: 3, bytes: bytes}} = FileCache.purge_workspace("shared-id")
      assert bytes > 0

      assert :miss = FileCache.get({"acme", "shared-id"}, "tests", "a")
      assert :miss = FileCache.get({"beta", "shared-id"}, "tests", "a")
      assert {:ok, [4.0]} = FileCache.get({"acme", "kept-id"}, "tests", "a")

      # A tenant left with nothing is not left behind as an empty directory.
      assert length(File.ls!(Path.join(dir, "tenants"))) == 1
    end

    test "a workspace that was never cached is not an error" do
      assert {:ok, %{files: 0, bytes: 0}} = FileCache.purge_workspace("never-cached")
      assert {:error, :invalid_workspace} = FileCache.purge_workspace("")
    end
  end

  test "text embeddings are served from the cache for the same model and input" do
    model = "cache-test-model"
    vector = [0.25, 0.5, 0.75]
    scope = [tenant_id: elem(@scope, 0), workspace_id: elem(@scope, 1)]
    :ok = FileCache.put(@scope, "embeddings", "#{model}\0cached sentence", vector)

    assert {:ok, ^vector} = Ollama.embed_text("cached sentence", [model: model] ++ scope)

    # Without a workspace the cache is not consulted; Ollama is a closed port in tests.
    capture_log(fn ->
      assert {:error, :ollama_unavailable} = Ollama.embed_text("cached sentence", model: model)
    end)
  end

  defp mode(path), do: File.stat!(path).mode &&& 0o777
end
