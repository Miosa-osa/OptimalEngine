defmodule OptimalEngine.Storage.NATSJetStreamIntegrationTest do
  @moduledoc """
  The JetStream client against a real server: `docker run -p 4222:4222 nats -js`
  and `OPTIMAL_TEST_NATS_URL=nats://127.0.0.1:4222`. Skipped without it.
  Every stream here is the test's own (`OPTIMAL_IT_<random>`) and is deleted
  when the test ends.
  """
  use ExUnit.Case, async: false

  alias OptimalEngine.Storage.NATS.{Connection, JetStream}

  @url System.get_env("OPTIMAL_TEST_NATS_URL")

  if is_nil(@url) or @url == "" do
    @moduletag skip: "set OPTIMAL_TEST_NATS_URL to a JetStream server (nats -js) to run"
  end

  @moduletag :nats_integration

  setup do
    name = :"nats_it_#{System.unique_integer([:positive])}"
    start_supervised!({Connection, name: name, url: @url, backoff: {50, 500}}, id: name)
    assert wait_for(fn -> Connection.status(name).state == "connected" end)

    stream = "OPTIMAL_IT_" <> Base.encode16(:crypto.strong_rand_bytes(4))
    subject = "optimal_it.#{String.downcase(stream)}"

    on_exit(fn ->
      cleanup = :"nats_it_cleanup_#{System.unique_integer([:positive])}"
      {:ok, pid} = Connection.start_link(name: cleanup, url: @url)
      wait_for(fn -> Connection.status(cleanup).state == "connected" end)
      JetStream.api(cleanup, "STREAM.DELETE." <> stream)
      GenServer.stop(pid)
    end)

    %{conn: name, stream: stream, subject: subject}
  end

  defp wait_for(fun, tries \\ 100) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(20) && wait_for(fun, tries - 1)
    end
  end

  test "status reports a JetStream server", %{conn: conn} do
    assert %{state: "connected", server: %{jetstream: true, version: version}} =
             Connection.status(conn)

    assert is_binary(version)
  end

  test "a stream is created, found as it is, and updated", %{
    conn: conn,
    stream: stream,
    subject: subject
  } do
    config = %{name: stream, subjects: [subject <> ".>"], storage: "memory", max_age_ms: 60_000}
    assert {:ok, :created, _} = JetStream.ensure_stream(conn, config)
    assert {:ok, :exists, _} = JetStream.ensure_stream(conn, config)

    assert {:ok, :updated, %{"config" => %{"max_age" => 120_000_000_000}}} =
             JetStream.ensure_stream(conn, %{config | max_age_ms: 120_000})
  end

  test "a message id is stored once, and the last message on a subject reads back with its headers",
       %{conn: conn, stream: stream, subject: subject} do
    {:ok, :created, _} =
      JetStream.ensure_stream(conn, %{name: stream, subjects: [subject <> ".>"], storage: "memory"})

    one = subject <> ".ws1"

    assert {:ok, %{seq: 1, duplicate: false}} =
             JetStream.publish(conn, one, "a", msg_id: "m1", headers: %{"Optimal-Seq" => "10"})

    assert {:ok, %{seq: 1, duplicate: true}} = JetStream.publish(conn, one, "a", msg_id: "m1")

    assert {:ok, %{seq: 2}} =
             JetStream.publish(conn, one, "b", msg_id: "m2", headers: %{"Optimal-Seq" => "11"})

    assert {:ok, %{seq: 2, payload: "b", headers: %{"Optimal-Seq" => "11"}}} =
             JetStream.get_message(conn, stream, last_by_subject: one)

    assert {:error, :not_found} =
             JetStream.get_message(conn, stream, last_by_subject: subject <> ".none")

    assert {:error, {:no_responders, _}} = JetStream.publish(conn, "optimal_it_nobody.x", "x")
  end

  test "a durable work queue delivers until acknowledged, redelivers a nak, drops a term",
       %{conn: conn, stream: stream, subject: subject} do
    {:ok, :created, _} =
      JetStream.ensure_stream(conn, %{
        name: stream,
        subjects: [subject <> ".>"],
        retention: "workqueue",
        storage: "memory"
      })

    assert {:ok, %{"name" => "w"}} =
             JetStream.ensure_consumer(conn, stream, %{durable_name: "w", ack_wait_ms: 30_000})

    for n <- 1..3,
        do: {:ok, _} = JetStream.publish(conn, subject <> ".job", "job-#{n}", msg_id: "j#{n}")

    assert {:ok, [first, second]} = JetStream.fetch(conn, stream, "w", batch: 2, expires_ms: 1_000)
    assert {first.payload, first.delivered, first.stream_seq} == {"job-1", 1, 1}
    :ok = JetStream.ack(conn, first)
    :ok = JetStream.nak(conn, second)

    assert {:ok, messages} = JetStream.fetch(conn, stream, "w", batch: 5, expires_ms: 500)
    # A redelivery has no place in line: JetStream may hand it out after newer messages.
    assert messages |> Enum.map(&{&1.payload, &1.delivered}) |> Enum.sort() == [
             {"job-2", 2},
             {"job-3", 1}
           ]

    [again, third] = Enum.sort_by(messages, & &1.payload)
    :ok = JetStream.term(conn, again)
    :ok = JetStream.nak(conn, third, delay_ms: 60_000)

    assert {:ok, []} = JetStream.fetch(conn, stream, "w", batch: 5, no_wait: true)
    assert {:ok, []} = JetStream.fetch(conn, stream, "w", batch: 5, expires_ms: 300)

    # The acknowledged and the terminated message are gone from the queue.
    Process.sleep(100)
    assert {:ok, %{"state" => %{"messages" => 1}}} = JetStream.api(conn, "STREAM.INFO." <> stream)
  end

  test "an unanswered message comes back after the ack wait", %{
    conn: conn,
    stream: stream,
    subject: subject
  } do
    {:ok, :created, _} =
      JetStream.ensure_stream(conn, %{
        name: stream,
        subjects: [subject <> ".>"],
        retention: "workqueue",
        storage: "memory"
      })

    {:ok, _} = JetStream.ensure_consumer(conn, stream, %{durable_name: "w", ack_wait_ms: 500})
    {:ok, _} = JetStream.publish(conn, subject <> ".job", "x", msg_id: "only")

    assert {:ok, [%{delivered: 1}]} = JetStream.fetch(conn, stream, "w", batch: 1, expires_ms: 500)

    assert {:ok, [%{delivered: 2} = back]} =
             JetStream.fetch(conn, stream, "w", batch: 1, expires_ms: 2_000)

    :ok = JetStream.ack(conn, back)
  end
end
