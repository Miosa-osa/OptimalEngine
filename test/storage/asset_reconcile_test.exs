defmodule OptimalEngine.Storage.AssetReconcileTest do
  @moduledoc """
  An asset kept on the local disk while its object store was down is put in
  the bucket once the store answers: uploaded, read back and checked against
  its hash before it is recorded as placed, with the local copy kept. A pass
  is idempotent, leaves an asset pending while the store is still down, and
  resolves an asset whose workspace now keeps assets on disk.

  A stored path is data a bundle import can write, so a pass reads only a
  regular file under the Engine's root and quarantines a row that names
  anything else, or whose copy does not match its hash. A row that changes
  during a pass is left as the change made it, and a workspace policy that
  cannot be read leaves an asset pending. The pending count and the
  quarantine count are gauges in /api/metrics, read from a cached count.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Plug.Test

  alias OptimalEngine.{MemoryCore, Store, WorkspaceTopology}
  alias OptimalEngine.Storage.{AssetReconcile, PolicyStore}
  alias OptimalEngine.TestSupport.S3Stub

  @pending_gauge "optimal_engine_storage_assets_pending_placement"
  @quarantined_gauge "optimal_engine_storage_assets_placement_quarantined"

  defmodule PutHook do
    @moduledoc false
    # The S3 stub, with a function run when an object is put, so a test can
    # change a row between the upload and the record of it.
    @behaviour Plug

    @impl Plug
    def init(opts), do: opts

    @impl Plug
    def call(conn, opts) do
      if conn.method == "PUT", do: Keyword.fetch!(opts, :on_put).()
      S3Stub.call(conn, agent: Keyword.fetch!(opts, :agent))
    end
  end

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

  defp run(ctx, opts \\ []),
    do: AssetReconcile.run(Keyword.put(opts, :workspace_id, ctx.workspace.id))

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

  test "a local copy that no longer matches its hash is quarantined and not retried", ctx do
    outage(ctx.stub)
    {changed, _bytes} = kept_on_disk(ctx, "changed.bin")
    {intact, _bytes} = kept_on_disk(ctx, "intact.bin")
    File.write!(changed.storage_path, "not the bytes the asset was stored with")

    # The changed asset is the oldest, so a pass of one looks at nothing else.
    set_created_at(changed, "2020-01-01 00:00:00")
    set_created_at(intact, "2020-01-02 00:00:00")
    point_at(ctx.stub)

    log =
      capture_log(fn ->
        assert {:ok, %{placed: 0, failed: 0, quarantined: 1, pending: 1}} = run(ctx, limit: 1)
      end)

    assert log =~ "quarantined"
    assert S3Stub.object_keys(ctx.stub.agent) == []

    assert {_path,
            %{
              "storage_placement_quarantined" => "local_copy_differs",
              "storage_placement_quarantined_at" => _,
              "storage_fallback_reason" => "s3_upload_failed"
            }} = row(changed.id)

    assert gauge(@quarantined_gauge) >= 1

    # The next pass does not try it again: it reaches the intact asset behind it.
    assert {:ok, %{placed: 1, failed: 0, quarantined: 0, pending: 0}} = run(ctx, limit: 1)
    assert {_path, %{"storage_backend" => "s3"}} = row(intact.id)
    assert {_path, %{"storage_placement_quarantined" => _}} = row(changed.id)
  end

  test "a stored path outside the Engine root is quarantined, never hashed or uploaded", ctx do
    outage(ctx.stub)
    {asset, _bytes} = kept_on_disk(ctx, "outside-root.bin")
    secret = "a file the Engine never stored"
    repoint(asset, outside_file("secret.txt", secret), sha256(secret))

    point_at(ctx.stub)
    capture_log(fn -> assert {:ok, %{placed: 0, quarantined: 1}} = run(ctx) end)

    assert S3Stub.object_keys(ctx.stub.agent) == []
    assert {_path, %{"storage_placement_quarantined" => "outside_root"}} = row(asset.id)
  end

  test "a symlink inside the root that leads outside is quarantined", ctx do
    outage(ctx.stub)
    {asset, _bytes} = kept_on_disk(ctx, "symlink.bin")
    secret = "a file the symlink points at"
    link = Path.join(ctx.tmp, "linked.bin")
    File.ln_s!(outside_file("target.txt", secret), link)
    repoint(asset, link, sha256(secret))

    point_at(ctx.stub)
    capture_log(fn -> assert {:ok, %{placed: 0, quarantined: 1}} = run(ctx) end)

    assert S3Stub.object_keys(ctx.stub.agent) == []
    assert {_path, %{"storage_placement_quarantined" => "outside_root"}} = row(asset.id)
  end

  # A FIFO is covered by the `Assets.confine_local/1` test, which never opens
  # one. It stays out of this file: a FIFO under the Engine root with a writer
  # waiting to open it, or any reader that opens it, blocks the VM's file
  # server, and every later file operation in the suite with it.
  test "a directory where the copy should be is quarantined, not read", ctx do
    outage(ctx.stub)
    {asset, _bytes} = kept_on_disk(ctx, "directory.bin")
    directory = Path.join(ctx.tmp, "directory.bin.d")
    File.mkdir_p!(directory)
    repoint(asset, directory, sha256("whatever a directory would yield"))

    point_at(ctx.stub)
    capture_log(fn -> assert {:ok, %{placed: 0, quarantined: 1}} = run(ctx) end)

    assert S3Stub.object_keys(ctx.stub.agent) == []
    assert {_path, %{"storage_placement_quarantined" => "not_a_regular_file"}} = row(asset.id)
  end

  test "a row changed during the pass is left as the change made it", ctx do
    outage(ctx.stub)
    {asset, _bytes} = kept_on_disk(ctx, "changed-during-pass.bin")
    {_path, metadata} = row(asset.id)
    changed = Map.put(metadata, "imported_during_pass", true)

    endpoint =
      hooked_endpoint(ctx, fn ->
        :ok =
          Store.raw_execute("UPDATE assets SET metadata = ?2 WHERE id = ?1", [
            asset.id,
            Jason.encode!(changed)
          ])
      end)

    point_at(ctx.stub)
    System.put_env("OPTIMAL_S3_ENDPOINT", endpoint)

    log =
      capture_log(fn ->
        assert {:ok, %{placed: 0, superseded: 1, failed: 0}} = run(ctx)
      end)

    refute log =~ "placed in the object store"
    assert {storage_path, ^changed} = row(asset.id)
    assert storage_path == asset.storage_path
  end

  test "a workspace policy that cannot be read leaves the asset pending", ctx do
    outage(ctx.stub)
    {asset, _bytes} = kept_on_disk(ctx, "policy-unreadable.bin")

    # The workspace selects S3 through its policy; the Engine-wide default does not.
    assert {:ok, _policy} =
             PolicyStore.put_policy(ctx.workspace.id, ["media_archive"],
               provider_overrides: %{"s3" => %{"assets" => true}}
             )

    System.delete_env("OPTIMAL_ASSET_STORAGE")
    point_at(ctx.stub)

    capture_log(fn ->
      without_policy_table(fn ->
        assert {:ok, %{resolved: 0, placed: 0, failed: 1, pending: 1}} = run(ctx)
      end)
    end)

    assert {_path, %{"storage_fallback_reason" => "s3_upload_failed"} = metadata} = row(asset.id)
    refute Map.has_key?(metadata, "storage_fallback_resolved")

    # The policy reads again, and the asset is placed where it belongs.
    assert {:ok, %{placed: 1, resolved: 0, pending: 0}} = run(ctx)
    assert {"s3://" <> _, %{"storage_backend" => "s3"}} = row(asset.id)
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

    assert gauge(@pending_gauge) == pending
    assert OptimalEngine.Telemetry.Prometheus.render() =~ "#{@pending_gauge} #{pending}"
    assert OptimalEngine.Telemetry.Prometheus.render() =~ "#{@quarantined_gauge} "
  end

  test "a scrape reads a cached count instead of scanning the assets table", ctx do
    outage(ctx.stub)
    {asset, _bytes} = kept_on_disk(ctx, "cached.bin")

    cached = gauge(@pending_gauge)
    assert cached == AssetReconcile.pending_count()

    # The asset stops being pending behind the cache's back, as an import could do.
    :ok =
      Store.raw_execute(
        "UPDATE assets SET metadata = json_remove(metadata, '$.storage_fallback_reason') WHERE id = ?1",
        [asset.id]
      )

    assert AssetReconcile.pending_count() == cached - 1
    assert gauge(@pending_gauge) == cached

    # The worker's tick refreshes the count.
    assert {:ok, %{pending: pending}} = AssetReconcile.refresh_counts()
    assert pending == cached - 1
    assert gauge(@pending_gauge) == cached - 1
  end

  defp gauge(name), do: Jason.decode!(metrics())["gauges"][name]

  defp metrics do
    conn(:get, "/api/metrics")
    |> OptimalEngine.API.Router.call(OptimalEngine.API.Router.init([]))
    |> Map.fetch!(:resp_body)
  end

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp set_created_at(asset, timestamp) do
    :ok =
      Store.raw_execute("UPDATE assets SET created_at = ?2 WHERE id = ?1", [asset.id, timestamp])
  end

  # The row as a bundle import could write it: the stored path and the hash
  # both name a file the workspace never stored.
  defp repoint(asset, path, hash) do
    {_path, metadata} = row(asset.id)

    :ok =
      Store.raw_execute(
        "UPDATE assets SET storage_path = ?2, content_hash = ?3, metadata = ?4 WHERE id = ?1",
        [asset.id, path, hash, Jason.encode!(Map.put(metadata, "local_path", path))]
      )
  end

  defp outside_file(name, bytes) do
    dir =
      Path.join(System.tmp_dir!(), "asset-reconcile-outside-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    path = Path.join(dir, name)
    File.write!(path, bytes)
    path
  end

  # The S3 stub behind a listener that runs `on_put` for every object put.
  defp hooked_endpoint(ctx, on_put) do
    ref = S3Stub.ref()

    {:ok, _pid} =
      Plug.Cowboy.http(PutHook, [agent: ctx.stub.agent, on_put: on_put], port: 0, ref: ref)

    on_exit(fn -> S3Stub.stop(ref) end)
    "http://127.0.0.1:#{:ranch.get_port(ref)}"
  end

  # Reading a workspace policy fails while `fun` runs: a database error, not an
  # absent policy.
  defp without_policy_table(fun) do
    away = "workspace_storage_policies_away"
    :ok = Store.raw_execute("ALTER TABLE workspace_storage_policies RENAME TO #{away}")

    try do
      fun.()
    after
      :ok = Store.raw_execute("ALTER TABLE #{away} RENAME TO workspace_storage_policies")
    end
  end
end
