defmodule OptimalEngine.API.ConnectorsAPITest do
  @moduledoc """
  The connector routes: register, list, change, run and delete a connector
  over HTTP, with credentials write-only and every route confined to the
  workspaces the caller's key covers.
  """

  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias OptimalEngine.API.Router
  alias OptimalEngine.Auth.ApiKey
  alias OptimalEngine.Authority.Evidence
  alias OptimalEngine.Store

  @opts Router.init([])
  @secret "example-connector-secret-value"

  setup do
    # The suite's OPTIMAL_AUTHORITY_KEY (test_helper.exs) stays: the evidence
    # signing key is wrapped under it once, so a fresh key per test would
    # leave the evidence chain unable to sign.
    saved_env = %{"CONNECTOR_KEY" => System.get_env("CONNECTOR_KEY")}

    System.put_env("CONNECTOR_KEY", Base.encode16(:crypto.strong_rand_bytes(32), case: :lower))

    original_auth = Application.get_env(:optimal_engine, :auth, [])

    Application.put_env(
      :optimal_engine,
      :auth,
      Keyword.merge(original_auth, auth_required: true, bcrypt_cost: 4)
    )

    on_exit(fn ->
      Application.put_env(:optimal_engine, :auth, original_auth)

      Enum.each(saved_env, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    suffix = System.unique_integer([:positive])
    ws_a = insert_workspace("default:conn-a-#{suffix}", "active")
    ws_b = insert_workspace("default:conn-b-#{suffix}", "active")
    old = insert_workspace("default:conn-old-#{suffix}", "archived")

    root = Path.join(System.tmp_dir!(), "oe-connectors-api-#{suffix}")
    File.mkdir_p!(root)
    File.write!(Path.join(root, "first.md"), "# First note #{suffix}\n\nThe first local note.")
    File.write!(Path.join(root, "second.md"), "# Second note #{suffix}\n\nThe second local note.")
    on_exit(fn -> File.rm_rf!(root) end)

    {:ok,
     suffix: suffix,
     ws_a: ws_a,
     ws_b: ws_b,
     old: old,
     root: root,
     admin: mint(["admin", "read"], ["*"]),
     operator_a: mint(["read", "connectors:write"], [ws_a]),
     writer_a: mint(["read", "write"], [ws_a]),
     reader_b: mint(["read"], [ws_b]),
     reader: mint(["read"], ["*"])}
  end

  describe "POST /api/connectors" do
    test "registers into the named workspace and answers without credentials", ctx do
      conn =
        request(ctx.admin, :post, "/api/connectors", %{
          "id" => "gmail-#{ctx.suffix}",
          "kind" => "gmail",
          "workspace" => ctx.ws_a,
          "config" => %{"user_email" => "ops@example.com"},
          "credentials" => %{
            "oauth_refresh_token" => @secret,
            "client_id" => "example-client",
            "client_secret" => @secret
          }
        })

      assert conn.status == 201
      body = json_body(conn)
      assert body["id"] == "gmail-#{ctx.suffix}"
      assert body["workspace_id"] == ctx.ws_a
      assert body["credentials"] == "stored"
      refute conn.resp_body =~ @secret
      refute conn.resp_body =~ "ciphertext"

      assert Enum.any?(
               Evidence.list("default", kind: "connector.registered"),
               &(&1["detail"]["connector_id"] == "gmail-#{ctx.suffix}")
             )
    end

    test "refuses a missing, archived, or out-of-scope workspace", ctx do
      base = %{"id" => "c-#{ctx.suffix}", "kind" => "sources_folder", "config" => %{}}

      assert %{status: 400} = request(ctx.admin, :post, "/api/connectors", base)

      conn = request(ctx.admin, :post, "/api/connectors", Map.put(base, "workspace", ctx.old))
      assert conn.status == 409
      assert json_body(conn)["error"] == "workspace_archived"

      conn =
        request(ctx.operator_a, :post, "/api/connectors", Map.put(base, "workspace", ctx.ws_b))

      assert conn.status == 403
    end

    test "a review workspace outside the key's scope is refused, on registration and on change",
         ctx do
      id = "review-#{ctx.suffix}"

      body = fn review ->
        %{
          "id" => id,
          "kind" => "sources_folder",
          "workspace" => ctx.ws_a,
          "config" => %{"root" => ctx.root, "review_workspace_id" => review}
        }
      end

      review_of = fn ->
        {:ok, [[review]]} =
          Store.raw_query(
            "SELECT json_extract(config, '$.review_workspace_id') FROM connectors WHERE id = ?1",
            [id]
          )

        review
      end

      conn = request(ctx.operator_a, :post, "/api/connectors", body.(ctx.ws_b))
      assert conn.status == 403
      assert json_body(conn)["error"] == "workspace_scope_denied"
      assert {:ok, []} = Store.raw_query("SELECT 1 FROM connectors WHERE id = ?1", [id])

      # A workspace the key holds is taken.
      assert %{status: 201} = request(ctx.operator_a, :post, "/api/connectors", body.(ctx.ws_a))
      assert review_of.() == ctx.ws_a

      conn =
        request(ctx.operator_a, :patch, "/api/connectors/#{id}", %{
          "config" => %{"root" => ctx.root, "review_workspace_id" => ctx.ws_b}
        })

      assert conn.status == 403
      assert json_body(conn)["error"] == "workspace_scope_denied"
      assert review_of.() == ctx.ws_a

      # A key that covers both names either.
      conn =
        request(ctx.admin, :patch, "/api/connectors/#{id}", %{
          "config" => %{"root" => ctx.root, "review_workspace_id" => ctx.ws_b}
        })

      assert conn.status == 200
      assert review_of.() == ctx.ws_b
    end

    test "needs admin or connectors:write", ctx do
      body = %{
        "id" => "folder-#{ctx.suffix}",
        "kind" => "sources_folder",
        "workspace" => ctx.ws_a,
        "config" => %{"root" => ctx.root}
      }

      assert %{status: 403} = request(ctx.reader, :post, "/api/connectors", body)
      assert %{status: 403} = request(ctx.writer_a, :post, "/api/connectors", body)
      assert %{status: 201} = request(ctx.operator_a, :post, "/api/connectors", body)
      assert %{status: 409} = request(ctx.operator_a, :post, "/api/connectors", body)
    end

    test "refuses secrets outside the credentials envelope", ctx do
      conn =
        request(ctx.admin, :post, "/api/connectors", %{
          "id" => "leaky-#{ctx.suffix}",
          "kind" => "github",
          "workspace" => ctx.ws_a,
          "config" => %{"org_or_user" => "example", "repos" => ["a"], "pat" => @secret}
        })

      assert conn.status == 422
      assert json_body(conn)["error"] == "credentials_outside_envelope"
    end
  end

  describe "workspace confinement" do
    setup ctx do
      a = register!(ctx, "conn-in-a-#{ctx.suffix}", ctx.ws_a)
      b = register!(ctx, "conn-in-b-#{ctx.suffix}", ctx.ws_b)
      {:ok, a: a, b: b}
    end

    test "a workspace key lists only its workspace's connectors", ctx do
      ids = ctx.writer_a |> request(:get, "/api/connectors") |> json_body() |> ids()
      assert ctx.a in ids
      refute ctx.b in ids

      ids =
        ctx.reader |> request(:get, "/api/connectors?workspace=#{ctx.ws_b}") |> json_body() |> ids()

      assert ids == [ctx.b]

      assert %{status: 403} = request(ctx.writer_a, :get, "/api/connectors?workspace=#{ctx.ws_b}")
    end

    test "another workspace's connector is not found on every route", ctx do
      assert %{status: 404} = request(ctx.writer_a, :get, "/api/connectors/#{ctx.b}")

      assert %{status: 404} =
               request(ctx.operator_a, :patch, "/api/connectors/#{ctx.b}", %{"enabled" => false})

      assert %{status: 404} = request(ctx.writer_a, :post, "/api/connectors/#{ctx.b}/run", %{})
      assert %{status: 404} = request(ctx.operator_a, :delete, "/api/connectors/#{ctx.b}")
      assert %{status: 404} = request(ctx.admin, :get, "/api/connectors/missing-#{ctx.suffix}")

      assert %{status: 200} = request(ctx.reader_b, :get, "/api/connectors/#{ctx.b}")
    end

    test "a connector cannot be moved into a workspace outside the key", ctx do
      assert %{status: 403} =
               request(ctx.operator_a, :patch, "/api/connectors/#{ctx.a}", %{
                 "workspace" => ctx.ws_b
               })

      assert %{status: 403} =
               request(ctx.operator_a, :patch, "/api/connectors/#{ctx.a}", %{
                 "workspace_id" => ctx.ws_b
               })

      assert %{status: 200, resp_body: body} =
               request(ctx.reader, :get, "/api/connectors/#{ctx.a}")

      assert Jason.decode!(body)["workspace_id"] == ctx.ws_a
    end

    test "the list never carries credentials or ciphertext", ctx do
      conn = request(ctx.reader, :get, "/api/connectors")
      assert conn.status == 200
      refute conn.resp_body =~ @secret
      refute conn.resp_body =~ "ciphertext"
    end
  end

  describe "a connector on the credential broker" do
    @reference "conn_0000000009.example-signature"

    defp broker_body(ctx, id) do
      %{
        "id" => id,
        "kind" => "gmail",
        "workspace" => ctx.ws_a,
        "config" => %{
          "user_email" => "ops@example.com",
          "credential_source" => "broker",
          "broker_url" => "https://connect.example.com/api/credentials",
          "broker_reference" => @reference,
          "broker_scopes" => ["gmail.readonly"]
        }
      }
    end

    test "its reference is sealed on write and redacted on every read, through a move", ctx do
      id = "broker-#{ctx.suffix}"

      conn = request(ctx.admin, :post, "/api/connectors", broker_body(ctx, id))
      assert conn.status == 201, conn.resp_body
      assert json_body(conn)["config"]["broker_reference"] == "[redacted]"
      assert json_body(conn)["credential_source"] == "broker"

      reads = fn ->
        [
          request(ctx.reader, :get, "/api/connectors/#{id}"),
          request(ctx.reader, :get, "/api/connectors"),
          request(ctx.reader, :get, "/api/metrics")
        ]
      end

      for conn <- reads.() do
        assert conn.status == 200
        refute conn.resp_body =~ @reference
        refute conn.resp_body =~ "broker_reference_ciphertext"
      end

      conn = request(ctx.admin, :patch, "/api/connectors/#{id}", %{"workspace" => ctx.ws_b})
      assert conn.status == 200, conn.resp_body
      assert json_body(conn)["workspace_id"] == ctx.ws_b
      assert json_body(conn)["config"]["broker_reference"] == "[redacted]"
      refute conn.resp_body =~ @reference

      for conn <- reads.() do
        refute conn.resp_body =~ @reference
        refute conn.resp_body =~ "broker_reference_ciphertext"
      end

      {:ok, [[stored]]} = Store.raw_query("SELECT config FROM connectors WHERE id = ?1", [id])
      refute stored =~ @reference
      assert stored =~ "broker_reference_ciphertext"

      refute Jason.encode!(Evidence.list("default")) =~ @reference
    end

    test "the ciphertext is the Engine's alone to write", ctx do
      id = "broker-forged-#{ctx.suffix}"
      assert %{status: 201} = request(ctx.admin, :post, "/api/connectors", broker_body(ctx, id))

      conn =
        request(ctx.admin, :patch, "/api/connectors/#{id}", %{
          "config" => %{"broker_reference_ciphertext" => "forged"}
        })

      assert conn.status == 422
      assert json_body(conn)["error"] == "credentials_outside_envelope"
    end

    test "a broker URL the Engine may not call is refused on write and on change", ctx do
      id = "broker-url-#{ctx.suffix}"
      body = broker_body(ctx, id)

      refused =
        put_in(body, ["config", "broker_url"], "https://elsewhere.example.net/api/credentials")

      conn = request(ctx.admin, :post, "/api/connectors", refused)
      assert conn.status == 422
      assert json_body(conn)["error"] == "broker_url_not_allowed"

      assert %{status: 201} = request(ctx.admin, :post, "/api/connectors", body)

      conn =
        request(ctx.admin, :patch, "/api/connectors/#{id}", %{
          "config" => %{"broker_url" => "https://connect.example.com:8443/api/credentials"}
        })

      assert conn.status == 422
      assert json_body(conn)["error"] == "broker_url_not_allowed"
    end
  end

  describe "PATCH, run, and DELETE" do
    setup ctx do
      {:ok, id: register!(ctx, "folder-#{ctx.suffix}", ctx.ws_a)}
    end

    test "PATCH changes enabled, cadence and credentials, and needs connectors:write", ctx do
      path = "/api/connectors/#{ctx.id}"
      assert %{status: 403} = request(ctx.writer_a, :patch, path, %{"enabled" => false})

      conn =
        request(ctx.operator_a, :patch, path, %{
          "enabled" => false,
          "cadence" => "hourly",
          "credentials" => %{"token" => "#{@secret}-2"}
        })

      assert conn.status == 200
      body = json_body(conn)
      assert body["enabled"] == false
      assert body["cadence"] == %{"interval_ms" => 3_600_000, "source" => "config"}
      assert body["credentials"] == "stored"
      refute conn.resp_body =~ @secret

      conn = request(ctx.operator_a, :patch, path, %{"cadence" => "every so often"})
      assert conn.status == 422
      assert json_body(conn)["error"] == "invalid_cadence"
    end

    test "run pulls now into the connector's workspace, and needs write", ctx do
      path = "/api/connectors/#{ctx.id}/run"
      assert %{status: 403} = request(ctx.reader, :post, path, %{})

      conn = request(ctx.writer_a, :post, path, %{})
      assert conn.status == 200
      body = json_body(conn)
      assert body["status"] == "success"
      assert body["signals"] == 2
      assert body["workspace_id"] == ctx.ws_a
      assert contexts_in(ctx.ws_a, "First note #{ctx.suffix}") >= 1

      # The list shows the run.
      [view] =
        ctx.writer_a |> request(:get, "/api/connectors/#{ctx.id}") |> json_body() |> List.wrap()

      assert view["last_run"]["status"] == "success"
      assert view["last_run"]["signals"] == 2
      assert view["signals_total"] == 2

      # A disabled connector does not run.
      request(ctx.operator_a, :patch, "/api/connectors/#{ctx.id}", %{"enabled" => false})
      conn = request(ctx.writer_a, :post, path, %{})
      assert conn.status == 409
      assert json_body(conn)["error"] == "connector_disabled"
    end

    test "DELETE removes the connector", ctx do
      assert %{status: 403} = request(ctx.writer_a, :delete, "/api/connectors/#{ctx.id}")
      assert %{status: 200} = request(ctx.operator_a, :delete, "/api/connectors/#{ctx.id}")
      assert %{status: 404} = request(ctx.writer_a, :get, "/api/connectors/#{ctx.id}")
    end
  end

  test "GET /api/metrics reports connector status within the key's workspaces", ctx do
    register!(ctx, "metric-a-#{ctx.suffix}", ctx.ws_a)
    register!(ctx, "metric-b-#{ctx.suffix}", ctx.ws_b)

    conn = request(ctx.reader_b, :get, "/api/metrics")
    assert conn.status == 200
    connectors = json_body(conn)["connectors"]
    assert connectors["total"] == 1
    assert connectors["enabled"] == 1
    refute conn.resp_body =~ "metric-a-#{ctx.suffix}"
  end

  # ─── helpers ──────────────────────────────────────────────────────────────

  defp register!(ctx, id, workspace) do
    conn =
      request(ctx.admin, :post, "/api/connectors", %{
        "id" => id,
        "kind" => "sources_folder",
        "workspace" => workspace,
        "config" => %{"root" => ctx.root},
        "credentials" => %{"token" => @secret}
      })

    assert conn.status == 201, conn.resp_body
    id
  end

  defp ids(%{"connectors" => connectors}), do: Enum.map(connectors, & &1["id"])

  defp mint(scopes, workspace_scope) do
    {:ok, %{key: token}} =
      ApiKey.mint(%{
        tenant_id: "default",
        name: "connectors api #{System.unique_integer([:positive])}",
        scopes: scopes,
        workspace_scope: workspace_scope
      })

    token
  end

  defp request(token, method, path, body \\ nil) do
    conn =
      case body do
        nil ->
          conn(method, path)

        body ->
          conn(method, path, Jason.encode!(body))
          |> put_req_header("content-type", "application/json")
      end

    conn
    |> put_req_header("authorization", "Bearer #{token}")
    |> Router.call(@opts)
  end

  defp json_body(conn), do: Jason.decode!(conn.resp_body)

  defp contexts_in(workspace_id, title) do
    {:ok, [[n]]} =
      Store.raw_query(
        "SELECT COUNT(*) FROM contexts WHERE workspace_id = ?1 AND title = ?2",
        [workspace_id, title]
      )

    n
  end

  defp insert_workspace(id, status) do
    {:ok, _} =
      Store.raw_query(
        """
        INSERT INTO workspaces (id, tenant_id, slug, name, status, metadata)
        VALUES (?1, 'default', ?2, ?3, ?4, '{}')
        """,
        [id, id |> String.split(":") |> List.last(), "WS #{id}", status]
      )

    id
  end
end
