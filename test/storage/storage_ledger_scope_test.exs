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
        [id, ctx.ws, ctx.local, entity_id, payload, "app-key-#{ctx.n}"]
      )

    id
  end
end
