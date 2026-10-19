defmodule OptimalEngine.Storage.BackupScheduleTest do
  @moduledoc """
  Scheduled offsite backups as durable Engine jobs: one job per interval slot,
  each taking a verified backup, shipping it sealed, and pruning old copies.
  A failure retries, then dead-letters, and is visible in the schedule status
  and the storage audit rather than passing silently.
  """

  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias OptimalEngine.{Backup, Jobs, Store}
  alias OptimalEngine.Backup.Schedule
  alias OptimalEngine.TestSupport.S3Stub

  @env ~w(OPTIMAL_S3_ENDPOINT OPTIMAL_S3_BUCKET OPTIMAL_S3_REGION OPTIMAL_S3_ACCESS_KEY_ID
          OPTIMAL_S3_SECRET_ACCESS_KEY OPTIMAL_S3_PREFIX OPTIMAL_S3_MAX_RETRIES
          OPTIMAL_BACKUP_KEY)

  @hour 3_600_000

  setup do
    previous_env = Map.new(@env, &{&1, System.get_env(&1)})
    previous_dir = Application.get_env(:optimal_engine, :backup_dir)
    previous_interval = Application.get_env(:optimal_engine, :offsite_backup_interval_ms)

    tmp = Path.join(System.tmp_dir!(), "backup-schedule-#{System.unique_integer([:positive])}")
    backing = Path.join(tmp, "backups")
    File.mkdir_p!(backing)
    Application.put_env(:optimal_engine, :backup_dir, backing)

    ref = S3Stub.ref()
    on_exit(fn -> S3Stub.stop(ref) end)
    {:ok, stub} = S3Stub.start(ref: ref, bucket: "engine-test")

    System.put_env("OPTIMAL_S3_ENDPOINT", stub.endpoint)
    System.put_env("OPTIMAL_S3_BUCKET", stub.bucket)
    System.put_env("OPTIMAL_S3_ACCESS_KEY_ID", stub.access_key_id)
    System.put_env("OPTIMAL_S3_SECRET_ACCESS_KEY", stub.secret_access_key)
    System.put_env("OPTIMAL_S3_REGION", stub.region)
    System.delete_env("OPTIMAL_S3_PREFIX")
    System.put_env("OPTIMAL_BACKUP_KEY", Base.encode16(:crypto.strong_rand_bytes(32)))

    reset_schedule_state()

    on_exit(fn ->
      reset_schedule_state()

      Enum.each(previous_env, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)

      restore_app_env(:backup_dir, previous_dir)
      restore_app_env(:offsite_backup_interval_ms, previous_interval)
      S3Stub.stop_agent(stub.agent)
      File.rm_rf(tmp)
    end)

    %{stub: stub, backing: backing}
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:optimal_engine, key)
  defp restore_app_env(key, value), do: Application.put_env(:optimal_engine, key, value)

  # The test database outlives a single run, so the jobs and catalog rows this
  # suite creates are cleared before and after each test.
  defp reset_schedule_state do
    :ok = Store.raw_execute("DELETE FROM jobs WHERE kind = ?1", [Schedule.kind()])
    :ok = Store.raw_execute("DELETE FROM dead_letter_jobs WHERE kind = ?1", [Schedule.kind()])

    :ok =
      Store.raw_execute(
        "DELETE FROM backup_records WHERE json_extract(metadata, '$.scheduled') = 1",
        []
      )
  end

  defp scheduled_rows do
    {:ok, rows} =
      Store.raw_query(
        """
        SELECT id, storage_uri, status, offsite, encrypted, metadata
        FROM backup_records
        WHERE json_extract(metadata, '$.scheduled') = 1
        ORDER BY created_at ASC, rowid ASC
        """,
        []
      )

    Enum.map(rows, fn [id, path, status, offsite, encrypted, metadata] ->
      %{
        id: id,
        path: path,
        status: status,
        offsite: offsite,
        encrypted: encrypted,
        metadata: Jason.decode!(metadata)
      }
    end)
  end

  defp slot_time(n), do: DateTime.add(~U[2026-10-01 00:00:00Z], n * 3_600, :second)

  test "the schedule is off when the interval is unset or zero" do
    assert :disabled = Schedule.schedule(interval_ms: 0)
    assert %{enabled: false, state: "disabled"} = Schedule.status(interval_ms: 0)
  end

  test "one job per interval slot, however often the scheduler ticks" do
    assert {:ok, first} = Schedule.schedule(now: slot_time(0), interval_ms: @hour)

    assert {:ok, again} =
             Schedule.schedule(now: DateTime.add(slot_time(0), 1_800, :second), interval_ms: @hour)

    assert again.id == first.id
    assert first.kind == Schedule.kind()

    assert {:ok, next} = Schedule.schedule(now: slot_time(1), interval_ms: @hour)
    refute next.id == first.id
  end

  test "a scheduled run takes a verified backup, ships it sealed, and records it", %{stub: stub} do
    {:ok, job} = Schedule.schedule(now: slot_time(0), interval_ms: @hour)
    assert [%{job_id: job_id, outcome: :completed}] = Schedule.drain(keep: 14, keep_local: 3)
    assert job_id == job.id

    assert [row] = scheduled_rows()
    assert row.status == "completed"
    assert row.offsite == 1
    assert row.encrypted == 1
    assert row.metadata["schedule_job_id"] == job.id
    assert File.regular?(row.path)

    object = S3Stub.object_body(stub.agent, row.metadata["offsite_key"])
    refute String.starts_with?(object, "SQLite format 3")

    status = Schedule.status(interval_ms: @hour)
    assert status.state == "ok"
    assert status.enabled
    assert status.encryption.key_configured
    assert status.last_success.backup_id == row.id
    assert status.last_job.status == "completed"
  end

  test "pruning keeps the newest offsite copies and a few local ones, never a hand-made backup",
       %{stub: stub} do
    {:ok, manual_target} = Backup.resolve_target("manual-before-schedule.db")
    {:ok, manual} = Backup.create(manual_target, offsite: true)
    assert manual.offsite.status == "shipped"

    for n <- 0..3 do
      {:ok, _} = Schedule.schedule(now: slot_time(n), interval_ms: @hour)
      assert [%{outcome: :completed}] = Schedule.drain(keep: 2, keep_local: 1)
    end

    rows = scheduled_rows()
    assert length(rows) == 4
    [oldest, older, newer, newest] = rows

    # The two newest keep their offsite copies; the older two lost theirs.
    assert Enum.map(rows, & &1.offsite) == [0, 0, 1, 1]

    assert S3Stub.object_keys(stub.agent) ==
             Enum.sort([
               manual.offsite.key,
               newer.metadata["offsite_key"],
               newest.metadata["offsite_key"]
             ])

    # Only the newest local copy remains on disk.
    assert Enum.map(rows, &File.regular?(&1.path)) == [false, false, false, true]

    # A backup with no copy left anywhere is marked pruned; one still offsite is not.
    assert oldest.status == "pruned"
    assert older.status == "pruned"
    assert newer.status == "completed"
    assert newest.status == "completed"
    assert oldest.metadata["offsite_pruned_at"]
    assert oldest.metadata["local_pruned_at"]

    # The hand-made backup is untouched.
    assert File.regular?(manual.target)
    assert S3Stub.object_body(stub.agent, manual.offsite.key) != nil
  end

  test "a failing bucket retries on the same local backup, then dead-letters, and says so" do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    System.put_env("OPTIMAL_S3_ENDPOINT", "http://127.0.0.1:#{port}")
    System.put_env("OPTIMAL_S3_MAX_RETRIES", "0")

    {:ok, job} = Schedule.schedule(now: slot_time(0), interval_ms: @hour)

    assert [%{outcome: :retry}] = Schedule.drain(retry_in: 0)
    assert {:ok, %{status: "available", last_error: error}} = Jobs.get(job.id, job.workspace_id)
    assert error =~ "transport"
    assert Schedule.status(interval_ms: @hour).state == "retrying"

    assert [%{outcome: :retry}] = Schedule.drain(retry_in: 0)
    assert [%{outcome: :dead}] = Schedule.drain(retry_in: 0)

    # Three attempts, one local backup: a retry ships the backup its job already took.
    assert [row] = scheduled_rows()
    assert row.offsite == 0
    assert File.regular?(row.path)

    status = Schedule.status(interval_ms: @hour)
    assert status.state == "failing"
    assert status.dead_letters.count == 1
    assert status.dead_letters.latest.final_error =~ "transport"
    assert status.last_job.status == "dead"

    Application.put_env(:optimal_engine, :offsite_backup_interval_ms, @hour)
    check = audit_check("offsite_backup_schedule")
    refute check.ok
    assert check.detail =~ "failing"
  end

  test "without a backup key a run fails before it takes a backup" do
    System.delete_env("OPTIMAL_BACKUP_KEY")

    assert %{state: "misconfigured", encryption: %{key_configured: false}} =
             Schedule.status(interval_ms: @hour)

    {:ok, job} = Schedule.schedule(now: slot_time(0), interval_ms: @hour)
    assert [%{outcome: :retry}] = Schedule.drain(retry_in: 0)
    assert {:ok, %{last_error: error}} = Jobs.get(job.id, job.workspace_id)
    assert error =~ "backup_key_missing"
    assert scheduled_rows() == []
  end

  test "the storage audit passes while the schedule is off or healthy" do
    Application.put_env(:optimal_engine, :offsite_backup_interval_ms, 0)
    assert %{ok: true, detail: %{state: "disabled"}} = audit_check("offsite_backup_schedule")

    Application.put_env(:optimal_engine, :offsite_backup_interval_ms, @hour)
    {:ok, _} = Schedule.schedule(now: DateTime.utc_now(), interval_ms: @hour)
    assert [%{outcome: :completed}] = Schedule.drain()
    assert %{ok: true, detail: %{state: "ok"}} = audit_check("offsite_backup_schedule")
  end

  test "GET /api/backup/offsite reports the schedule next to the copies" do
    Application.put_env(:optimal_engine, :offsite_backup_interval_ms, @hour)

    conn =
      conn(:get, "/api/backup/offsite")
      |> put_req_header("accept", "application/json")
      |> OptimalEngine.API.Router.call(OptimalEngine.API.Router.init([]))

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["schedule"]["enabled"] == true
    assert body["schedule"]["interval_ms"] == @hour
    assert body["schedule"]["keep"] == 14
    assert body["schedule"]["state"] in ["pending", "ok"]
    refute conn.resp_body =~ System.get_env("OPTIMAL_BACKUP_KEY")
  end

  defp audit_check(name) do
    OptimalEngine.StorageAudit.run().checks |> Enum.find(&(&1.name == name))
  end
end
