defmodule OptimalEngine.API.ActorRuleTest do
  @moduledoc """
  `POST /api/memory/remember` and `POST /api/ingest` resolve who is acting the
  same way as every other route (`OptimalEngine.API.Actor.of/2`): a keyed
  caller is always its key's principal, and an anonymous local caller that
  names no actor is the configured local operator.

  `POST /api/memory/reconstruction/benchmark` measures only the questions the
  caller sends; without them it refuses instead of measuring placeholders.
  """

  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias OptimalEngine.API.Router
  alias OptimalEngine.Auth.ApiKey
  alias OptimalEngine.Identity.Principal
  alias OptimalEngine.Store
  alias OptimalEngine.Tenancy.Tenant

  @opts Router.init([])

  setup do
    n = System.unique_integer([:positive])
    original = Application.get_env(:optimal_engine, :local_operator_id)
    Application.put_env(:optimal_engine, :local_operator_id, "user:operator-#{n}")

    on_exit(fn ->
      if original,
        do: Application.put_env(:optimal_engine, :local_operator_id, original),
        else: Application.delete_env(:optimal_engine, :local_operator_id)
    end)

    %{n: n, operator: "user:operator-#{n}"}
  end

  defp post(path, body, token \\ nil) do
    conn =
      conn(:post, path, Jason.encode!(body))
      |> put_req_header("content-type", "application/json")

    conn = if token, do: put_req_header(conn, "authorization", "Bearer " <> token), else: conn
    Router.call(conn, @opts)
  end

  defp claim_actor(claim_id) do
    {:ok, [[evaluator]]} =
      Store.raw_query("SELECT evaluator_id FROM claims WHERE id = ?1", [claim_id])

    evaluator
  end

  defp source_package_creator(id) do
    {:ok, [[created_by]]} =
      Store.raw_query("SELECT created_by FROM source_packages WHERE id = ?1", [id])

    created_by
  end

  defp keyed(ctx) do
    tenant = "actor-#{ctx.n}"
    {:ok, _} = Tenant.create(%{id: tenant, name: "Actor #{ctx.n}"})
    principal = "agent:writer-#{ctx.n}"

    {:ok, _} =
      Principal.upsert(%{id: principal, tenant_id: tenant, kind: :agent, display_name: "Writer"})

    {:ok, %{key: key}} =
      ApiKey.mint(%{
        tenant_id: tenant,
        name: "actor-test",
        scopes: ["read", "write"],
        workspace_scope: ["*"],
        principal_id: principal
      })

    {tenant, principal, key}
  end

  describe "POST /api/memory/remember" do
    test "an anonymous local caller that names no actor acts as the local operator", ctx do
      conn =
        post("/api/memory/remember", %{
          "content" => "The weekly review moves to Thursday #{ctx.n}.",
          "workspace" => "actor-remember-#{ctx.n}",
          "force" => true
        })

      assert conn.status == 200
      %{"pending_claim_id" => claim_id} = Jason.decode!(conn.resp_body)
      assert is_binary(claim_id)
      assert claim_actor(claim_id) == ctx.operator
    end

    test "an anonymous local caller may still name the actor", ctx do
      conn =
        post("/api/memory/remember", %{
          "content" => "The launch checklist has a new owner #{ctx.n}.",
          "workspace" => "actor-remember-#{ctx.n}",
          "actor_id" => "user:named-#{ctx.n}",
          "force" => true
        })

      %{"pending_claim_id" => claim_id} = Jason.decode!(conn.resp_body)
      assert claim_actor(claim_id) == "user:named-#{ctx.n}"
    end

    test "a keyed caller acts as its key's principal", ctx do
      {tenant, principal, key} = keyed(ctx)

      conn =
        post(
          "/api/memory/remember",
          %{
            "content" => "Quotes above the threshold need sign-off #{ctx.n}.",
            "workspace" => "#{tenant}:ops",
            "force" => true
          },
          key
        )

      assert conn.status == 200
      %{"pending_claim_id" => claim_id} = Jason.decode!(conn.resp_body)
      assert claim_actor(claim_id) == principal
    end
  end

  describe "POST /api/ingest" do
    test "an anonymous local caller that names no actor acts as the local operator", ctx do
      conn =
        post("/api/ingest", %{
          "text" => "Meeting note: the vendor review is scheduled for Friday #{ctx.n}.",
          "workspace" => "actor-ingest-#{ctx.n}"
        })

      assert conn.status == 200
      %{"source_package_id" => id} = Jason.decode!(conn.resp_body)
      assert source_package_creator(id) == ctx.operator
    end

    test "a keyed caller acts as its key's principal", ctx do
      {tenant, principal, key} = keyed(ctx)

      conn =
        post(
          "/api/ingest",
          %{
            "text" => "Meeting note: the renewal terms were agreed #{ctx.n}.",
            "workspace" => "#{tenant}:ops"
          },
          key
        )

      assert conn.status == 200
      %{"source_package_id" => id} = Jason.decode!(conn.resp_body)
      assert source_package_creator(id) == principal
    end
  end

  describe "POST /api/memory/reconstruction/benchmark" do
    test "without questions it is 400 questions_required" do
      for body <- [%{"workspace" => "default"}, %{"workspace" => "default", "questions" => []}] do
        conn = post("/api/memory/reconstruction/benchmark", body)
        assert conn.status == 400
        assert Jason.decode!(conn.resp_body)["error"] == "questions_required"
      end
    end

    test "questions that are not strings are still 400" do
      conn = post("/api/memory/reconstruction/benchmark", %{"questions" => [1, 2]})
      assert conn.status == 400
      assert Jason.decode!(conn.resp_body)["error"] == "questions must be a list of strings"
    end
  end
end
