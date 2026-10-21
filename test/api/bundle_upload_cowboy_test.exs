defmodule OptimalEngine.API.BundleUploadCowboyTest do
  @moduledoc """
  Raw bundle uploads through a real Cowboy listener with short limits (idle
  timeout 2 s, inactivity timeout 3 s). A client that goes silent mid-upload
  is closed by the server, an upload its client cuts off leaves no file, and
  a client that sends a byte now and then is stopped at the upload deadline.
  The long-request watcher ticks every 500 ms here, so an upload read under
  it would be kept open and the silent client would never be closed.
  """

  use ExUnit.Case, async: false

  alias OptimalEngine.API.Router
  alias OptimalEngine.Portability.WorkspaceBundle

  setup do
    previous = Application.fetch_env(:optimal_engine, :bundle_long_request_tick_ms)
    previous_deadline = Application.fetch_env(:optimal_engine, :bundle_upload_deadline_ms)
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

      restore(:bundle_long_request_tick_ms, previous)
      restore(:bundle_upload_deadline_ms, previous_deadline)
    end)

    %{port: :ranch.get_port(ref), before: uploads()}
  end

  defp restore(key, {:ok, value}), do: Application.put_env(:optimal_engine, key, value)
  defp restore(key, :error), do: Application.delete_env(:optimal_engine, key)

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

  # What the server sends until `expected` arrives, the connection closes, or
  # the deadline passes.
  defp read_response(socket, expected, deadline, acc \\ "") do
    remaining = deadline - System.monotonic_time(:millisecond)

    cond do
      acc =~ expected ->
        acc

      remaining <= 0 ->
        acc

      true ->
        case :gen_tcp.recv(socket, 0, remaining) do
          {:ok, data} -> read_response(socket, expected, deadline, acc <> data)
          {:error, _closed_or_timeout} -> acc
        end
    end
  end

  # Sends one byte every 250 ms, well inside the idle and inactivity
  # timeouts, so only the upload deadline can stop the client.
  defp trickle(socket, 0), do: socket

  defp trickle(socket, left) do
    Process.sleep(250)

    case :gen_tcp.send(socket, "x") do
      :ok -> trickle(socket, left - 1)
      {:error, _} -> socket
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

  test "a client that sends a byte now and then is stopped at the upload deadline", ctx do
    # A 1.5 s deadline against a client that would take 40 bytes 10 s.
    Application.put_env(:optimal_engine, :bundle_upload_deadline_ms, 1_500)
    socket = start_upload(ctx.port, 1_000_000, 1)
    sender = spawn(fn -> trickle(socket, 40) end)
    started = System.monotonic_time(:millisecond)

    response = read_response(socket, "upload_timeout", started + 9_000)
    elapsed = System.monotonic_time(:millisecond) - started
    Process.exit(sender, :kill)

    assert response =~ "HTTP/1.1 408"
    assert response =~ "upload_timeout"
    assert elapsed < 6_000, "the upload was stopped after #{elapsed} ms"
    assert eventually(fn -> uploads() -- ctx.before == [] end)
  end
end
