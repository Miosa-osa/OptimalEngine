defmodule OptimalEngine.API.IntParamTest do
  @moduledoc """
  An integer a request supplies is parsed in one place, and a value outside the
  signed 64-bit range is a `400 invalid_parameter`. SQLite binds 64 bits; a
  larger integer used to reach the Store's bind, which raises, and the Store
  GenServer died with every caller's in-flight call.
  """

  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias OptimalEngine.API.{IntParam, Router}
  alias OptimalEngine.API.IntParam.OutOfRange
  alias OptimalEngine.Auth.ApiKey
  alias OptimalEngine.{MemoryCore, Organization, Sync, Workspace}
  alias OptimalEngine.Tenancy.Tenant

  @opts Router.init([])

  @int64_max 9_223_372_036_854_775_807
  @int64_min -9_223_372_036_854_775_808

  describe "parse/3" do
    test "text, numbers and the default" do
      assert IntParam.parse("12", 0) == 12
      assert IntParam.parse("-12", 0) == -12
      assert IntParam.parse(12, 0) == 12
      assert IntParam.parse(nil, 7) == 7
      assert IntParam.parse("", 7) == 7
      assert IntParam.parse("abc", 7) == 7
      assert IntParam.parse("12abc", 7) == 7
      assert IntParam.parse(" 12", 7) == 7
      assert IntParam.parse("1.5", 7) == 7
      assert IntParam.parse(12.0, 7) == 7
      assert IntParam.parse(%{}, 7) == 7
      assert IntParam.parse([1], 7) == 7
      assert IntParam.parse(true, 7) == 7
    end

    test ":partial reads the digits before trailing text" do
      assert IntParam.parse("12abc", 7, partial: true) == 12
      assert IntParam.parse("1.5", 7, partial: true) == 1
      assert IntParam.parse(2.5, 7, partial: true) == 2
      assert IntParam.parse("abc", 7, partial: true) == 7
    end

    test ":positive turns zero and below into the default" do
      assert IntParam.parse("5", 7, positive: true) == 5
      assert IntParam.parse("0", 7, positive: true) == 7
      assert IntParam.parse("-5", 7, positive: true) == 7
      assert IntParam.parse(0, 7, positive: true) == 7
      assert IntParam.parse(nil, nil, positive: true) == nil
    end

    test "the 64-bit bounds are accepted and one past either is refused" do
      assert IntParam.parse(Integer.to_string(@int64_max), 0) == @int64_max
      assert IntParam.parse(Integer.to_string(@int64_min), 0) == @int64_min
      assert IntParam.parse(@int64_max, 0) == @int64_max
      assert IntParam.parse(@int64_min, 0) == @int64_min
      assert IntParam.min() == @int64_min
      assert IntParam.max() == @int64_max

      for value <- [
            Integer.to_string(@int64_max + 1),
            Integer.to_string(@int64_min - 1),
            @int64_max + 1,
            @int64_min - 1,
            "99999999999999999999999999999999"
          ],
          opts <- [[], [partial: true], [positive: true], [partial: true, positive: true]] do
        assert_raise OutOfRange, fn -> IntParam.parse(value, 7, opts) end
      end

      # Trailing text is not an integer unless :partial reads the digits.
      big = Integer.to_string(@int64_max + 1) <> "abc"
      assert IntParam.parse(big, 7) == 7
      assert_raise OutOfRange, fn -> IntParam.parse(big, 7, partial: true) end
    end
  end

  # {method, path, where the parameter goes, the integer parameters}. `{ws}` is
  # the workspace id. A body route gets the parameter as a JSON number.
  @routes [
    {:get, "/api/graph/triangles", :query, ~w(limit)},
    {:get, "/api/graph/reflect", :query, ~w(min)},
    {:get, "/api/review/routing", :query, ~w(limit)},
    {:get, "/api/entities/review", :query, ~w(limit)},
    {:get, "/api/maintenance/log", :query, ~w(lines)},
    {:get, "/api/storage/workspaces/{ws}/mutations", :query, ~w(after limit)},
    {:get, "/api/stores/main/records", :query, ~w(limit)},
    {:get, "/api/memory-core/claims", :query, ~w(limit)},
    {:get, "/api/memory-core/claim-review", :query, ~w(limit)},
    {:get, "/api/search", :query, ~w(offset limit)},
    {:get, "/api/grep", :query, ~w(offset limit)},
    {:get, "/api/wiki", :query, ~w(offset limit)},
    {:get, "/api/wiki/contradictions", :query, ~w(offset limit)},
    {:get, "/api/activity", :query, ~w(offset limit)},
    {:get, "/api/workspaces", :query, ~w(offset limit)},
    {:get, "/api/subscriptions", :query, ~w(offset limit)},
    {:get, "/api/memory", :query, ~w(offset limit)},
    {:get, "/api/auth/keys", :query, ~w(offset limit)},
    {:get, "/api/sessions", :query, ~w(offset limit)},
    {:get, "/api/brief", :query, ~w(limit)},
    {:get, "/api/loops", :query, ~w(limit)},
    {:get, "/api/rhythm/notes", :query, ~w(limit)},
    {:get, "/api/federation/search", :query, ~w(limit)},
    {:get, "/api/sync/changes", :query, ~w(since limit)},
    {:get, "/api/sync/runs", :query, ~w(limit before)},
    {:get, "/api/sync/ledger", :query, ~w(limit before)},
    {:get, "/api/viability/history", :query, ~w(days)},
    {:get, "/api/viability/audit", :query, ~w(limit)},
    {:get, "/api/signal-events", :query, ~w(limit)},
    {:get, "/api/agent-actions", :query, ~w(limit)},
    {:get, "/api/analyses", :query, ~w(limit)},
    {:get, "/api/jobs", :query, ~w(limit)},
    {:get, "/api/jobs/dead", :query, ~w(limit)},
    {:get, "/api/authority/evidence", :query, ~w(after limit)},
    {:get, "/api/authority/evidence/export", :query, ~w(after until limit)},
    {:get, "/api/import/notion/tree", :query, ~w(limit offset)},
    {:get, "/api/data/collections/tasks/records", :query, ~w(limit)},
    {:get, "/api/data/changes/stream", :query, ~w(since idle_timeout)},
    {:patch, "/api/data/collections/tasks/records/r1", :query, ~w(version)},
    {:post, "/api/rag", :body,
     ~w(hybrid_limit memory_limit reconstruction_steps reconstruction_tokens)},
    {:post, "/api/assemble", :body,
     ~w(limit token_budget step_budget reconstruction_steps reconstruction_tokens)},
    {:post, "/api/reconstruct", :body,
     ~w(limit token_budget step_budget reconstruction_steps reconstruction_tokens)},
    {:post, "/api/memory/embeddings/rebuild", :body, ~w(limit concurrency)},
    {:post, "/api/memory/consolidate", :body, ~w(minimum_observations)},
    {:post, "/api/memory-core/context-packages/refresh-stale", :body, ~w(batch_limit limit)},
    {:post, "/api/memory-core/active-pools/{pool}/retrieve", :body, ~w(limit)},
    {:post, "/api/viability/snapshot", :body, ~w(days)},
    {:post, "/api/viability/audit/run", :body, ~w(size)}
  ]

  defp call(ctx, method, path, where, param, value) do
    path = path |> String.replace("{ws}", ctx.workspace) |> String.replace("{pool}", ctx.pool)
    operator? = String.starts_with?(path, "/api/maintenance/")
    fixed = %{"q" => "x", "query" => "x"}
    # The operator's key belongs to another tenant, so it names no workspace.
    fixed = if operator?, do: fixed, else: Map.put(fixed, "workspace", ctx.workspace)

    conn =
      case where do
        :query ->
          query = URI.encode_query(Map.put(fixed, param, to_string(value)))
          conn(method, path <> "?" <> query)

        :body ->
          body = fixed |> Map.put(param, value) |> Jason.encode!()
          method |> conn(path, body) |> put_req_header("content-type", "application/json")
      end

    key = if operator?, do: ctx.operator_key, else: ctx.key
    answer(put_req_header(conn, "authorization", "Bearer " <> key))
  end

  # `Plug.ErrorHandler` sends the error response and then re-raises, so a
  # request that fails is read from what was sent.
  defp answer(conn) do
    conn = Router.call(conn, @opts)
    {conn.status, conn.resp_body}
  rescue
    error in Plug.Conn.WrapperError ->
      {status, _headers, body} = Plug.Test.sent_resp(error.conn)
      {status, body}
  end

  # The evidence routes name the parameter (`after_out_of_range`, `until_out_of_range`),
  # as their guide documents; every other route answers `invalid_parameter`.
  defp refused?({status, body}, path) do
    status == 400 and
      (body =~ "invalid_parameter" or
         (String.starts_with?(path, "/api/authority/evidence") and body =~ "_out_of_range"))
  end

  describe "every route that takes an integer" do
    setup do
      n = System.unique_integer([:positive])
      tenant = "intparam-#{n}"
      org = "#{tenant}:org"
      {:ok, _} = Tenant.create(%{id: tenant, name: "Int #{n}"})
      {:ok, _} = Organization.create(%{id: org, tenant_id: tenant, slug: "org", name: "Org"})

      {:ok, ws} =
        Workspace.create(%{
          id: "#{tenant}:a",
          tenant_id: tenant,
          organization_id: org,
          slug: "a",
          name: "A"
        })

      {:ok, %{key: key}} =
        ApiKey.mint(%{tenant_id: tenant, name: "all", scopes: ["*"], workspace_scope: ["*"]})

      # The Engine log covers every tenant, so only the default tenant's admin reads it.
      {:ok, %{key: operator_key}} =
        ApiKey.mint(%{
          tenant_id: Tenant.default_id(),
          name: "operator-#{n}",
          scopes: ["*"],
          workspace_scope: ["*"]
        })

      # /api/sync/changes answers 409 until sync is enabled for the workspace.
      {:ok, _} = Sync.enable(tenant, ws.id, "user:owner")

      # The pool routes answer 404 for a pool the caller cannot see before they
      # read a parameter, so the retrieve route needs a pool of the tenant's own.
      {:ok, pool} =
        MemoryCore.open_active_pool(tenant_id: tenant, workspace_id: ws.id, task_type: "intparam")

      %{tenant: tenant, workspace: ws.id, key: key, operator_key: operator_key, pool: pool.id}
    end

    test "a value outside 64 bits is a 400 invalid_parameter and the Store keeps running", ctx do
      store = Process.whereis(OptimalEngine.Store.SQLite)

      failures =
        for {method, path, where, params} <- @routes,
            param <- params,
            value <- [@int64_max + 1, @int64_min - 1],
            answer = call(ctx, method, path, where, param, value),
            not refused?(answer, path) do
          {status, body} = answer
          "#{method} #{path} #{param}=#{value} answered #{status} #{String.slice(body, 0, 120)}"
        end

      assert failures == [], Enum.join(failures, "\n")
      assert Process.whereis(OptimalEngine.Store.SQLite) == store
    end

    test "the largest 64-bit integer is not refused", ctx do
      failures =
        for {method, path, where, params} <- @routes,
            # An open event stream never answers, so it cannot be read in a test.
            path != "/api/data/changes/stream",
            param <- params,
            # `until` must name an entry of the chain, and 2^63 - 1 names none.
            {path, param} != {"/api/authority/evidence/export", "until"},
            answer = call(ctx, method, path, where, param, @int64_max),
            refused?(answer, path) do
          {status, body} = answer
          "#{method} #{path} #{param}=#{@int64_max} answered #{status} #{body}"
        end

      assert failures == [], Enum.join(failures, "\n")
    end
  end
end
