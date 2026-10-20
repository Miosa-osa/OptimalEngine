defmodule OptimalEngine.API.ViabilityBusyTest do
  @moduledoc """
  `GET /api/signals/classification` reads the Store. A Store that does not
  answer in time, or one that reports a lock, is a retryable 503 with
  Retry-After; any other Store failure is a 500 that does not echo the
  failure.
  """

  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias OptimalEngine.API.ViabilityAPI
  alias OptimalEngine.Signal.Reclassifier
  alias OptimalEngine.Store

  setup do
    previous = Application.get_env(:optimal_engine, :store_call_timeout_ms)
    Application.put_env(:optimal_engine, :store_call_timeout_ms, 300)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:optimal_engine, :store_call_timeout_ms, previous),
        else: Application.delete_env(:optimal_engine, :store_call_timeout_ms)
    end)
  end

  # Holds the single-writer Store for `ms` inside one transaction.
  defp hold_store(ms) do
    parent = self()

    task =
      Task.async(fn ->
        Store.transaction(
          fn _txn ->
            send(parent, :holding)
            Process.sleep(ms)
            {:ok, :released}
          end,
          ms + 5_000
        )
      end)

    assert_receive :holding, 2_000
    task
  end

  defp classification(query),
    do: ViabilityAPI.classification(conn(:get, "/api/signals/classification?" <> query))

  test "the reclassifier answers busy, not an exit, while the Store is held" do
    task = hold_store(1_500)

    assert {:error, :busy} = Reclassifier.distribution("busy-ws", tenant_id: "default")
    assert {:error, :busy} = Reclassifier.plan("busy-ws", tenant_id: "default")

    assert {:ok, :released} = Task.await(task, 10_000)
    assert {:ok, %{}} = Reclassifier.distribution("busy-ws", tenant_id: "default")
  end

  test "the route answers 503 with Retry-After while the Store is held, with and without a plan" do
    task = hold_store(2_500)

    for query <- ["workspace=busy-ws", "workspace=busy-ws&plan=true"] do
      response = classification(query)

      assert response.status == 503
      assert get_resp_header(response, "retry-after") == ["1"]
      assert %{"error" => "busy"} = Jason.decode!(response.resp_body)
    end

    assert {:ok, :released} = Task.await(task, 10_000)
    assert classification("workspace=busy-ws").status == 200
  end

  test "a Store that reports a lock is busy, whatever the reason's shape" do
    for reason <- [
          :busy,
          :timeout,
          "database is locked",
          "database table is locked",
          "Database BUSY",
          %{message: "database is locked"}
        ] do
      response = ViabilityAPI.store_error(conn(:get, "/api/signals/classification"), reason)

      assert response.status == 503, "#{inspect(reason)} should be busy"
      assert get_resp_header(response, "retry-after") == ["1"]
    end
  end

  test "any other Store failure is a 500 that does not echo the failure" do
    for reason <- ["no such table: contexts", :enoent, %{message: "disk I/O error"}] do
      response = ViabilityAPI.store_error(conn(:get, "/api/signals/classification"), reason)

      assert response.status == 500
      assert Jason.decode!(response.resp_body) == %{"error" => "store_error"}
      refute response.resp_body =~ "contexts"
    end
  end
end
