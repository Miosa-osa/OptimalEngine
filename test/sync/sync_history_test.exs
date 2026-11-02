defmodule OptimalEngine.SyncHistoryTest do
  @moduledoc """
  Sync history: one `sync_runs` row per peer cycle, peer and Engine labels,
  the ledger with the origin of each change, and their routes
  (`GET /api/sync/runs`, `GET /api/sync/ledger`).
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Plug.Conn, only: [put_req_header: 3]
  import Plug.Test, only: [conn: 2, conn: 3]

  alias OptimalEngine.API.Router
  alias OptimalEngine.Auth.ApiKey
  alias OptimalEngine.{Organization, Store, Sync, Workspace}
  alias OptimalEngine.Sync.History
  alias OptimalEngine.Tenancy.Tenant

  @run_keys ~w(id peer_id peer_label started_at finished_at status pulled pushed conflicts gated message)
  @ledger_keys ~w(sequence table entity_id op device_id origin origin_label occurred_at recorded_at)

  setup do
    n = System.unique_integer([:positive])
    tenant = "synchist-#{n}"
    {:ok, _} = Tenant.create(%{id: tenant, name: "Sync history #{n}"})

    {:ok, _} =
      Organization.create(%{
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

    previous_key = System.get_env("CONNECTOR_KEY")
    System.put_env("CONNECTOR_KEY", Base.encode16(:crypto.strong_rand_bytes(32)))

    scheduler = Process.whereis(OptimalEngine.Sync.Scheduler)
    if scheduler, do: :sys.suspend(scheduler, 60_000)

    {:ok, [[previous_label]]} =
      Store.raw_query("SELECT label FROM sync_identity WHERE id = 1", [])

    on_exit(fn ->
      if scheduler && Process.alive?(scheduler), do: :sys.resume(scheduler)
      Application.delete_env(:optimal_engine, :http_mock)
      Application.delete_env(:optimal_engine, :sync_runs_kept)
      Store.raw_query("UPDATE sync_identity SET label = ?1 WHERE id = 1", [previous_label])

      if previous_key,
        do: System.put_env("CONNECTOR_KEY", previous_key),
        else: System.delete_env("CONNECTOR_KEY")
    end)

    {:ok, _} = Sync.enable(tenant, ws.id, "user:owner")
    %{tenant: tenant, ws: ws.id, n: n}
  end

  defp respond(status, body) do
    {:ok,
     {{~c"HTTP/1.1", status, ~c"OK"}, [{~c"content-type", ~c"application/json"}],
      Jason.encode!(body)}}
  end

  defp insert_context(ctx, id) do
    {:ok, _} =
      Store.raw_query(
        "INSERT INTO contexts (id, tenant_id, workspace_id, title, content, created_at) VALUES (?1, ?2, ?3, 'T', 'body', '2026-10-14T10:00:00Z')",
        [id, ctx.tenant, ctx.ws]
      )
  end

  defp remote_change(ctx, device, id) do
    %{
      "id" => "mut_remote_#{System.unique_integer([:positive])}",
      "device_id" => device,
      "entity_type" => "contexts",
      "entity_id" => id,
      "operation" => "create",
      "occurred_at" => "2026-10-14T12:00:00.000",
      "payload" => %{
        "row" => %{
          "id" => id,
          "title" => "Remote",
          "content" => "remote body",
          "workspace_id" => ctx.ws,
          "tenant_id" => ctx.tenant
        },
        "blobs" => %{}
      }
    }
  end

  defp add_peer(ctx, url, extra \\ %{}) do
    Sync.add_peer(
      ctx.tenant,
      Map.merge(%{"workspace_id" => ctx.ws, "url" => url, "api_key" => "replica-key"}, extra),
      "u"
    )
  end

  defp run_rows(ctx) do
    {:ok, rows} =
      Store.raw_query(
        "SELECT status, pulled, pushed, conflicts, gated, message, started_at, finished_at FROM sync_runs WHERE tenant_id = ?1 AND workspace_id = ?2 ORDER BY id",
        [ctx.tenant, ctx.ws]
      )

    rows
  end

  describe "runs" do
    test "a successful cycle writes exactly one row with its counts", ctx do
      engine = Sync.engine_info() |> Map.put("replica_id", "rep_cloud")
      remote_id = "pulled-#{ctx.n}"

      Application.put_env(:optimal_engine, :http_mock, fn _url, opts ->
        case opts[:method] do
          :get ->
            respond(200, %{
              "mutations" => [remote_change(ctx, "rep_cloud", remote_id)],
              "cursor" => 7,
              "engine" => engine
            })

          :post ->
            respond(200, %{"applied" => length(opts[:body]["mutations"])})
        end
      end)

      {:ok, _} = add_peer(ctx, "https://cloud.example")
      insert_context(ctx, "local-#{ctx.n}")

      {:ok, _} =
        Store.raw_query(
          "INSERT INTO facts (id, tenant_id, workspace_id, fact_text, security_labels) VALUES (?1, ?2, ?3, 'Bank detail', '[\"restricted\"]')",
          ["restricted-#{ctx.n}", ctx.tenant, ctx.ws]
        )

      [result] = Sync.run_all() |> Enum.filter(&(&1.workspace_id == ctx.ws))
      assert result.status == "active"

      assert [["ok", 1, pushed, 0, 1, nil, started, finished]] = run_rows(ctx)
      assert pushed >= 1
      assert String.ends_with?(started, "Z") and String.ends_with?(finished, "Z")
      assert started <= finished
    end

    test "a failed cycle writes exactly one error row with the peer's message", ctx do
      Application.put_env(:optimal_engine, :http_mock, fn _url, _opts ->
        respond(502, %{"error" => "bad gateway"})
      end)

      {:ok, _} = add_peer(ctx, "https://down.example", %{"policy" => "pull"})
      [result] = Sync.run_all() |> Enum.filter(&(&1.workspace_id == ctx.ws))
      assert result.status == "error"

      assert [["error", 0, 0, 0, 0, message, _started, _finished]] = run_rows(ctx)
      assert message == hd(Sync.peers(ctx.tenant, ctx.ws)).message
      assert is_binary(message)
    end

    test "a cycle that raises still writes its error row", ctx do
      Application.put_env(:optimal_engine, :http_mock, fn _url, _opts -> raise "boom" end)

      {:ok, _} = add_peer(ctx, "https://raises.example", %{"policy" => "pull"})
      capture_log(fn -> Sync.run_all() end)

      assert [["error", 0, 0, 0, 0, message, _, _]] = run_rows(ctx)
      assert message =~ "boom"
    end

    test "a peer on another schema version records a paused run", ctx do
      Application.put_env(:optimal_engine, :http_mock, fn _url, _opts ->
        respond(200, %{
          "mutations" => [],
          "cursor" => 0,
          "engine" => %{"replica_id" => "rep_old", "migration" => 1}
        })
      end)

      {:ok, _} = add_peer(ctx, "https://old.example", %{"policy" => "pull"})
      Sync.run_all()

      assert [["paused", 0, 0, 0, 0, message, _, _]] = run_rows(ctx)
      assert message =~ "same Engine version"
    end

    test "prune keeps the newest rows of each peer", ctx do
      Application.put_env(:optimal_engine, :sync_runs_kept, 3)

      Application.put_env(:optimal_engine, :http_mock, fn _url, _opts ->
        respond(502, %{"error" => "down"})
      end)

      {:ok, _} = add_peer(ctx, "https://down.example", %{"policy" => "pull"})
      for _ <- 1..5, do: Sync.run_all()

      {:ok, ids} =
        Store.raw_query(
          "SELECT id FROM sync_runs WHERE tenant_id = ?1 AND workspace_id = ?2 ORDER BY id",
          [ctx.tenant, ctx.ws]
        )

      assert length(ids) == 3

      %{data: data} = History.runs(ctx.tenant, ctx.ws, limit: 10)
      assert Enum.map(data, & &1.id) == ids |> List.flatten() |> Enum.reverse()
    end

    test "runs page newest first with a cursor, filter by peer, and cap the limit", ctx do
      Application.put_env(:optimal_engine, :http_mock, fn _url, _opts ->
        respond(502, %{"error" => "down"})
      end)

      {:ok, a} = add_peer(ctx, "https://a.example", %{"policy" => "pull", "label" => "Laptop"})
      {:ok, b} = add_peer(ctx, "https://b.example", %{"policy" => "pull"})
      for _ <- 1..3, do: Sync.run_all()

      first = History.runs(ctx.tenant, ctx.ws, limit: 4)
      assert length(first.data) == 4
      assert is_binary(first.next_cursor)
      ids = Enum.map(first.data, & &1.id)
      assert ids == Enum.sort(ids, :desc)

      rest =
        History.runs(ctx.tenant, ctx.ws, limit: 4, before: String.to_integer(first.next_cursor))

      assert length(rest.data) == 2
      assert rest.next_cursor == nil
      assert Enum.all?(rest.data, &(&1.id < List.last(ids)))

      only_a = History.runs(ctx.tenant, ctx.ws, peer_id: a.id)
      assert length(only_a.data) == 3
      assert Enum.all?(only_a.data, &(&1.peer_id == a.id and &1.peer_label == "Laptop"))

      assert Enum.all?(
               History.runs(ctx.tenant, ctx.ws, peer_id: b.id).data,
               &(&1.peer_label == "b.example")
             )

      assert History.limit(1000) == 200
      assert History.limit(nil) == 50
      assert History.limit(0) == 50
    end
  end

  describe "labels" do
    test "a peer takes the label given, keeps it when added again, else its host", ctx do
      {:ok, peer} = add_peer(ctx, "https://cloud.example/", %{"label" => "  Office  "})
      assert peer.label == "Office"

      assert peer.id ==
               Sync.peer_id(%{
                 tenant_id: ctx.tenant,
                 workspace_id: ctx.ws,
                 url: "https://cloud.example"
               })

      {:ok, again} = add_peer(ctx, "https://cloud.example")
      assert again.label == "Office"
      assert again.id == peer.id

      {:ok, plain} = add_peer(ctx, "https://other.example:4200")
      assert plain.label == "other.example"

      {:ok, relay} = add_peer(ctx, "relay+https://miosa.example/api/v1/engines/e1/sync")
      assert relay.label == "MIOSA cloud"

      assert {:error, :invalid_label} =
               add_peer(ctx, "https://x.example", %{"label" => String.duplicate("a", 65)})

      assert {:error, :invalid_label} = add_peer(ctx, "https://x.example", %{"label" => 7})

      status = Sync.status(ctx.tenant, ctx.ws)
      labels = Map.new(status.peers, &{&1.url, &1.label})
      assert labels["https://cloud.example"] == "Office"
      assert Enum.all?(status.peers, &is_binary(&1.id))
    end

    test "enable sets this Engine's own label, shown by status", ctx do
      {:ok, _} = Sync.enable(ctx.tenant, ctx.ws, "u", label: "Roberto's laptop")
      assert Sync.status(ctx.tenant, ctx.ws).label == "Roberto's laptop"

      {:ok, _} = Sync.enable(ctx.tenant, ctx.ws, "u")
      assert Sync.label() == "Roberto's laptop"

      assert {:error, :invalid_label} =
               Sync.enable(ctx.tenant, ctx.ws, "u", label: String.duplicate("b", 65))
    end
  end

  describe "ledger" do
    setup ctx do
      {:ok, laptop} = add_peer(ctx, "https://laptop.example", %{"label" => "Laptop"})

      {:ok, _} =
        Store.raw_query(
          "UPDATE sync_peers SET peer_replica_id = 'rep_laptop' WHERE tenant_id = ?1 AND workspace_id = ?2 AND url = ?3",
          [
            ctx.tenant,
            ctx.ws,
            "https://laptop.example"
          ]
        )

      insert_context(ctx, "own-#{ctx.n}")

      {:ok, %{applied: 2}} =
        Sync.apply_changes(ctx.tenant, ctx.ws, [
          remote_change(ctx, "rep_laptop", "laptop-#{ctx.n}"),
          remote_change(ctx, "rep_stranger", "stranger-#{ctx.n}")
        ])

      %{laptop: laptop}
    end

    test "labels each change local, the matching peer, or an unknown peer", ctx do
      %{data: data, next_cursor: nil} = History.ledger(ctx.tenant, ctx.ws)
      by_id = Map.new(data, &{&1.entity_id, &1})

      own = by_id["own-#{ctx.n}"]
      assert %{origin: "local", op: "insert", table: "contexts"} = own
      assert own.device_id == Sync.replica_id()

      assert %{origin: "peer", origin_label: "Laptop", device_id: "rep_laptop", op: "insert"} =
               by_id["laptop-#{ctx.n}"]

      assert %{origin: "peer", origin_label: "unknown peer", device_id: "rep_stranger"} =
               by_id["stranger-#{ctx.n}"]

      for entry <- data do
        assert entry |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort() ==
                 Enum.sort(@ledger_keys)

        assert String.ends_with?(entry.occurred_at, "Z")
        assert String.ends_with?(entry.recorded_at, "Z")
        refute String.contains?(entry.recorded_at, " ")
      end

      sequences = Enum.map(data, & &1.sequence)
      assert sequences == Enum.sort(sequences, :desc)
    end

    test "filters by origin and table and pages by sequence", ctx do
      local = History.ledger(ctx.tenant, ctx.ws, origin: "local").data
      assert local != [] and Enum.all?(local, &(&1.origin == "local"))

      peer = History.ledger(ctx.tenant, ctx.ws, origin: "peer").data
      assert length(peer) == 2 and Enum.all?(peer, &(&1.origin == "peer"))

      assert History.ledger(ctx.tenant, ctx.ws, table: "facts").data == []

      all = History.ledger(ctx.tenant, ctx.ws).data
      first = History.ledger(ctx.tenant, ctx.ws, limit: 1)
      assert [entry] = first.data
      assert first.next_cursor == to_string(entry.sequence)

      second = History.ledger(ctx.tenant, ctx.ws, limit: 1, before: entry.sequence)
      assert [next] = second.data
      assert next.sequence < entry.sequence
      assert Enum.map(all, & &1.sequence) |> Enum.take(2) == [entry.sequence, next.sequence]
    end
  end

  describe "routes" do
    setup ctx do
      mint = fn scopes ->
        {:ok, %{key: key}} =
          ApiKey.mint(%{
            tenant_id: ctx.tenant,
            name: "k-#{Enum.join(scopes)}",
            scopes: scopes,
            workspace_scope: [ctx.ws]
          })

        key
      end

      Application.put_env(:optimal_engine, :http_mock, fn _url, _opts ->
        respond(502, %{"error" => "down"})
      end)

      {:ok, _} = add_peer(ctx, "https://down.example", %{"policy" => "pull", "label" => "Desk"})
      Sync.run_all()
      insert_context(ctx, "routed-#{ctx.n}")

      %{reader: mint.(["read"]), replica: mint.(["sync"])}
    end

    defp get(path, token) do
      conn =
        conn(:get, path)
        |> put_req_header("authorization", "Bearer " <> token)
        |> Router.call(Router.init([]))

      {conn.status, Jason.decode!(conn.resp_body)}
    end

    defp path(route, ctx, query),
      do: route <> "?" <> URI.encode_query(Map.put(query, "workspace", ctx.ws))

    test "the read scope of /api/sync/status reads runs and ledger; the sync scope does not", ctx do
      for route <- ~w(/api/sync/status /api/sync/runs /api/sync/ledger) do
        assert {200, _} = get(path(route, ctx, %{}), ctx.reader), route
        assert {403, _} = get(path(route, ctx, %{}), ctx.replica), route
      end
    end

    test "the shapes match the contract", ctx do
      {200, status} = get(path("/api/sync/status", ctx, %{}), ctx.reader)
      assert Map.has_key?(status, "label")
      assert is_binary(status["replica_id"])
      [peer] = status["peers"]

      for key <- ~w(id url label policy status last_sync_at message),
          do: assert(Map.has_key?(peer, key), key)

      assert peer["label"] == "Desk"

      {200, runs} = get(path("/api/sync/runs", ctx, %{"limit" => "1000"}), ctx.reader)
      assert Map.keys(runs) |> Enum.sort() == ["data", "next_cursor"]
      [run] = runs["data"]
      assert run |> Map.keys() |> Enum.sort() == Enum.sort(@run_keys)
      assert %{"status" => "error", "peer_label" => "Desk", "peer_id" => peer_id} = run
      assert peer_id == peer["id"]
      assert runs["next_cursor"] == nil

      {200, %{"data" => [^run]}} =
        get(path("/api/sync/runs", ctx, %{"peer_id" => peer_id}), ctx.reader)

      {200, %{"data" => []}} =
        get(path("/api/sync/runs", ctx, %{"peer_id" => "peer_none"}), ctx.reader)

      {200, ledger} = get(path("/api/sync/ledger", ctx, %{"limit" => "1"}), ctx.reader)
      assert Map.keys(ledger) |> Enum.sort() == ["data", "next_cursor"]
      [entry] = ledger["data"]
      assert entry |> Map.keys() |> Enum.sort() == Enum.sort(@ledger_keys)
      refute Map.has_key?(entry, "payload")
      assert %{"origin" => "local", "table" => "contexts", "op" => "insert"} = entry

      {200, %{"data" => local}} =
        get(
          path("/api/sync/ledger", ctx, %{"origin" => "local", "table" => "contexts"}),
          ctx.reader
        )

      assert Enum.any?(local, &(&1["entity_id"] == "routed-#{ctx.n}"))

      assert {400, %{"error" => "invalid_origin"}} =
               get(path("/api/sync/ledger", ctx, %{"origin" => "cloud"}), ctx.reader)
    end

    test "the limit is capped at 200", ctx do
      for i <- 1..205, do: insert_context(ctx, "bulk-#{ctx.n}-#{i}")

      {200, %{"data" => data, "next_cursor" => cursor}} =
        get(path("/api/sync/ledger", ctx, %{"limit" => "500"}), ctx.reader)

      assert length(data) == 200
      assert cursor == to_string(List.last(data)["sequence"])
    end

    test "POST /api/sync/enable takes a label and refuses a long one", ctx do
      {:ok, %{key: admin}} =
        ApiKey.mint(%{
          tenant_id: ctx.tenant,
          name: "admin",
          scopes: ["admin"],
          workspace_scope: [ctx.ws]
        })

      post = fn body ->
        conn =
          conn(:post, "/api/sync/enable", Jason.encode!(body))
          |> put_req_header("content-type", "application/json")
          |> put_req_header("authorization", "Bearer " <> admin)
          |> Router.call(Router.init([]))

        {conn.status, Jason.decode!(conn.resp_body)}
      end

      assert {200, %{"label" => "Cloud box"}} =
               post.(%{"workspace" => ctx.ws, "label" => "Cloud box"})

      assert {422, %{"error" => "invalid_label"}} =
               post.(%{"workspace" => ctx.ws, "label" => String.duplicate("c", 65)})

      {200, status} = get(path("/api/sync/status", ctx, %{}), ctx.reader)
      assert status["label"] == "Cloud box"
    end
  end
end
