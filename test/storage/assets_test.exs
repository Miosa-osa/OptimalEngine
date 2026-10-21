defmodule OptimalEngine.Storage.AssetsTest do
  @moduledoc """
  Asset bytes stay on the local filesystem by default and move to an S3 bucket
  only when the workspace policy or the engine configuration says so. A remote
  backend that cannot be reached falls back to the filesystem with an alert
  instead of losing the evidence.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias OptimalEngine.{MemoryCore, WorkspaceTopology}
  alias OptimalEngine.MemoryCore.SourcePackage
  alias OptimalEngine.Storage.{Assets, PolicyStore}
  alias OptimalEngine.TestSupport.S3Stub

  @s3_env ~w(OPTIMAL_S3_ENDPOINT OPTIMAL_S3_BUCKET OPTIMAL_S3_REGION OPTIMAL_S3_ACCESS_KEY_ID
             OPTIMAL_S3_SECRET_ACCESS_KEY OPTIMAL_S3_PREFIX OPTIMAL_S3_MAX_RETRIES
             OPTIMAL_ASSET_STORAGE)

  setup do
    previous_env = Map.new(@s3_env, &{&1, System.get_env(&1)})
    previous_root = Application.get_env(:optimal_engine, :root_path)

    tmp = Path.join(System.tmp_dir!(), "assets-s3-#{System.unique_integer([:positive])}")
    Application.put_env(:optimal_engine, :root_path, tmp)

    ref = S3Stub.ref()
    on_exit(fn -> S3Stub.stop(ref) end)
    {:ok, stub} = S3Stub.start(ref: ref, bucket: "engine-test")

    on_exit(fn ->
      Enum.each(previous_env, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)

      case previous_root do
        nil -> Application.delete_env(:optimal_engine, :root_path)
        value -> Application.put_env(:optimal_engine, :root_path, value)
      end

      File.rm_rf(tmp)
    end)

    suffix = System.unique_integer([:positive])

    {:ok, workspace} =
      WorkspaceTopology.create_workspace(%{
        slug: "assets-s3-#{suffix}",
        name: "Assets S3 #{suffix}"
      })

    %{stub: stub, tmp: tmp, workspace: workspace, suffix: suffix}
  end

  defp point_at(stub) do
    System.put_env("OPTIMAL_S3_ENDPOINT", stub.endpoint)
    System.put_env("OPTIMAL_S3_BUCKET", stub.bucket)
    System.put_env("OPTIMAL_S3_ACCESS_KEY_ID", stub.access_key_id)
    System.put_env("OPTIMAL_S3_SECRET_ACCESS_KEY", stub.secret_access_key)
    System.put_env("OPTIMAL_S3_REGION", stub.region)
  end

  # Sends this test every fallback event's metadata.
  defp watch_fallbacks do
    handler = "asset-fallback-#{System.unique_integer([:positive])}"
    test = self()

    :telemetry.attach(
      handler,
      [:optimal_engine, :storage, :asset_fallback],
      fn _event, _measurements, metadata, _config -> send(test, {:asset_fallback, metadata}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  # The snapshot call is ordered after this process's telemetry events.
  defp fallback_count do
    OptimalEngine.Telemetry.snapshot().counters[:"optimal_engine.storage.asset_fallback"] || 0
  end

  defp write_source(tmp, name, bytes \\ nil) do
    bytes = bytes || :crypto.strong_rand_bytes(2_048)
    path = Path.join(tmp, name)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, bytes)
    {path, bytes}
  end

  test "the filesystem remains the default backend", %{tmp: tmp, workspace: workspace} do
    {source, bytes} = write_source(tmp, "default.txt")

    assert Assets.selected_backend(workspace_id: workspace.id) == :filesystem

    assert {:ok, %{asset: asset, storage_backend: :filesystem}} =
             MemoryCore.store_asset_file(source, workspace_id: workspace.id, actor_id: "test")

    assert asset.storage_path ==
             Path.join([tmp, workspace.slug, "assets", asset_shard(asset), asset_name(asset)])

    assert asset.metadata["storage_backend"] == "filesystem"
    refute Assets.remote?(asset.storage_path)
    assert {:ok, ^bytes} = MemoryCore.read_asset(asset.id, workspace_id: workspace.id)
    assert {:ok, _path} = MemoryCore.materialize_asset(asset.id, workspace_id: workspace.id)
  end

  test "a workspace policy selects s3 and the bytes live in the bucket", %{
    stub: stub,
    tmp: tmp,
    workspace: workspace
  } do
    point_at(stub)

    assert {:ok, _policy} =
             PolicyStore.put_policy(workspace.id, ["media_archive"],
               provider_overrides: %{"s3" => %{"assets" => true}}
             )

    {source, bytes} = write_source(tmp, "policy.bin")

    assert Assets.selected_backend(workspace_id: workspace.id) == :s3

    assert {:ok, %{asset: asset, storage_backend: :s3} = stored} =
             MemoryCore.store_asset_file(source, workspace_id: workspace.id, actor_id: "test")

    assert Assets.remote?(asset.storage_path)
    assert {:ok, parsed_bucket, _key} = OptimalEngine.Storage.S3.parse_uri(asset.storage_path)
    assert parsed_bucket == stub.bucket
    refute Map.has_key?(asset.metadata, "storage_fallback_reason")
    assert asset.metadata["storage_backend"] == "s3"
    assert asset.metadata["object_uri"] == asset.storage_path
    assert asset.metadata["object_size_bytes"] == byte_size(bytes)

    # The bytes are in the bucket under a tenant and workspace prefix, and the
    # workspace asset directory holds no copy of them.
    key = asset.metadata["object_key"]
    assert key =~ "default/#{workspace.slug}/assets/"
    assert S3Stub.object_body(stub.agent, key) == bytes

    refute File.exists?(Path.join([tmp, workspace.id, "assets"])) and
             File.exists?(
               Assets.local_path(%{
                 workspace_key: workspace.id,
                 hash: asset.content_hash,
                 extension: ".bin"
               })
             )

    assert {:ok, ^bytes} = MemoryCore.read_asset(asset.id, workspace_id: workspace.id)

    assert {:ok, path} = MemoryCore.materialize_asset(asset.id, workspace_id: workspace.id)
    assert path != asset.storage_path
    assert File.read!(path) == bytes

    assert stored.source_package.verbatim_archive_uri == asset.storage_path
    assert %SourcePackage{id: _} = stored.source_package
  end

  test "an engine-wide setting selects s3 without a workspace policy", %{
    stub: stub,
    tmp: tmp,
    workspace: workspace
  } do
    point_at(stub)
    System.put_env("OPTIMAL_ASSET_STORAGE", "s3")

    {source, bytes} = write_source(tmp, "engine-wide.bin")

    assert Assets.selected_backend(workspace_id: workspace.id) == :s3

    assert {:ok, %{asset: asset}} =
             MemoryCore.store_asset_file(source, workspace_id: workspace.id, actor_id: "test")

    assert Assets.remote?(asset.storage_path)
    assert S3Stub.object_body(stub.agent, asset.metadata["object_key"]) == bytes
  end

  test "an unreachable object store falls back to the filesystem with an alert", %{
    stub: stub,
    tmp: tmp,
    workspace: workspace
  } do
    point_at(stub)
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)

    System.put_env("OPTIMAL_S3_ENDPOINT", "http://127.0.0.1:#{port}")
    System.put_env("OPTIMAL_S3_MAX_RETRIES", "0")
    System.put_env("OPTIMAL_ASSET_STORAGE", "s3")

    {source, bytes} = write_source(tmp, "fallback.bin")
    fallbacks = fallback_count()
    watch_fallbacks()

    log =
      capture_log(fn ->
        assert {:ok, %{asset: asset, storage_backend: :filesystem}} =
                 MemoryCore.store_asset_file(source, workspace_id: workspace.id, actor_id: "test")

        assert asset.metadata["storage_fallback_reason"] == "s3_upload_failed"
        assert File.regular?(asset.storage_path)
        assert File.read!(asset.storage_path) == bytes
        assert {:ok, ^bytes} = MemoryCore.read_asset(asset.id, workspace_id: workspace.id)
      end)

    assert log =~ "asset storage alert"
    assert log =~ "keeping the file on the local filesystem"
    assert S3Stub.object_keys(stub.agent) == []
    # The alert is also a counter an operator can scrape and alert on.
    assert fallback_count() == fallbacks + 1
    # The metric names the reason only, never the object key or the error.
    assert_received {:asset_fallback, %{reason: :s3_upload_failed} = metadata}
    assert map_size(metadata) == 1
  end

  test "an unconfigured object store falls back to the filesystem with an alert", %{
    tmp: tmp,
    workspace: workspace
  } do
    System.put_env("OPTIMAL_ASSET_STORAGE", "s3")
    {source, bytes} = write_source(tmp, "unconfigured.bin")
    fallbacks = fallback_count()
    watch_fallbacks()

    log =
      capture_log(fn ->
        assert {:ok, %{asset: asset, storage_backend: :filesystem}} =
                 MemoryCore.store_asset_file(source, workspace_id: workspace.id, actor_id: "test")

        assert asset.metadata["storage_fallback_reason"] == "s3_not_configured"
        assert File.read!(asset.storage_path) == bytes
      end)

    assert log =~ "s3 is selected for assets but not configured"
    assert fallback_count() == fallbacks + 1
    assert_received {:asset_fallback, %{reason: :s3_not_configured} = metadata}
    assert map_size(metadata) == 1
  end

  test "an explicit option overrides the workspace policy", %{
    stub: stub,
    tmp: tmp,
    workspace: workspace
  } do
    point_at(stub)

    assert {:ok, _policy} =
             PolicyStore.put_policy(workspace.id, ["media_archive"],
               provider_overrides: %{"s3" => %{"assets" => true}}
             )

    {source, _bytes} = write_source(tmp, "override.bin")

    assert Assets.selected_backend(workspace_id: workspace.id) == :s3

    assert {:ok, %{asset: asset, storage_backend: :filesystem}} =
             MemoryCore.store_asset_file(source,
               workspace_id: workspace.id,
               actor_id: "test",
               storage_backend: :filesystem
             )

    assert File.regular?(asset.storage_path)
    assert S3Stub.object_keys(stub.agent) == []
  end

  test "the asset inventory checks local files and object references", %{
    stub: stub,
    tmp: tmp,
    workspace: workspace
  } do
    point_at(stub)

    {source, _bytes} = write_source(tmp, "inventory.bin")

    assert {:ok, %{asset: asset}} =
             MemoryCore.store_asset_file(source, workspace_id: workspace.id, actor_id: "test")

    key =
      Assets.object_key(%{
        tenant_id: "default",
        workspace_id: workspace.slug,
        hash: asset.content_hash,
        extension: ".bin"
      })

    assert {:ok, _} = OptimalEngine.Storage.S3.put_object(key, "object bytes")
    uri = OptimalEngine.Storage.S3.uri(key)

    assert {:ok, %{local: 1, objects: 1, objects_verified: 1}} =
             Assets.inventory([asset.storage_path, uri], verify_remote: true)

    assert {:error, %{objects_unverified: 1}} =
             Assets.inventory([uri <> "-absent"], verify_remote: true)

    assert {:error, %{local_missing: 1}} = Assets.inventory([asset.storage_path <> "x"])
  end

  test "the inventory reports a missing local file as a failure" do
    assert {:error, %{local_missing: 1, missing: ["/nope/missing.bin"]}} =
             Assets.inventory(["/nope/missing.bin"])
  end

  test "object keys are namespaced by tenant, workspace, and content hash" do
    key =
      Assets.object_key(%{
        tenant_id: "default",
        workspace_id: "ws-1",
        hash: "sha256:abcdef0123456789",
        extension: ".PDF"
      })

    assert key == "default/ws-1/assets/ab/abcdef0123456789.pdf"
  end

  defp asset_shard(asset) do
    asset.content_hash |> String.replace_prefix("sha256:", "") |> String.slice(0, 2)
  end

  defp asset_name(asset) do
    hash = String.replace_prefix(asset.content_hash, "sha256:", "")
    extension = Path.extname(asset.original_path) |> String.downcase()
    hash <> extension
  end
end
