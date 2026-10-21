defmodule OptimalEngine.Connectors.HTTPTest do
  @moduledoc """
  The redirect switch of `OptimalEngine.Connectors.HTTP`, against a loopback
  server that answers `/` with a redirect to `/elsewhere`. Nothing outside the
  machine is called.
  """

  use ExUnit.Case, async: false

  alias OptimalEngine.Connectors.HTTP

  setup do
    original = Application.get_env(:optimal_engine, :http_mock)
    Application.delete_env(:optimal_engine, :http_mock)

    on_exit(fn ->
      if original, do: Application.put_env(:optimal_engine, :http_mock, original)
    end)

    parent = self()

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listener)
    server = spawn_link(fn -> serve(listener, parent, port) end)

    on_exit(fn ->
      Process.unlink(server)
      Process.exit(server, :kill)
      :gen_tcp.close(listener)
    end)

    {:ok, base: "http://127.0.0.1:#{port}"}
  end

  test "follows a redirect by default", %{base: base} do
    assert {:ok, %{status: 200}} = HTTP.get_json(base <> "/")

    assert_received {:requested, "/"}
    assert_received {:requested, "/elsewhere"}
  end

  test "hands a redirect back as the answer when told not to follow it", %{base: base} do
    assert {:ok, %{status: 302, headers: headers}} =
             HTTP.get_json(base <> "/", follow_redirects: false)

    assert {_, location} = Enum.find(headers, fn {name, _} -> name == "location" end)
    assert location == base <> "/elsewhere"

    assert_received {:requested, "/"}
    refute_received {:requested, "/elsewhere"}
  end

  # ─── loopback server ──────────────────────────────────────────────────────

  defp serve(listener, parent, port) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        answer(socket, parent, port)
        :gen_tcp.close(socket)
        serve(listener, parent, port)

      {:error, _closed} ->
        :ok
    end
  end

  defp answer(socket, parent, port) do
    with {:ok, request} <- :gen_tcp.recv(socket, 0, 2_000),
         [_method, path | _rest] <- String.split(request, " ", parts: 3) do
      send(parent, {:requested, path})

      response =
        case path do
          "/" ->
            "HTTP/1.1 302 Found\r\nlocation: http://127.0.0.1:#{port}/elsewhere\r\n" <>
              "content-length: 0\r\nconnection: close\r\n\r\n"

          _other ->
            body = ~s({"ok":true})

            "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\n" <>
              "content-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n" <> body
        end

      :gen_tcp.send(socket, response)
    end
  end
end
