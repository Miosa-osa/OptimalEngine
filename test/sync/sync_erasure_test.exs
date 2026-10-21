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

    test "stay when a context created in the same batch refers to the package", ctx do
      first = local_work!(ctx, "first-in-batch")
      second = %{local_work!(ctx, "second-in-batch") | package: first.package}

      assert {:ok, %{applied: 1}} =
               Sync.apply_changes(ctx.tenant, ctx.ws, [create_context(ctx, first)])

      # The package looks like the first context's alone until the batch has been applied.
      batch = [create_context(ctx, second), delete_context(first.context)]
      assert {:ok, %{applied: 2}} = Sync.apply_changes(ctx.tenant, ctx.ws, batch)

      assert {:ok, [[0]]} =
               Store.raw_query("SELECT COUNT(*) FROM contexts WHERE id = ?1", [first.context])

      assert {:ok, [[1]]} =
               Store.raw_query("SELECT COUNT(*) FROM contexts WHERE id = ?1", [second.context])

      assert File.exists?(first.checkpoint)
      assert File.exists?(first.asset_file)
      assert pointer(first.run) == first.checkpoint
    end

    test "come with the rows this Engine made from the package, and the text in them", ctx do
      gone = local_work!(ctx, "rows-gone")
      kept = local_work!(ctx, "rows-kept")
      create = [create_context(ctx, gone), create_context(ctx, kept)]
      assert {:ok, %{applied: 2}} = Sync.apply_changes(ctx.tenant, ctx.ws, create)

      assert {:ok, %{applied: 1}} =
               Sync.apply_changes(ctx.tenant, ctx.ws, [delete_context(gone.context)])

      for {table, id} <- [
            {"decomposition_runs", gone.run},
            {"assets", gone.asset},
            {"asset_extractions", gone.extraction}
          ] do
        assert rows(table, id) == 0, "#{table} still holds the deleted context's row"
      end

      for {table, id} <- [
            {"decomposition_runs", kept.run},
            {"assets", kept.asset},
            {"asset_extractions", kept.extraction}
          ] do
        assert rows(table, id) == 1, "#{table} lost another context's row"
      end
    end

    test "are swept when only the source package is deleted", ctx do
      work = local_work!(ctx, "package-only")

      assert {:ok, %{applied: 1}} =
               Sync.apply_changes(ctx.tenant, ctx.ws, [delete_package(work.package)])

      assert rows("source_packages", work.package) == 0
      refute File.exists?(work.checkpoint)
      refute File.exists?(work.asset_file)
      assert rows("decomposition_runs", work.run) == 0
      assert rows("assets", work.asset) == 0
      assert rows("asset_extractions", work.extraction) == 0
    end

    test "stay when a context here still refers to the package that was deleted", ctx do
      work = local_work!(ctx, "package-held")

      assert {:ok, %{applied: 1}} =
               Sync.apply_changes(ctx.tenant, ctx.ws, [create_context(ctx, work)])

      Sync.apply_changes(ctx.tenant, ctx.ws, [delete_package(work.package)])

      assert File.exists?(work.checkpoint)
      assert File.exists?(work.asset_file)
      assert rows("decomposition_runs", work.run) == 1
      assert rows("asset_extractions", work.extraction) == 1
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
        "INSERT INTO source_packages (id, tenant_id, workspace_id, content_hash, raw_text) VALUES (?1, ?2, ?3, ?4, 'raw')",
        [package, ctx.tenant, ctx.ws, "hash-#{id}"]
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

    {:ok, _} =
      Store.raw_query(
        """
        INSERT INTO asset_adapter_runs (id, tenant_id, workspace_id, asset_id, adapter_id, adapter_role, modality, status, started_at)
        VALUES (?1, ?2, ?3, ?4, 'test', 'ocr', 'text', 'ok', datetime('now'))
        """,
        ["adapter-#{id}", ctx.tenant, ctx.ws, "asset-#{id}"]
      )

    {:ok, _} =
      Store.raw_query(
        """
        INSERT INTO asset_extractions (id, tenant_id, workspace_id, asset_id, adapter_run_id, extraction_type, modality, content_text)
        VALUES (?1, ?2, ?3, ?4, ?5, 'text', 'text', ?6)
        """,
        [
          "extraction-#{id}",
          ctx.tenant,
          ctx.ws,
          "asset-#{id}",
          "adapter-#{id}",
          "text read from #{id}"
        ]
      )

    %{
      context: "ctx-#{id}",
      package: package,
      run: run,
      asset: "asset-#{id}",
      extraction: "extraction-#{id}",
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

  defp delete_package(id) do
    mutation(%{
      "operation" => "delete",
      "entity_type" => "source_packages",
      "entity_id" => id,
      "occurred_at" => "2026-10-14T12:06:00.000",
      "payload" => %{"row" => %{"id" => id}, "blobs" => %{}}
    })
  end

  defp rows(table, id) do
    {:ok, [[n]]} = Store.raw_query("SELECT COUNT(*) FROM #{table} WHERE id = ?1", [id])
    n
  end

  defp pointer(run) do
    case Store.raw_query("SELECT checkpoint_uri FROM decomposition_runs WHERE id = ?1", [run]) do
      {:ok, [[uri]]} -> uri
      {:ok, []} -> nil
    end
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
