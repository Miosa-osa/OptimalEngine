defmodule OptimalEngine.TestSupport.ValkeyStub do
  @moduledoc """
  A local RESP2 server for tests: the slice of the Redis protocol the Valkey
  provider uses (`AUTH`, `SELECT`, `PING`, `SET`, `GET`, `DEL`), with an
  in-memory key space and a record of every command it served. It is written
  independently of `OptimalEngine.Storage.Valkey`, parsing requests as they
  arrive on the wire. No test here talks to a real Valkey.
  """

  @doc """
  Starts a listener on a free port. Options: `:password` (the stub refuses
  commands before a matching `AUTH` when set). Returns
  `{:ok, %{port: port, agent: agent, listener: listener}}`.
  """
  @spec start(keyword()) :: {:ok, map()}
  def start(opts \\ []) do
    {:ok, agent} = Agent.start_link(fn -> %{keys: %{}, commands: []} end)
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listener)
    password = Keyword.get(opts, :password)
    spawn_link(fn -> accept(listener, agent, password) end)
    {:ok, %{port: port, agent: agent, listener: listener}}
  end

  @doc "Stops the listener."
  @spec stop(map()) :: :ok
  def stop(%{listener: listener}), do: :gen_tcp.close(listener)

  @doc "Every command served, oldest first, as lists of binaries."
  @spec commands(map()) :: [[String.t()]]
  def commands(%{agent: agent}), do: agent |> Agent.get(& &1.commands) |> Enum.reverse()

  @doc "The keys the stub holds now."
  @spec keys(map()) :: map()
  def keys(%{agent: agent}), do: Agent.get(agent, & &1.keys)

  defp accept(listener, agent, password) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        spawn_link(fn -> serve(socket, agent, password, is_nil(password), "") end)
        accept(listener, agent, password)

      {:error, _closed} ->
        :ok
    end
  end

  defp serve(socket, agent, password, authed?, buffer) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, data} ->
        {commands, rest} = parse_all(buffer <> data, [])

        authed? =
          Enum.reduce(commands, authed?, fn command, authed? ->
            Agent.update(agent, &%{&1 | commands: [command | &1.commands]})
            {reply, authed?} = respond(command, agent, password, authed?)
            :ok = :gen_tcp.send(socket, reply)
            authed?
          end)

        serve(socket, agent, password, authed?, rest)

      {:error, _closed} ->
        :gen_tcp.close(socket)
    end
  end

  defp respond(["AUTH" | rest], _agent, password, _authed?) do
    if List.last(rest) == password,
      do: {"+OK\r\n", true},
      else: {"-WRONGPASS invalid username-password pair\r\n", false}
  end

  defp respond(_command, _agent, _password, false),
    do: {"-NOAUTH Authentication required.\r\n", false}

  defp respond(["PING"], _agent, _password, authed?), do: {"+PONG\r\n", authed?}
  defp respond(["SELECT", _db], _agent, _password, authed?), do: {"+OK\r\n", authed?}

  defp respond(["SET", key, value | _options], agent, _password, authed?) do
    Agent.update(agent, &put_in(&1, [:keys, key], value))
    {"+OK\r\n", authed?}
  end

  defp respond(["GET", key], agent, _password, authed?) do
    case Agent.get(agent, &Map.get(&1.keys, key)) do
      nil -> {"$-1\r\n", authed?}
      value -> {"$#{byte_size(value)}\r\n#{value}\r\n", authed?}
    end
  end

  defp respond(["DEL" | keys], agent, _password, authed?) do
    deleted =
      Agent.get_and_update(agent, fn state ->
        present = Enum.count(keys, &Map.has_key?(state.keys, &1))
        {present, %{state | keys: Map.drop(state.keys, keys)}}
      end)

    {":#{deleted}\r\n", authed?}
  end

  defp respond([command | _], _agent, _password, authed?),
    do: {"-ERR unknown command '#{command}'\r\n", authed?}

  # RESP arrays of bulk strings, as a client sends them.
  defp parse_all(buffer, acc) do
    case parse_one(buffer) do
      {:ok, command, rest} -> parse_all(rest, [command | acc])
      :incomplete -> {Enum.reverse(acc), buffer}
    end
  end

  defp parse_one("*" <> rest) do
    with [count, tail] <- String.split(rest, "\r\n", parts: 2),
         {n, ""} <- Integer.parse(count) do
      parse_bulks(n, tail, [])
    else
      _ -> :incomplete
    end
  end

  defp parse_one(_other), do: :incomplete

  defp parse_bulks(0, rest, acc), do: {:ok, Enum.reverse(acc), rest}

  defp parse_bulks(n, "$" <> rest, acc) do
    with [length, tail] <- String.split(rest, "\r\n", parts: 2),
         {size, ""} <- Integer.parse(length),
         true <- byte_size(tail) >= size + 2 do
      <<value::binary-size(size), "\r\n", remaining::binary>> = tail
      parse_bulks(n - 1, remaining, [value | acc])
    else
      _ -> :incomplete
    end
  end

  defp parse_bulks(_n, _rest, _acc), do: :incomplete
end
