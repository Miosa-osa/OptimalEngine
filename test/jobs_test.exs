defmodule OptimalEngine.JobsTest do
  use ExUnit.Case, async: false

  alias OptimalEngine.Jobs
  alias OptimalEngine.WorkspaceTopology

  setup do
    suffix = System.unique_integer([:positive])

    {:ok, workspace} =
      WorkspaceTopology.create_workspace(%{slug: "jobs-#{suffix}", name: "Jobs #{suffix}"})

    %{workspace_id: workspace.id, kind: "test.job.#{suffix}"}
  end

  defp claim(ws, kind, opts \\ []) do
    Jobs.claim(Keyword.merge([workspace_id: ws, kinds: [kind], lease_owner: "worker-a"], opts))
  end

  test "enqueue persists a due job and claim leases it once", %{workspace_id: ws, kind: kind} do
    assert {:ok, job} = Jobs.enqueue(ws, kind, %{"n" => 1})
    assert job.status == "available"
    assert job.payload == %{"n" => 1}
    assert job.attempts == 0

    assert {:ok, claimed} = claim(ws, kind)
    assert claimed.id == job.id
    assert claimed.status == "running"
    assert claimed.attempts == 1
    assert claimed.lease_owner == "worker-a"

    assert {:ok, nil} = claim(ws, kind)
    assert {:ok, done} = Jobs.complete(job.id, "worker-a")
    assert done.status == "completed"
    assert is_binary(done.completed_at)
  end

  test "higher priority runs first", %{workspace_id: ws, kind: kind} do
    {:ok, low} = Jobs.enqueue(ws, kind, %{}, priority: 1)
    {:ok, high} = Jobs.enqueue(ws, kind, %{}, priority: 9)

    assert {:ok, %{id: first}} = claim(ws, kind)
    assert {:ok, %{id: second}} = claim(ws, kind)
    assert [first, second] == [high.id, low.id]
  end

  test "future jobs are not due yet", %{workspace_id: ws, kind: kind} do
    {:ok, _} = Jobs.enqueue(ws, kind, %{}, run_in: 3_600)
    assert {:ok, nil} = claim(ws, kind)
  end

  test "idempotency keys return the existing job within a workspace", %{
    workspace_id: ws,
    kind: kind
  } do
    {:ok, first} = Jobs.enqueue(ws, kind, %{"v" => 1}, idempotency_key: "same")
    {:ok, second} = Jobs.enqueue(ws, kind, %{"v" => 2}, idempotency_key: "same")
    assert first.id == second.id
    assert second.payload == %{"v" => 1}
  end

  test "a failed attempt backs off before it is due again", %{workspace_id: ws, kind: kind} do
    {:ok, job} = Jobs.enqueue(ws, kind, %{}, max_attempts: 3)
    {:ok, claimed} = claim(ws, kind)

    assert {:ok, %{outcome: :retry, job: retried}} = Jobs.fail(job.id, "worker-a", "boom")
    assert retried.status == "available"
    assert retried.last_error == "boom"
    assert retried.lease_owner == nil
    assert retried.run_at > claimed.run_at
    assert {:ok, nil} = claim(ws, kind)
  end

  test "exhausted retries dead-letter the job", %{workspace_id: ws, kind: kind} do
    {:ok, job} = Jobs.enqueue(ws, kind, %{"task" => "flaky"}, max_attempts: 2)

    {:ok, _} = claim(ws, kind)
    assert {:ok, %{outcome: :retry}} = Jobs.fail(job.id, "worker-a", "boom 1", retry_in: 0)

    {:ok, again} = claim(ws, kind)
    assert again.attempts == 2
    assert {:ok, %{outcome: :dead, job: dead}} = Jobs.fail(job.id, "worker-a", {:error, :final})
    assert dead.status == "dead"
    assert {:ok, nil} = claim(ws, kind)

    assert {:ok, [letter]} = Jobs.dead_letters(ws)
    assert letter.original_job_id == job.id
    assert letter.attempts == 2
    assert letter.final_error =~ "final"
    assert letter.payload == %{"task" => "flaky"}
  end

  test "a dead letter replays exactly once with a fresh budget", %{workspace_id: ws, kind: kind} do
    {:ok, job} = Jobs.enqueue(ws, kind, %{"x" => 1}, max_attempts: 1)
    {:ok, _} = claim(ws, kind)
    {:ok, %{outcome: :dead}} = Jobs.fail(job.id, "worker-a", "nope")
    {:ok, [letter]} = Jobs.dead_letters(ws)

    assert {:ok, replay} = Jobs.replay_dead_letter(letter.id, ws)
    assert replay.id != job.id
    assert replay.status == "available"
    assert replay.attempts == 0
    assert replay.payload == %{"x" => 1}

    assert {:error, :already_replayed} = Jobs.replay_dead_letter(letter.id, ws)
    assert {:error, :not_found} = Jobs.replay_dead_letter(letter.id, "another-workspace")
  end

  test "an expired lease is reclaimed and the old owner loses it", %{workspace_id: ws, kind: kind} do
    {:ok, job} = Jobs.enqueue(ws, kind, %{})
    {:ok, _} = claim(ws, kind, lease_seconds: 0)

    assert {:ok, reclaimed} = claim(ws, kind, lease_owner: "worker-b")
    assert reclaimed.id == job.id
    assert reclaimed.attempts == 2

    assert {:error, :lease_lost} = Jobs.complete(job.id, "worker-a")
    assert {:error, :lease_lost} = Jobs.fail(job.id, "worker-a", "late")
    assert {:ok, %{status: "completed"}} = Jobs.complete(job.id, "worker-b")
  end

  test "run_next completes, retries, and dead-letters through a handler", %{
    workspace_id: ws,
    kind: kind
  } do
    {:ok, ok_job} = Jobs.enqueue(ws, kind, %{"result" => "ok"}, priority: 3)
    {:ok, raise_job} = Jobs.enqueue(ws, kind, %{"result" => "raise"}, priority: 2, max_attempts: 1)
    {:ok, err_job} = Jobs.enqueue(ws, kind, %{"result" => "error"}, priority: 1)

    handler = fn
      %{payload: %{"result" => "ok"}} -> :ok
      %{payload: %{"result" => "raise"}} -> raise "handler crashed"
      %{payload: %{"result" => "error"}} -> {:error, :transient}
    end

    opts = [workspace_id: ws, kinds: [kind]]

    assert {:ok, %{job: %{id: id1}, outcome: :completed}} = Jobs.run_next(handler, opts)
    assert {:ok, %{job: %{id: id2}, outcome: :dead}} = Jobs.run_next(handler, opts)
    assert {:ok, %{job: %{id: id3}, outcome: :retry}} = Jobs.run_next(handler, opts)
    assert [id1, id2, id3] == [ok_job.id, raise_job.id, err_job.id]
    assert :empty = Jobs.run_next(handler, opts)

    assert {:ok, [letter]} = Jobs.dead_letters(ws)
    assert letter.final_error =~ "handler crashed"
  end

  test "jobs are workspace scoped", %{workspace_id: ws, kind: kind} do
    {:ok, job} = Jobs.enqueue(ws, kind, %{})
    assert {:error, :not_found} = Jobs.get(job.id, "another-workspace")
    assert {:ok, nil} = Jobs.claim(workspace_id: "another-workspace", kinds: [kind])
    assert {:error, :workspace_not_found} = Jobs.enqueue("missing-workspace", kind, %{})
  end

  test "invalid input is rejected", %{workspace_id: ws} do
    assert {:error, :kind_required} = Jobs.enqueue(ws, " ", %{})
    assert {:error, :invalid_max_attempts} = Jobs.enqueue(ws, "k", %{}, max_attempts: 0)
  end

  test "enqueue_coalesced keeps one active job of a kind per workspace, even under concurrency",
       %{workspace_id: ws, kind: kind} do
    results =
      1..8
      |> Enum.map(fn n -> Task.async(fn -> Jobs.enqueue_coalesced(ws, kind, %{"n" => n}) end) end)
      |> Enum.map(&Task.await/1)

    assert [{:ok, job, :queued}] = Enum.filter(results, &match?({:ok, _, :queued}, &1))
    assert Enum.all?(results, fn {:ok, other, _} -> other.id == job.id end)

    assert {:ok, %{id: id}} = claim(ws, kind)
    assert id == job.id
    assert {:ok, again, :active} = Jobs.enqueue_coalesced(ws, kind)
    assert again.id == job.id

    {:ok, _} = Jobs.complete(job.id, "worker-a")
    assert {:ok, next, :queued} = Jobs.enqueue_coalesced(ws, kind, %{}, idempotency_key: "x")
    refute next.id == job.id
    assert next.idempotency_key == nil
    assert {:error, :workspace_not_found} = Jobs.enqueue_coalesced("no-such-workspace", kind)
  end

  test "complete_and_enqueue completes a job and queues its continuation in one step",
       %{workspace_id: ws, kind: kind} do
    {:ok, job} = Jobs.enqueue(ws, kind, %{"step" => 1}, priority: 3, max_attempts: 2)
    {:ok, _} = claim(ws, kind)

    assert {:ok, %{completed: done, next: next, state: :queued}} =
             Jobs.complete_and_enqueue(job.id, "worker-a", %{"step" => 2})

    assert done.id == job.id
    assert done.status == "completed"
    assert next.payload == %{"step" => 2}
    assert next.status == "available"
    assert {next.priority, next.max_attempts} == {3, 2}

    assert {:error, :lease_lost} = Jobs.complete_and_enqueue(next.id, "worker-a", %{})
    assert {:ok, [_]} = Jobs.list(ws, status: "available")
  end

  test "a job enqueued while the running one finishes is the continuation it coalesces onto",
       %{workspace_id: ws, kind: kind} do
    {:ok, job} = Jobs.enqueue(ws, kind, %{"step" => 1})
    {:ok, _} = claim(ws, kind)
    # A request that slipped past coalescing while the job was running.
    {:ok, other} = Jobs.enqueue(ws, kind, %{"from" => "request"})

    assert {:ok, %{completed: done, next: next, state: :active}} =
             Jobs.complete_and_enqueue(job.id, "worker-a", %{"step" => 2})

    assert done.status == "completed"
    assert next.id == other.id
    assert {:ok, [only]} = Jobs.list(ws, status: "available")
    assert only.id == other.id
  end

  test "defer puts a job back later without spending an attempt", %{workspace_id: ws, kind: kind} do
    {:ok, job} = Jobs.enqueue(ws, kind, %{"n" => 1}, max_attempts: 1)
    {:ok, claimed} = claim(ws, kind)
    assert claimed.attempts == 1

    assert {:ok, deferred} =
             Jobs.defer(job.id, "worker-a", "deferred: waiting", 600, payload: %{"n" => 2})

    assert deferred.status == "available"
    assert deferred.attempts == 0
    assert deferred.last_error == "deferred: waiting"
    assert deferred.payload == %{"n" => 2}
    assert deferred.lease_owner == nil
    assert {:ok, nil} = claim(ws, kind)
    assert {:error, :lease_lost} = Jobs.defer(job.id, "worker-a", "again", 0)
  end
end
