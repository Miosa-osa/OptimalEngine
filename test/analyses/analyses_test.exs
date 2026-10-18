defmodule OptimalEngine.AnalysesTest do
  @moduledoc """
  Analyses as scheduled Engine jobs: scheduling once a day, draining with
  reports, running one now, failures that retry, and the HTTP routes.
  """

  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias OptimalEngine.API.Router
  alias OptimalEngine.Auth.ApiKey
  alias OptimalEngine.{Analyses, Jobs, Store}
  alias OptimalEngine.Tenancy.Tenant

  setup do
    n = System.unique_integer([:positive])
    tenant = "analyses-#{n}"
    {:ok, _} = Tenant.create(%{id: tenant, name: "Analyses #{n}"})
    workspace = "#{tenant}:ops"

    {:ok, _} =
      Store.raw_query(
        "INSERT INTO workspaces (id, tenant_id, slug, name, status, metadata) VALUES (?1, ?2, 'ops', 'ops', 'active', '{}')",
        [workspace, tenant]
      )

    %{tenant: tenant, workspace: workspace, n: n}
  end

  defp signal(ctx, id, content) do
    {:ok, _} =
      Store.raw_query(
        "INSERT INTO contexts (id, tenant_id, workspace_id, type, title, content, created_at) VALUES (?1, ?2, ?3, 'signal', 'Call', ?4, ?5)",
        [id, ctx.tenant, ctx.workspace, content, DateTime.utc_now() |> DateTime.to_iso8601()]
      )
  end

  test "promises finds commitments and reports what is open", ctx do
    signal(ctx, "p-#{ctx.n}", "Thanks for the call. I'll send the revised proposal by Friday.")

    {:ok, result} = Analyses.run_now(ctx.tenant, ctx.workspace, "promises")
    assert result.outcome == :completed
    assert result.report.status == "ok"
    assert result.report.report["detected"] >= 1
    assert result.report.report["open"] >= 1
    assert result.report.summary =~ "detected"
  end

  test "tenant analyses report storage usage, audits, and retention", ctx do
    for kind <- ~w(storage_usage file_audit retention_sweep) do
      {:ok, result} = Analyses.run_now(ctx.tenant, ctx.workspace, kind)
      assert result.report.status == "ok", "#{kind}: #{inspect(result.report)}"
    end

    [usage] = Analyses.reports(ctx.tenant, [ctx.workspace], kind: "storage_usage")
    assert usage.report["profile"]["id"] == "business"
  end

  test "the day's analyses are scheduled once and drained", ctx do
    today = Date.utc_today()
    first = Analyses.schedule(today)
    assert first >= 2

    {:ok, jobs} = Jobs.list(ctx.workspace)
    kinds = jobs |> Enum.map(& &1.kind) |> Enum.sort()
    assert "analysis.promises" in kinds

    # Scheduling again the same day adds no new jobs.
    Analyses.schedule(today)
    {:ok, again} = Jobs.list(ctx.workspace)
    assert length(again) == length(jobs)

    ran = Analyses.drain(200)
    assert Enum.any?(ran, &(&1[:kind] == "analysis.promises" and &1[:outcome] == :completed))
    assert [_ | _] = Analyses.reports(ctx.tenant, [ctx.workspace], kind: "promises")
  end

  test "an unknown analysis is refused and a failing one is reported and retried", ctx do
    assert {:error, :unknown_analysis} = Analyses.run_now(ctx.tenant, ctx.workspace, "everything")

    {:ok, job} =
      Jobs.enqueue(ctx.workspace, "analysis.promises", %{"kind" => "nonsense"}, max_attempts: 2)

    assert {:ok, %{outcome: :retry}} =
             Jobs.run_next(&Analyses.handle/1,
               workspace_id: ctx.workspace,
               kinds: ["analysis.promises"]
             )

    assert [%{status: "failed", job_id: job_id}] =
             Analyses.reports(ctx.tenant, [ctx.workspace], kind: "nonsense")

    assert job_id == job.id
  end

  test "routes: reports, run, jobs", ctx do
    {:ok, %{key: root}} =
      ApiKey.mint(%{tenant_id: ctx.tenant, name: "r", scopes: ["*"], workspace_scope: ["*"]})

    {:ok, %{key: reader}} =
      ApiKey.mint(%{
        tenant_id: ctx.tenant,
        name: "k",
        scopes: ["read"],
        workspace_scope: [ctx.workspace]
      })

    call = fn method, path, key, body ->
      conn =
        if body,
          do:
            conn(method, path, Jason.encode!(body))
            |> put_req_header("content-type", "application/json"),
          else: conn(method, path)

      conn |> put_req_header("authorization", "Bearer " <> key) |> Router.call(Router.init([]))
    end

    assert call.(:post, "/api/analyses/run", reader, %{
             "workspace" => ctx.workspace,
             "kind" => "promises"
           }).status == 403

    run =
      call.(:post, "/api/analyses/run", root, %{"workspace" => ctx.workspace, "kind" => "promises"})

    assert run.status == 200
    assert Jason.decode!(run.resp_body)["outcome"] == "completed"

    assert call.(:post, "/api/analyses/run", root, %{"workspace" => ctx.workspace, "kind" => "x"}).status ==
             422

    reports = call.(:get, "/api/analyses?workspace=#{ctx.workspace}", reader, nil)
    assert [%{"kind" => "promises"} | _] = Jason.decode!(reports.resp_body)["reports"]

    jobs = call.(:get, "/api/jobs?workspace=#{ctx.workspace}", reader, nil)

    assert [%{"kind" => "analysis.promises", "status" => "completed"} | _] =
             Jason.decode!(jobs.resp_body)["jobs"]

    assert call.(:get, "/api/jobs/dead?workspace=#{ctx.workspace}", reader, nil).status == 200
  end
end
