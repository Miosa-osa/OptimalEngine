defmodule OptimalEngine.TestSupport.ValkeyStub do
  @moduledoc """
  A local RESP2 server for tests: the slice of the Redis protocol the Valkey
  provider uses (`AUTH`, `SELECT`, `PING`, `SET` with `PX`/`NX`, `GET`, `DEL`,
  `EXISTS`, `INCR`, `PEXPIRE`, `HSET`, `HMGET`, `EVAL`, `EVALSHA`), with an in-memory key
  space that honours expiry and a record of every command it served. It is
  written independently of `OptimalEngine.Storage.Valkey`, parsing requests as
  they arrive on the wire. No test here talks to a real Valkey (the tagged
  integration test does).

  There is no Lua here. A script is recognised by its first line,
  `-- optimal:<name>`, and run as the Elixir below, which follows the script's
  text; `EVALSHA` answers `NOSCRIPT` until the script was sent once by `EVAL`,
  as a fresh server does. The integration test runs the real scripts.

  `set_mode/2` makes the server misbehave: `:down` closes every connection and
  refuses new ones, `:hang` reads commands and never answers; `:normal` again
  serves.
  """

  @doc """
  Starts a listener on a free port. Options: `:password` (the stub refuses
  commands before a matching `AUTH` when set). Returns
  `{:ok, %{port: port, agent: agent, listener: listener}}`.
  """
  @spec start(keyword()) :: {:ok, map()}
  def start(opts \\ []) do
    {:ok, agent} =
      Agent.start_link(fn ->
        %{
          keys: %{},
          expires: %{},
          commands: [],
          scripts: %{},
          mode: :normal,
          handlers: [],
          fail: nil
        }
      end)

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

  @doc "The keys the stub holds now (expired ones excluded)."
  @spec keys(map()) :: map()
  def keys(%{agent: agent}) do
    Agent.get(agent, fn state ->
      now = now()
      Map.reject(state.keys, fn {key, _} -> expired?(state, key, now) end)
    end)
  end

  @doc "The remaining TTL in milliseconds of a key, or nil."
  @spec pttl(map(), String.t()) :: integer() | nil
  def pttl(%{agent: agent}, key) do
    Agent.get(agent, fn state ->
      case Map.get(state.expires, key) do
        nil -> nil
        at -> at - now()
      end
    end)
  end

  @doc "Removes a key's TTL, as PERSIST does (a key written before it had one)."
  @spec persist(map(), String.t()) :: :ok
  def persist(%{agent: agent}, key),
    do: Agent.update(agent, &%{&1 | expires: Map.delete(&1.expires, key)})

  @doc "Replaces the value of a key as stored (tests tampering with Valkey)."
  @spec put_raw(map(), String.t(), term()) :: :ok
  def put_raw(%{agent: agent}, key, value),
    do: Agent.update(agent, &put_in(&1, [:keys, key], value))

  @doc "`:normal`, `:down` (close all, refuse new) or `:hang` (never answer)."
  @spec set_mode(map(), :normal | :down | :hang) :: :ok
  def set_mode(%{agent: agent}, mode) do
    handlers = Agent.get_and_update(agent, &{&1.handlers, %{&1 | mode: mode}})
    if mode == :down, do: Enum.each(handlers, &Process.exit(&1, :kill))
    :ok
  end

  @doc """
  Makes the server answer an error to every command `fun` returns a message
  for (`fun.(command)` gives `nil` to serve it), as an ACL that refuses a
  key (`NOPERM`) or a failing script does; `nil` serves everything again.
  """
  @spec fail_when(map(), (list() -> String.t() | nil) | nil) :: :ok
  def fail_when(%{agent: agent}, fun), do: Agent.update(agent, &%{&1 | fail: fun})

  @doc "Closes every open connection (as a server dropping idle clients does)."
  @spec disconnect_all(map()) :: :ok
  def disconnect_all(%{agent: agent}) do
    agent |> Agent.get(& &1.handlers) |> Enum.each(&Process.exit(&1, :kill))
  end

  defp accept(listener, agent, password) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        if Agent.get(agent, & &1.mode) == :down do
          :gen_tcp.close(socket)
        else
          pid =
            spawn(fn ->
              receive do
                :go -> serve(socket, agent, password, is_nil(password), "")
              end
            end)

          :ok = :gen_tcp.controlling_process(socket, pid)
          Agent.update(agent, &%{&1 | handlers: [pid | &1.handlers]})
          send(pid, :go)
        end

        accept(listener, agent, password)

      {:error, _closed} ->
        :ok
    end
  end

  defp serve(socket, agent, password, authed?, buffer) do
    case :gen_tcp.recv(socket, 0) do
      {:ok, data} ->
        {commands, rest} = parse_all(buffer <> data, [])

        authed? =
          Enum.reduce(commands, authed?, fn command, authed? ->
            Agent.update(agent, &%{&1 | commands: [command | &1.commands]})

            if Agent.get(agent, & &1.mode) == :hang do
              authed?
            else
              {reply, authed?} = respond(command, agent, password, authed?)
              :ok = :gen_tcp.send(socket, reply)
              authed?
            end
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

  defp respond(command, agent, _password, authed?) do
    reply =
      Agent.get_and_update(agent, fn state ->
        case state.fail && state.fail.(command) do
          message when is_binary(message) -> {{:error, message}, state}
          _serve -> run(command, purge(state))
        end
      end)

    {encode(reply), authed?}
  end

  # ---------------------------------------------------------------------------
  # Commands, on the state; each returns {reply, state}.
  # ---------------------------------------------------------------------------

  defp run(["PING"], state), do: {{:simple, "PONG"}, state}
  defp run(["SELECT", _db], state), do: {{:simple, "OK"}, state}

  defp run(["SET", key, value | options], state) do
    upper = Enum.map(options, &String.upcase/1)

    if "NX" in upper and Map.has_key?(state.keys, key) do
      {nil, state}
    else
      state = put_key(state, key, value)

      state =
        case Enum.find_index(upper, &(&1 == "PX")) do
          nil -> state
          i -> expire(state, key, String.to_integer(Enum.at(options, i + 1)))
        end

      {{:simple, "OK"}, state}
    end
  end

  defp run(["GET", key], state) do
    case Map.get(state.keys, key) do
      value when is_binary(value) or is_nil(value) -> {value, state}
      _other -> {{:error, "WRONGTYPE"}, state}
    end
  end

  defp run(["EXISTS" | keys], state),
    do: {Enum.count(keys, &Map.has_key?(state.keys, &1)), state}

  defp run(["DEL" | keys], state) do
    present = Enum.count(keys, &Map.has_key?(state.keys, &1))
    {present, %{state | keys: Map.drop(state.keys, keys), expires: Map.drop(state.expires, keys)}}
  end

  defp run(["INCR", key], state) do
    n = String.to_integer(Map.get(state.keys, key, "0")) + 1
    {n, %{state | keys: Map.put(state.keys, key, Integer.to_string(n))}}
  end

  defp run(["PEXPIRE", key, ms], state) do
    if Map.has_key?(state.keys, key),
      do: {1, expire(state, key, String.to_integer(ms))},
      else: {0, state}
  end

  defp run(["PTTL", key], state) do
    cond do
      not Map.has_key?(state.keys, key) -> {-2, state}
      Map.has_key?(state.expires, key) -> {Map.fetch!(state.expires, key) - now(), state}
      true -> {-1, state}
    end
  end

  # One pass over every key: the cursor always comes back "0".
  defp run(["SCAN", _cursor | options], state) do
    upper = Enum.map(options, &String.upcase/1)

    pattern =
      case Enum.find_index(upper, &(&1 == "MATCH")) do
        nil -> ~r/.*/s
        i -> glob(Enum.at(options, i + 1))
      end

    {["0", state.keys |> Map.keys() |> Enum.filter(&Regex.match?(pattern, &1)) |> Enum.sort()],
     state}
  end

  defp run(["HSET", key | pairs], state) do
    hash = Map.get(state.keys, key, %{})
    fields = pairs |> Enum.chunk_every(2) |> Map.new(fn [f, v] -> {f, v} end)
    {map_size(fields), %{state | keys: Map.put(state.keys, key, Map.merge(hash, fields))}}
  end

  defp run(["HMGET", key | fields], state) do
    hash = Map.get(state.keys, key, %{})
    {Enum.map(fields, &Map.get(hash, &1)), state}
  end

  defp run(["EVAL", source, numkeys | rest], state) do
    sha = Base.encode16(:crypto.hash(:sha, source), case: :lower)

    case Regex.run(~r/\A-- optimal:(\w+)/, source) do
      [_, name] ->
        state = put_in(state, [:scripts, sha], name)
        script(name, split_args(numkeys, rest), state)

      _ ->
        {{:error, "ERR stub runs only the Engine's scripts"}, state}
    end
  end

  defp run(["EVALSHA", sha, numkeys | rest], state) do
    case Map.get(state.scripts, sha) do
      nil -> {{:error, "NOSCRIPT No matching script. Please use EVAL."}, state}
      name -> script(name, split_args(numkeys, rest), state)
    end
  end

  defp run([command | _], state),
    do: {{:error, "ERR unknown command '#{command}'"}, state}

  defp split_args(numkeys, rest), do: Enum.split(rest, String.to_integer(numkeys))

  defp glob(pattern) do
    pattern
    |> Regex.escape()
    |> String.replace("\\*", ".*")
    |> String.replace("\\?", ".")
    |> then(&Regex.compile!("\\A" <> &1 <> "\\z", "s"))
  end

  # ---------------------------------------------------------------------------
  # The Engine's scripts (OptimalEngine.Storage.Shared), line for line.
  # ---------------------------------------------------------------------------

  # As the script: INCR the generation and give it its TTL again.
  defp script("clear", {[gen_key], [ttl]}, state) do
    {n, state} = run(["INCR", gen_key], state)
    {n, expire(state, gen_key, String.to_integer(ttl))}
  end

  # As @resolve: a generation in use whose TTL is missing or past half is
  # given its full TTL again.
  defp script(name, {[gen_key], [gen_ttl, prefix, key | argv]}, state) do
    {gen, state} =
      case Map.get(state.keys, gen_key) do
        nil ->
          {"0", state}

        g ->
          ttl = String.to_integer(gen_ttl)

          case run(["PTTL", gen_key], state) do
            {left, state} when left < div(ttl, 2) -> {g, expire(state, gen_key, ttl)}
            {_left, state} -> {g, state}
          end
      end

    run_script(name, prefix <> gen <> ":" <> key, argv, state)
  end

  defp run_script("get", k, [], state), do: run(["GET", k], state)

  defp run_script("put", k, [value, ttl], state) do
    {_, state} = run(["SET", k, value, "PX", ttl], state)
    {1, state}
  end

  defp run_script("del", k, [], state), do: run(["DEL", k], state)

  defp run_script("incr", k, [ttl], state) do
    {n, state} = run(["INCR", k], state)
    state = if n == 1, do: elem(run(["PEXPIRE", k, ttl], state), 1), else: state
    {n, state}
  end

  defp run_script("lock", k, [token, ttl], state) do
    case run(["SET", k, token, "NX", "PX", ttl], state) do
      {nil, state} -> {0, state}
      {_ok, state} -> {1, state}
    end
  end

  defp run_script("unlock", k, [token], state) do
    if Map.get(state.keys, k) == token, do: run(["DEL", k], state), else: {0, state}
  end

  defp run_script("bucket", k, [cap, rate, deny, ttl | rest], state) do
    cap = parse_number(cap)
    rate = parse_number(rate)
    now = System.os_time(:millisecond)

    spent =
      case rest do
        [text] when text != "" -> parse_number(text)
        _ -> nil
      end

    {current, elapsed, exists?} =
      case Map.get(state.keys, k) do
        %{"tokens" => tokens, "at" => at} ->
          elapsed = max(0, now - String.to_integer(at))
          {min(cap, parse_number(tokens) + elapsed * rate), elapsed, true}

        _ ->
          {cap, 0, false}
      end

    # As the script: what this node spent during an outage is taken off the
    # server's bucket, never set as its count.
    {current, lowered?} =
      if spent != nil and spent > 0,
        do: {max(0.0, current - spent), true},
        else: {current, false}

    cond do
      current >= 1 ->
        {[1, format(current - 1)], save_bucket(state, k, current - 1, now, ttl)}

      # As the script: a kept denial writes nothing, unless it lowered the bucket.
      deny == "keep" and exists? and not lowered? ->
        {[0, format(current), elapsed], state}

      true ->
        {[0, format(current), elapsed], save_bucket(state, k, current, now, ttl)}
    end
  end

  defp save_bucket(state, k, tokens, at, ttl) do
    {_, state} = run(["HSET", k, "tokens", format(tokens), "at", Integer.to_string(at)], state)
    expire(state, k, String.to_integer(ttl))
  end

  defp parse_number(text) do
    {value, ""} = Float.parse(text)
    value
  end

  defp format(number), do: :erlang.float_to_binary(number * 1.0, [:short])

  # ---------------------------------------------------------------------------

  defp put_key(state, key, value),
    do: %{state | keys: Map.put(state.keys, key, value), expires: Map.delete(state.expires, key)}

  defp expire(state, key, ms), do: put_in(state, [:expires, key], now() + ms)

  defp purge(state) do
    now = now()
    gone = for {key, at} <- state.expires, at <= now, do: key
    %{state | keys: Map.drop(state.keys, gone), expires: Map.drop(state.expires, gone)}
  end

  defp expired?(state, key, now) do
    case Map.get(state.expires, key) do
      nil -> false
      at -> at <= now
    end
  end

  defp now, do: System.monotonic_time(:millisecond)

  defp encode({:simple, text}), do: "+#{text}\r\n"
  defp encode({:error, text}), do: "-#{text}\r\n"
  defp encode(nil), do: "$-1\r\n"
  defp encode(int) when is_integer(int), do: ":#{int}\r\n"
  defp encode(bin) when is_binary(bin), do: "$#{byte_size(bin)}\r\n#{bin}\r\n"

  defp encode(list) when is_list(list),
    do: ["*#{length(list)}\r\n" | Enum.map(list, &encode/1)] |> IO.iodata_to_binary()

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
