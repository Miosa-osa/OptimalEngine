defmodule OptimalEngine.Portability.BundleJobsTest do
  @moduledoc """
  Bundle export and import as durable jobs: started with 202 and followed by
  status, idempotent under an Idempotency-Key, one per workspace, cancellable,
  cleaned up when they fail or are cut off by a restart, and swept when their
  bundle expires. The worker is off in tests; each test runs the queue itself.
  """

  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias OptimalEngine.API.Router
  alias OptimalEngine.Auth.ApiKey
  alias OptimalEngine.{Jobs, Store, Workspace}
  alias OptimalEngine.Portability.{BundleJobs, WorkspaceBundle}
  alias OptimalEngine.Tenancy.Tenant

  setup do
    drain_all()
    n = System.unique_integer([:positive])
    tenant = "bjobs-#{n}"
    {:ok, _} = Tenant.create(%{id: tenant, name: "Bundle jobs #{n}"})

    {:ok, _} =
      OptimalEngine.Organization.create(%{
        id: "#{tenant}:org",
        tenant_id: tenant,
        slug: "org",
        name: "Org"
      })

    {:ok, ws} =
      Workspace.create(%{
        tenant_id: tenant,
        organization_id: "#{tenant}:org",
        slug: "open",
        name: "Open"
      })

    for i <- 1..3, do: context(tenant, ws.id, "bjobs-#{n}-#{i}")

    on_exit(&drain_all/0)
    %{tenant: tenant, n: n, ws: ws.id}
  end

  defp context(tenant, workspace, id) do
    {:ok, _} =
      Store.raw_query(
        "INSERT INTO contexts (id, tenant_id, workspace_id, title, content, created_at, uri) VALUES (?1, ?2, ?3, ?1, 'body', '2026-10-14T10:00:00Z', ?4)",
        [id, tenant, workspace, "optimal://#{workspace}/contexts/#{id}"]
      )
  end

  defp drain_all do
    case BundleJobs.drain() do
      {:ok, :idle} -> :ok
      _ -> drain_all()
    end
  end

  defp with_auth(fun) do
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

  defp admin_key(tenant, scope \\ ["*"]) do
    {:ok, %{key: key}} =
      ApiKey.mint(%{tenant_id: tenant, name: "admin", scopes: ["*"], workspace_scope: scope})

    key
  end

  defp call(method, path, token, body \\ nil, headers \\ []) do
    conn =
      if body,
        do:
          conn(method, path, Jason.encode!(body))
          |> put_req_header("content-type", "application/json"),
        else: conn(method, path)

    headers
    |> Enum.reduce(conn, fn {name, value}, conn -> put_req_header(conn, name, value) end)
    |> put_req_header("authorization", "Bearer " <> token)
    |> Router.call(Router.init([]))
  end

  defp decode(conn), do: Jason.decode!(conn.resp_body)

  defp status!(tenant, job_id) do
    {:ok, view} = BundleJobs.status(tenant, job_id)
    view
  end

  # Moves the workspace's rows out (as a finished move does), so a copy of the
  # bundle can be imported into the same database without id clashes.
  defp exported_and_moved(ctx) do
    name = "moved-#{ctx.n}.tar.gz"
    path = Path.join(WorkspaceBundle.bundle_dir(ctx.tenant), name)
    {:ok, manifest} = WorkspaceBundle.export(ctx.tenant, ctx.ws, path)
    :ok = WorkspaceBundle.prepare_move(ctx.tenant, ctx.ws, manifest["bundle_sha256"])

    {:ok, _} =
      WorkspaceBundle.finalize_move(ctx.tenant, ctx.ws, manifest["bundle_sha256"], %{
        "target_url" => "https://other.example"
      })

    {name, manifest}
  end

  # A chain of `n` memories in the workspace, each pointing at the one before,
  # moved out into a bundle.
  defp exported_with_memory_chain(ctx, n) do
    for i <- 1..n do
      parent = if i > 1, do: "chain-#{ctx.n}-#{i - 1}"

      {:ok, _} =
        Store.raw_query(
          "INSERT INTO memories (id, tenant_id, workspace_id, content, root_memory_id, parent_memory_id) VALUES (?1, ?2, ?3, 'chain', ?1, ?4)",
          ["chain-#{ctx.n}-#{i}", ctx.tenant, ctx.ws, parent]
        )
    end

    exported_and_moved(ctx)
  end

  defp memory_ids(workspace) do
    {:ok, rows} =
      Store.raw_query("SELECT id FROM memories WHERE workspace_id = ?1 ORDER BY id", [workspace])

    List.flatten(rows)
  end

  # An import the Engine stopped under: claimed, so it is marked running, with
  # the report and the log of rows written that it had left behind.
  defp cut_off_import(ctx, bundle, target, log) do
    {:ok, view, :queued} =
      BundleJobs.submit_import(ctx.tenant, %{
        "workspace_id" => target,
        "bundle" => bundle,
        "mode" => "merge"
      })

    assert {:ok, %{id: id}} =
             Jobs.claim(kinds: BundleJobs.kinds(), lease_owner: "gone-#{ctx.n}-#{view.job_id}")

    assert id == view.job_id

    dir = Path.join([WorkspaceBundle.backup_dir(), "bundle-jobs", id])
    report_path = Path.join(dir, "report.json")
    report = report_path |> File.read!() |> Jason.decode!()

    File.write!(
      report_path,
      Jason.encode!(
        Map.merge(report, %{
          "status" => "running",
          "phase" => "writing",
          "target_was_empty" => true,
          "record_created" => false
        })
      )
    )

    File.write!(Path.join(dir, "written.jsonl"), log)
    id
  end

  defp on_event(event, fun) do
    handler = "bundle-jobs-#{System.unique_integer([:positive])}"
    :ok = :telemetry.attach(handler, event, &__MODULE__.handle_event/4, fun)
    on_exit(fn -> :telemetry.detach(handler) end)
  end

  @doc false
  def handle_event(_event, _measurements, metadata, fun), do: fun.(metadata)

  describe "starting and following a job" do
    test "an export answers 202, runs, and reports its bundle, which downloads", ctx do
      with_auth(fn ->
        key = admin_key(ctx.tenant)
        started = call(:post, "/api/bundles/jobs/export", key, %{"workspace_id" => ctx.ws})
        assert started.status == 202
        job = decode(started)
        assert job["status"] == "queued"
        assert get_resp_header(started, "location") == ["/api/bundles/jobs/" <> job["job_id"]]

        drain_all()

        done = decode(call(:get, "/api/bundles/jobs/" <> job["job_id"], key))
        assert done["status"] == "succeeded"
        assert done["phase"] == "done"
        assert done["attempt"] == 1
        result = done["result"]
        assert result["rows"] >= 3
        assert result["size_bytes"] > 0
        assert result["download_path"] == "/api/bundles/" <> result["bundle"]

        download = call(:get, result["download_path"], key)
        assert download.status == 200

        assert :crypto.hash(:sha256, download.resp_body) |> Base.encode16(case: :lower) ==
                 result["file_sha256"]

        listed = decode(call(:get, "/api/bundles/jobs?workspace_id=" <> ctx.ws, key))
        assert Enum.map(listed["jobs"], & &1["job_id"]) == [job["job_id"]]

        finished = call(:post, "/api/bundles/jobs/#{job["job_id"]}/cancel", key)
        assert finished.status == 409
        assert decode(finished)["error"] == "job_finished"
      end)
    end

    test "an import by name runs as a job and lands the workspace", ctx do
      {name, manifest} = exported_and_moved(ctx)
      target = "#{ctx.tenant}:copy"

      with_auth(fn ->
        key = admin_key(ctx.tenant)

        started =
          call(:post, "/api/bundles/jobs/import", key, %{"workspace_id" => target, "bundle" => name})

        assert started.status == 202
        drain_all()

        done = status!(ctx.tenant, decode(started)["job_id"])
        assert done.status == "succeeded"
        assert done.result["workspace_id"] == target
        assert done.result["bundle_sha256"] == manifest["bundle_sha256"]
        assert done.result["ledger_sequence"] == manifest["ledger_sequence"]
        assert {:ok, _} = Workspace.get(target)
      end)
    end

    test "the same Idempotency-Key returns the job; another request under it is refused", ctx do
      with_auth(fn ->
        key = admin_key(ctx.tenant)
        headers = [{"idempotency-key", "export-#{ctx.n}"}]

        first = call(:post, "/api/bundles/jobs/export", key, %{"workspace_id" => ctx.ws}, headers)
        assert first.status == 202

        again = call(:post, "/api/bundles/jobs/export", key, %{"workspace_id" => ctx.ws}, headers)
        assert again.status == 200
        assert decode(again)["duplicate"] == true
        assert decode(again)["job_id"] == decode(first)["job_id"]

        other =
          call(
            :post,
            "/api/bundles/jobs/export",
            key,
            %{"workspace_id" => ctx.ws, "for_move" => true},
            headers
          )

        assert other.status == 409
        assert decode(other)["error"] == "idempotency_key_reused"

        bad =
          call(:post, "/api/bundles/jobs/export", key, %{"workspace_id" => ctx.ws}, [
            {"idempotency-key", "has space"}
          ])

        assert bad.status == 400
        assert decode(bad)["error"] == "invalid_idempotency_key"

        # Finished, the key still names the same job.
        drain_all()

        after_run =
          call(:post, "/api/bundles/jobs/export", key, %{"workspace_id" => ctx.ws}, headers)

        assert after_run.status == 200
        assert decode(after_run)["status"] == "succeeded"
      end)
    end

    test "one bundle job per workspace at a time", ctx do
      with_auth(fn ->
        key = admin_key(ctx.tenant)
        first = call(:post, "/api/bundles/jobs/export", key, %{"workspace_id" => ctx.ws})
        assert first.status == 202

        second = call(:post, "/api/bundles/jobs/export", key, %{"workspace_id" => ctx.ws})
        assert second.status == 409

        assert decode(second) == %{
                 "error" => "bundle_job_active",
                 "job_id" => decode(first)["job_id"]
               }
      end)
    end

    test "a job is its tenant's and its workspace's", ctx do
      other = "bjobs-other-#{ctx.n}"
      {:ok, _} = Tenant.create(%{id: other, name: "Other"})

      with_auth(fn ->
        started =
          call(:post, "/api/bundles/jobs/export", admin_key(ctx.tenant), %{"workspace_id" => ctx.ws})

        job_id = decode(started)["job_id"]

        stranger = admin_key(other)
        assert call(:get, "/api/bundles/jobs/" <> job_id, stranger).status == 404
        assert call(:post, "/api/bundles/jobs/#{job_id}/cancel", stranger).status == 404
        assert decode(call(:get, "/api/bundles/jobs", stranger))["jobs"] == []

        narrow = admin_key(ctx.tenant, ["#{ctx.tenant}:elsewhere"])
        assert call(:get, "/api/bundles/jobs/" <> job_id, narrow).status == 403

        assert call(:post, "/api/bundles/jobs/export", narrow, %{"workspace_id" => ctx.ws}).status ==
                 403
      end)
    end

    test "source_url is refused while no host is allowed, and needs the file's sha256", ctx do
      with_auth(fn ->
        key = admin_key(ctx.tenant)
        target = "#{ctx.tenant}:fetched"
        url = "https://storage.example.com/bundle.tar.gz?X-Signature=secret"

        no_hosts =
          call(:post, "/api/bundles/jobs/import", key, %{
            "workspace_id" => target,
            "source_url" => url,
            "sha256" => String.duplicate("a", 64)
          })

        assert no_hosts.status == 400
        assert decode(no_hosts)["error"] == "source_url_not_allowed"
        refute no_hosts.resp_body =~ "secret"

        no_sha =
          call(:post, "/api/bundles/jobs/import", key, %{
            "workspace_id" => target,
            "source_url" => url
          })

        assert no_sha.status == 400
        assert decode(no_sha)["error"] == "invalid_request"

        both =
          call(:post, "/api/bundles/jobs/import", key, %{
            "workspace_id" => target,
            "source_url" => url,
            "bundle" => "x.tar.gz"
          })

        assert both.status == 400
      end)
    end
  end

  describe "cancelling" do
    test "a queued job is cancelled at once and never runs", ctx do
      with_auth(fn ->
        key = admin_key(ctx.tenant)

        job_id =
          decode(call(:post, "/api/bundles/jobs/export", key, %{"workspace_id" => ctx.ws}))[
            "job_id"
          ]

        cancelled = call(:post, "/api/bundles/jobs/#{job_id}/cancel", key)
        assert cancelled.status == 200
        assert decode(cancelled)["status"] == "cancelled"

        assert {:ok, :idle} = BundleJobs.drain()
        assert status!(ctx.tenant, job_id).status == "cancelled"
        assert call(:post, "/api/bundles/jobs/#{job_id}/cancel", key).status == 200

        # The workspace is free for the next job.
        assert call(:post, "/api/bundles/jobs/export", key, %{"workspace_id" => ctx.ws}).status ==
                 202
      end)
    end

    test "a running export stops at its next page and leaves no file", ctx do
      previous = Application.get_env(:optimal_engine, :bundle_export_page_rows)
      Application.put_env(:optimal_engine, :bundle_export_page_rows, 1)
      on_exit(fn -> restore(:bundle_export_page_rows, previous) end)

      before = Path.wildcard(Path.join(WorkspaceBundle.bundle_dir(ctx.tenant), "*"))
      {:ok, view, :queued} = BundleJobs.submit_export(ctx.tenant, ctx.ws, %{})

      on_event([:optimal_engine, :bundle, :export_page], fn %{table: table} ->
        if table == "contexts", do: BundleJobs.cancel(ctx.tenant, view.job_id)
      end)

      {:ok, done} = BundleJobs.drain()
      assert done.job_id == view.job_id
      assert done.status == "cancelled"
      assert done.result == nil
      assert Path.wildcard(Path.join(WorkspaceBundle.bundle_dir(ctx.tenant), "*")) == before

      # Cancelling it again answers as cancelled.
      assert {:ok, %{status: "cancelled"}, :cancelled} = BundleJobs.cancel(ctx.tenant, view.job_id)
    end

    test "a running create import stops between batches and leaves no workspace", ctx do
      {name, _manifest} = exported_and_moved(ctx)
      target = "#{ctx.tenant}:copy"

      {:ok, view, :queued} =
        BundleJobs.submit_import(ctx.tenant, %{"workspace_id" => target, "bundle" => name})

      on_event([:optimal_engine, :bundle, :import_batch], fn _meta ->
        BundleJobs.cancel(ctx.tenant, view.job_id)
      end)

      {:ok, done} = BundleJobs.drain()
      assert done.status == "cancelled"
      assert Workspace.get(target) == {:error, :not_found}

      assert {:ok, [[0]]} =
               Store.raw_query("SELECT COUNT(*) FROM contexts WHERE workspace_id = ?1", [target])
    end
  end

  describe "an import that does not finish takes back only what it wrote" do
    # A second writer puts a row into the target while the import runs, after
    # the contexts batch is committed. Returns the id of that row.
    defp foreign_write_after_contexts(ctx, target, fun) do
      foreign = "foreign-#{ctx.n}"

      on_event([:optimal_engine, :bundle, :import_batch], fn
        %{table: "contexts"} ->
          unless Process.get(:foreign_written) do
            Process.put(:foreign_written, true)
            context(ctx.tenant, target, foreign)
          end

          fun.()

        _other ->
          :ok
      end)

      foreign
    end

    defp context_ids(workspace) do
      {:ok, rows} =
        Store.raw_query("SELECT id FROM contexts WHERE workspace_id = ?1 ORDER BY id", [workspace])

      List.flatten(rows)
    end

    defp create_target(ctx, slug \\ "copy") do
      {:ok, workspace} =
        Workspace.create(%{
          tenant_id: ctx.tenant,
          organization_id: "#{ctx.tenant}:org",
          slug: slug,
          name: slug
        })

      workspace.id
    end

    test "a cancelled create keeps another writer's row, and the workspace it is in", ctx do
      {name, _manifest} = exported_and_moved(ctx)
      target = "#{ctx.tenant}:copy"

      {:ok, view, :queued} =
        BundleJobs.submit_import(ctx.tenant, %{"workspace_id" => target, "bundle" => name})

      foreign =
        foreign_write_after_contexts(ctx, target, fn ->
          BundleJobs.cancel(ctx.tenant, view.job_id)
        end)

      {:ok, done} = BundleJobs.drain()

      assert done.status == "cancelled"
      assert context_ids(target) == [foreign]
      assert {:ok, _workspace} = Workspace.get(target)
      refute done.partial
    end

    test "a cancelled merge into an empty workspace keeps another writer's row", ctx do
      {name, _manifest} = exported_and_moved(ctx)
      target = create_target(ctx)

      {:ok, view, :queued} =
        BundleJobs.submit_import(ctx.tenant, %{
          "workspace_id" => target,
          "bundle" => name,
          "mode" => "merge"
        })

      foreign =
        foreign_write_after_contexts(ctx, target, fn ->
          BundleJobs.cancel(ctx.tenant, view.job_id)
        end)

      {:ok, done} = BundleJobs.drain()

      assert done.status == "cancelled"
      assert context_ids(target) == [foreign]
      assert {:ok, _workspace} = Workspace.get(target)
      refute done.partial
    end

    test "a cancelled merge into a workspace that held rows is partial", ctx do
      {name, _manifest} = exported_and_moved(ctx)
      target = create_target(ctx)
      context(ctx.tenant, target, "held-#{ctx.n}")

      {:ok, view, :queued} =
        BundleJobs.submit_import(ctx.tenant, %{
          "workspace_id" => target,
          "bundle" => name,
          "mode" => "merge"
        })

      on_event([:optimal_engine, :bundle, :import_batch], fn
        %{table: "contexts"} -> BundleJobs.cancel(ctx.tenant, view.job_id)
        _other -> :ok
      end)

      {:ok, done} = BundleJobs.drain()

      assert done.status == "cancelled"
      assert done.partial
      assert length(context_ids(target)) == 4
    end

    test "an import cut off by a restart is undone by its log, and only its rows", ctx do
      {name, _manifest} = exported_and_moved(ctx)
      target = create_target(ctx)

      {:ok, view, :queued} =
        BundleJobs.submit_import(ctx.tenant, %{
          "workspace_id" => target,
          "bundle" => name,
          "mode" => "merge"
        })

      foreign =
        foreign_write_after_contexts(ctx, target, fn ->
          if Process.get(:stop_engine), do: Process.exit(self(), :kill)
        end)

      {pid, ref} =
        spawn_monitor(fn ->
          Process.put(:stop_engine, true)
          BundleJobs.drain()
        end)

      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 10_000
      assert status!(ctx.tenant, view.job_id).status == "running"
      assert length(context_ids(target)) == 4

      assert BundleJobs.recover() == 1
      assert context_ids(target) == [foreign]
      assert {:ok, _workspace} = Workspace.get(target)
    end
  end

  describe "taking an import back" do
    test "a cancelled create of memories linked across batches is taken back whole", ctx do
      {name, _manifest} = exported_with_memory_chain(ctx, 6)
      path = Path.join(WorkspaceBundle.bundle_dir(ctx.tenant), name)
      target = "#{ctx.tenant}:copy"

      # Two rows a batch: each batch's parents were written by an earlier one.
      observe = fn
        {:rows, "memories", _n} ->
          batches = Process.get(:memory_batches, 0) + 1
          Process.put(:memory_batches, batches)
          if batches == 3, do: :cancel, else: :ok

        _event ->
          :ok
      end

      assert {:error, :cancelled} =
               WorkspaceBundle.import(path, ctx.tenant,
                 workspace_id: target,
                 batch_rows: 2,
                 observe: observe
               )

      assert Process.get(:memory_batches) == 3
      assert memory_ids(target) == []
      assert context_ids(target) == []
      assert Workspace.get(target) == {:error, :not_found}
    end

    test "a batch too large for one delete statement is taken back whole", ctx do
      # 520 memories in one batch of 1,000; a delete statement takes 500 keys.
      {name, _manifest} = exported_with_memory_chain(ctx, 520)
      path = Path.join(WorkspaceBundle.bundle_dir(ctx.tenant), name)
      target = "#{ctx.tenant}:copy"

      observe = fn
        {:rows, "memories", _n} -> :cancel
        _event -> :ok
      end

      assert {:error, :cancelled} =
               WorkspaceBundle.import(path, ctx.tenant, workspace_id: target, observe: observe)

      assert memory_ids(target) == []
      assert Workspace.get(target) == {:error, :not_found}
    end

    test "recovery skips a line the log lost to a full disk, and ends the job partial", ctx do
      {name, _manifest} = exported_and_moved(ctx)
      target = create_target(ctx)
      row = "written-#{ctx.n}"
      context(ctx.tenant, target, row)

      good = Jason.encode!(%{"table" => "contexts", "columns" => ["id"], "keys" => [[row]]})
      torn = ~s({"table":"contexts","columns":["id"],"keys":[["lost)
      job_id = cut_off_import(ctx, name, target, good <> "\n" <> torn)

      assert BundleJobs.recover() == 1

      # What the log names is gone; what was cut off with the log is not known.
      assert context_ids(target) == []
      failed = status!(ctx.tenant, job_id)
      assert failed.status == "failed"
      assert failed.partial
      assert failed.error["code"] == "cleanup_incomplete"
      assert failed.error["retryable"] == false
      assert failed.error["partial"] == true

      # It is not run again, and the next boot does not meet it.
      assert {:ok, :idle} = BundleJobs.drain()
      assert BundleJobs.recover() == 0
    end

    test "a job that cannot be taken back does not stop the recovery of the others", ctx do
      {name, _manifest} = exported_and_moved(ctx)
      refused = create_target(ctx, "refused")
      other = create_target(ctx, "other")
      row = "other-#{ctx.n}"
      context(ctx.tenant, other, row)

      # The log names a table the Engine does not have: its delete is refused.
      missing =
        Jason.encode!(%{
          "table" => "no_such_table_#{ctx.n}",
          "columns" => ["id"],
          "keys" => [["x"]]
        })

      names_row = Jason.encode!(%{"table" => "contexts", "columns" => ["id"], "keys" => [[row]]})

      first = cut_off_import(ctx, name, refused, missing <> "\n")
      second = cut_off_import(ctx, name, other, names_row <> "\n")

      assert BundleJobs.recover() == 2

      assert status!(ctx.tenant, first).status == "failed"
      assert status!(ctx.tenant, first).partial

      # The other is released to run again from the start, and its rows are gone.
      assert status!(ctx.tenant, second).status == "running"
      refute status!(ctx.tenant, second).partial
      assert context_ids(other) == []
    end

    test "a log that cannot be read ends the job partial instead of crashing recovery", ctx do
      {name, _manifest} = exported_and_moved(ctx)
      target = create_target(ctx)
      row = "unreadable-#{ctx.n}"
      context(ctx.tenant, target, row)

      names_row = Jason.encode!(%{"table" => "contexts", "columns" => ["id"], "keys" => [[row]]})
      job_id = cut_off_import(ctx, name, target, names_row <> "\n")
      log = Path.join([WorkspaceBundle.backup_dir(), "bundle-jobs", job_id, "written.jsonl"])
      File.chmod!(log, 0o000)
      on_exit(fn -> File.chmod(log, 0o600) end)

      # A reader that ignores file modes (root) reads it, and recovery is normal.
      readable? = match?({:ok, _}, File.read(log))

      assert BundleJobs.recover() == 1

      if readable? do
        assert context_ids(target) == []
      else
        assert context_ids(target) == [row]
        failed = status!(ctx.tenant, job_id)
        assert failed.status == "failed"
        assert failed.partial
        assert failed.error["code"] == "cleanup_incomplete"
      end
    end
  end

  describe "failures and restarts" do
    test "an import that fails leaves no partial workspace", ctx do
      # The source still holds its rows, so the copy clashes on their ids.
      name = "clash-#{ctx.n}.tar.gz"

      {:ok, _} =
        WorkspaceBundle.export(
          ctx.tenant,
          ctx.ws,
          Path.join(WorkspaceBundle.bundle_dir(ctx.tenant), name)
        )

      target = "#{ctx.tenant}:clash"

      {:ok, view, :queued} =
        BundleJobs.submit_import(ctx.tenant, %{"workspace_id" => target, "bundle" => name})

      {:ok, done} = BundleJobs.drain()
      assert done.job_id == view.job_id
      assert done.status == "failed"
      assert done.error["retryable"] == false
      refute done.error["partial"]
      assert Workspace.get(target) == {:error, :not_found}

      assert {:ok, [[0]]} =
               Store.raw_query("SELECT COUNT(*) FROM contexts WHERE workspace_id = ?1", [target])
    end

    test "an import cut off by a restart is cleaned up and runs again from the start", ctx do
      {name, manifest} = exported_and_moved(ctx)
      target = "#{ctx.tenant}:copy"

      {:ok, view, :queued} =
        BundleJobs.submit_import(ctx.tenant, %{"workspace_id" => target, "bundle" => name})

      # The Engine stops after the first batch is written.
      on_event([:optimal_engine, :bundle, :import_batch], fn _meta ->
        if Process.get(:stop_engine), do: Process.exit(self(), :kill)
      end)

      {pid, ref} =
        spawn_monitor(fn ->
          Process.put(:stop_engine, true)
          BundleJobs.drain()
        end)

      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 10_000
      assert status!(ctx.tenant, view.job_id).status == "running"
      assert {:ok, _} = Workspace.get(target)

      # The next boot: the cut-off job is cleaned up and released.
      assert BundleJobs.recover() == 1
      assert Workspace.get(target) == {:error, :not_found}

      {:ok, done} = BundleJobs.drain()
      assert done.status == "succeeded"
      assert done.attempt == 2
      rows = manifest["tables"] |> Enum.find(&(&1["name"] == "contexts")) |> Map.fetch!("rows")
      assert done.result["rows"]["contexts"] == rows

      assert {:ok, [[^rows]]} =
               Store.raw_query("SELECT COUNT(DISTINCT id) FROM contexts WHERE workspace_id = ?1", [
                 target
               ])
    end

    test "after its last attempt a job cut off by restarts fails with engine_restarted", ctx do
      {:ok, view, :queued} = BundleJobs.submit_export(ctx.tenant, ctx.ws, %{})

      for owner <- ["gone-1", "gone-2", "gone-3"] do
        assert {:ok, %{id: id}} = Jobs.claim(kinds: BundleJobs.kinds(), lease_owner: owner)
        assert id == view.job_id
        assert BundleJobs.recover() == 1
      end

      assert {:ok, :idle} = BundleJobs.drain()
      failed = status!(ctx.tenant, view.job_id)
      assert failed.status == "failed"
      assert failed.error["code"] == "engine_restarted"
      assert failed.error["retryable"] == true
    end
  end

  describe "the name of an export's bundle" do
    test "holds a random part, so it cannot be guessed from the workspace and the time", ctx do
      names =
        for _ <- 1..2 do
          {:ok, _view, :queued} = BundleJobs.submit_export(ctx.tenant, ctx.ws, %{})
          {:ok, done} = BundleJobs.drain()
          done.result["bundle"]
        end

      assert length(Enum.uniq(names)) == 2

      for name <- names do
        assert name =~ ~r/\A[a-z0-9-]+-\d{10}-[0-9a-f]{16}\.tar\.gz\z/
      end
    end
  end

  describe "retention" do
    test "job records go after thirty days, counted on the clock the column keeps", ctx do
      ids =
        for _ <- 1..3 do
          {:ok, view, :queued} = BundleJobs.submit_export(ctx.tenant, ctx.ws, %{})
          {:ok, _done} = BundleJobs.drain()
          view.job_id
        end

      [past, edge, recent] = ids

      # Ages in seconds; the edge is one hour inside the thirty days, which can
      # fall on the same date as the cutoff.
      for {id, age} <- [{past, 31 * 86_400}, {edge, 30 * 86_400 - 3_600}, {recent, 86_400}] do
        stamp =
          DateTime.utc_now()
          |> DateTime.add(-age, :second)
          |> Calendar.strftime("%Y-%m-%d %H:%M:%S")

        {:ok, _} = Store.raw_query("UPDATE jobs SET updated_at = ?2 WHERE id = ?1", [id, stamp])
      end

      {_expired, old} = BundleJobs.sweep()

      assert old >= 1
      assert {:error, _} = Jobs.fetch(past)
      assert {:ok, _} = Jobs.fetch(edge)
      assert {:ok, _} = Jobs.fetch(recent)
    end

    test "an export's bundle is removed once it expires", ctx do
      {:ok, view, :queued} = BundleJobs.submit_export(ctx.tenant, ctx.ws, %{})
      {:ok, done} = BundleJobs.drain()
      {:ok, path} = WorkspaceBundle.bundle_path(ctx.tenant, done.result["bundle"])
      assert File.exists?(path)

      # Finished eight days ago, past the default seven.
      report = Path.join([WorkspaceBundle.backup_dir(), "bundle-jobs", view.job_id, "report.json"])

      long_ago =
        DateTime.utc_now() |> DateTime.add(-8 * 86_400, :second) |> DateTime.to_iso8601()

      File.write!(
        report,
        report
        |> File.read!()
        |> Jason.decode!()
        |> Map.put("finished_at", long_ago)
        |> Jason.encode!()
      )

      {expired, _old} = BundleJobs.sweep()
      assert expired >= 1
      refute File.exists?(path)
    end
  end

  defp restore(key, nil), do: Application.delete_env(:optimal_engine, key)
  defp restore(key, value), do: Application.put_env(:optimal_engine, key, value)
end
