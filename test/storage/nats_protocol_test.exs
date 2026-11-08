defmodule OptimalEngine.Storage.NATSProtocolTest do
  @moduledoc """
  The NATS frames the long-lived client reads, parsed from a byte buffer that
  may end anywhere, and the commands it writes.
  """
  use ExUnit.Case, async: true

  alias OptimalEngine.Storage.NATS.Protocol

  test "control frames, a MSG with and without a reply, and the rest kept" do
    buffer =
      "INFO {\"server_id\":\"x\",\"jetstream\":true}\r\nPING\r\n+OK\r\nPONG\r\n" <>
        "MSG a.b 7 5\r\nhello\r\nMSG a.c 7 _INBOX.r 0\r\n\r\nMSG a.d 7 3\r\nab"

    assert {:ok, frames, rest} = Protocol.parse(buffer)

    assert [
             {:info, %{"jetstream" => true}},
             :ping,
             :ok,
             :pong,
             {:msg, %{subject: "a.b", sid: "7", reply: nil, payload: "hello", headers: %{}}},
             {:msg, %{subject: "a.c", reply: "_INBOX.r", payload: ""}}
           ] = frames

    assert rest == "MSG a.d 7 3\r\nab"
    assert {:ok, [{:msg, %{payload: "abc"}}], ""} = Protocol.parse(rest <> "c\r\n")
  end

  test "a payload that holds CRLF is framed by its size, not by the line" do
    assert {:ok, [{:msg, %{payload: "a\r\nb"}}], ""} = Protocol.parse("MSG s 1 4\r\na\r\nb\r\n")
  end

  test "an HMSG carries its headers and its status" do
    headers = "NATS/1.0\r\nNats-Msg-Id: m1\r\nOptimal-Seq: 4\r\n\r\n"
    payload = "{}"
    size = byte_size(headers) + byte_size(payload)

    frame =
      "HMSG orders.created 3 $JS.ACK.S.C.1.4.4.0.0 #{byte_size(headers)} #{size}\r\n#{headers}#{payload}\r\n"

    assert {:ok, [{:msg, msg}], ""} = Protocol.parse(frame)
    assert msg.headers == %{"Nats-Msg-Id" => "m1", "Optimal-Seq" => "4"}
    assert msg.reply == "$JS.ACK.S.C.1.4.4.0.0"
    assert msg.status == nil
    assert msg.payload == "{}"

    status = "NATS/1.0 404 No Messages\r\n\r\n"

    assert {:ok, [{:msg, %{status: "404", description: "No Messages", payload: ""}}], ""} =
             Protocol.parse(
               "HMSG _INBOX.x 2 #{byte_size(status)} #{byte_size(status)}\r\n#{status}\r\n"
             )
  end

  test "an error frame, an unknown frame, and a MSG line that does not parse" do
    assert {:ok, [{:err, "Authorization Violation"}, {:unknown, "HELLO"}], ""} =
             Protocol.parse("-ERR 'Authorization Violation'\r\nHELLO\r\n")

    assert {:error, :bad_frame} = Protocol.parse("MSG a 1 x\r\n")
    assert {:error, :bad_frame} = Protocol.parse("HMSG a 1 9 3\r\nabc\r\n")
  end

  test "PUB without headers, HPUB with them, and a header that would break the block is refused" do
    assert IO.iodata_to_binary(Protocol.pub("a.b", nil, "hi")) == "PUB a.b 2\r\nhi\r\n"
    assert IO.iodata_to_binary(Protocol.pub("a.b", "r.1", "hi")) == "PUB a.b r.1 2\r\nhi\r\n"

    hpub = IO.iodata_to_binary(Protocol.pub("a.b", "r.1", "hi", [{"Nats-Msg-Id", "k:1"}]))
    block = "NATS/1.0\r\nNats-Msg-Id: k:1\r\n\r\n"
    assert hpub == "HPUB a.b r.1 #{byte_size(block)} #{byte_size(block) + 2}\r\n#{block}hi\r\n"

    # What the client writes, the parser reads back.
    assert {:ok, [{:msg, %{headers: %{"Nats-Msg-Id" => "k:1"}, payload: "hi"}}], ""} =
             hpub |> String.replace_prefix("HPUB a.b r.1", "HMSG a.b 1 r.1") |> Protocol.parse()

    assert_raise ArgumentError, fn -> Protocol.pub("a", nil, "x", [{"Id", "a\r\nX: y"}]) end
  end

  test "a subject token holds any id and never breaks a subject" do
    assert Protocol.token("ws-1_a") == "ws-1_a"
    assert Protocol.token("default:my.workspace *>") == "default%3Amy%2Eworkspace%20%2A%3E"
    refute Protocol.token("a.b") == Protocol.token("a%2Eb")
    assert Protocol.publishable?("optimal.ledger." <> Protocol.token("x.y z"))
    refute Protocol.publishable?("optimal..ledger")
    refute Protocol.publishable?("optimal.>")
  end
end
