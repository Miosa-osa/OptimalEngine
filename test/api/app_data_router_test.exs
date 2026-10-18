defmodule OptimalEngine.API.AppDataRouterTest do
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias OptimalEngine.API.Router
  alias OptimalEngine.Auth.ApiKey

  @opts Router.init([])

  defp request(method, path, body \\ nil, headers \\ []) do
    conn =
      case body do
        nil ->
          conn(method, path)

        b ->
          conn(method, path, Jason.encode!(b)) |> put_req_header("content-type", "application/json")
      end

    conn = Enum.reduce(headers, conn, fn {k, v}, c -> put_req_header(c, k, v) end)
    Router.call(conn, @opts)
  end

  defp auth(key), do: [{"authorization", "Bearer " <> key}]

  defp decode(conn), do: Jason.decode!(conn.resp_body)

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

  defp mint(scopes, workspaces) do
    {:ok, %{key: key}} =
      ApiKey.mint(%{
        tenant_id: "default",
        name: "test",
        scopes: scopes,
        workspace_scope: workspaces
      })

    key
  end

  defp ws, do: "default:data-#{System.unique_integer([:positive])}"

  @tasks %{
    "name" => "tasks",
    "fields" => [
      %{"name" => "title", "type" => "string", "required" => true},
      %{"name" => "done", "type" => "boolean", "default" => false},
      %{"name" => "due", "type" => "datetime"},
      %{"name" => "owner", "type" => "string"}
    ],
    "owner_field" => "owner",
    "search" => %{"text" => ["title"]}
  }

  defp create_tasks(workspace, headers \\ []) do
    conn = request(:post, "/api/data/collections", Map.put(@tasks, "workspace", workspace), headers)
    assert conn.status == 201, conn.resp_body
    decode(conn)
  end

  describe "trusted local mode" do
    test "records round trip with versions, ETags, and If-Match" do
      w = ws()
      create_tasks(w)

      conn =
        request(:post, "/api/data/collections/tasks/records", %{
          "workspace" => w,
          "data" => %{"title" => "first"}
        })

      assert conn.status == 201
      task = decode(conn)
      assert task["version"] == 1
      assert task["data"]["owner"] == "local:operator"

      conn = request(:get, "/api/data/collections/tasks/records/#{task["id"]}?workspace=#{w}")
      assert conn.status == 200
      assert get_resp_header(conn, "etag") == [~s("1")]

      path = "/api/data/collections/tasks/records/#{task["id"]}"

      conn =
        request(:patch, path, %{"workspace" => w, "data" => %{"done" => true}}, [
          {"if-match", ~s("1")}
        ])

      assert conn.status == 200
      assert decode(conn)["version"] == 2

      conn =
        request(:patch, path, %{"workspace" => w, "data" => %{"done" => false}}, [
          {"if-match", ~s("1")}
        ])

      assert conn.status == 409
      assert %{"error" => "version_conflict", "current_version" => 2} = decode(conn)

      conn = request(:delete, path <> "?workspace=#{w}&version=2")
      assert conn.status == 200
      assert %{"deleted" => true, "version" => 3} = decode(conn)
    end

    test "requests must name their workspace, consistently" do
      conn = request(:get, "/api/data/collections")
      assert conn.status == 400
      assert decode(conn)["error"] == "workspace_required"

      w = ws()

      conn =
        request(:post, "/api/data/collections/tasks/query?workspace=#{w}", %{"workspace" => ws()})

      assert conn.status == 400
      assert decode(conn)["error"] == "workspace_mismatch"
    end

    test "query by GET and POST, with filters, sort, cursor, and count" do
      w = ws()
      create_tasks(w)

      records =
        for i <- 1..5,
            do: %{"data" => %{"title" => "t#{i}", "due" => "2026-11-0#{i}", "done" => i > 3}}

      conn =
        request(:post, "/api/data/collections/tasks/records/bulk", %{
          "workspace" => w,
          "records" => records
        })

      assert conn.status == 201
      assert decode(conn)["count"] == 5

      where = URI.encode_www_form(Jason.encode!(%{"done" => false}))

      conn =
        request(
          :get,
          "/api/data/collections/tasks/records?workspace=#{w}&where=#{where}&sort=-due&limit=2&count=true"
        )

      page = decode(conn)
      assert Enum.map(page["records"], & &1["data"]["title"]) == ["t3", "t2"]
      assert page["count"] == 3

      conn =
        request(:post, "/api/data/collections/tasks/query", %{
          "workspace" => w,
          "where" => %{"done" => false},
          "sort" => ["-due"],
          "limit" => 2,
          "cursor" => page["next_cursor"]
        })

      assert Enum.map(decode(conn)["records"], & &1["data"]["title"]) == ["t1"]

      conn =
        request(:post, "/api/data/collections/tasks/query", %{
          "workspace" => w,
          "where" => %{"bogus" => 1}
        })

      assert conn.status == 422
    end

    test "a failed transaction reports the failing operation and commits nothing" do
      w = ws()
      create_tasks(w)

      conn =
        request(:post, "/api/data/transactions", %{
          "workspace" => w,
          "operations" => [
            %{"op" => "create", "collection" => "tasks", "id" => "a", "data" => %{"title" => "ok"}},
            %{"op" => "create", "collection" => "tasks", "id" => "b", "data" => %{"done" => true}}
          ]
        })

      assert conn.status == 422
      assert %{"operation_index" => 1, "committed" => false} = decode(conn)
      assert request(:get, "/api/data/collections/tasks/records/a?workspace=#{w}").status == 404
    end

    test "files upload and download with byte ranges" do
      w = ws()
      create_tasks(w)

      task =
        decode(
          request(:post, "/api/data/collections/tasks/records", %{
            "workspace" => w,
            "data" => %{"title" => "f"}
          })
        )

      bytes = "0123456789abcdef"

      conn =
        request(:post, "/api/data/collections/tasks/records/#{task["id"]}/files", %{
          "workspace" => w,
          "filename" => "digits.txt",
          "content_type" => "text/plain",
          "content_base64" => Base.encode64(bytes)
        })

      assert conn.status == 201
      file = decode(conn)
      path = "/api/data/collections/tasks/records/#{task["id"]}/files/#{file["id"]}?workspace=#{w}"

      conn = request(:get, path)
      assert conn.status == 200
      assert conn.resp_body == bytes
      assert get_resp_header(conn, "accept-ranges") == ["bytes"]

      conn = request(:get, path, nil, [{"range", "bytes=2-5"}])
      assert conn.status == 206
      assert conn.resp_body == "2345"
      assert get_resp_header(conn, "content-range") == ["bytes 2-5/16"]

      conn = request(:get, path, nil, [{"range", "bytes=-3"}])
      assert conn.status == 206 and conn.resp_body == "def"

      conn = request(:get, path, nil, [{"range", "bytes=10-"}])
      assert conn.status == 206 and conn.resp_body == "abcdef"

      conn = request(:get, path, nil, [{"range", "bytes=40-50"}])
      assert conn.status == 416
      assert get_resp_header(conn, "content-range") == ["bytes */16"]
    end

    test "the change feed polls and streams, resuming from a sequence" do
      w = ws()
      create_tasks(w)

      for t <- ["one", "two", "three"] do
        assert request(:post, "/api/data/collections/tasks/records", %{
                 "workspace" => w,
                 "data" => %{"title" => t}
               }).status == 201
      end

      feed =
        decode(request(:get, "/api/data/changes?workspace=#{w}&collection=tasks&since=0&limit=2"))

      assert Enum.map(feed["changes"], & &1["op"]) == ["schema", "create"]

      rest = decode(request(:get, "/api/data/changes?workspace=#{w}&since=#{feed["next_since"]}"))
      assert Enum.map(rest["changes"], & &1["data"]["data"]["title"]) == ["two", "three"]

      conn =
        request(:get, "/api/data/changes/stream?workspace=#{w}&idle_timeout=1", nil, [
          {"last-event-id", to_string(feed["next_since"])}
        ])

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") |> hd() =~ "text/event-stream"

      ids =
        Regex.scan(~r/^id: (\d+)$/m, conn.resp_body)
        |> Enum.map(fn [_, id] -> String.to_integer(id) end)

      assert ids == Enum.map(rest["changes"], & &1["seq"])
    end

    test "migrations apply once" do
      w = ws()

      body = %{
        "workspace" => w,
        "app" => "todo",
        "migrations" => [
          %{
            "version" => 1,
            "operations" => [%{"op" => "create_collection", "collection" => @tasks}]
          }
        ]
      }

      assert decode(request(:post, "/api/data/migrations", body))["applied"] == [1]
      assert decode(request(:post, "/api/data/migrations", body))["skipped"] == [1]

      assert [%{"version" => 1}] =
               decode(request(:get, "/api/data/migrations?workspace=#{w}&app=todo"))["migrations"]
    end
  end

  describe "keys, scopes, and end users" do
    test "an end user scoped to owner A cannot read owner B's tasks" do
      with_auth_required(fn ->
        w = ws()
        root = mint(["*"], [w])
        create_tasks(w, auth(root))

        for {title, owner} <- [{"a1", "user-a"}, {"a2", "user-a"}, {"b1", "user-b"}] do
          conn =
            request(
              :post,
              "/api/data/collections/tasks/records",
              %{"workspace" => w, "data" => %{"title" => title, "owner" => owner}},
              auth(root)
            )

          assert conn.status == 201
        end

        conn =
          request(
            :post,
            "/api/data/keys",
            %{
              "workspace" => w,
              "name" => "user-a session",
              "owner" => "user-a",
              "collections" => ["tasks"],
              "operations" => ["read", "create", "update"]
            },
            auth(root)
          )

        assert conn.status == 201
        user_a = decode(conn)
        assert user_a["data_access"]["owner"] == "user-a"
        a = auth(user_a["key"])

        page =
          decode(
            request(:get, "/api/data/collections/tasks/records?workspace=#{w}&count=true", nil, a)
          )

        assert page["count"] == 2
        assert Enum.all?(page["records"], &(&1["data"]["owner"] == "user-a"))

        b_id =
          decode(
            request(:get, "/api/data/collections/tasks/records?workspace=#{w}", nil, auth(root))
          )["records"]
          |> Enum.find(&(&1["data"]["owner"] == "user-b"))
          |> Map.fetch!("id")

        assert request(:get, "/api/data/collections/tasks/records/#{b_id}?workspace=#{w}", nil, a).status ==
                 404

        assert request(
                 :post,
                 "/api/data/collections/tasks/query",
                 %{"workspace" => w, "where" => %{"owner" => "user-b"}, "count" => true},
                 a
               )
               |> decode()
               |> Map.fetch!("count") == 0

        conn =
          request(
            :post,
            "/api/data/collections/tasks/records",
            %{"workspace" => w, "data" => %{"title" => "x", "owner" => "user-b"}},
            a
          )

        assert conn.status == 403
        assert decode(conn)["error"] == "owner_mismatch"

        conn =
          request(
            :post,
            "/api/data/collections/tasks/records",
            %{"workspace" => w, "data" => %{"title" => "mine"}},
            a
          )

        assert conn.status == 201
        assert decode(conn)["data"]["owner"] == "user-a"

        assert request(
                 :delete,
                 "/api/data/collections/tasks/records/#{b_id}?workspace=#{w}",
                 nil,
                 a
               ).status == 403
      end)
    end

    test "a data key is confined to its workspace, collections, operations, and /api/data" do
      with_auth_required(fn ->
        w = ws()
        root = mint(["*"], [w])
        create_tasks(w, auth(root))

        conn =
          request(
            :post,
            "/api/data/keys",
            %{"workspace" => w, "name" => "reader", "collections" => ["tasks"]},
            auth(root)
          )

        reader = auth(decode(conn)["key"])

        assert request(:get, "/api/data/collections/tasks/records?workspace=#{w}", nil, reader).status ==
                 200

        conn =
          request(
            :post,
            "/api/data/collections/tasks/records",
            %{"workspace" => w, "data" => %{"title" => "x"}},
            reader
          )

        assert conn.status == 403 and decode(conn)["error"] == "permission_scope_denied"

        conn = request(:get, "/api/search?q=x&workspace=#{w}", nil, reader)
        assert conn.status == 403 and decode(conn)["error"] == "data_key_confined"

        conn = request(:get, "/api/data/collections/other/records?workspace=#{w}", nil, reader)
        assert conn.status == 403 and decode(conn)["error"] == "collection_not_allowed"

        conn = request(:post, "/api/data/collections", Map.put(@tasks, "workspace", w), reader)
        assert conn.status == 403

        conn =
          request(
            :post,
            "/api/data/keys",
            %{"workspace" => w, "name" => "escalate", "operations" => ["delete"]},
            reader
          )

        assert conn.status == 403

        assert [%{"name" => "reader"}] =
                 decode(request(:get, "/api/data/keys?workspace=#{w}", nil, auth(root)))["keys"]
      end)
    end

    test "a key scoped to workspace A cannot touch workspace B's collections" do
      with_auth_required(fn ->
        w_a = ws()
        w_b = ws()
        create_tasks(w_b, auth(mint(["*"], [w_b])))
        key_a = auth(mint(["read", "write"], [w_a]))

        for {method, path, body} <- [
              {:get, "/api/data/collections?workspace=#{w_b}", nil},
              {:get, "/api/data/collections/tasks/records?workspace=#{w_b}", nil},
              {:post, "/api/data/collections/tasks/records",
               %{"workspace" => w_b, "data" => %{"title" => "x"}}},
              {:post, "/api/data/collections/tasks/query", %{"workspace" => w_b}},
              {:get, "/api/data/changes?workspace=#{w_b}", nil}
            ] do
          conn = request(method, path, body, key_a)
          assert conn.status == 403, "#{method} #{path}: #{conn.resp_body}"
          assert decode(conn)["error"] == "workspace_scope_denied"
        end

        conn = request(:post, "/api/data/collections", Map.put(@tasks, "workspace", w_a), key_a)
        assert conn.status == 403 and decode(conn)["error"] == "permission_scope_denied"
      end)
    end

    test "a keyed writer without data:admin owns what it creates and cannot assign others" do
      with_auth_required(fn ->
        w = ws()
        create_tasks(w, auth(mint(["*"], [w])))
        writer = auth(mint(["read", "write"], [w]))

        conn =
          request(
            :post,
            "/api/data/collections/tasks/records",
            %{"workspace" => w, "data" => %{"title" => "x"}},
            writer
          )

        assert conn.status == 201
        record = decode(conn)
        assert "api_key:" <> _ = record["data"]["owner"]
        assert record["created_by"] == record["data"]["owner"]

        conn =
          request(
            :post,
            "/api/data/collections/tasks/records",
            %{"workspace" => w, "data" => %{"title" => "x", "owner" => "someone"}},
            writer
          )

        assert conn.status == 403 and decode(conn)["error"] == "owner_mismatch"

        conn =
          request(
            :post,
            "/api/data/collections/tasks/records",
            %{"workspace" => w, "actor_id" => "spoofed", "data" => %{"title" => "x"}},
            writer
          )

        assert conn.status == 403 and decode(conn)["error"] == "actor_identity_mismatch"
      end)
    end
  end
end
