defmodule OptimalEngine.Storage.NATSClientTest do
  @moduledoc """
  The long-lived JetStream client: one supervised connection that comes back
  by itself after the server goes away, publishes with an acknowledgement and
  a message id, provisions streams and durable pull consumers, and delivers
  what a consumer has not acknowledged until it is. Never a raise and never a
  wait on a server that is not there: a call while disconnected answers
  `{:error, :not_connected}` at once.
  """
  use ExUnit.Case, async: false

  alias OptimalEngine.Storage.NATS.{Connection, JetStream}
  alias OptimalEngine.TestSupport.NATSStub

  defp start_client(stub, extra \\ []) do
    name = :"nats_client_#{System.unique_integer([:positive])}"
    opts = [name: name, url: "nats://127.0.0.1:#{stub.port}", backoff: {20, 100}] ++ extra
    start_supervised!({Connection, opts}, id: name)
    assert wait_for(fn -> Connection.status(name).state == "connected" end)
    name
  end

  defp wait_for(fun, tries \\ 100) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(20) && wait_for(fun, tries - 1)
    end
  end

  setup do
    {:ok, stub} = NATSStub.start()
    on_exit(fn -> NATSStub.stop(stub) end)
    %{stub: stub}
  end

  test "without a URL the client idles as not_configured and every call is refused at once" do
    name = :nats_client_unconfigured
    start_supervised!({Connection, name: name, url: nil}, id: name)

    assert %{state: "not_configured", reconnects: 0} = Connection.status(name)
    assert {:error, :not_connected} = Connection.request(name, "a.b", "x")
    assert {:error, :not_connected} = JetStream.publish(name, "a.b", "x", msg_id: "1")
  end

  test "status names the server and never the credential", %{stub: stub} do
    {:ok, secured} = NATSStub.start(token: "s3cret")
    on_exit(fn -> NATSStub.stop(secured) end)

    name = :"nats_client_#{System.unique_integer([:positive])}"
    url = "nats://s3cret@127.0.0.1:#{secured.port}"
    start_supervised!({Connection, name: name, url: url, backoff: {20, 100}}, id: name)
    assert wait_for(fn -> Connection.status(name).state == "connected" end)

    status = Connection.status(name)
    assert status.server.version == "2.10.0"
    assert status.server.jetstream
    refute inspect(status) =~ "s3cret"

    wrong = :"nats_client_#{System.unique_integer([:positive])}"
    url = "nats://wrong@127.0.0.1:#{secured.port}"
    start_supervised!({Connection, name: wrong, url: url, backoff: {20, 100}}, id: wrong)
    assert wait_for(fn -> Connection.status(wrong).last_error != nil end)
    assert %{state: state, last_error: error} = Connection.status(wrong)
    assert state in ~w(disconnected connecting)
    assert error =~ "Authorization Violation"
    refute inspect(Connection.status(wrong)) =~ "wrong@"

    _ = stub
  end

  test "a stream is created once, updated when its subjects change, and reported as such", %{
    stub: stub
  } do
    conn = start_client(stub)
    config = %{name: "OPT_T", subjects: ["opt.t.>"], retention: "limits", storage: "memory"}

    assert {:ok, :created, _} = JetStream.ensure_stream(conn, config)
    assert {:ok, :exists, _} = JetStream.ensure_stream(conn, config)

    assert {:ok, :updated, %{"config" => %{"subjects" => ["opt.t.>", "opt.u.>"]}}} =
             JetStream.ensure_stream(conn, %{config | subjects: ["opt.t.>", "opt.u.>"]})
  end

  test "a publish is acknowledged with its sequence, once per message id", %{stub: stub} do
    conn = start_client(stub)

    {:ok, _, _} =
      JetStream.ensure_stream(conn, %{name: "OPT_P", subjects: ["opt.p.>"], storage: "memory"})

    assert {:ok, %{stream: "OPT_P", seq: 1, duplicate: false}} =
             JetStream.publish(conn, "opt.p.a", ~s({"n":1}),
               msg_id: "k1",
               headers: %{"Optimal-Seq" => "7"}
             )

    assert {:ok, %{seq: 1, duplicate: true}} =
             JetStream.publish(conn, "opt.p.a", ~s({"n":1}), msg_id: "k1")

    assert {:ok, %{seq: 2}} = JetStream.publish(conn, "opt.p.a", ~s({"n":2}), msg_id: "k2")
    assert length(NATSStub.messages(stub, "OPT_P")) == 2

    assert {:ok, %{seq: 1, headers: %{"Optimal-Seq" => "7", "Nats-Msg-Id" => "k1"}}} =
             JetStream.get_message(conn, "OPT_P", seq: 1)

    assert {:ok, %{seq: 2, payload: ~s({"n":2})}} =
             JetStream.get_message(conn, "OPT_P", last_by_subject: "opt.p.a")

    assert {:error, :not_found} = JetStream.get_message(conn, "OPT_P", last_by_subject: "opt.p.b")
    assert {:error, {:no_responders, _}} = JetStream.publish(conn, "nobody.here", "x", msg_id: "z")
  end

  test "a durable pull consumer delivers until acknowledged, redelivers a nak, and drops a term",
       %{stub: stub} do
    conn = start_client(stub)

    {:ok, _, _} =
      JetStream.ensure_stream(conn, %{
        name: "OPT_Q",
        subjects: ["opt.q.>"],
        retention: "workqueue",
        storage: "memory"
      })

    assert {:ok, _} =
             JetStream.ensure_consumer(conn, "OPT_Q", %{durable_name: "worker", ack_wait_ms: 30_000})

    for n <- 1..3, do: {:ok, _} = JetStream.publish(conn, "opt.q.job", "job-#{n}", msg_id: "j#{n}")

    assert {:ok, [first, second]} =
             JetStream.fetch(conn, "OPT_Q", "worker", batch: 2, expires_ms: 200)

    assert {first.payload, first.delivered, first.stream_seq} == {"job-1", 1, 1}
    assert second.payload == "job-2"

    :ok = JetStream.ack(conn, first)
    :ok = JetStream.nak(conn, second)

    assert {:ok, messages} = JetStream.fetch(conn, "OPT_Q", "worker", batch: 5, expires_ms: 200)
    # A redelivery has no place in line: JetStream may hand it out after newer messages.
    assert messages |> Enum.map(&{&1.payload, &1.delivered}) |> Enum.sort() == [
             {"job-2", 2},
             {"job-3", 1}
           ]

    [again, third] = Enum.sort_by(messages, & &1.payload)
    :ok = JetStream.term(conn, again)
    :ok = JetStream.nak(conn, third, delay_ms: 60_000)

    assert {:ok, []} = JetStream.fetch(conn, "OPT_Q", "worker", batch: 5, expires_ms: 100)
    assert {:ok, []} = JetStream.fetch(conn, "OPT_Q", "worker", batch: 5, no_wait: true)

    # A work queue forgets what was acknowledged or terminated.
    assert Enum.map(NATSStub.messages(stub, "OPT_Q"), & &1.data) == ["job-3"]
  end

  test "the connection comes back after the server drops it, and a stopped server is reported", %{
    stub: stub
  } do
    conn = start_client(stub)

    {:ok, _, _} =
      JetStream.ensure_stream(conn, %{name: "OPT_R", subjects: ["opt.r.>"], storage: "memory"})

    NATSStub.drop(stub)
    assert wait_for(fn -> Connection.status(conn).reconnects >= 1 end)
    assert wait_for(fn -> Connection.status(conn).state == "connected" end)
    assert {:ok, %{seq: 1}} = JetStream.publish(conn, "opt.r.a", "x", msg_id: "r1")

    port = stub.port
    NATSStub.stop(stub)
    assert wait_for(fn -> Connection.status(conn).state != "connected" end)
    assert {:error, :not_connected} = JetStream.publish(conn, "opt.r.a", "y", msg_id: "r2")
    assert Connection.status(conn).last_error != nil

    {:ok, back} = NATSStub.start(port: port)
    on_exit(fn -> NATSStub.stop(back) end)
    assert wait_for(fn -> Connection.status(conn).state == "connected" end, 200)
  end

  test "a request still waiting when the connection drops is answered, not left hanging", %{
    stub: stub
  } do
    conn = start_client(stub)

    {:ok, _, _} =
      JetStream.ensure_stream(conn, %{name: "OPT_W", subjects: ["opt.w.>"], storage: "memory"})

    {:ok, _} = JetStream.ensure_consumer(conn, "OPT_W", %{durable_name: "w"})

    task = Task.async(fn -> JetStream.fetch(conn, "OPT_W", "w", batch: 1, expires_ms: 5_000) end)
    Process.sleep(50)
    NATSStub.drop(stub)
    assert {:error, :disconnected} = Task.await(task, 2_000)
  end
end
