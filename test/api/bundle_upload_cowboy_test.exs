defmodule OptimalEngine.API.BundleUploadCowboyTest do
  @moduledoc """
  Raw bundle uploads through a real Cowboy listener with short limits (idle
  timeout 2 s, inactivity timeout 3 s). A client that goes silent mid-upload
  is closed by the server, and an upload its client cuts off leaves no file.
  The long-request watcher ticks every 500 ms here, so an upload read under
  it would be kept open and the silent client would never be closed.
  """

  use ExUnit.Case, async: false

  alias OptimalEngine.API.Router
  alias OptimalEngine.Portability.WorkspaceBundle

  setup do
    previous = Application.fetch_env(:optimal_engine, :bundle_long_request_tick_ms)
    Application.put_env(:optimal_engine, :bundle_long_request_tick_ms, 500)
    ref = :"bundle_upload_cowboy_#{System.unique_integer([:positive])}"

    {:ok, _pid} =
      Plug.Cowboy.http(Router, [],
        ip: {127, 0, 0, 1},
        port: 0,
        ref: ref,
        protocol_options: [idle_timeout: 2_000, inactivity_timeout: 3_000]
      )

    on_exit(fn ->
      Plug.Cowboy.shutdown(ref)

      case previous do
        {:ok, tick} -> Application.put_env(:optimal_engine, :bundle_long_request_tick_ms, tick)
        :error -> Application.delete_env(:optimal_engine, :bundle_long_request_tick_ms)
      end
    end)

    %{port: :ranch.get_port(ref), before: uploads()}
  end

  defp uploads,
    do:
      Path.wildcard(Path.join(WorkspaceBundle.bundle_dir("default"), ".upload-*"), match_dot: true)

  # Starts a raw upload that declares `declared` bytes and sends `sent` of them.
  defp start_upload(port, declared, sent) do
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])

    head =
      "POST /api/bundles/import HTTP/1.1\r\nhost: 127.0.0.1\r\n" <>
        "content-type: application/gzip\r\ncontent-length: #{declared}\r\n\r\n"

    :ok = :gen_tcp.send(socket, head <> :binary.copy("x", sent))
    socket
  end

  # Reads until the server closes the connection; :open if it is still open.
  defp read_until_closed(socket, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      :open
    else
      case :gen_tcp.recv(socket, 0, remaining) do
        {:ok, _data} -> read_until_closed(socket, deadline)
        {:error, :closed} -> :closed
        {:error, :timeout} -> :open
      end
    end
  end

  defp eventually(fun, deadline \\ System.monotonic_time(:millisecond) + 5_000) do
    cond do
      fun.() ->
        true

      System.monotonic_time(:millisecond) > deadline ->
        false

      true ->
        Process.sleep(50)
        eventually(fun, deadline)
    end
  end

  test "a client that goes silent mid-upload is closed, and its upload is removed", ctx do
    socket = start_upload(ctx.port, 1_000_000, 1_000)
    assert eventually(fn -> uploads() -- ctx.before != [] end)

    started = System.monotonic_time(:millisecond)
    assert read_until_closed(socket, started + 10_000) == :closed
    assert System.monotonic_time(:millisecond) - started < 8_000

    assert eventually(fn -> uploads() -- ctx.before == [] end)
  end

  test "an upload its client cuts off leaves no file", ctx do
    socket = start_upload(ctx.port, 1_000_000, 100_000)
    assert eventually(fn -> uploads() -- ctx.before != [] end)

    :ok = :gen_tcp.close(socket)
    assert eventually(fn -> uploads() -- ctx.before == [] end)
  end
end
