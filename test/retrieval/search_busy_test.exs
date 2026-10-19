defmodule OptimalEngine.Retrieval.SearchBusyTest do
  @moduledoc """
  A search that reaches a Store busy past its call timeout (a long write, or
  the Engine warming up after boot) answers busy: the search process keeps
  running and the HTTP route answers 503 with Retry-After, never a 500 and
  never an empty result list that looks like "nothing found".
  """

  use ExUnit.Case, async: false

  import Plug.Test

  alias OptimalEngine.API.Router
  alias OptimalEngine.Retrieval.Search
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

  test "a search while the Store is busy answers busy, and the search process lives on" do
    pid = Process.whereis(Search)
    task = hold_store(1_500)

    assert {:error, :busy} = Search.search("anything at all")
    assert Process.whereis(Search) == pid

    assert {:ok, :released} = Task.await(task, 10_000)
    assert {:ok, _results} = Search.search("anything at all")
  end

  test "the search route answers 503 with Retry-After while the Store is busy" do
    task = hold_store(1_500)

    # Workspace authorization reads the Store before the search runs, so the
    # request fails there; the error handler still answers 503, then
    # re-raises (Plug.ErrorHandler), and sent_resp/1 reads what was sent.
    conn = conn(:get, "/api/search?q=anything")
    catch_exit(Router.call(conn, Router.init([])))
    {status, headers, body} = sent_resp(conn)

    assert status == 503
    assert {"retry-after", "1"} in headers
    assert %{"error" => "busy"} = Jason.decode!(body)

    assert {:ok, :released} = Task.await(task, 10_000)

    assert conn(:get, "/api/search?q=anything") |> Router.call(Router.init([])) |> Map.get(:status) ==
             200
  end
end
