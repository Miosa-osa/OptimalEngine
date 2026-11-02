defmodule OptimalEngine.TestSupport.OpenBaoStub do
  @moduledoc """
  A local OpenBao HTTP endpoint for tests: `sys/health`, `auth/token/lookup-self`
  and a KV version 2 mount (`secret` unless started otherwise), with an
  in-memory secret table and a record of every request. Options: `:token` (the
  only token accepted), `:sealed` (health reports sealed and every other call
  is 503). No test here talks to a real OpenBao.
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
      mount: Keyword.get(opts, :mount, "secret")
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

    case {conn.method, conn.path_info} do
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

      {"POST", ["v1", ^mount, "data" | path]} ->
        Agent.update(agent, &put_in(&1, [:secrets, Enum.join(path, "/")], body["data"]))
        json(conn, 200, %{data: %{version: 1}})

      {"GET", ["v1", ^mount, "data" | path]} ->
        case Map.get(state.secrets, Enum.join(path, "/")) do
          nil -> json(conn, 404, %{errors: []})
          data -> json(conn, 200, %{data: %{data: data, metadata: %{version: 1}}})
        end

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
