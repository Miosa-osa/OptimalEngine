defmodule OptimalEngine.SyncRemoteWorkspaceTest do
  @moduledoc """
  A peer whose workspace has another id on the other Engine (MIO-1101): a
  laptop Engine keeps an organization in a tenant of its own, so its
  `<tenant>:<slug>` workspace id differs from the cloud Engine's. Every request
  to the peer names the peer's id; the peer is kept under the local one.
  """

  use ExUnit.Case, async: false

  alias OptimalEngine.{Sync, Workspace}
  alias OptimalEngine.Tenancy.Tenant

  @relay "relay+https://api.example/api/v1/engines/e1/sync"
  @remote "default:agency"

  setup do
    n = System.unique_integer([:positive])
    tenant = "org-#{n}"
    {:ok, _} = Tenant.create(%{id: tenant, name: "Org #{n}"})

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
        slug: "agency",
        name: "Agency"
      })

    previous = System.get_env("CONNECTOR_KEY")
    System.put_env("CONNECTOR_KEY", Base.encode16(:crypto.strong_rand_bytes(32)))
    scheduler = Process.whereis(OptimalEngine.Sync.Scheduler)
    if scheduler, do: :sys.suspend(scheduler, 60_000)

    on_exit(fn ->
      if scheduler && Process.alive?(scheduler), do: :sys.resume(scheduler)
      Application.delete_env(:optimal_engine, :http_mock)

      if previous,
        do: System.put_env("CONNECTOR_KEY", previous),
        else: System.delete_env("CONNECTOR_KEY")
    end)

    %{tenant: tenant, ws: ws.id}
  end

  test "every request to the relay names the peer's workspace id, and the peer stays under the local one",
       ctx do
    refute ctx.ws == @remote
    seen = :ets.new(:seen, [:public, :bag])
    relay(seen)

    assert {:ok, peer} =
             Sync.add_peer(
               ctx.tenant,
               %{
                 "workspace_id" => ctx.ws,
                 "remote_workspace_id" => @remote,
                 "url" => @relay,
                 "api_key" => "relay-key",
                 "policy" => "both"
               },
               "u"
             )

    assert peer.remote_workspace_id == @remote
    assert [%{workspace_id: local, remote_workspace_id: @remote}] = Sync.peers(ctx.tenant, ctx.ws)
    assert local == ctx.ws

    [result] = Sync.run_all() |> Enum.filter(&(&1.workspace_id == ctx.ws))
    assert result.status == "active", inspect(result)

    routes = for {route, workspace} <- :ets.tab2list(seen), do: {route, workspace}
    assert {"status", @remote} in routes
    assert {"pull", @remote} in routes
    refute Enum.any?(routes, fn {_route, workspace} -> workspace == ctx.ws end)
  end

  test "a peer without one names this Engine's workspace id, as before", ctx do
    seen = :ets.new(:seen, [:public, :bag])
    relay(seen)

    {:ok, peer} =
      Sync.add_peer(
        ctx.tenant,
        %{"workspace_id" => ctx.ws, "url" => @relay, "api_key" => "relay-key", "policy" => "pull"},
        "u"
      )

    assert peer.remote_workspace_id == ctx.ws
    [_result] = Sync.run_all() |> Enum.filter(&(&1.workspace_id == ctx.ws))
    assert {"status", ctx.ws} in :ets.tab2list(seen)
  end

  test "a remote workspace id that is not printable text is refused", ctx do
    for bad <- ["", 42, String.duplicate("a", 257), "bad\u0000id"] do
      assert {:error, :invalid_remote_workspace_id} =
               Sync.add_peer(
                 ctx.tenant,
                 %{
                   "workspace_id" => ctx.ws,
                   "remote_workspace_id" => bad,
                   "url" => @relay,
                   "api_key" => "k"
                 },
                 "u"
               )
    end
  end

  # A relay that answers for `@remote` and for the local id of the second test,
  # and records the workspace every request named.
  defp relay(seen) do
    engine = %{
      "replica_id" => "rep_cloud",
      "migration" => Sync.engine_info()["migration"],
      "version" => "0.0.0"
    }

    Application.put_env(:optimal_engine, :http_mock, fn url, req ->
      uri = URI.parse(url)
      workspace = URI.decode_query(uri.query || "")["workspace"]
      route = uri.path |> String.split("/") |> List.last()
      :ets.insert(seen, {route, workspace})

      case {req[:method], route} do
        {:get, "status"} ->
          answer(200, %{
            "data" => Map.merge(engine, %{"workspace_id" => workspace, "enabled" => true})
          })

        {:get, "pull"} ->
          answer(200, %{
            "data" => %{
              "workspace_id" => workspace,
              "mutations" => [],
              "cursor" => 0,
              "more" => false,
              "engine" => engine
            }
          })

        {:post, "push"} ->
          answer(200, %{"data" => %{"applied" => 0, "engine" => engine}})

        _other ->
          answer(404, %{"error" => %{"code" => "NOT_FOUND"}})
      end
    end)
  end

  defp answer(status, body) do
    {:ok,
     {{~c"HTTP/1.1", status, ~c"OK"}, [{~c"content-type", ~c"application/json"}],
      Jason.encode!(body)}}
  end
end
