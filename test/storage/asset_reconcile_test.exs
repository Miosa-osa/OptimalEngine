defmodule OptimalEngine.Storage.AssetReconcileTest do
  @moduledoc """
  An asset kept on the local disk while its object store was down is put in
  the bucket once the store answers: uploaded, read back and checked against
  its hash before it is recorded as placed, with the local copy kept. A pass
  is idempotent, leaves an asset pending while the store is still down or its
  copy no longer matches, and resolves an asset whose workspace now keeps
  assets on disk. The pending count is a gauge in /api/metrics.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Plug.Test

  alias OptimalEngine.{MemoryCore, Store, WorkspaceTopology}
  alias OptimalEngine.Storage.AssetReconcile
  alias OptimalEngine.TestSupport.S3Stub

  @s3_env ~w(OPTIMAL_S3_ENDPOINT OPTIMAL_S3_BUCKET OPTIMAL_S3_REGION OPTIMAL_S3_ACCESS_KEY_ID
             OPTIMAL_S3_SECRET_ACCESS_KEY OPTIMAL_S3_PREFIX OPTIMAL_S3_MAX_RETRIES
             OPTIMAL_ASSET_STORAGE)

  setup do
    previous_env = Map.new(@s3_env, &{&1, System.get_env(&1)})
    previous_root = Application.get_env(:optimal_engine, :root_path)

    tmp = Path.join(System.tmp_dir!(), "asset-reconcile-#{System.unique_integer([:positive])}")
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
        slug: "asset-reconcile-#{suffix}",
        name: "Asset reconcile #{suffix}"
      })

    %{stub: stub, tmp: tmp, workspace: workspace}
  end

  defp point_at(stub) do
    System.put_env("OPTIMAL_S3_ENDPOINT", stub.endpoint)
    System.put_env("OPTIMAL_S3_BUCKET", stub.bucket)
    System.put_env("OPTIMAL_S3_ACCESS_KEY_ID", stub.access_key_id)
    System.put_env("OPTIMAL_S3_SECRET_ACCESS_KEY", stub.secret_access_key)
    System.put_env("OPTIMAL_S3_REGION", stub.region)
  end

  # Points S3 at a port nothing listens on: configured, and unreachable.
  defp outage(stub) do
    point_at(stub)
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    System.put_env("OPTIMAL_S3_ENDPOINT", "http://127.0.0.1:#{port}")
    System.put_env("OPTIMAL_S3_MAX_RETRIES", "0")
    System.put_env("OPTIMAL_ASSET_STORAGE", "s3")
  end

  # An asset written during the outage: on the local disk, pending.
  defp kept_on_disk(ctx, name) do
    bytes = :crypto.strong_rand_bytes(4_096)
    source = Path.join(ctx.tmp, name)
    File.mkdir_p!(ctx.tmp)
    File.write!(source, bytes)

    capture_log(fn ->
      {:ok, %{asset: asset, storage_backend: :filesystem}} =
        MemoryCore.store_asset_file(source, workspace_id: ctx.workspace.id, actor_id: "test")

      send(self(), {:asset, asset})
    end)

    assert_received {:asset, asset}
    assert asset.metadata["storage_fallback_reason"] == "s3_upload_failed"
    {asset, bytes}
  end

  defp row(asset_id) do
    {:ok, [[storage_path, metadata]]} =
      Store.raw_query("SELECT storage_path, metadata FROM assets WHERE id = ?1", [asset_id])

    {storage_path, Jason.decode!(metadata)}
  end

  defp run(ctx), do: AssetReconcile.run(workspace_id: ctx.workspace.id)

  test "a kept asset is placed once the store answers, verified, and its local copy stays", ctx do
    outage(ctx.stub)
    {asset, bytes} = kept_on_disk(ctx, "outage.bin")
    local = asset.storage_path
    assert AssetReconcile.pending_count(workspace_id: ctx.workspace.id) == 1

    point_at(ctx.stub)
    assert {:ok, %{placed: 1, failed: 0, pending: 0}} = run(ctx)

    {storage_path, metadata} = row(asset.id)
    assert String.starts_with?(storage_path, "s3://")
    assert metadata["storage_backend"] == "s3"
    assert metadata["object_uri"] == storage_path

    assert metadata["object_checksum_sha256"] ==
             :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

    assert metadata["storage_fallback_resolved"] == "s3_upload_failed"
    refute Map.has_key?(metadata, "storage_fallback_reason")
    assert metadata["storage_placed_at"]

    assert S3Stub.object_body(ctx.stub.agent, metadata["object_key"]) == bytes
    assert File.read!(local) == bytes
    assert {:ok, ^bytes} = MemoryCore.read_asset(asset.id, workspace_id: ctx.workspace.id)

    # Nothing is pending, so a second pass places nothing.
    assert {:ok, %{placed: 0, failed: 0, pending: 0}} = run(ctx)
  end

  test "an asset stays pending while the store is still down", ctx do
    outage(ctx.stub)
    {first, _} = kept_on_disk(ctx, "first.bin")
    {second, _} = kept_on_disk(ctx, "second.bin")

    capture_log(fn ->
      # The first transport error ends the pass: the second is not tried.
      assert {:ok, %{placed: 0, failed: 1, pending: 2}} = run(ctx)
    end)

    for asset <- [first, second] do
      {storage_path, metadata} = row(asset.id)
      assert storage_path == asset.storage_path
      assert metadata["storage_fallback_reason"] == "s3_upload_failed"
    end

    assert S3Stub.object_keys(ctx.stub.agent) == []
  end

  test "a local copy that no longer matches its hash stays pending", ctx do
    outage(ctx.stub)
    {asset, _bytes} = kept_on_disk(ctx, "changed.bin")
    File.write!(asset.storage_path, "not the bytes the asset was stored with")

    point_at(ctx.stub)

    log =
      capture_log(fn ->
        assert {:ok, %{placed: 0, failed: 1, pending: 1}} = run(ctx)
      end)

    assert log =~ "stays pending"
    assert S3Stub.object_keys(ctx.stub.agent) == []
    assert {_path, %{"storage_fallback_reason" => "s3_upload_failed"}} = row(asset.id)
  end

  test "an asset whose workspace now keeps assets on disk is resolved without an upload", ctx do
    outage(ctx.stub)
    {asset, _bytes} = kept_on_disk(ctx, "now-local.bin")

    point_at(ctx.stub)
    System.delete_env("OPTIMAL_ASSET_STORAGE")

    assert {:ok, %{placed: 0, resolved: 1, pending: 0}} = run(ctx)
    {storage_path, metadata} = row(asset.id)
    assert storage_path == asset.storage_path
    assert metadata["storage_fallback_resolved"] == "backend_now_filesystem"
    assert S3Stub.object_keys(ctx.stub.agent) == []
  end

  test "an Engine without S3 configured touches nothing", ctx do
    outage(ctx.stub)
    {asset, _bytes} = kept_on_disk(ctx, "unconfigured.bin")
    System.delete_env("OPTIMAL_S3_ENDPOINT")
    System.delete_env("OPTIMAL_S3_BUCKET")

    assert {:error, :s3_not_configured} = run(ctx)
    assert {_path, %{"storage_fallback_reason" => "s3_upload_failed"}} = row(asset.id)
  end

  test "/api/metrics and Prometheus report the assets pending placement", ctx do
    outage(ctx.stub)
    kept_on_disk(ctx, "metric.bin")
    pending = AssetReconcile.pending_count()
    assert pending >= 1

    metrics =
      conn(:get, "/api/metrics") |> OptimalEngine.API.Router.call(OptimalEngine.API.Router.init([]))

    assert Jason.decode!(metrics.resp_body)["gauges"][
             "optimal_engine_storage_assets_pending_placement"
           ] == pending

    assert OptimalEngine.Telemetry.Prometheus.render() =~
             "optimal_engine_storage_assets_pending_placement #{pending}"
  end
end
