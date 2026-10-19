defmodule OptimalEngine.Sync.SchedulerRetryTest do
  @moduledoc """
  Capture triggers are installed once at startup. When the Store is busy at
  that moment (right after boot, or during a long write) the install fails;
  it must be retried, or a changed or new table goes uncaptured, and its
  changes never replicate, until the next restart.
  """

  use ExUnit.Case, async: false

  alias OptimalEngine.Store
  alias OptimalEngine.Sync.Capture

  @trigger "sync_capture_ai_contexts"

  setup do
    previous =
      for key <- [:store_call_timeout_ms, :sync_install_retry_ms],
          do: {key, Application.get_env(:optimal_engine, key)}

    Application.put_env(:optimal_engine, :store_call_timeout_ms, 300)
    Application.put_env(:optimal_engine, :sync_install_retry_ms, 200)

    on_exit(fn ->
      for {key, value} <- previous do
        if value,
          do: Application.put_env(:optimal_engine, key, value),
          else: Application.delete_env(:optimal_engine, key)
      end

      Capture.install("contexts")
    end)
  end

  test "a capture install that fails on a busy Store is retried until it succeeds" do
    :ok = Store.raw_execute("DROP TRIGGER IF EXISTS #{@trigger}", [])
    refute trigger?()

    parent = self()

    holder =
      Task.async(fn ->
        Store.transaction(
          fn _txn ->
            send(parent, :holding)
            Process.sleep(1_500)
            {:ok, :released}
          end,
          10_000
        )
      end)

    assert_receive :holding, 2_000
    send(Process.whereis(OptimalEngine.Sync.Scheduler), :install)
    assert {:ok, :released} = Task.await(holder, 10_000)

    assert eventually(&trigger?/0, 5_000), "the capture trigger was not reinstalled"
  end

  defp trigger? do
    {:ok, rows} =
      Store.raw_query("SELECT 1 FROM sqlite_master WHERE type = 'trigger' AND name = ?1", [
        @trigger
      ])

    rows != []
  end

  defp eventually(check, remaining) when remaining <= 0, do: check.()

  defp eventually(check, remaining) do
    if check.() do
      true
    else
      Process.sleep(100)
      eventually(check, remaining - 100)
    end
  end
end
