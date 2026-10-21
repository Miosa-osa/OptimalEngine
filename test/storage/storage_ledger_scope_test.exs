defmodule OptimalEngine.Storage.StorageLedgerScopeTest do
  @moduledoc """
  Storage mutation entries share the replication ledger with change capture and
  sync applies. An entry may not name a table of this Engine or take a key of
  its capture space, and an entry is never served, pushed or taken for a local
  change, whatever entity type it names.
  """

  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias OptimalEngine.API.Router
  alias OptimalEngine.Auth.ApiKey
  alias OptimalEngine.{Store, Sync}
  alias OptimalEngine.Storage.PolicyStore

  @opts Router.init([])

  setup do
    n = System.unique_integer([:positive])
    ws = "default:storage-scope-#{n}"

    {:ok, _} =
      Store.raw_query(
        """
        INSERT OR IGNORE INTO workspaces (id, tenant_id, slug, name, status, metadata)
        VALUES (?1, 'default', ?2, ?3, 'active', '{}')
        """,
        [ws, "storage-scope-#{n}", "Storage scope #{n}"]
      )

    {:ok, _} = Sync.enable("default", ws, "user:owner")

    {:ok, %{key: token}} =
      ApiKey.mint(%{
        tenant_id: "default",
        name: "writer",
        scopes: ["write", "read"],
        workspace_scope: [ws]
      })

    previous_key = System.get_env("CONNECTOR_KEY")
    System.put_env("CONNECTOR_KEY", Base.encode16(:crypto.strong_rand_bytes(32)))
    scheduler = Process.whereis(OptimalEngine.Sync.Scheduler)
    if scheduler, do: :sys.suspend(scheduler, 60_000)

    on_exit(fn ->
      if scheduler && Process.alive?(scheduler), do: :sys.resume(scheduler)
      Application.delete_env(:optimal_engine, :http_mock)

      if previous_key,
        do: System.put_env("CONNECTOR_KEY", previous_key),
        else: System.delete_env("CONNECTOR_KEY")
    end)

    %{n: n, ws: ws, token: token, local: Sync.replica_id()}
  end

  describe "POST /api/storage/workspaces/:id/mutations" do
    test "refuses an entity type that names a table of this Engine", ctx do
      for type <- ["contexts", "Contexts", "facts", "api_keys", "authority_records_#{ctx.n}"] do
        conn = append(ctx, %{"entity_type" => type, "idempotency_key" => "t-#{type}-#{ctx.n}"})
        assert conn.status == 422, "#{type}: #{conn.status} #{conn.resp_body}"
        assert Jason.decode!(conn.resp_body)["error"] == "entity_type_names_a_table"
      end

      assert ledger_count(ctx) == 0
    end

    test "refuses an idempotency key of this Engine's capture space", ctx do
      for key <- ["#{ctx.local}:5", "mut_#{ctx.local}_5", "peer:mut_rep_remote_#{ctx.n}"] do
        conn = append(ctx, %{"idempotency_key" => key})
        assert conn.status == 422, "#{key}: #{conn.status} #{conn.resp_body}"
        assert Jason.decode!(conn.resp_body)["error"] == "reserved_idempotency_key"
      end

      assert ledger_count(ctx) == 0
    end

    test "appends and replays an entry with a free-form entity type", ctx do
      body = %{"entity_type" => "memory_object", "idempotency_key" => "app-#{ctx.n}"}

      first = append(ctx, body)
      assert first.status == 201, first.resp_body
      again = append(ctx, body)
      assert again.status == 201, again.resp_body
      assert Jason.decode!(again.resp_body)["id"] == Jason.decode!(first.resp_body)["id"]

      listed = get(ctx, "/api/storage/workspaces/#{ctx.ws}/mutations?after=0")
      assert listed.status == 200
      assert %{"count" => 1} = Jason.decode!(listed.resp_body)
    end
  end

  describe "an entry written before the check" do
    test "is not served, pushed or taken for a local change, though it names a replicated table",
         ctx do
      id = "ctx-#{ctx.n}"
      insert_context(ctx, id, "Written here")

      # What the storage route stored before it refused table names: a free-form
      # entry under any device id, this Engine's included, with any time.
      planted = plant_entry(ctx, id, "Planted 9137")

      served = Enum.map(Sync.changes("default", ctx.ws, limit: 2_000)["mutations"], & &1["id"])
      refute planted in served

      pushed = :ets.new(:pushed, [:public, :bag])
      engine = Sync.engine_info() |> Map.put("replica_id", "rep_cloud_#{ctx.n}")

      Application.put_env(:optimal_engine, :http_mock, fn _url, opts ->
        if opts[:method] == :post, do: :ets.insert(pushed, {:body, opts[:body]})

        body =
          if opts[:method] == :post,
            do: %{"applied" => length(opts[:body]["mutations"]), "engine" => engine},
            else: %{"mutations" => [], "cursor" => 0, "more" => false, "engine" => engine}

        {:ok,
         {{~c"HTTP/1.1", 200, ~c"OK"}, [{~c"content-type", ~c"application/json"}],
          Jason.encode!(body)}}
      end)

      {:ok, _} =
        Sync.add_peer(
          "default",
          %{"workspace_id" => ctx.ws, "url" => "https://cloud-#{ctx.n}.example", "api_key" => "k"},
          "u"
        )

      Sync.run_all()

      sent = for {:body, body} <- :ets.lookup(pushed, :body), m <- body["mutations"], do: m
      assert Enum.any?(sent, &(&1["entity_id"] == id))
      refute Enum.any?(sent, &(&1["id"] == planted))
      refute Jason.encode!(sent) =~ "Planted 9137"

      # A peer's newer edit of the row is applied: the entry is not a later local change.
      edit = %{
        "id" => "mut_rep_peer_#{ctx.n}_1",
        "device_id" => "rep_peer_#{ctx.n}",
        "entity_type" => "contexts",
        "entity_id" => id,
        "operation" => "update",
        "occurred_at" => "2100-01-01T00:00:00.000",
        "idempotency_key" => "rep_peer_#{ctx.n}:1",
        "payload" => %{
          "row" => %{"id" => id, "title" => "Edited by the peer", "workspace_id" => ctx.ws},
          "blobs" => %{}
        }
      }

      assert {:ok, %{applied: 1}} = Sync.apply_changes("default", ctx.ws, [edit])

      assert {:ok, [["Edited by the peer"]]} =
               Store.raw_query("SELECT title FROM contexts WHERE id = ?1", [id])
    end

    test "replays by its key, though it names a table", ctx do
      body = %{
        "entity_type" => "contexts",
        "entity_id" => "ctx-old-#{ctx.n}",
        "operation" => "update",
        "payload" => %{"row" => %{"id" => "ctx-old-#{ctx.n}", "title" => "Kept 4410"}},
        "idempotency_key" => "old-#{ctx.n}"
      }

      stored = plant(ctx, Map.put(body, "device_id", "app-device-#{ctx.n}"))

      replay = append(ctx, body)
      assert replay.status == 201, replay.resp_body
      assert Jason.decode!(replay.resp_body)["id"] == stored

      changed = append(ctx, put_in(body, ["payload", "row", "title"], "Changed"))
      assert changed.status == 409, changed.resp_body
      assert ledger_count(ctx) == 1
    end

    test "a replay by key never answers with a replicated change", ctx do
      peer = "rep_peer_#{ctx.n}"

      body = %{
        "entity_type" => "contexts",
        "entity_id" => "ctx-peer-#{ctx.n}",
        "operation" => "update",
        "payload" => %{"row" => %{"id" => "ctx-peer-#{ctx.n}", "title" => "Peer's 5521"}},
        "idempotency_key" => "#{peer}:3"
      }

      # A change a peer sent before the ledger key change, under the key it sent.
      plant(ctx, body |> Map.put("device_id", peer) |> Map.put("id", "mut_#{peer}_3"))

      conn = append(ctx, body)
      assert conn.status in [409, 422], conn.resp_body
      refute conn.resp_body =~ "mut_#{peer}_3"
    end
  end

  describe "PolicyStore.append_mutation/1" do
    test "gives an entry its own id, never the caller's", ctx do
      wanted = "mut_#{ctx.local}_#{900_000_000 + ctx.n}"

      assert {:ok, entry} =
               PolicyStore.append_mutation(%{
                 id: wanted,
                 workspace_id: ctx.ws,
                 device_id: "app-device-#{ctx.n}",
                 entity_type: "memory_object",
                 entity_id: "obj-#{ctx.n}",
                 operation: :create,
                 payload: %{"text" => "App entry"}
               })

      assert entry.id != wanted
      assert {:ok, []} = Store.raw_query("SELECT 1 FROM sync_mutations WHERE id = ?1", [wanted])
    end
  end

  describe "change rows" do
    test "change_row?/3 and the ledger query agree", ctx do
      local = ctx.local
      peer = "rep_peer_#{ctx.n}"
      under = "rep_x_#{ctx.n}"
      accented = "rép-#{ctx.n}"
      odd = "rep%_#{ctx.n}"
      big = 900_000_000 + ctx.n

      rows = [
        # {id, device, key, a change row?}
        {"mut_#{local}_#{big}", local, "#{local}:#{big}", true},
        {"mut_#{peer}_7", peer, "#{peer}:7", true},
        {"applied-#{ctx.n}", peer, "peer:applied-#{ctx.n}", true},
        {"mut_#{under}_1", under, "#{under}:1", true},
        {"mut_#{accented}_2", accented, "#{accented}:2", true},
        {"mut_#{odd}_3", odd, "#{odd}:3", true},
        {"mut_#{peer}_", peer, "#{peer}:", true},
        {UUID.uuid4(), local, "entry-#{ctx.n}", false},
        {UUID.uuid4(), local, "#{local}:#{big + 1}", false},
        {"mut_#{local}_#{big + 2}", peer, "#{peer}:#{big + 2}", false},
        {"elsewhere-#{ctx.n}", peer, "peer:other-#{ctx.n}", false},
        {"mut_#{under}_4", "rep_x", "#{under}:4", false},
        {"mut_Rep-#{ctx.n}_5", "Rep-#{ctx.n}", "rep-#{ctx.n}:5", false},
        {"mut_#{peer}_8", peer, "#{peer}:9", false}
      ]

      for {id, device, key, _} <- rows do
        {:ok, _} =
          Store.raw_query(
            """
            INSERT INTO sync_mutations
              (id, tenant_id, workspace_id, device_id, entity_type, entity_id, operation, payload,
               payload_hash, idempotency_key, occurred_at)
            VALUES (?1, 'default', ?2, ?3, 'contexts', 'c1', 'update', '{"row":{},"blobs":{}}', 'h', ?4,
                    '2026-10-14T12:00:00.000')
            """,
            [id, ctx.ws, device, key]
          )
      end

      planted = MapSet.new(rows, &elem(&1, 0))

      {:ok, matched} =
        Store.raw_query(
          "SELECT id FROM sync_mutations WHERE workspace_id = ?1 AND #{Sync.change_row_sql()}",
          [ctx.ws]
        )

      by_sql = matched |> List.flatten() |> Enum.filter(&(&1 in planted)) |> Enum.sort()
      by_elixir = for {id, device, key, _} <- rows, Sync.change_row?(id, device, key), do: id
      expected = for {id, _, _, true} <- rows, do: id

      assert by_sql == Enum.sort(by_elixir)
      assert Enum.sort(by_elixir) == Enum.sort(expected)
    end

    test "a peer's change is served onward, applied now or keyed by its sender before", ctx do
      peer = "rep_peer_#{ctx.n}"

      row = fn id ->
        %{
          "row" => %{
            "id" => id,
            "title" => "From the peer",
            "content" => "remote body",
            "workspace_id" => ctx.ws,
            "tenant_id" => "default"
          },
          "blobs" => %{}
        }
      end

      now = %{
        "id" => "mut_#{peer}_1",
        "device_id" => peer,
        "entity_type" => "contexts",
        "entity_id" => "ctx-now-#{ctx.n}",
        "operation" => "create",
        "occurred_at" => "2026-10-14T12:00:00.000",
        "idempotency_key" => "#{peer}:1",
        "payload" => row.("ctx-now-#{ctx.n}")
      }

      assert {:ok, %{applied: 1}} = Sync.apply_changes("default", ctx.ws, [now])

      assert {:ok, [["peer:mut_" <> _]]} =
               Store.raw_query("SELECT idempotency_key FROM sync_mutations WHERE id = ?1", [
                 now["id"]
               ])

      # A change applied before the ledger key change kept the key its sender gave.
      insert_context(ctx, "ctx-before-#{ctx.n}", "From the peer")

      before =
        plant(ctx, %{
          "id" => "mut_#{peer}_2",
          "device_id" => peer,
          "entity_type" => "contexts",
          "entity_id" => "ctx-before-#{ctx.n}",
          "operation" => "create",
          "payload" => row.("ctx-before-#{ctx.n}"),
          "idempotency_key" => "#{peer}:2"
        })

      served =
        Sync.changes("default", ctx.ws, requester: "rep_cloud_#{ctx.n}", limit: 2_000)["mutations"]
        |> Enum.map(& &1["id"])

      assert now["id"] in served
      assert before in served
    end

    test "a planted entry is not counted as pending for a peer", ctx do
      {:ok, _} =
        Sync.add_peer(
          "default",
          %{
            "workspace_id" => ctx.ws,
            "url" => "https://cloud-#{ctx.n}.example",
            "api_key" => "k",
            "policy" => "push"
          },
          "u"
        )

      insert_context(ctx, "ctx-pending-#{ctx.n}", "Pending")
      plant_entry(ctx, "ctx-pending-#{ctx.n}", "Planted")
      plant_entry(ctx, "ctx-other-#{ctx.n}", "Planted elsewhere")

      assert [%{pending_push: 1}] = Sync.status("default", ctx.ws).peers
    end
  end

  # -- helpers ------------------------------------------------------------------

  defp append(ctx, body) do
    body =
      Map.merge(
        %{
          "device_id" => "app-device-#{ctx.n}",
          "entity_type" => "memory_object",
          "entity_id" => "obj-#{ctx.n}",
          "operation" => "create",
          "payload" => %{"row" => %{"id" => "obj-#{ctx.n}", "text" => "App entry"}}
        },
        body
      )

    with_auth_required(fn ->
      conn(:post, "/api/storage/workspaces/#{ctx.ws}/mutations", Jason.encode!(body))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer " <> ctx.token)
      |> Router.call(@opts)
    end)
  end

  defp get(ctx, path) do
    with_auth_required(fn ->
      conn(:get, path)
      |> put_req_header("authorization", "Bearer " <> ctx.token)
      |> Router.call(@opts)
    end)
  end

  defp with_auth_required(fun) do
    original = Application.get_env(:optimal_engine, :auth, [])

    Application.put_env(
      :optimal_engine,
      :auth,
      Keyword.merge(original, auth_required: true, bcrypt_cost: 4)
    )

    try do
      fun.()
    after
      Application.put_env(:optimal_engine, :auth, original)
    end
  end

  defp ledger_count(ctx) do
    {:ok, [[count]]} =
      Store.raw_query(
        "SELECT COUNT(*) FROM sync_mutations WHERE workspace_id = ?1 AND device_id = ?2",
        [ctx.ws, "app-device-#{ctx.n}"]
      )

    count
  end

  defp insert_context(ctx, id, title) do
    {:ok, _} =
      Store.raw_query(
        "INSERT INTO contexts (id, tenant_id, workspace_id, title, content, created_at) VALUES (?1, 'default', ?2, ?3, 'body', '2026-10-14T10:00:00Z')",
        [id, ctx.ws, title]
      )

    {:ok, _} = OptimalEngine.Sync.Capture.seal()
  end

  # A ledger row as an earlier version stored it, with the payload hash the
  # storage route gives a payload.
  defp plant(ctx, row) do
    id = Map.get(row, "id", UUID.uuid4())
    payload = Jason.encode!(row["payload"])

    {:ok, _} =
      Store.raw_query(
        """
        INSERT INTO sync_mutations
          (id, tenant_id, workspace_id, device_id, entity_type, entity_id, operation, payload,
           payload_hash, idempotency_key, occurred_at)
        VALUES (?1, 'default', ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, '2026-10-14T12:00:00.000')
        """,
        [
          id,
          ctx.ws,
          row["device_id"],
          row["entity_type"],
          row["entity_id"],
          row["operation"],
          payload,
          :crypto.hash(:sha256, payload) |> Base.encode16(case: :lower),
          row["idempotency_key"]
        ]
      )

    id
  end

  defp plant_entry(ctx, entity_id, title) do
    id = UUID.uuid4()

    payload =
      Jason.encode!(%{
        "row" => %{"id" => entity_id, "title" => title, "workspace_id" => ctx.ws},
        "blobs" => %{}
      })

    {:ok, _} =
      Store.raw_query(
        """
        INSERT INTO sync_mutations
          (id, tenant_id, workspace_id, device_id, entity_type, entity_id, operation, payload,
           payload_hash, idempotency_key, occurred_at)
        VALUES (?1, 'default', ?2, ?3, 'contexts', ?4, 'update', ?5, 'h', ?6,
                '2999-01-01T00:00:00.000')
        """,
        [id, ctx.ws, ctx.local, entity_id, payload, "app-key-#{entity_id}"]
      )

    id
  end
end
