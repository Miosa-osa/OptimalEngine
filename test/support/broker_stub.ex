defmodule OptimalEngine.Test.BrokerStub do
  @moduledoc """
  A credential broker and a provider API that checks the bearer token of every
  call, behind the Engine's HTTP mock seam. No real broker or provider is
  called.

      stub =
        BrokerStub.install(:gmail,
          issue: [{"example-token-a", 3_600}, {"example-token-b", 3_600}],
          expire: %{"example-token-a" => 2}
        )

  `issue` is the broker's answers, one per broker call, in order:

    * `{token, expires_in_seconds}` - a `200` answering
      `{"credentials": {"access_token": token, "expires_at": ...}}`, the
      broker contract, with `expires_at` that far ahead
    * `{:body, map}` - a `200` answering that body as it is
    * `{:status, code}` - that status with an error body
    * `:unreachable` - a network error

  The broker answers at `broker_url:` (default `broker_url/0`).

  `override:` is a function of `%{url:, bearer:, nth:}` (`nth` counts the calls
  already made with that bearer, plus one) that answers a provider call itself
  with `{status, body}` or `{status, body, headers}`, or `nil` to leave it to
  the rules above. An overridden call does not count against `expire`.

  A broker call beyond the list raises, so a test that expects a bounded
  number of fetches fails loudly when the Engine asks again.

  The API refuses a token named in `reject` on every call, and a token named
  in `expire` (`token => calls`) after it has served that many calls; a
  refusal is `reject_with` (`{401, %{}}` by default). Every other API call is
  answered by the kind's recorded fixture (`ConnectorFixtureStub`), or by
  `api:`, a function of `(url, opts)` that returns `{status, body}`.

  Tests that use it must be `async: false`: the mock seam is application-wide.
  """

  alias OptimalEngine.Test.ConnectorFixtureStub

  @broker_url "https://connect.example.com/api/credentials"

  @type handle :: %{agent: pid(), fixture: ConnectorFixtureStub.handle() | nil}

  @doc "The broker URL the stub answers."
  @spec broker_url() :: String.t()
  def broker_url, do: @broker_url

  @doc "Installs the stub as the HTTP mock and returns its handle."
  @spec install(atom() | nil, keyword()) :: handle()
  def install(kind, opts \\ []) do
    fixture = if kind, do: ConnectorFixtureStub.install(kind)
    recording = if fixture, do: Application.get_env(:optimal_engine, :http_mock)

    {:ok, agent} =
      Agent.start(fn ->
        %{
          issue: Keyword.get(opts, :issue, []),
          reject: Keyword.get(opts, :reject, []),
          expire: Keyword.get(opts, :expire, %{}),
          served: %{},
          broker_calls: [],
          api_calls: []
        }
      end)

    api = Keyword.get(opts, :api)
    override = Keyword.get(opts, :override)
    broker_url = Keyword.get(opts, :broker_url, @broker_url)
    reject_with = Keyword.get(opts, :reject_with, {401, %{}})

    Application.put_env(:optimal_engine, :http_mock, fn url, request_opts ->
      if String.starts_with?(url, broker_url),
        do: broker(agent, url, request_opts),
        else: provider(agent, url, request_opts, api || recording, reject_with, override)
    end)

    %{agent: agent, fixture: fixture}
  end

  @doc "Removes the mock and stops the stub."
  @spec uninstall(handle()) :: :ok
  def uninstall(%{agent: agent, fixture: fixture}) do
    if fixture, do: ConnectorFixtureStub.uninstall(fixture)
    Application.delete_env(:optimal_engine, :http_mock)
    if Process.alive?(agent), do: Agent.stop(agent)
    :ok
  end

  @doc "The broker calls, oldest first: `[%{url:, opts:, body:, headers:, timeout:, follow_redirects:}]`."
  @spec broker_calls(handle()) :: [map()]
  def broker_calls(%{agent: agent}),
    do: agent |> Agent.get(& &1.broker_calls) |> Enum.reverse()

  @doc "The provider calls, oldest first: `[%{url:, method:, bearer:, status:}]`."
  @spec api_calls(handle()) :: [map()]
  def api_calls(%{agent: agent}), do: agent |> Agent.get(& &1.api_calls) |> Enum.reverse()

  @doc "The bearer token of each provider call, oldest first (`nil` for none)."
  @spec bearers(handle()) :: [String.t() | nil]
  def bearers(handle), do: handle |> api_calls() |> Enum.map(& &1.bearer)

  # ─── broker ──────────────────────────────────────────────────────────────

  defp broker(agent, url, opts) do
    call = %{
      url: url,
      opts: opts,
      body: Keyword.get(opts, :body),
      headers: Keyword.get(opts, :headers, []),
      timeout: Keyword.get(opts, :timeout),
      follow_redirects: Keyword.get(opts, :follow_redirects, true)
    }

    answer =
      Agent.get_and_update(agent, fn state ->
        case state.issue do
          [next | rest] ->
            {next, %{state | issue: rest, broker_calls: [call | state.broker_calls]}}

          [] ->
            {:exhausted, %{state | broker_calls: [call | state.broker_calls]}}
        end
      end)

    case answer do
      {token, expires_in} when is_binary(token) ->
        expires_at = DateTime.utc_now() |> DateTime.add(expires_in, :second)

        httpc(200, %{
          "credentials" => %{
            "access_token" => token,
            "expires_at" => DateTime.to_iso8601(expires_at)
          }
        })

      {:body, body} when is_map(body) ->
        httpc(200, body)

      {:status, status} ->
        httpc(status, %{"error" => "refused"})

      :unreachable ->
        {:error, :econnrefused}

      :exhausted ->
        raise "the broker was asked more often than the test allows"
    end
  end

  # ─── provider ────────────────────────────────────────────────────────────

  defp provider(agent, url, opts, answer, reject_with, override) do
    bearer = bearer(Keyword.get(opts, :headers, []))
    overridden = overridden(agent, override, url, bearer)
    refused? = overridden == nil and refuse?(agent, bearer)

    response =
      cond do
        overridden != nil ->
          answer_call(fn _url, _opts -> overridden end, url, opts)

        refused? ->
          {status, body} = reject_with
          httpc(status, body)

        is_function(answer, 2) ->
          answer_call(answer, url, opts)

        true ->
          raise "no provider answer for #{url}"
      end

    status =
      case response do
        {:ok, {{_vsn, status, _reason}, _headers, _body}} -> status
        _error -> nil
      end

    call = %{
      url: url,
      method: opts |> Keyword.get(:method, :get) |> to_string() |> String.upcase(),
      bearer: bearer,
      status: status
    }

    Agent.update(agent, &%{&1 | api_calls: [call | &1.api_calls]})
    response
  end

  defp overridden(_agent, nil, _url, _bearer), do: nil

  defp overridden(agent, override, url, bearer) do
    nth = agent |> Agent.get(& &1.api_calls) |> Enum.count(&(&1.bearer == bearer)) |> Kernel.+(1)
    override.(%{url: url, bearer: bearer, nth: nth})
  end

  # A recording answers with the raw :httpc shape; an `api:` function with
  # `{status, body}` or `{status, body, headers}`.
  defp answer_call(answer, url, opts) do
    case answer.(url, opts) do
      {status, body} when is_integer(status) -> httpc(status, body)
      {status, body, headers} when is_integer(status) -> httpc(status, body, headers)
      raw -> raw
    end
  end

  defp refuse?(_agent, nil), do: false

  defp refuse?(agent, bearer) do
    Agent.get_and_update(agent, fn state ->
      served = Map.get(state.served, bearer, 0)

      refused =
        bearer in state.reject or
          (Map.has_key?(state.expire, bearer) and served >= Map.fetch!(state.expire, bearer))

      served = if refused, do: served, else: served + 1
      {refused, %{state | served: Map.put(state.served, bearer, served)}}
    end)
  end

  defp bearer(headers) do
    Enum.find_value(headers, fn {name, value} ->
      if String.downcase(to_string(name)) == "authorization" do
        case to_string(value) do
          "Bearer " <> token -> token
          _other -> nil
        end
      end
    end)
  end

  defp httpc(status, body, extra \\ []) do
    headers =
      [{~c"content-type", ~c"application/json"}] ++
        Enum.map(extra, fn {name, value} ->
          {String.to_charlist(name), String.to_charlist(value)}
        end)

    {:ok, {{~c"HTTP/1.1", status, ~c"OK"}, headers, Jason.encode!(body)}}
  end
end
