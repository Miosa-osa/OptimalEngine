defmodule OptimalEngine.API.EncodedPathTest do
  @moduledoc """
  A route reached through percent-escapes is checked like the plain path.

  `Plug.Router` matches decoded segments, so `/%61pi/auth/%6Beys` is
  `/api/auth/keys` to the router. `OptimalEngine.API.PathPlug` refuses a path
  that escapes an unreserved character or `%`, and hands every plug after it
  the decoded segments, so the workspace, permission and authority plugs see
  the route the router dispatches to.
  """

  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias OptimalEngine.API.{AuthorityPlug, PathPlug, PermissionPlug, Router}
  alias OptimalEngine.Auth.ApiKey
  alias OptimalEngine.Authority.{Policy, Settings}
  alias OptimalEngine.{Organization, Workspace}
  alias OptimalEngine.Tenancy.Tenant

  @opts Router.init([])

  setup do
    n = System.unique_integer([:positive])
    tenant = "path-#{n}"
    org = "#{tenant}:org"
    {:ok, _} = Tenant.create(%{id: tenant, name: "Path #{n}"})
    {:ok, _} = Organization.create(%{id: org, tenant_id: tenant, slug: "org", name: "Org"})

    {:ok, a} =
      Workspace.create(%{
        id: "#{tenant}:a",
        tenant_id: tenant,
        organization_id: org,
        slug: "a",
        name: "A"
      })

    {:ok, b} =
      Workspace.create(%{
        id: "#{tenant}:b",
        tenant_id: tenant,
        organization_id: org,
        slug: "b",
        name: "B"
      })

    {:ok, %{key: writer}} =
      ApiKey.mint(%{
        tenant_id: tenant,
        name: "writer",
        scopes: ["read", "write"],
        workspace_scope: ["*"]
      })

    {:ok, %{key: reader_a}} =
      ApiKey.mint(%{tenant_id: tenant, name: "reader-a", scopes: ["read"], workspace_scope: [a.id]})

    %{tenant: tenant, a: a.id, b: b.id, writer: writer, reader_a: reader_a}
  end

  defp request(method, path, token, body \\ nil) do
    conn =
      if body do
        method
        |> conn(path, Jason.encode!(body))
        |> put_req_header("content-type", "application/json")
      else
        conn(method, path)
      end

    conn
    |> put_req_header("authorization", "Bearer " <> token)
    |> Router.call(@opts)
  end

  defp refused?(conn), do: conn.status == 400 and conn.resp_body =~ "invalid_path"

  describe "a route spelled with escapes" do
    test "a write key cannot reach the admin key routes through escapes", ctx do
      body = %{name: "minted", scopes: ["read"]}

      for path <- ["/api/auth/%6Beys", "/%61pi/auth/keys", "/api/%61uth/keys", "/v1/auth/%6Beys"] do
        conn = request(:post, path, ctx.writer, body)
        assert refused?(conn), "#{path} answered #{conn.status}: #{conn.resp_body}"
      end

      # Spelled plainly, the route is admin, as it was.
      assert request(:post, "/api/auth/keys", ctx.writer, body).status == 403
    end

    test "a workspace-scoped key cannot read another workspace through escapes", ctx do
      query = "?" <> URI.encode_query(%{q: "anything", workspace: ctx.b, tenant: ctx.tenant})

      for path <- ["/%61pi/search", "/api/%73earch", "/api/searc%68"] do
        conn = request(:get, path <> query, ctx.reader_a)
        assert refused?(conn), "#{path} answered #{conn.status}: #{conn.resp_body}"
      end

      assert request(:get, "/api/search" <> query, ctx.reader_a).status == 403
    end

    test "an escaped percent sign and a malformed escape are refused", ctx do
      for path <- [
            "/%2561pi/search",
            "/api/search%",
            "/api/search%2",
            "/api/search%zz",
            "/api/%%41"
          ] do
        assert refused?(request(:get, path, ctx.writer)), path
      end
    end
  end

  describe "an id that escapes a reserved character" do
    test "is read as the decoded id by the plugs and the route", ctx do
      encoded = fn id -> "/api/workspaces/" <> URI.encode(id, &URI.char_unreserved?/1) end

      assert encoded.(ctx.a) =~ "%3A"

      conn = request(:get, encoded.(ctx.a), ctx.reader_a)
      assert conn.status == 200
      assert Jason.decode!(conn.resp_body)["id"] == ctx.a

      assert request(:get, encoded.(ctx.b), ctx.reader_a).status == 403
    end

    test "the plug hands on the decoded segments, with an escaped slash kept escaped" do
      conn = PathPlug.call(conn(:get, "/api/workspaces/t%3Aa/files/x%2fy%2Fz"), [])

      refute conn.halted
      assert conn.path_info == ["api", "workspaces", "t:a", "files", "x%2Fy%2Fz"]
    end

    test "an escaped slash cannot lower the grant a route needs", ctx do
      # Joined after decoding, `a/b` would no longer match the one-segment id
      # of the review route, and the change would be graded as a plain write.
      path =
        "/api/memory-core/claims/a%2Fb/promote?" <> URI.encode_query(%{workspace: ctx.a})

      conn = request(:post, path, ctx.writer, %{})
      assert conn.status == 403, "answered #{conn.status}: #{conn.resp_body}"
      assert Jason.decode!(conn.resp_body)["error"] == "permission_scope_denied"
    end

    test "an escaped slash in a workspace id is refused before the route grades it", ctx do
      # WorkspaceAuthPlug refuses the id; PermissionPlug would grade the same
      # path as admin. The two checks agree, and this pins the first.
      for {method, path} <- [
            {:get, "/api/workspaces/a%2Fb/bundle"},
            {:post, "/api/workspaces/a%2Fb/finalize-move"}
          ] do
        conn = request(method, path, ctx.writer, if(method == :post, do: %{}))
        assert conn.status == 400, "#{path} answered #{conn.status}: #{conn.resp_body}"
        assert conn.resp_body =~ "invalid workspace"
      end
    end

    test "a control byte or text that is not UTF-8 is refused", ctx do
      for path <- ["/api/search%00", "/api/wiki/a%0Ab", "/api/wiki/%C0%AF", "/api/wiki/%FF"] do
        assert refused?(request(:get, path, ctx.writer)), path
      end
    end
  end

  describe "the grade of a plain path" do
    test "claims promote and reject, the steward's decision and the workspace bundle routes" do
      grade = &PermissionPlug.required_grant/2

      for op <- ["promote", "reject"] do
        assert grade.("POST", ["api", "memory-core", "claims", "c1", op]) == "claims:review"
        assert grade.("GET", ["api", "memory-core", "claims", "c1", op]) == "read"
      end

      assert grade.("POST", ["api", "data-steward", "claims", "decide"]) == "claims:review"

      for route <- ["bundle", "finalize-move"], method <- ["GET", "POST"] do
        assert grade.(method, ["api", "workspaces", "w1", route]) == "admin"
      end

      assert grade.("GET", ["api", "workspaces", "w1", "files"]) == "read"
      assert grade.("GET", ["api", "workspaces", "bundle"]) == "read"
    end

    test "a path that only looks like one of those routes is graded as itself" do
      grade = &PermissionPlug.required_grant/2

      # A claim id is one segment: `a/b` is two, so this is not the review route.
      assert grade.("POST", ["api", "memory-core", "claims", "a", "b", "promote"]) == "write"
      assert grade.("POST", ["api", "memory-core", "claims", "c1", "promote", "x"]) == "write"
      assert grade.("POST", ["api", "memory-core", "claims", "c1", "demote"]) == "write"
      assert grade.("POST", ["api", "workspaces", "w1", "bundle", "x"]) == "topology:write"
      assert grade.("POST", ["api", "memory-core", "claims"]) == "write"
    end

    test "only GET of /api/auth/whoami answers a key that holds no read grant", ctx do
      {:ok, %{key: sync_only}} =
        ApiKey.mint(%{
          tenant_id: ctx.tenant,
          name: "sync-only",
          scopes: ["sync"],
          workspace_scope: ["*"]
        })

      assert request(:get, "/api/auth/whoami", sync_only).status == 200
      assert request(:post, "/api/auth/whoami", sync_only, %{}).status == 403
      assert request(:get, "/api/auth/whoami/extra", sync_only).status == 403
      assert request(:get, "/api/search?q=x&workspace=" <> ctx.a, sync_only).status == 403
    end
  end

  describe "a refusal that comes before the router's own plugs" do
    test "an invalid_path answer carries the CORS headers a browser needs", ctx do
      conn = request(:get, "/%61pi/search", ctx.writer)

      assert refused?(conn)
      assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
      assert get_resp_header(conn, "access-control-allow-headers") != []
      assert get_resp_header(conn, "x-api-version") == ["v1"]
    end

    test "a preflight for an invalid path is answered with the CORS headers too" do
      conn = Router.call(conn(:options, "/api/%zz"), @opts)

      assert conn.status == 400
      assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
    end

    test "an incompatible client's refusal carries them as well", ctx do
      conn =
        :get
        |> conn("/api/search")
        |> put_req_header("authorization", "Bearer " <> ctx.writer)
        |> put_req_header("user-agent", "optimal-cli/999.0.0")
        |> Router.call(@opts)

      assert conn.status == 426
      assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
    end
  end

  describe "the authority resource" do
    test "a segment that holds a slash is encoded and never reads as two" do
      conn = %{
        conn(:put, "/api/rhythm/notes/weekly/x")
        | path_info: ["api", "rhythm", "notes", "weekly", "2026/W1"]
      }

      assert AuthorityPlug.describe(conn, "t").resource ==
               "optimal://engine/rhythm/notes/weekly/2026%2FW1"

      # A segment that was already escaped is left as it is.
      conn = %{conn | path_info: ["api", "rhythm", "notes", "weekly", "2026%2FW1"]}

      assert AuthorityPlug.describe(conn, "t").resource ==
               "optimal://engine/rhythm/notes/weekly/2026%2FW1"
    end

    test "a deny rule on rhythm/notes/*/* matches a period with an escaped slash", ctx do
      :ok = Settings.put_mode(ctx.tenant, "enforce", "user:owner")

      {:ok, _policy, _previous} =
        Policy.publish(
          ctx.tenant,
          "tenant",
          ctx.tenant,
          %{
            "name" => "no-rhythm-notes",
            "rules" => [
              %{
                "id" => "no-notes",
                "effect" => "deny",
                "actions" => ["write"],
                "resources" => ["optimal://*/rhythm/notes/*/*"]
              }
            ]
          },
          "user:owner"
        )

      path = "/api/rhythm/notes/weekly/2026%2FW1?workspace=" <> ctx.a
      conn = request(:put, path, ctx.writer, %{"note" => "x"})

      assert conn.status == 403, "answered #{conn.status}: #{conn.resp_body}"
      assert conn.resp_body =~ "authority_denied"
      assert conn.resp_body =~ "no-notes"
    end
  end

  describe "acceptable?/1" do
    test "accepts reserved escapes and refuses the rest" do
      for segment <- ["plain", "t%3Aa", "a%2Fb", "a%20b", "%E2%82%AC"],
          do: assert(PathPlug.acceptable?(segment), segment)

      for segment <- ["%61", "%2D", "%2e", "%5F", "%7E", "%25", "%", "%4", "%g1", "a%%41"],
          do: refute(PathPlug.acceptable?(segment), segment)
    end
  end
end
