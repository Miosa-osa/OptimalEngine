defmodule OptimalEngine.Storage.S3Test do
  @moduledoc """
  Exercises the S3 client against the local stub, which verifies the request
  signature itself. A request the client signs incorrectly is rejected with
  403 by the stub, so every passing operation here is evidence that the
  canonical request, the credential scope, and the payload hash are right.
  """

  use ExUnit.Case, async: false

  alias OptimalEngine.Storage.S3
  alias OptimalEngine.TestSupport.S3Stub

  @env ~w(OPTIMAL_S3_ENDPOINT OPTIMAL_S3_BUCKET OPTIMAL_S3_REGION OPTIMAL_S3_ACCESS_KEY_ID
          OPTIMAL_S3_SECRET_ACCESS_KEY OPTIMAL_S3_PREFIX OPTIMAL_S3_PATH_STYLE
          OPTIMAL_S3_TIMEOUT_MS OPTIMAL_S3_MAX_RETRIES)

  setup do
    previous = Map.new(@env, &{&1, System.get_env(&1)})

    # Allocate the listener reference first so cleanup can shut it down even
    # when the start or the test body fails.
    ref = S3Stub.ref()
    on_exit(fn -> S3Stub.stop(ref) end)

    {:ok, stub} = S3Stub.start(ref: ref, bucket: "engine-test")

    configure(stub)

    on_exit(fn ->
      S3Stub.stop(stub)
      S3Stub.stop_agent(stub.agent)

      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    %{stub: stub}
  end

  defp configure(stub, extra \\ []) do
    System.put_env("OPTIMAL_S3_ENDPOINT", stub.endpoint)
    System.put_env("OPTIMAL_S3_BUCKET", stub.bucket)
    System.put_env("OPTIMAL_S3_ACCESS_KEY_ID", stub.access_key_id)
    System.put_env("OPTIMAL_S3_SECRET_ACCESS_KEY", stub.secret_access_key)
    System.put_env("OPTIMAL_S3_REGION", stub.region)

    Enum.each(extra, fn {name, value} -> System.put_env(to_string(name), value) end)
  end

  describe "configuration" do
    test "reports not configured without an endpoint" do
      Enum.each(@env, &System.delete_env/1)

      refute S3.configured?()
      assert {:error, :not_configured} = S3.config()
      assert {:error, :not_configured} = S3.get_object("any/key")
    end

    test "resolves endpoint, bucket, region, and addressing style", %{stub: stub} do
      assert S3.configured?()
      assert {:ok, config} = S3.config()

      assert config.bucket == "engine-test"
      assert config.region == stub.region
      assert config.endpoint.host == "127.0.0.1"
      assert config.endpoint.port == stub.port
      assert config.path_style
    end

    test "a key prefix is applied to every object key", %{stub: stub} do
      configure(stub, OPTIMAL_S3_PREFIX: "/engine/one/")

      assert S3.object_key(["assets", "ab", "hash.pdf"]) == "engine/one/assets/ab/hash.pdf"
      assert S3.object_key([]) == "engine/one"
    end
  end

  describe "object operations" do
    test "put, head, get, list, and delete round trip", %{stub: stub} do
      key = S3.object_key(["proof", "small.txt"])
      body = "signed object body"

      assert {:ok, put} = S3.put_object(key, body)
      assert put.size_bytes == byte_size(body)
      assert put.checksum_sha256 == S3.sha256(body)
      refute put.multipart
      assert S3Stub.object_body(stub.agent, key) == body

      assert {:ok, head} = S3.head_object(key)
      assert head.size_bytes == byte_size(body)
      assert head.metadata["sha256"] == S3.sha256(body)

      assert {:ok, fetched} = S3.get_object(key)
      assert fetched.body == body
      assert fetched.checksum_sha256 == S3.sha256(body)

      assert {:ok, listed} = S3.list_objects("proof")
      assert key in listed.keys
      assert listed.truncated == false

      assert :ok = S3.delete_object(key)
      assert {:error, :not_found} = S3.head_object(key)
      assert {:error, :not_found} = S3.get_object(key)
    end

    test "a missing object is not_found, not an exception" do
      assert {:error, :not_found} = S3.get_object("absent/key.txt")
      assert {:error, :not_found} = S3.head_object("absent/key.txt")
    end

    test "an empty key is refused before any request reaches the bucket", %{stub: stub} do
      path = Path.join(System.tmp_dir!(), "s3-empty-key-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm(path) end)
      File.write!(path, "body")

      for key <- ["", "/", "//"] do
        assert {:error, :invalid_object_key} = S3.put_object(key, "body")
        assert {:error, :invalid_object_key} = S3.put_file(key, path)
        assert {:error, :invalid_object_key} = S3.get_object(key)
        assert {:error, :invalid_object_key} = S3.get_object_to_file(key, path <> ".out")
        assert {:error, :invalid_object_key} = S3.head_object(key)
        assert {:error, :invalid_object_key} = S3.delete_object(key)
      end

      assert S3Stub.requests(stub.agent) == []
      refute File.exists?(path <> ".out")
    end

    test "keys with characters that need encoding survive the signature", %{stub: stub} do
      key = S3.object_key(["workspaces", "acme team", "hash+name=v1.bin"])

      assert {:ok, _} = S3.put_object(key, "bytes")
      assert S3Stub.object_body(stub.agent, key) == "bytes"
      assert {:ok, %{body: "bytes"}} = S3.get_object(key)
    end

    test "put_file stores a file and get_object_to_file restores the same bytes" do
      tmp = Path.join(System.tmp_dir!(), "s3-client-#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      source = Path.join(tmp, "evidence.bin")
      bytes = :crypto.strong_rand_bytes(64_000)
      File.write!(source, bytes)

      key = S3.object_key(["assets", "evidence.bin"])

      assert {:ok, put} = S3.put_file(key, source)
      assert put.size_bytes == byte_size(bytes)

      restored = Path.join([tmp, "restored", "evidence.bin"])
      assert {:ok, downloaded} = S3.get_object_to_file(key, restored)
      assert File.read!(restored) == bytes
      assert downloaded.checksum_sha256 == put.checksum_sha256

      on_exit(fn -> File.rm_rf(tmp) end)
    end

    test "get_object_to_file streams to disk and leaves nothing behind on a miss", %{stub: stub} do
      tmp = Path.join(System.tmp_dir!(), "s3-stream-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf(tmp) end)

      bytes = :crypto.strong_rand_bytes(3 * 1_048_576 + 17)
      key = S3.object_key(["streamed", "large.bin"])
      assert {:ok, _} = S3.put_object(key, bytes, multipart_threshold: byte_size(bytes) + 1)
      assert S3Stub.object_body(stub.agent, key) == bytes

      target = Path.join([tmp, "nested", "large.bin"])
      assert {:ok, downloaded} = S3.get_object_to_file(key, target)
      assert downloaded.path == target
      assert downloaded.size_bytes == byte_size(bytes)
      assert downloaded.checksum_sha256 == S3.sha256(bytes)
      refute Map.has_key?(downloaded, :body)
      assert File.read!(target) == bytes

      missing = Path.join(tmp, "missing.bin")
      assert {:error, :not_found} = S3.get_object_to_file("streamed/absent.bin", missing)
      assert Path.wildcard(Path.join(tmp, "missing.bin*")) == []
    end

    test "the stub rejects a request signed with the wrong secret", %{stub: stub} do
      System.put_env("OPTIMAL_S3_SECRET_ACCESS_KEY", "not-the-stub-secret")
      assert {:error, :access_denied} = S3.put_object("rejected/key.txt", "bytes")

      System.put_env("OPTIMAL_S3_SECRET_ACCESS_KEY", stub.secret_access_key)
      assert {:ok, _} = S3.put_object("accepted/key.txt", "bytes")
    end

    test "the stub rejects a request scoped to the wrong region", %{stub: stub} do
      System.put_env("OPTIMAL_S3_REGION", "eu-west-1")
      assert {:error, :access_denied} = S3.put_object("region/key.txt", "bytes")

      System.put_env("OPTIMAL_S3_REGION", stub.region)
      assert {:ok, _} = S3.put_object("region/key.txt", "bytes")
    end
  end

  describe "multipart upload" do
    test "an object above the threshold is uploaded in parts and reassembles", %{stub: stub} do
      key = S3.object_key(["assets", "large.bin"])
      body = :crypto.strong_rand_bytes(200_000)

      assert {:ok, upload} =
               S3.put_object(key, body, multipart_threshold: 100_000, part_size: 64_000)

      assert upload.multipart
      assert upload.parts == 4
      assert upload.size_bytes == byte_size(body)
      assert upload.checksum_sha256 == S3.sha256(body)
      assert S3Stub.object_body(stub.agent, key) == body

      assert {:ok, fetched} = S3.get_object(key)
      assert fetched.body == body
    end

    test "put_file streams a large file in parts", %{stub: stub} do
      tmp = Path.join(System.tmp_dir!(), "s3-multipart-#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      source = Path.join(tmp, "archive.bin")
      bytes = :crypto.strong_rand_bytes(150_000)
      File.write!(source, bytes)

      key = S3.object_key(["backups", "archive.bin"])

      assert {:ok, upload} =
               S3.put_file(key, source, multipart_threshold: 50_000, part_size: 50_000)

      assert upload.multipart
      assert upload.size_bytes == byte_size(bytes)
      assert S3Stub.object_body(stub.agent, key) == bytes

      on_exit(fn -> File.rm_rf(tmp) end)
    end
  end

  describe "round trip proof" do
    test "the provider self-check writes, reads, lists, and deletes", %{stub: stub} do
      before = length(S3Stub.object_keys(stub.agent))

      assert {:ok, proof} = S3.round_trip()
      assert proof.listed
      assert proof.deleted
      assert byte_size(proof.checksum_sha256) == 64
      assert proof.key =~ "health/"
      assert length(S3Stub.object_keys(stub.agent)) == before
    end
  end

  describe "URI handling" do
    test "s3 URIs round trip through uri and parse_uri" do
      uri = S3.uri("assets/ab/hash.pdf")
      assert uri == "s3://engine-test/assets/ab/hash.pdf"
      assert S3.uri?(uri)
      assert {:ok, "engine-test", "assets/ab/hash.pdf"} = S3.parse_uri(uri)
    end

    test "a URI without a bucket is refused" do
      assert {:error, :invalid_uri} = S3.parse_uri("s3:///assets/hash.pdf")
      assert {:error, :invalid_uri} = S3.parse_uri("/tmp/assets/hash.pdf")
      refute S3.uri?("/tmp/assets/hash.pdf")
    end
  end
end
