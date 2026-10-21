defmodule OptimalEngine.API.ActivePoolErrorsTest do
  @moduledoc """
  The pool routes name an id the way the router reads it, and answer an error
  they cannot explain with a fixed code, keeping the reason in the log.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Plug.Conn
  import Plug.Test

  alias OptimalEngine.API.Router
  alias OptimalEngine.MemoryCore
  alias OptimalEngine.MemoryCore.RetrievalCoordinator
  alias OptimalEngine.MemoryCore.Store, as: MemoryCoreStore

  @opts Router.init([])

  setup do
    n = System.unique_integer([:positive])
    workspace_id = "pool-errors-#{n}"

    {:ok, pool} =
      MemoryCore.open_active_pool(
        tenant_id: "default",
        workspace_id: workspace_id,
        task_type: "pool_errors_#{n}"
      )

    {:ok, n: n, workspace_id: workspace_id, pool: pool}
  end

  test "an id that holds an escaped slash is the same id to the plug and the handler", ctx do
    id = "amp_slash/#{ctx.n}"
    assert :ok = MemoryCoreStore.insert_active_memory_pool(%{ctx.pool | id: id})

    conn = request(:get, "/api/memory-core/active-pools/amp_slash%2F#{ctx.n}")

    assert conn.status == 200
    assert Jason.decode!(conn.resp_body)["active_memory_pool"]["id"] == id
  end

  test "a pool that is not open answers 409, not a server error", ctx do
    {:ok, _closed} = MemoryCore.close_active_pool(ctx.pool.id, reason: "test")

    conn =
      request(:post, "/api/memory-core/active-pools/#{ctx.pool.id}/observations", %{
        "observation" => "Too late.",
        "claim_text" => "Too late.",
        "subject_anchor" => "pool_errors",
        "action_class" => "observed",
        "object_anchor" => "pool"
      })

    assert conn.status == 409
    assert Jason.decode!(conn.resp_body) == %{"error" => "pool_not_open"}
  end

  test "an error the pool code cannot explain is a fixed code, and the reason is logged", ctx do
    {:ok, package} =
      RetrievalCoordinator.retrieve("anything",
        workspace_id: ctx.workspace_id,
        actor_id: "agent:builder",
        allowed_partitions: [],
        allowed_security_labels: ["restricted"]
      )

    {:ok, _pool} = MemoryCore.load_context_package(ctx.pool.id, package)

    :ok =
      MemoryCoreStore.invalidate_context_packages_for_object("fact", "none",
        workspace_id: ctx.workspace_id,
        reason: "pool_errors_test"
      )

    # Another reader, with grants that do not cover the package, and a refresh
    # that stops at the first package it may not refresh.
    {conn, log} =
      with_log(fn ->
        request(:post, "/api/memory-core/active-pools/#{ctx.pool.id}/refresh-context", %{
          "actor_id" => "agent:other",
          "allowed_security_labels" => [],
          "continue_on_error" => false
        })
      end)

    assert conn.status == 500
    assert Jason.decode!(conn.resp_body) == %{"error" => "internal_error"}
    refute conn.resp_body =~ package.id
    assert log =~ "not_found"
    assert log =~ package.id
  end

  defp request(method, path, body \\ nil) do
    conn =
      case body do
        nil ->
          conn(method, path)

        body ->
          conn(method, path, Jason.encode!(body))
          |> put_req_header("content-type", "application/json")
      end

    Router.call(conn, @opts)
  end
end
