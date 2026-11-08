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

  setup do
    previous = Application.get_env(:optimal_engine, :store_call_timeout_ms)
    Application.put_env(:optimal_engine, :store_call_timeout_ms, 300)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:optimal_engine, :store_call_timeout_ms, previous),
        else: Application.delete_env(:optimal_engine, :store_call_timeout_ms)
    end)
  end

  # Stalls the Store for `ms`: no statement is answered until it ends.
  defp hold_store(ms), do: OptimalEngine.Test.StoreStall.hold(ms)

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

    # Workspace authorization reads the Store before the search runs. A call
    # to SQLite's store exits when it is not answered in time, and the error
    # handler still answers 503, then re-raises (Plug.ErrorHandler); the
    # PostgreSQL store returns busy and the route answers 503 itself. Either
    # way sent_resp/1 reads what was sent.
    conn = conn(:get, "/api/search?q=anything")

    try do
      Router.call(conn, Router.init([]))
    catch
      :exit, _reason -> :exited
    end

    {status, headers, body} = sent_resp(conn)

    assert status == 503
    assert {"retry-after", "1"} in headers
    assert %{"error" => "busy"} = Jason.decode!(body)

    assert {:ok, :released} = Task.await(task, 10_000)

    assert conn(:get, "/api/search?q=anything") |> Router.call(Router.init([])) |> Map.get(:status) ==
             200
  end
end
