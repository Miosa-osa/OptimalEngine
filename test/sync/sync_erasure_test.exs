defmodule OptimalEngine.SyncErasureTest do
  @moduledoc """
  A context a peer deleted (an erasure, a retention delete, a move) is deleted here by the
  sync, and what this Engine cached from its workspace's text goes with it.
  """

  use ExUnit.Case, async: false

  alias OptimalEngine.Embed.Text
  alias OptimalEngine.{Store, Sync, Workspace}
  alias OptimalEngine.Workspace.Filesystem
  alias OptimalEngine.Tenancy.Tenant
  alias OptimalEngine.TestSupport.EmbedStub

  setup do
    n = System.unique_integer([:positive])
    tenant = "sync-erase-#{n}"
    saved = Map.new([:cache_path, :text_embedding], &{&1, Application.get_env(:optimal_engine, &1)})
    dir = Path.join(System.tmp_dir!(), "sync-erase-#{n}")
    Application.put_env(:optimal_engine, :cache_path, dir)
    {url, stop} = EmbedStub.start()
    Application.put_env(:optimal_engine, :text_embedding, url: url, dimensions: 4)

    on_exit(fn ->
      stop.()

      Enum.each(saved, fn
        {name, nil} -> Application.delete_env(:optimal_engine, name)
        {name, value} -> Application.put_env(:optimal_engine, name, value)
      end)

      File.rm_rf(dir)
    end)

    {:ok, _} = Tenant.create(%{id: tenant, name: "Sync erase #{n}"})

    {:ok, _} =
      OptimalEngine.Organization.create(%{
        id: "#{tenant}:org",
        tenant_id: tenant,
        slug: "org",
        name: "Org"
      })

    {:ok, ws} =
      Workspace.create(%{
        tenant_id: tenant,
        organization_id: "#{tenant}:org",
        slug: "notes",
        name: "Notes"
      })

    {:ok, bystander} =
      Workspace.create(%{
        tenant_id: tenant,
        organization_id: "#{tenant}:org",
        slug: "bystander",
        name: "Bystander"
      })

    {:ok, _} = Sync.enable(tenant, ws.id, "user:owner")
    %{n: n, tenant: tenant, ws: ws.id, bystander: bystander.id, dir: dir}
  end

  test "deleting a context here from a peer's delete purges the workspace's cache", ctx do
    {:ok, _} = Text.embed("erased text #{ctx.n}", tenant_id: ctx.tenant, workspace_id: ctx.ws)
    {:ok, _} = Text.embed("kept text #{ctx.n}", tenant_id: ctx.tenant, workspace_id: ctx.bystander)
    assert length(cache_files(ctx.dir)) == 2

    id = "ctx-#{ctx.n}"

    create =
      mutation(%{
        "operation" => "create",
        "occurred_at" => "2026-10-14T12:00:00.000",
        "payload" => context_row(id, ctx)
      })

    # An ordinary change purges nothing.
    assert {:ok, %{applied: 1}} = Sync.apply_changes(ctx.tenant, ctx.ws, [create])
    assert length(cache_files(ctx.dir)) == 2

    delete =
      mutation(%{
        "operation" => "delete",
        "entity_id" => id,
        "occurred_at" => "2026-10-14T12:05:00.000",
        "payload" => %{"row" => %{"id" => id}, "blobs" => %{}}
      })

    assert {:ok, %{applied: 1}} = Sync.apply_changes(ctx.tenant, ctx.ws, [delete])

    assert {:ok, []} = Store.raw_query("SELECT 1 FROM contexts WHERE id = ?1", [id])
    assert length(cache_files(ctx.dir)) == 1
  end

  describe "the files of the contexts a peer deleted" do
    test "go with them, and no other run's checkpoint or asset does", ctx do
      gone = local_work!(ctx, "gone")
      kept = local_work!(ctx, "kept")
      create = [create_context(ctx, gone), create_context(ctx, kept)]
      assert {:ok, %{applied: 2}} = Sync.apply_changes(ctx.tenant, ctx.ws, create)

      assert {:ok, %{applied: 1}} =
               Sync.apply_changes(ctx.tenant, ctx.ws, [delete_context(gone.context)])

      refute File.exists?(gone.checkpoint)
      refute File.exists?(gone.asset_file)
      assert pointer(gone.run) == nil

      # Work of a context that stays, or one under way, keeps its files.
      assert File.exists?(kept.checkpoint)
      assert File.exists?(kept.asset_file)
      assert pointer(kept.run) == kept.checkpoint
    end

    test "stay while another context of the package remains", ctx do
      first = local_work!(ctx, "first")
      second = %{local_work!(ctx, "second") | package: first.package}
      create = [create_context(ctx, first), create_context(ctx, second)]
      assert {:ok, %{applied: 2}} = Sync.apply_changes(ctx.tenant, ctx.ws, create)

      assert {:ok, %{applied: 1}} =
               Sync.apply_changes(ctx.tenant, ctx.ws, [delete_context(first.context)])

      assert File.exists?(first.checkpoint)

      assert {:ok, %{applied: 1}} =
               Sync.apply_changes(ctx.tenant, ctx.ws, [delete_context(second.context)])

      refute File.exists?(first.checkpoint)
    end

    test "are not touched when the delete does not take the context", ctx do
      other = local_work!(ctx, "other-workspace")

      # A context of another workspace: a delete applied under this one's cannot remove it.
      {:ok, _} =
        Store.raw_query(
          """
          INSERT INTO contexts (id, tenant_id, workspace_id, uri, title, content, metadata, genre, node)
          VALUES (?1, ?2, ?3, ?4, 't', 'text', ?5, 'note', 'person-operator')
          """,
          [
            other.context,
            ctx.tenant,
            ctx.bystander,
            "optimal://sync-erase/#{other.context}",
            Jason.encode!(%{"source_package_id" => other.package})
          ]
        )

      Sync.apply_changes(ctx.tenant, ctx.ws, [delete_context(other.context)])

      assert {:ok, [[1]]} =
               Store.raw_query("SELECT COUNT(*) FROM contexts WHERE id = ?1", [other.context])

      assert File.exists?(other.checkpoint)
      assert File.exists?(other.asset_file)
    end
  end

  # What this Engine itself made from a context's source package: a decomposition run with
  # its checkpoint file and an asset with its bytes. Neither is replicated.
  defp local_work!(ctx, label) do
    id = "#{label}-#{ctx.n}"
    package = "pkg-#{id}"
    run = "run-#{id}"
    checkpoint = Path.join(ctx.dir, "decomposition/#{run}.json")
    root = Application.get_env(:optimal_engine, :root_path, File.cwd!())
    asset_file = Path.join([Filesystem.path(root, ctx.ws), "assets", "ab", "#{id}.bin"])

    File.mkdir_p!(Path.dirname(checkpoint))

    File.write!(
      checkpoint,
      Jason.encode!(%{run_id: run, workspace_id: ctx.ws, output: %{chunks: [%{text: id}]}})
    )

    File.mkdir_p!(Path.dirname(asset_file))
    File.write!(asset_file, "bytes of #{id}")
    on_exit(fn -> File.rm(asset_file) end)

    {:ok, _} =
      Store.raw_query(
        "INSERT INTO source_packages (id, content_hash, raw_text) VALUES (?1, ?2, 'raw')",
        [package, "hash-#{id}"]
      )

    {:ok, _} =
      Store.raw_query(
        """
        INSERT INTO decomposition_runs (id, tenant_id, organization_id, workspace_id, source_package_id, strategy, checkpoint_uri)
        VALUES (?1, ?2, 'org', ?3, ?4, 'deterministic', ?5)
        """,
        [run, ctx.tenant, ctx.ws, package, checkpoint]
      )

    {:ok, _} =
      Store.raw_query(
        """
        INSERT INTO assets (id, tenant_id, content_type, size_bytes, storage_path, workspace_id, source_package_id)
        VALUES (?1, ?2, 'application/octet-stream', 10, ?3, ?4, ?5)
        """,
        ["asset-#{id}", ctx.tenant, asset_file, ctx.ws, package]
      )

    %{
      context: "ctx-#{id}",
      package: package,
      run: run,
      checkpoint: checkpoint,
      asset_file: asset_file
    }
  end

  defp create_context(ctx, work) do
    row = context_row(work.context, ctx)

    mutation(%{
      "operation" => "create",
      "occurred_at" => "2026-10-14T12:00:00.000",
      "payload" =>
        put_in(row, ["row", "metadata"], Jason.encode!(%{"source_package_id" => work.package}))
    })
  end

  defp delete_context(id) do
    mutation(%{
      "operation" => "delete",
      "entity_id" => id,
      "occurred_at" => "2026-10-14T12:05:00.000",
      "payload" => %{"row" => %{"id" => id}, "blobs" => %{}}
    })
  end

  defp pointer(run) do
    {:ok, [[uri]]} =
      Store.raw_query("SELECT checkpoint_uri FROM decomposition_runs WHERE id = ?1", [run])

    uri
  end

  defp mutation(attrs) do
    Map.merge(
      %{
        "id" => "mut_remote_#{System.unique_integer([:positive])}",
        "device_id" => "rep_remote",
        "entity_type" => "contexts"
      },
      attrs
    )
    |> then(fn m -> Map.put_new(m, "entity_id", get_in(m, ["payload", "row", "id"])) end)
  end

  defp context_row(id, ctx) do
    %{
      "row" => %{
        "id" => id,
        "title" => "From a peer",
        "content" => "remote body",
        "workspace_id" => ctx.ws,
        "tenant_id" => ctx.tenant
      },
      "blobs" => %{}
    }
  end

  defp cache_files(dir) do
    dir |> Path.join("**/*") |> Path.wildcard(match_dot: true) |> Enum.filter(&File.regular?/1)
  end
end
