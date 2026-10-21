defmodule OptimalEngine.API.SecurityFoundationsTest do
  @moduledoc """
  Regression tests for the API security foundations:

  1. The acting identity comes from the authenticated key, never the body.
  2. Access lists follow an explicit absent policy and ranked permissions.
  3. Every route family is workspace-scoped unless it is a global family,
     `workspace_id` is authorized like `workspace`, and a key restricted to
     named workspaces must name one.
  4. Governed grants come only from the key.
  5. Key minting only narrows, keys are revoked only inside their tenant,
     and an unreadable expiry fails closed.
  6. Sync idempotency keys never cross workspaces.
  7. Backups are confined to the backup directory.
  8. Connector credentials are encrypted whatever their key form.
  """

  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias OptimalEngine.API.{Actor, Router}
  alias OptimalEngine.Auth.{ApiKey, KeyIssuance}
  alias OptimalEngine.Identity.{ACL, Principal}
  alias OptimalEngine.Store
  alias OptimalEngine.Tenancy.Tenant

  @opts Router.init([])

  setup do
    suffix = System.unique_integer([:positive])
    alpha = insert_workspace("default:alpha-#{suffix}", "default", "alpha-#{suffix}")
    beta = insert_workspace("default:beta-#{suffix}", "default", "beta-#{suffix}")

    foreign_tenant = "othertenant-#{suffix}"
    {:ok, _} = Tenant.create(%{id: foreign_tenant, name: "Other #{suffix}"})
    foreign = insert_workspace("#{foreign_tenant}:vault", foreign_tenant, "vault")

    {:ok, _} =
      Principal.upsert(%{
        id: "agent:writer-#{suffix}",
        tenant_id: "default",
        kind: :agent,
        display_name: "Writer #{suffix}"
      })

    {:ok,
     suffix: suffix,
     alpha: alpha,
     beta: beta,
     foreign_tenant: foreign_tenant,
     foreign: foreign,
     principal: "agent:writer-#{suffix}"}
  end

  defp insert_workspace(id, tenant_id, slug) do
    {:ok, _} =
      Store.raw_query(
        """
        INSERT OR IGNORE INTO workspaces (id, tenant_id, slug, name, status, metadata)
        VALUES (?1, ?2, ?3, ?4, 'active', '{}')
        """,
        [id, tenant_id, slug, "WS #{slug}"]
      )

    id
  end

  defp request(method, path, token \\ nil, body \\ nil) do
    conn =
      case body do
        nil ->
          conn(method, path)

        body ->
          conn(method, path, Jason.encode!(body))
          |> put_req_header("content-type", "application/json")
      end

    conn = if token, do: put_req_header(conn, "authorization", "Bearer " <> token), else: conn
    Router.call(conn, @opts)
  end

  defp json_body(conn), do: Jason.decode!(conn.resp_body)

  defp with_env(app_key, value, fun) do
    original = Application.get_env(:optimal_engine, app_key)
    Application.put_env(:optimal_engine, app_key, value)

    try do
      fun.()
    after
      if is_nil(original),
        do: Application.delete_env(:optimal_engine, app_key),
        else: Application.put_env(:optimal_engine, app_key, original)
    end
  end

  defp with_auth_required(fun) do
    original = Application.get_env(:optimal_engine, :auth, [])
    with_env(:auth, Keyword.merge(original, auth_required: true, bcrypt_cost: 4), fun)
  end

  defp mint!(attrs) do
    {:ok, %{key: token, id: id}} = ApiKey.mint(Map.merge(%{tenant_id: "default"}, attrs))
    {token, id}
  end

  describe "acting identity" do
    test "a keyed mutation that names another actor is refused", ctx do
      {token, _id} =
        mint!(%{
          name: "writer",
          scopes: ["write"],
          workspace_scope: [ctx.alpha],
          principal_id: ctx.principal
        })

      conn =
        request(:post, "/api/storage/workspaces/#{ctx.alpha}/mutations", token, %{
          "device_id" => "device-1",
          "entity_type" => "note",
          "entity_id" => "n1",
          "operation" => "create",
          "actor_id" => "user:someone-else"
        })

      assert conn.status == 403
      assert json_body(conn)["error"] == "actor_identity_mismatch"
    end

    test "a keyed mutation records the key's principal", ctx do
      {token, _id} =
        mint!(%{
          name: "writer",
          scopes: ["write"],
          workspace_scope: [ctx.alpha],
          principal_id: ctx.principal
        })

      conn =
        request(:post, "/api/storage/workspaces/#{ctx.alpha}/mutations", token, %{
          "device_id" => "device-1",
          "entity_type" => "note",
          "entity_id" => "n1",
          "operation" => "create"
        })

      assert conn.status == 201
      assert json_body(conn)["actor_id"] == ctx.principal
    end

    test "a key without a principal acts as itself", ctx do
      {token, id} = mint!(%{name: "anon key", scopes: ["write"], workspace_scope: [ctx.alpha]})

      conn =
        request(:post, "/api/storage/workspaces/#{ctx.alpha}/mutations", token, %{
          "device_id" => "device-1",
          "entity_type" => "note",
          "entity_id" => "n2",
          "operation" => "create"
        })

      assert conn.status == 201
      assert json_body(conn)["actor_id"] == "api_key:" <> id
    end

    test "an anonymous local request acts as the configured local operator", ctx do
      assert Actor.local_operator() == "local:operator"

      with_env(:local_operator_id, "operator:example", fn ->
        conn =
          request(:post, "/api/storage/workspaces/#{ctx.alpha}/mutations", nil, %{
            "device_id" => "device-1",
            "entity_type" => "note",
            "entity_id" => "n3",
            "operation" => "create"
          })

        assert conn.status == 201
        assert json_body(conn)["actor_id"] == "operator:example"
      end)
    end

    test "an anonymous local caller may name an actor; a keyed caller may not" do
      anonymous = conn(:post, "/")
      assert Actor.of(anonymous, %{"actor_id" => "agent:named"}) == "agent:named"
      assert Actor.of(anonymous, %{}) == Actor.local_operator()

      keyed = assign(anonymous, :current_principal_id, "agent:keyed")
      assert Actor.of(keyed, %{"actor_id" => "agent:named"}) == "agent:keyed"
    end
  end

  describe "access lists" do
    test "a resource with no rows follows the absent policy", ctx do
      uri = "optimal://test/absent-#{ctx.suffix}"
      assert ACL.can?(ctx.principal, uri, :read, absent: :allow)
      refute ACL.can?(ctx.principal, uri, :read, absent: :deny)

      with_env(:acl_absent, :deny, fn -> refute ACL.can?(ctx.principal, uri, :read) end)
      with_env(:acl_absent, :bogus, fn -> refute ACL.can?(ctx.principal, uri, :read) end)
    end

    test "permissions are ranked admin over write over read", ctx do
      uri = "optimal://test/ranked-#{ctx.suffix}"
      :ok = ACL.grant(%{resource_uri: uri, permission: :write, principal_id: ctx.principal})

      assert ACL.can?(ctx.principal, uri, :read)
      assert ACL.can?(ctx.principal, uri, :write)
      refute ACL.can?(ctx.principal, uri, :admin)
      refute ACL.can?("agent:stranger-#{ctx.suffix}", uri, :read, absent: :allow)
    end
  end

  describe "workspace scope on every route family" do
    test "families that used to skip the check now refuse a foreign workspace", ctx do
      for path <- [
            "/api/rhythm/draft?workspace=#{ctx.foreign}",
            "/api/context-health?workspace=#{ctx.foreign}",
            "/api/operating-projection?workspace=#{ctx.foreign}",
            "/api/entities/quality?workspace=#{ctx.foreign}",
            "/api/data-steward/dashboard?workspace=#{ctx.foreign}",
            "/api/l0?workspace=#{ctx.foreign}",
            "/api/stats?workspace=#{ctx.foreign}"
          ] do
        conn = request(:get, path)
        assert conn.status == 404, "#{path} returned #{conn.status}"
      end
    end

    test "workspace_id is authorized like workspace", ctx do
      {token, _id} = mint!(%{name: "alpha reader", scopes: ["read"], workspace_scope: [ctx.alpha]})

      with_auth_required(fn ->
        conn = request(:get, "/api/stores/relational/records?workspace_id=#{ctx.beta}", token)
        assert conn.status == 403
        assert json_body(conn)["error"] == "workspace_scope_denied"

        conn = request(:get, "/api/stores/relational/records?workspace_id=#{ctx.foreign}", token)
        assert conn.status == 404
      end)
    end

    test "a key restricted to named workspaces must name one", ctx do
      {token, _id} = mint!(%{name: "alpha only", scopes: ["read"], workspace_scope: [ctx.alpha]})

      with_auth_required(fn ->
        conn = request(:get, "/api/rhythm/draft", token)
        assert conn.status == 400
        assert json_body(conn)["error"] == "workspace_required"

        assert request(:get, "/api/rhythm/draft?workspace=#{ctx.alpha}", token).status != 400
        assert request(:get, "/api/status", token).status == 200
      end)
    end

    test "a key whose scope covers default keeps the implicit default", ctx do
      {token, _id} =
        mint!(%{name: "default reader", scopes: ["read"], workspace_scope: ["default", ctx.alpha]})

      with_auth_required(fn ->
        conn = request(:get, "/api/graph", token)
        assert conn.status == 200
        assert conn.assigns[:workspace_id] == "default"
      end)
    end
  end

  describe "governed grants" do
    test "assemble takes partitions and labels from the key, never the body", ctx do
      {token, _id} =
        mint!(%{
          name: "grant holder",
          scopes: ["read"],
          workspace_scope: ["*"],
          principal_id: ctx.principal,
          metadata: %{"allowed_partitions" => ["team-a"], "allowed_security_labels" => ["internal"]}
        })

      body = %{
        "query" => "what is in the restricted partition",
        "workspace" => ctx.alpha,
        "allowed_partitions" => ["restricted"],
        "allowed_security_labels" => ["secret"],
        "permissions" => ["memory.reconstruction.review"]
      }

      conn = request(:post, "/api/assemble", token, body)
      assert conn.status == 200
      envelope = get_in(json_body(conn), ["context_package", "authorization_envelope"])
      assert envelope["allowed_partitions"] == ["team-a"]
      assert envelope["allowed_security_labels"] == ["internal"]

      {bare, _id} = mint!(%{name: "no grants", scopes: ["read"], workspace_scope: ["*"]})
      conn = request(:post, "/api/assemble", bare, body)
      assert conn.status == 200
      envelope = get_in(json_body(conn), ["context_package", "authorization_envelope"])
      assert envelope["allowed_partitions"] == []
      assert envelope["allowed_security_labels"] == []
    end
  end

  describe "key issuance" do
    test "delegation only narrows", ctx do
      parent = %ApiKey{
        id: "parent",
        tenant_id: "default",
        scopes: ["read", "write", "admin"],
        workspace_scope: [ctx.alpha, ctx.beta],
        expires_at: "2099-01-01T00:00:00Z",
        metadata: %{
          "allowed_partitions" => ["team-a", "team-b"],
          "allowed_security_labels" => ["internal"],
          "permissions" => ["memory:read"]
        }
      }

      assert {:ok, attrs} = KeyIssuance.attrs(parent, "default", %{"name" => "child"})
      assert attrs.scopes == parent.scopes
      assert attrs.workspace_scope == parent.workspace_scope
      assert attrs.expires_at == parent.expires_at

      # Operation scopes and permissions are inherited when omitted; label and
      # partition grants are not: a key minted without them holds none.
      assert attrs.metadata == %{"permissions" => ["memory:read"]}

      assert {:ok,
              %{metadata: %{"allowed_partitions" => ["team-a"], "allowed_security_labels" => []}}} =
               KeyIssuance.attrs(parent, "default", %{
                 "name" => "granted",
                 "allowed_partitions" => ["team-a"],
                 "allowed_security_labels" => []
               })

      assert {:ok, %{scopes: ["read"], workspace_scope: [_]}} =
               KeyIssuance.attrs(parent, "default", %{
                 "name" => "narrow",
                 "scopes" => ["read"],
                 "workspace_scope" => [ctx.alpha]
               })

      for {field, value, error} <- [
            {"scopes", ["*"], "scope_exceeds_minter"},
            {"scopes", ["topology:write"], "scope_exceeds_minter"},
            {"workspace_scope", ["*"], "workspace_scope_exceeds_minter"},
            {"workspace_scope", ["default:elsewhere"], "workspace_scope_exceeds_minter"},
            {"expires_at", "2100-01-01T00:00:00Z", "expiry_exceeds_minter"},
            {"allowed_partitions", ["team-c"], "allowed_partitions_exceeds_minter"},
            {"allowed_security_labels", ["secret"], "allowed_security_labels_exceeds_minter"}
          ] do
        assert {:error, ^error} =
                 KeyIssuance.attrs(parent, "default", %{"name" => "wide", field => value}),
               "#{field} #{inspect(value)}"
      end
    end

    test "a key minted without label or partition grants never inherits the minter's wildcard",
         ctx do
      bootstrap = %ApiKey{
        id: "bootstrap",
        tenant_id: "default",
        scopes: ["*"],
        workspace_scope: ["*"],
        metadata: %{
          "source" => "bootstrap",
          "allowed_security_labels" => ["*"],
          "allowed_partitions" => ["*"]
        }
      }

      assert {:ok, attrs} =
               KeyIssuance.attrs(bootstrap, "default", %{
                 "name" => "child",
                 "scopes" => ["read"],
                 "workspace_scope" => [ctx.alpha]
               })

      refute Map.has_key?(attrs.metadata, "allowed_security_labels")
      refute Map.has_key?(attrs.metadata, "allowed_partitions")

      # The minter may give what it holds, a wildcard included, when it is asked to.
      assert {:ok, %{metadata: %{"allowed_security_labels" => ["*"]}}} =
               KeyIssuance.attrs(bootstrap, "default", %{
                 "name" => "wide",
                 "scopes" => ["read"],
                 "allowed_security_labels" => ["*"]
               })

      # A minter without a wildcard cannot give one.
      holder = %{
        bootstrap
        | scopes: ["read"],
          metadata: %{"allowed_security_labels" => ["internal"]}
      }

      assert {:error, "allowed_security_labels_exceeds_minter"} =
               KeyIssuance.attrs(holder, "default", %{
                 "name" => "wider",
                 "allowed_security_labels" => ["*"]
               })
    end

    test "a root key issues any scopes but never a wider workspace", ctx do
      root = %ApiKey{id: "root", tenant_id: "default", scopes: ["*"], workspace_scope: [ctx.alpha]}

      assert {:ok, %{scopes: ["*"]}} =
               KeyIssuance.attrs(root, "default", %{"name" => "c", "scopes" => ["*"]})

      assert {:error, "workspace_scope_exceeds_minter"} =
               KeyIssuance.attrs(root, "default", %{
                 "name" => "c",
                 "scopes" => ["read"],
                 "workspace_scope" => ["*"]
               })
    end

    test "a root key gives only the label and partition grants it holds", ctx do
      root = %ApiKey{id: "root", tenant_id: "default", scopes: ["*"], workspace_scope: [ctx.alpha]}

      for field <- ["allowed_security_labels", "allowed_partitions"],
          value <- [["*"], ["restricted"]] do
        expected = "#{field}_exceeds_minter"

        assert {:error, ^expected} =
                 KeyIssuance.attrs(root, "default", %{
                   "name" => "c",
                   "scopes" => ["*"],
                   field => value
                 }),
               "#{field} #{inspect(value)}"
      end

      narrowed = %{root | metadata: %{"allowed_security_labels" => ["public"]}}

      assert {:error, "allowed_security_labels_exceeds_minter"} =
               KeyIssuance.attrs(narrowed, "default", %{
                 "name" => "sibling",
                 "scopes" => ["*"],
                 "allowed_security_labels" => ["*"]
               })

      assert {:ok, %{metadata: %{"allowed_security_labels" => ["public"]}}} =
               KeyIssuance.attrs(narrowed, "default", %{
                 "name" => "same",
                 "scopes" => ["*"],
                 "allowed_security_labels" => ["public"]
               })

      holder = %{
        root
        | metadata: %{"allowed_security_labels" => ["*"], "allowed_partitions" => ["*"]}
      }

      assert {:ok,
              %{metadata: %{"allowed_security_labels" => ["*"], "allowed_partitions" => ["*"]}}} =
               KeyIssuance.attrs(holder, "default", %{
                 "name" => "wide",
                 "scopes" => ["*"],
                 "allowed_security_labels" => ["*"],
                 "allowed_partitions" => ["*"]
               })
    end

    test "a root-scoped key minted without grants cannot mint a wildcard grant over HTTP" do
      {root_child, _id} = mint!(%{name: "root-child", scopes: ["*"], workspace_scope: ["*"]})

      with_auth_required(fn ->
        for field <- ["allowed_security_labels", "allowed_partitions"] do
          conn =
            request(:post, "/api/auth/keys", root_child, %{
              "name" => "grandchild",
              "scopes" => ["*"],
              field => ["*"]
            })

          assert conn.status == 403
          assert json_body(conn)["error"] == "#{field}_exceeds_minter"
        end

        conn =
          request(:post, "/api/auth/keys", root_child, %{
            "name" => "plain",
            "scopes" => ["read"]
          })

        assert conn.status == 201
      end)
    end

    test "scopes are never unrestricted by omission" do
      root = %ApiKey{id: "root", tenant_id: "default", scopes: ["*"], workspace_scope: ["*"]}
      reader = %ApiKey{id: "reader", tenant_id: "default", scopes: ["read"], workspace_scope: ["*"]}

      assert {:error, "scopes_required"} = KeyIssuance.attrs(root, "default", %{"name" => "c"})
      assert {:error, "scopes_required"} = KeyIssuance.attrs(nil, "default", %{"name" => "c"})

      assert {:ok, %{scopes: ["*"]}} =
               KeyIssuance.attrs(root, "default", %{"name" => "c", "scopes" => ["*"]})

      assert {:ok, %{scopes: ["read", "write"]}} =
               KeyIssuance.attrs(nil, "default", %{"name" => "c", "scopes" => ["read", "write"]})

      # A minter whose scopes are named still passes them down.
      assert {:ok, %{scopes: ["read"]}} = KeyIssuance.attrs(reader, "default", %{"name" => "c"})
    end

    test "the principal must exist in the tenant", ctx do
      assert {:error, "principal_not_found"} =
               KeyIssuance.attrs(nil, "default", %{
                 "name" => "c",
                 "scopes" => ["read"],
                 "principal_id" => "agent:missing-#{ctx.suffix}"
               })

      assert {:error, "principal_not_found"} =
               KeyIssuance.attrs(nil, ctx.foreign_tenant, %{
                 "name" => "c",
                 "scopes" => ["read"],
                 "principal_id" => ctx.principal
               })

      assert {:ok, %{principal_id: principal}} =
               KeyIssuance.attrs(nil, "default", %{
                 "name" => "c",
                 "scopes" => ["read"],
                 "principal_id" => ctx.principal
               })

      assert principal == ctx.principal
    end

    test "malformed requests are refused" do
      assert {:error, "name is required"} = KeyIssuance.attrs(nil, "default", %{})

      assert {:error, "invalid scopes"} =
               KeyIssuance.attrs(nil, "default", %{"name" => "c", "scopes" => "*"})

      assert {:error, "invalid expires_at"} =
               KeyIssuance.attrs(nil, "default", %{
                 "name" => "c",
                 "scopes" => ["read"],
                 "expires_at" => "next week"
               })
    end

    test "the HTTP route applies the narrowing rules", ctx do
      {admin, _id} =
        mint!(%{name: "admin", scopes: ["read", "admin"], workspace_scope: [ctx.alpha]})

      with_auth_required(fn ->
        conn = request(:post, "/api/auth/keys", admin, %{"name" => "wide", "scopes" => ["write"]})
        assert conn.status == 403
        assert json_body(conn)["error"] == "scope_exceeds_minter"

        conn =
          request(:post, "/api/auth/keys", admin, %{
            "name" => "ghost",
            "principal_id" => "agent:ghost-#{ctx.suffix}"
          })

        assert conn.status == 422

        conn = request(:post, "/api/auth/keys", admin, %{"name" => "child", "scopes" => ["read"]})
        assert conn.status == 201
        child = json_body(conn)["key"]

        assert {:ok, %ApiKey{scopes: ["read"], workspace_scope: [workspace]}} =
                 ApiKey.verify(child)

        assert workspace == ctx.alpha
      end)
    end

    test "keys are revoked and deleted only inside their own tenant", ctx do
      {_token, foreign_key} =
        mint!(%{tenant_id: ctx.foreign_tenant, name: "foreign key", scopes: ["read"]})

      {admin, _id} = mint!(%{name: "admin", scopes: ["*"], workspace_scope: ["*"]})

      with_auth_required(fn ->
        assert request(:post, "/api/auth/keys/#{foreign_key}/revoke", admin).status == 404
        assert request(:delete, "/api/auth/keys/#{foreign_key}", admin).status == 404
      end)

      assert {:ok, [[nil]]} =
               Store.raw_query("SELECT revoked_at FROM api_keys WHERE id = ?1", [foreign_key])
    end

    test "an expiry that cannot be read fails closed" do
      {token, id} = mint!(%{name: "odd expiry", scopes: ["read"]})
      {:ok, _} = Store.raw_query("UPDATE api_keys SET expires_at = 'never' WHERE id = ?1", [id])
      assert {:error, :expired} = ApiKey.verify(token)
    end
  end

  describe "principals" do
    test "admins register principals; ids owned by another tenant are refused", ctx do
      {admin, _id} = mint!(%{name: "admin", scopes: ["admin"], workspace_scope: ["*"]})
      {reader, _id} = mint!(%{name: "reader", scopes: ["read"], workspace_scope: ["*"]})

      {foreign_admin, _id} =
        mint!(%{tenant_id: ctx.foreign_tenant, name: "foreign admin", scopes: ["admin"]})

      with_auth_required(fn ->
        body = %{
          "id" => "agent:registered-#{ctx.suffix}",
          "kind" => "agent",
          "display_name" => "Registered"
        }

        assert request(:post, "/api/principals", reader, body).status == 403

        conn = request(:post, "/api/principals", admin, body)
        assert conn.status == 201
        assert json_body(conn)["kind"] == "agent"

        assert request(:get, "/api/principals?kind=agent", admin)
               |> json_body()
               |> Map.get("principals")
               |> Enum.any?(&(&1["id"] == body["id"]))

        conn =
          request(
            :post,
            "/api/principals",
            foreign_admin,
            Map.put(body, "display_name", "Hijacked")
          )

        assert conn.status == 409

        assert request(:get, "/api/principals/#{URI.encode_www_form(body["id"])}", foreign_admin).status ==
                 404
      end)

      assert {:ok, %{display_name: "Registered"}} =
               Principal.get("agent:registered-#{ctx.suffix}", "default")
    end
  end

  describe "sync idempotency" do
    defp mutation(workspace, key, entity_id) do
      OptimalEngine.Storage.PolicyStore.append_mutation(%{
        workspace_id: workspace,
        device_id: "device-1",
        entity_type: "note",
        entity_id: entity_id,
        operation: "create",
        payload: %{"text" => "hello"},
        idempotency_key: key
      })
    end

    test "a replay in the same workspace returns the recorded mutation", ctx do
      key = "idem-#{ctx.suffix}"
      assert {:ok, first} = mutation(ctx.alpha, key, "n1")
      assert {:ok, replay} = mutation(ctx.alpha, key, "n1")
      assert replay.id == first.id
    end

    test "a key reused for another mutation or workspace is a conflict", ctx do
      key = "idem-shared-#{ctx.suffix}"
      assert {:ok, first} = mutation(ctx.alpha, key, "n1")
      assert {:error, :idempotency_key_conflict} = mutation(ctx.alpha, key, "n2")
      assert {:error, :idempotency_key_conflict} = mutation(ctx.beta, key, "n1")

      conn =
        request(:post, "/api/storage/workspaces/#{ctx.beta}/mutations", nil, %{
          "device_id" => "device-1",
          "entity_type" => "note",
          "entity_id" => "n1",
          "operation" => "create",
          "payload" => %{"text" => "hello"},
          "idempotency_key" => key
        })

      assert conn.status == 409
      refute conn.resp_body =~ first.id
    end
  end

  describe "backups" do
    test "a backup path outside the backup directory is refused", ctx do
      dir = Path.join(System.tmp_dir!(), "oe-backups-#{ctx.suffix}")

      with_env(:backup_dir, dir, fn ->
        for body <- [
              %{"path" => "/tmp/escape-#{ctx.suffix}.db"},
              %{"path" => "../escape-#{ctx.suffix}.db"},
              %{"name" => "../escape.db"},
              %{"name" => "/abs.db"}
            ] do
          conn = request(:post, "/api/backup", nil, body)
          assert conn.status == 400, inspect(body)
        end

        conn = request(:post, "/api/backup", nil, %{"name" => "named-#{ctx.suffix}.db"})
        assert conn.status == 200
        assert json_body(conn)["path"] == Path.join(Path.expand(dir), "named-#{ctx.suffix}.db")
      end)

      File.rm_rf!(dir)
    end
  end

  describe "connector credentials" do
    alias OptimalEngine.Connectors.Runner

    defp stored_config(id) do
      {:ok, [[config]]} = Store.raw_query("SELECT config FROM connectors WHERE id = ?1", [id])
      Jason.decode!(config)
    end

    test "atom-keyed credentials are encrypted", ctx do
      key = Base.encode16(:crypto.strong_rand_bytes(32))
      previous = System.get_env("CONNECTOR_KEY")
      System.put_env("CONNECTOR_KEY", key)

      try do
        id = "conn-atom-#{ctx.suffix}"

        assert {:ok, ^id} =
                 Runner.upsert_row(%{
                   id: id,
                   kind: :slack,
                   config: %{:credentials => %{"token" => "xoxb-example"}, "channel" => "c"}
                 })

        config = stored_config(id)
        assert is_binary(config["credentials_ciphertext"])
        refute Map.has_key?(config, "credentials")
        refute Jason.encode!(config) =~ "xoxb-example"
      after
        if previous,
          do: System.put_env("CONNECTOR_KEY", previous),
          else: System.delete_env("CONNECTOR_KEY")
      end
    end

    test "without a connector key an authenticated deployment refuses credentials", ctx do
      previous = System.get_env("CONNECTOR_KEY")
      System.delete_env("CONNECTOR_KEY")

      try do
        with_auth_required(fn ->
          assert {:error, :connector_key_missing} =
                   Runner.upsert_row(%{
                     id: "conn-nokey-#{ctx.suffix}",
                     kind: :slack,
                     config: %{"credentials" => %{"token" => "xoxb-example"}}
                   })
        end)
      after
        if previous, do: System.put_env("CONNECTOR_KEY", previous)
      end
    end
  end
end
