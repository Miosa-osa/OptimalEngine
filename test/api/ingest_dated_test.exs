defmodule OptimalEngine.API.IngestDatedTest do
  @moduledoc """
  `POST /api/ingest` takes the capture fields intake already supports: `occurred_at`
  dates the signal when the item happened, `source_id` makes re-ingesting the same
  source item replace its row, and a bad `occurred_at` is a 400.
  """

  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias OptimalEngine.API.Router
  alias OptimalEngine.Auth.ApiKey
  alias OptimalEngine.Store
  alias OptimalEngine.Tenancy.Tenant

  setup do
    n = System.unique_integer([:positive])
    tenant = "dated-#{n}"
    {:ok, _} = Tenant.create(%{id: tenant, name: "Dated #{n}"})
    workspace = "#{tenant}:ops"

    {:ok, _} =
      Store.raw_query(
        "INSERT INTO workspaces (id, tenant_id, slug, name, status, metadata) VALUES (?1, ?2, 'ops', 'ops', 'active', '{}')",
        [workspace, tenant]
      )

    {:ok, %{key: key}} =
      ApiKey.mint(%{
        tenant_id: tenant,
        name: "k",
        scopes: ["read", "write"],
        workspace_scope: [workspace]
      })

    %{workspace: workspace, key: key}
  end

  defp ingest(ctx, fields) do
    body = Map.merge(%{"workspace" => ctx.workspace, "write_files" => false}, fields)

    conn(:post, "/api/ingest", Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer " <> ctx.key)
    |> Router.call(Router.init([]))
  end

  defp created_at(id) do
    {:ok, [[at]]} = Store.raw_query("SELECT created_at FROM contexts WHERE id = ?1", [id])
    at
  end

  test "occurred_at dates the signal when the item happened", ctx do
    conn =
      ingest(ctx, %{
        "title" => "Call with the supplier",
        "text" => "The supplier agreed to ship the second batch on Friday.",
        "occurred_at" => "2025-09-24T15:30:00Z"
      })

    assert conn.status == 200
    id = Jason.decode!(conn.resp_body)["signal_id"]
    assert String.starts_with?(created_at(id), "2025-09-24")
  end

  test "a bare date is noon UTC on that day", ctx do
    conn =
      ingest(ctx, %{
        "title" => "Day log",
        "text" => "Three calls, one proposal sent, the invoice was paid.",
        "occurred_at" => "2026-01-13"
      })

    assert conn.status == 200
    id = Jason.decode!(conn.resp_body)["signal_id"]
    assert String.starts_with?(created_at(id), "2026-01-13T12:00:00")
  end

  test "the same source_id replaces its row instead of adding one", ctx do
    first =
      ingest(ctx, %{
        "title" => "Chat day",
        "text" => "Morning: we agreed on the scope.",
        "source_id" => "chat:42:2026-10-28"
      })

    second =
      ingest(ctx, %{
        "title" => "Chat day",
        "text" => "Morning: we agreed on the scope. Evening: the client signed.",
        "source_id" => "chat:42:2026-10-28"
      })

    assert first.status == 200 and second.status == 200
    id = Jason.decode!(first.resp_body)["signal_id"]
    assert id == Jason.decode!(second.resp_body)["signal_id"]

    {:ok, [[count]]} =
      Store.raw_query("SELECT COUNT(*) FROM contexts WHERE workspace_id = ?1", [ctx.workspace])

    assert count == 1
  end

  test "an occurred_at that is not a date is rejected", ctx do
    conn = ingest(ctx, %{"text" => "Anything.", "occurred_at" => "last tuesday"})

    assert conn.status == 400

    assert %{"error" => "occurred_at must be an ISO 8601 date or date-time"} =
             Jason.decode!(conn.resp_body)
  end
end
