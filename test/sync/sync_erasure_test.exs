defmodule OptimalEngine.SyncErasureTest do
  @moduledoc """
  A context a peer deleted (an erasure, a retention delete, a move) is deleted here by the
  sync, and what this Engine cached from its workspace's text goes with it.
  """

  use ExUnit.Case, async: false

  alias OptimalEngine.Embed.Text
  alias OptimalEngine.{Store, Sync, Workspace}
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
