defmodule OptimalEngine.TestSupport.OpenBaoStub do
  @moduledoc """
  A local OpenBao HTTP endpoint for tests: `sys/health`, `auth/token/lookup-self`
  and a KV version 2 mount (`secret` unless started otherwise), with an
  in-memory secret table and a record of every request. Options: `:token` (the
  only token accepted), `:sealed` (health reports sealed and every other call
  is 503), `kv: 1` (the mount answers as KV version 1: a write is 204 and a
  read has no metadata), `delete: :forbidden` (deleting metadata is 403),
  `transit_keys:` (the names of the keys a `transit` mount holds; a data key
  is made under one and decrypted only by it) and `transit_mount:` (`transit`).
  `read: :tampered` (every KV read answers with one field changed, as a
  copy that did not survive would), `mount: nil` (no KV mount until `sys/mounts` enables one; `mount_enable:
  :forbidden` refuses that), `put_secret/3` seeds a secret, and `seal/1` and `unseal/1` change the seal of
  a running stub. No test here talks to a real OpenBao.
  """

  @behaviour Plug

  import Plug.Conn

  @doc "Starts a listener on a free port. Returns `{:ok, %{endpoint:, ref:, agent:, token:}}`."
  @spec start(keyword()) :: {:ok, map()}
  def start(opts \\ []) do
    token = Keyword.get(opts, :token, "root-#{System.unique_integer([:positive])}")

    state = %{
      secrets: %{},
      requests: [],
      token: token,
      sealed: Keyword.get(opts, :sealed, false),
      mount: Keyword.get(opts, :mount, "secret"),
      kv: Keyword.get(opts, :kv, 2),
      delete: Keyword.get(opts, :delete, :ok),
      read: Keyword.get(opts, :read, :ok),
      mount_enable: Keyword.get(opts, :mount_enable, :ok),
      transit_mount: Keyword.get(opts, :transit_mount, "transit"),
      transit_keys: Keyword.get(opts, :transit_keys, []),
      data_keys: %{}
    }

    {:ok, agent} = Agent.start_link(fn -> state end)
    ref = :"#{__MODULE__}.HTTP#{System.unique_integer([:positive])}"
    {:ok, _pid} = Plug.Cowboy.http(__MODULE__, [agent: agent], port: 0, ref: ref)
    port = :ranch.get_port(ref)
    {:ok, %{endpoint: "http://127.0.0.1:#{port}", ref: ref, agent: agent, token: token}}
  end

  @doc "Stops the listener."
  @spec stop(map()) :: :ok | {:error, :not_found}
  def stop(%{ref: ref}), do: Plug.Cowboy.shutdown(ref)

  @doc "Every request served, oldest first, as `{method, path}`."
  @spec requests(map()) :: [{String.t(), String.t()}]
  def requests(%{agent: agent}), do: agent |> Agent.get(& &1.requests) |> Enum.reverse()

  @doc "The secrets the stub holds now, by path."
  @spec secrets(map()) :: map()
  def secrets(%{agent: agent}), do: Agent.get(agent, & &1.secrets)

  @doc "Stores `data` (a map) at `path` under the KV mount, as a write through the API would."
  @spec put_secret(map(), String.t(), map()) :: :ok
  def put_secret(%{agent: agent}, path, data),
    do: Agent.update(agent, &put_in(&1, [:secrets, path], data))

  @doc "Seals the running stub: health says sealed and every other call is 503."
  @spec seal(map()) :: :ok
  def seal(%{agent: agent}), do: Agent.update(agent, &%{&1 | sealed: true})

  @doc "Unseals the running stub."
  @spec unseal(map()) :: :ok
  def unseal(%{agent: agent}), do: Agent.update(agent, &%{&1 | sealed: false})

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, opts) do
    agent = Keyword.fetch!(opts, :agent)
    state = Agent.get(agent, & &1)
    Agent.update(agent, &%{&1 | requests: [{conn.method, conn.request_path} | &1.requests]})
    {:ok, raw, conn} = read_body(conn)
    body = if raw == "", do: %{}, else: Jason.decode!(raw)
    mount = state.mount
    provided = token(conn)

    case {conn.method, Enum.map(conn.path_info, &URI.decode/1)} do
      {"GET", ["v1", "sys", "health"]} ->
        json(conn, if(state.sealed, do: 503, else: 200), %{
          initialized: true,
          sealed: state.sealed,
          standby: false
        })

      _ when state.sealed ->
        json(conn, 503, %{errors: ["Vault is sealed"]})

      _ when state.token != provided ->
        json(conn, 403, %{errors: ["permission denied"]})

      {"GET", ["v1", "auth", "token", "lookup-self"]} ->
        json(conn, 200, %{data: %{policies: ["root"]}})

      # `mount: nil` starts the stub with no KV mount, as a freshly initialised
      # server has; enabling one makes it the mount every KV route answers on.
      {"POST", ["v1", "sys", "mounts", name]} when state.mount_enable == :ok ->
        Agent.update(agent, &%{&1 | mount: name})
        send_resp(conn, 204, "")

      {"POST", ["v1", "sys", "mounts", _name]} ->
        json(conn, 403, %{errors: ["permission denied"]})

      {"POST", ["v1", ^mount, "data" | path]} when state.kv == 1 ->
        Agent.update(agent, &put_in(&1, [:secrets, Enum.join(path, "/")], body["data"]))
        send_resp(conn, 204, "")

      {"POST", ["v1", ^mount, "data" | path]} ->
        Agent.update(agent, &put_in(&1, [:secrets, Enum.join(path, "/")], body["data"]))
        json(conn, 200, %{data: %{version: 1}})

      {"GET", ["v1", ^mount, "data" | path]} ->
        case Map.get(state.secrets, Enum.join(path, "/")) do
          nil ->
            json(conn, 404, %{errors: []})

          data ->
            data = if state.read == :tampered, do: Map.put(data, "tampered", "1"), else: data
            json(conn, 200, %{data: %{data: data, metadata: %{version: 1}}})
        end

      {"POST", ["v1", transit, "datakey", "plaintext", name]}
      when transit == state.transit_mount ->
        if name in state.transit_keys do
          plaintext = :crypto.strong_rand_bytes(div(Map.get(body, "bits", 256), 8))
          ciphertext = "vault:v1:" <> Base.encode64(:crypto.strong_rand_bytes(48))
          Agent.update(agent, &put_in(&1, [:data_keys, ciphertext], {name, plaintext}))
          json(conn, 200, %{data: %{plaintext: Base.encode64(plaintext), ciphertext: ciphertext}})
        else
          json(conn, 400, %{errors: ["encryption key not found"]})
        end

      {"POST", ["v1", transit, "decrypt", name]} when transit == state.transit_mount ->
        case Map.get(state.data_keys, body["ciphertext"]) do
          {^name, plaintext} -> json(conn, 200, %{data: %{plaintext: Base.encode64(plaintext)}})
          _other -> json(conn, 400, %{errors: ["cipher: message authentication failed"]})
        end

      {"DELETE", ["v1", ^mount, "metadata" | _path]} when state.delete == :forbidden ->
        json(conn, 403, %{errors: ["permission denied"]})

      {"DELETE", ["v1", ^mount, "metadata" | path]} ->
        Agent.update(agent, &%{&1 | secrets: Map.delete(&1.secrets, Enum.join(path, "/"))})
        send_resp(conn, 204, "")

      _ ->
        json(conn, 404, %{errors: ["no handler for route"]})
    end
  end

  defp token(conn), do: conn |> get_req_header("x-vault-token") |> List.first()

  defp json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
