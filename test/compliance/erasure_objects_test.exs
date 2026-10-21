defmodule OptimalEngine.Compliance.ErasureObjectsTest do
  @moduledoc """
  Erasing a context deletes the objects of its assets from the object store the Engine is
  configured for, and only those: not an object another asset still uses, not one in another
  bucket or outside the asset's workspace prefix, and none when no store is configured.
  Archiving and moving a workspace delete no object.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias OptimalEngine.Compliance.{Artifacts, DerivedData, Erasure, Retention}
  alias OptimalEngine.Identity.Principal
  alias OptimalEngine.Storage.S3
  alias OptimalEngine.Store
  alias OptimalEngine.TestSupport.S3Stub
  alias OptimalEngine.Workspace

  @s3_env ~w(OPTIMAL_S3_ENDPOINT OPTIMAL_S3_BUCKET OPTIMAL_S3_REGION OPTIMAL_S3_ACCESS_KEY_ID
             OPTIMAL_S3_SECRET_ACCESS_KEY OPTIMAL_S3_PREFIX OPTIMAL_S3_PATH_STYLE
             OPTIMAL_S3_MAX_RETRIES OPTIMAL_S3_CREDENTIALS_FILE)

  setup do
    previous = Map.new(@s3_env, &{&1, System.get_env(&1)})
    Enum.each(@s3_env, &System.delete_env/1)

    ref = S3Stub.ref()
    on_exit(fn -> S3Stub.stop(ref) end)
    {:ok, stub} = S3Stub.start(ref: ref, bucket: "engine-test")

    on_exit(fn ->
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    point_at(stub)
    System.put_env("OPTIMAL_S3_MAX_RETRIES", "0")
    %{stub: stub, n: System.unique_integer([:positive])}
  end

  defp point_at(stub) do
    System.put_env("OPTIMAL_S3_ENDPOINT", stub.endpoint)
    System.put_env("OPTIMAL_S3_BUCKET", stub.bucket)
    System.put_env("OPTIMAL_S3_ACCESS_KEY_ID", stub.access_key_id)
    System.put_env("OPTIMAL_S3_SECRET_ACCESS_KEY", stub.secret_access_key)
    System.put_env("OPTIMAL_S3_REGION", stub.region)
  end

  test "deletes the objects of the erased contexts' assets and no other", ctx do
    gone = seed!(ctx, "gone")
    kept = seed!(ctx, "kept")
    assert Enum.sort(keys(ctx)) == Enum.sort([gone.key, kept.key])

    assert {:ok, %{assets: 1}} = DerivedData.erase_contexts("default", [gone.context])

    assert keys(ctx) == [kept.key]
    assert count("assets", "id", gone.asset) == 0
    assert count("assets", "id", kept.asset) == 1
  end

  test "leaves an object that an asset which stays also uses", ctx do
    gone = seed!(ctx, "shared-gone")
    kept = seed!(ctx, "shared-kept")

    {:ok, _} =
      Store.raw_query("UPDATE assets SET storage_path = ?1 WHERE id = ?2", [gone.uri, kept.asset])

    assert {:ok, _} = DerivedData.erase_contexts("default", [gone.context])

    assert gone.key in keys(ctx)
  end

  test "leaves an object outside the asset's workspace prefix, or in another bucket", ctx do
    outside =
      seed!(ctx, "outside",
        key: S3.object_key(["another-tenant", "default", "assets", "ab", "outside-#{ctx.n}.bin"])
      )

    elsewhere = seed!(ctx, "elsewhere")

    {:ok, _} =
      Store.raw_query("UPDATE assets SET storage_path = ?1 WHERE id = ?2", [
        "s3://another-bucket/" <> elsewhere.key,
        elsewhere.asset
      ])

    assert {:ok, _} = DerivedData.erase_contexts("default", [outside.context, elsewhere.context])

    for seeded <- [outside, elsewhere], do: assert(seeded.key in keys(ctx))
    assert count("assets", "id", outside.asset) == 0
    assert deletes(ctx) == []
  end

  test "a forged asset row deletes no object of another workspace", ctx do
    gone = seed!(ctx, "forged-gone")

    victim_key =
      S3.object_key(["default", "default:victim", "assets", "ab", "victim-#{ctx.n}.bin"])

    {:ok, _} = S3.put_object(victim_key, "another workspace's bytes")

    # Rows of the erased package that name the other workspace's object: one says it is in
    # the erased workspace (the key is not under that workspace's prefix), one says it is in
    # the other workspace (which none of the erased contexts is in).
    for {workspace, i} <- Enum.with_index(["default", "default:victim"]) do
      sql!(
        """
        INSERT INTO assets (id, tenant_id, content_type, size_bytes, storage_path, workspace_id, source_package_id)
        VALUES (?1, 'default', 'application/octet-stream', 1, ?2, ?3, ?4)
        """,
        ["forged-#{ctx.n}-#{i}", S3.uri(victim_key), workspace, gone.package]
      )
    end

    assert {:ok, %{assets: 3}} = DerivedData.erase_contexts("default", [gone.context])

    assert keys(ctx) == [victim_key]
    assert length(deletes(ctx)) == 1
  end

  test "never asks the store to delete a key that climbs out of the prefix", ctx do
    climbing = seed!(ctx, "climbing")

    key =
      S3.object_key([
        "default",
        "default",
        "assets",
        "ab",
        "..",
        "..",
        "..",
        "another-tenant",
        "x.bin"
      ])

    {:ok, _} =
      Store.raw_query("UPDATE assets SET storage_path = ?1 WHERE id = ?2", [
        S3.uri(key),
        climbing.asset
      ])

    assert {:ok, _} = DerivedData.erase_contexts("default", [climbing.context])

    assert deletes(ctx) == []
    assert climbing.key in keys(ctx)
  end

  test "deletes no object when no object store is configured", ctx do
    seeded = seed!(ctx, "unconfigured")
    Enum.each(@s3_env, &System.delete_env/1)

    assert {:ok, %{assets: 1}} = DerivedData.erase_contexts("default", [seeded.context])

    assert seeded.key in keys(ctx)
    assert count("contexts", "id", seeded.context) == 0
  end

  test "a store whose settings cannot be read is an error and the rows stay", ctx do
    seeded = seed!(ctx, "unreadable")
    System.delete_env("OPTIMAL_S3_ACCESS_KEY_ID")
    System.delete_env("OPTIMAL_S3_SECRET_ACCESS_KEY")
    System.put_env("OPTIMAL_S3_CREDENTIALS_FILE", "/nonexistent/credentials-#{ctx.n}")

    # Not "no store configured": the Engine has one it cannot use, and deleting the rows
    # would leave the object with nothing that points at it.
    assert {:error, {:artifact_not_removed, :asset_object, :credentials_file_unreadable}} =
             DerivedData.erase_contexts("default", [seeded.context])

    assert seeded.key in keys(ctx)
    assert count("contexts", "id", seeded.context) == 1
    assert count("assets", "id", seeded.asset) == 1

    System.delete_env("OPTIMAL_S3_CREDENTIALS_FILE")
    point_at(ctx.stub)
    assert {:ok, _} = DerivedData.erase_contexts("default", [seeded.context])
    refute seeded.key in keys(ctx)
  end

  test "an object the store no longer has is gone, not an error that stops every run", ctx do
    seeded = seed!(ctx, "missing")

    # A bucket the store does not have answers a delete with 404.
    System.put_env("OPTIMAL_S3_BUCKET", "bucket-that-is-gone")

    {:ok, _} =
      Store.raw_query("UPDATE assets SET storage_path = ?1 WHERE id = ?2", [
        "s3://bucket-that-is-gone/" <> seeded.key,
        seeded.asset
      ])

    assert {:ok, %{assets: 1}} = DerivedData.erase_contexts("default", [seeded.context])

    assert count("contexts", "id", seeded.context) == 0
    assert count("assets", "id", seeded.asset) == 0
  end

  describe "an object the store is not asked to delete" do
    test "is counted by reason and logged, without a key", ctx do
      seeded = seed!(ctx, "counted")
      elsewhere = S3.object_key(["another-tenant", "default", "assets", "ab", "x-#{ctx.n}.bin"])

      log =
        capture_log(fn ->
          send(
            self(),
            {:result,
             Artifacts.remove([
               {:asset_object, "s3://another-bucket/" <> seeded.key, "default", "default"},
               {:asset_object, S3.uri(elsewhere), "default", "default"},
               {:asset_object, "not an address", "default", "default"}
             ])}
          )
        end)

      assert_received {:result, {:ok, result}}
      assert result.files == 0

      assert result.skipped == %{
               asset_object: %{other_bucket: 1, outside_prefix: 1, not_ours: 1}
             }

      assert log =~ "left alone"
      refute log =~ seeded.key
      assert deletes(ctx) == []
    end

    test "is counted as not configured when the Engine has no store", ctx do
      seeded = seed!(ctx, "not-configured")
      Enum.each(@s3_env, &System.delete_env/1)

      assert {:ok, %{skipped: %{asset_object: %{not_configured: 1}}}} =
               Artifacts.remove([{:asset_object, seeded.uri, "default", "default"}])

      assert seeded.key in keys(ctx)
    end
  end

  test "an object that cannot be deleted leaves the rows, and the next run finishes", ctx do
    seeded = seed!(ctx, "refused")
    good = System.get_env("OPTIMAL_S3_SECRET_ACCESS_KEY")
    System.put_env("OPTIMAL_S3_SECRET_ACCESS_KEY", "not-the-secret")

    assert {:error, {:artifact_not_removed, :asset_object, :access_denied}} =
             DerivedData.erase_contexts("default", [seeded.context])

    assert seeded.key in keys(ctx)
    assert count("contexts", "id", seeded.context) == 1
    assert count("assets", "id", seeded.asset) == 1

    System.put_env("OPTIMAL_S3_SECRET_ACCESS_KEY", good)
    assert {:ok, _} = DerivedData.erase_contexts("default", [seeded.context])
    refute seeded.key in keys(ctx)
  end

  test "erasing a principal deletes the objects of their assets", ctx do
    principal = "user:objects-#{ctx.n}@test"
    {:ok, _} = Principal.upsert(%{id: principal, kind: :user, display_name: "Subject"})
    gone = seed!(ctx, "principal")
    kept = seed!(ctx, "bystander")

    {:ok, _} =
      Store.raw_query("UPDATE contexts SET created_by = ?1 WHERE id = ?2", [
        principal,
        gone.context
      ])

    assert {:ok, report} = Erasure.erase(principal)

    assert report.deleted.assets == 1
    assert keys(ctx) == [kept.key]
  end

  test "a retention delete deletes the objects of the context's assets", ctx do
    tenant = "objects-ret-#{ctx.n}"

    {:ok, _} =
      Retention.add_policy(tenant_id: tenant, scope_type: "tenant", ttl_days: 1, action: "delete")

    seeded = seed!(ctx, "retention", tenant: tenant)

    {:ok, _} =
      Store.raw_query("UPDATE contexts SET created_at = '2020-01-01T00:00:00Z' WHERE id = ?1", [
        seeded.context
      ])

    assert {:ok, %{actions_taken: 1, errors: 0}} = Retention.sweep(tenant_id: tenant)

    refute seeded.key in keys(ctx)
  end

  test "archiving a workspace deletes no object", ctx do
    {:ok, workspace} = Workspace.create(%{slug: "objects-archive-#{ctx.n}", name: "Archive"})
    seeded = seed!(ctx, "archived", workspace: workspace.id)

    assert :ok = Workspace.archive(workspace.id)

    assert seeded.key in keys(ctx)
  end

  test "the purge a move runs deletes no object either", ctx do
    {:ok, workspace} = Workspace.create(%{slug: "objects-move-#{ctx.n}", name: "Move"})
    seeded = seed!(ctx, "moved", workspace: workspace.id)

    assert {:ok, _} = Artifacts.purge_workspace(workspace.id)

    assert seeded.key in keys(ctx)
  end

  # ── seed data ──────────────────────────────────────────────────────────────

  # A context with a source package and an asset whose bytes are an object in the store.
  defp seed!(ctx, label, opts \\ []) do
    tenant = Keyword.get(opts, :tenant, "default")
    workspace = Keyword.get(opts, :workspace, "default")
    id = "#{label}-#{ctx.n}"

    key =
      Keyword.get_lazy(opts, :key, fn ->
        S3.object_key([tenant, workspace, "assets", "ab", "#{id}.bin"])
      end)

    {:ok, _} = S3.put_object(key, "bytes of #{id}")
    uri = S3.uri(key)

    sql!(
      "INSERT INTO source_packages (id, tenant_id, workspace_id, content_hash, raw_text) VALUES (?1, ?2, ?3, ?4, 'raw')",
      ["pkg-#{id}", tenant, workspace, "hash-#{id}"]
    )

    sql!(
      """
      INSERT INTO contexts (id, tenant_id, workspace_id, uri, title, content, genre, node, metadata)
      VALUES (?1, ?2, ?3, ?4, 't', 'text', 'note', 'person-operator', ?5)
      """,
      [
        "ctx-#{id}",
        tenant,
        workspace,
        "optimal://objects/#{id}",
        Jason.encode!(%{"source_package_id" => "pkg-#{id}"})
      ]
    )

    sql!(
      """
      INSERT INTO assets (id, tenant_id, content_type, size_bytes, storage_path, workspace_id, source_package_id)
      VALUES (?1, ?2, 'application/octet-stream', 10, ?3, ?4, ?5)
      """,
      ["asset-#{id}", tenant, uri, workspace, "pkg-#{id}"]
    )

    %{context: "ctx-#{id}", package: "pkg-#{id}", asset: "asset-#{id}", key: key, uri: uri}
  end

  defp keys(ctx), do: ctx.stub.agent |> S3Stub.object_keys() |> Enum.sort()

  # The requests the store was asked to delete with.
  defp deletes(ctx),
    do: ctx.stub.agent |> S3Stub.requests() |> Enum.filter(&(&1.method == "DELETE"))

  defp sql!(sql, params) do
    {:ok, _} = Store.raw_query(sql, params)
    :ok
  end

  defp count(table, column, value) do
    {:ok, [[n]]} = Store.raw_query("SELECT COUNT(*) FROM #{table} WHERE #{column} = ?1", [value])
    n
  end
end
