defmodule OptimalEngine.API.SignalClassificationTest do
  @moduledoc """
  `GET /api/signals/classification`: a workspace's Signals counted by genre
  and mode, as stored and as re-running classification would set them,
  without writing and without any content leaving the Engine.
  """

  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias OptimalEngine.API.Router
  alias OptimalEngine.Auth.ApiKey
  alias OptimalEngine.Store
  alias OptimalEngine.Tenancy.Tenant

  @transcript "Alice: Thanks for joining, we review the import plan.\nBob: Staging is done.\nAlice: Then we require a dry run first."
  @route "/api/signals/classification"
  @prose "Observed that the nightly export took forty minutes again. Worth checking the index window."

  setup do
    n = System.unique_integer([:positive])
    tenant = "classify-#{n}"
    {:ok, _} = Tenant.create(%{id: tenant, name: "Classify #{n}"})
    workspace = "#{tenant}:ops"
    other = "#{tenant}:other"

    for {id, slug} <- [{workspace, "ops"}, {other, "other"}] do
      {:ok, _} =
        Store.raw_query(
          "INSERT INTO workspaces (id, tenant_id, slug, name, status, metadata) VALUES (?1, ?2, ?3, ?3, 'active', '{}')",
          [id, tenant, slug]
        )
    end

    # Stored the way older intake stored them: transcripts and chats as code.
    insert(tenant, workspace, "t1-#{n}", @transcript, "code", "transcript")
    insert(tenant, workspace, "t2-#{n}", @transcript, "code", "transcript")
    insert(tenant, workspace, "c1-#{n}", @prose, "code", "chat")
    insert(tenant, other, "o1-#{n}", @prose, "code", "transcript")

    %{n: n, tenant: tenant, workspace: workspace, other: other}
  end

  defp insert(tenant, workspace, id, content, mode, genre) do
    {:ok, _} =
      Store.raw_query(
        """
        INSERT INTO contexts (id, tenant_id, workspace_id, uri, title, node, type, mode,
                              genre, content, l0_abstract, l1_overview, created_at, metadata)
        VALUES (?1, ?2, ?3, ?4, ?5, 'inbox', 'signal', ?6, ?7, ?8, '', '',
                '2026-10-18T09:00:00Z', '{}')
        """,
        [id, tenant, workspace, "optimal://inbox/#{id}.md", "Title #{id}", mode, genre, content]
      )
  end

  defp request(path, token) do
    conn(:get, path)
    |> put_req_header("authorization", "Bearer " <> token)
    |> Router.call(Router.init([]))
  end

  defp key(tenant, workspaces) do
    {:ok, %{key: key}} =
      ApiKey.mint(%{
        tenant_id: tenant,
        name: "classification",
        scopes: ["read"],
        workspace_scope: workspaces
      })

    key
  end

  test "counts the stored Signals by genre and mode, for one workspace only", %{
    tenant: tenant,
    workspace: workspace
  } do
    response = request("#{@route}?workspace=#{workspace}", key(tenant, [workspace]))

    assert response.status == 200
    body = Jason.decode!(response.resp_body)
    assert body["workspace_id"] == workspace
    assert body["signals"] == 3
    assert body["stored"] == %{"transcript" => %{"code" => 2}, "chat" => %{"code" => 1}}
    refute Map.has_key?(body, "plan")
  end

  test "plan=true reports what re-running classification sets, and writes nothing", %{
    n: n,
    tenant: tenant,
    workspace: workspace
  } do
    response = request("#{@route}?workspace=#{workspace}&plan=true", key(tenant, [workspace]))

    assert response.status == 200
    plan = Jason.decode!(response.resp_body)["plan"]
    assert plan["scanned"] == 3
    assert plan["changes"] == 3

    assert plan["planned"] == %{
             "transcript" => %{"linguistic" => 2},
             "note" => %{"linguistic" => 1}
           }

    assert plan["planned_modes_by_stored_genre"] == %{
             "transcript" => %{"linguistic" => 2},
             "chat" => %{"linguistic" => 1}
           }

    assert %{"from" => "code", "to" => "linguistic", "count" => 3} in plan["mode_transitions"]
    assert %{"from" => "chat", "to" => "note", "count" => 1} in plan["genre_transitions"]

    assert {:ok, [["code", "transcript"]]} =
             Store.raw_query("SELECT mode, genre FROM contexts WHERE id = ?1", ["t1-#{n}"])
  end

  test "the answer carries counts only, never content, titles, or ids", %{
    n: n,
    tenant: tenant,
    workspace: workspace
  } do
    response = request("#{@route}?workspace=#{workspace}&plan=true", key(tenant, [workspace]))

    for fragment <- ["Alice", "nightly export", "Title ", "t1-#{n}", "optimal://"] do
      refute response.resp_body =~ fragment
    end
  end

  test "a key for another workspace is refused", %{
    tenant: tenant,
    workspace: workspace,
    other: other
  } do
    response = request("#{@route}?workspace=#{workspace}", key(tenant, [other]))
    assert response.status == 403
  end
end
