defmodule OptimalEngine.Test.ConnectorFixtureStub do
  @moduledoc """
  Serves recorded connector fixtures through the Engine's HTTP mock seam.

  Every adapter test runs against a recorded fixture under
  `test/fixtures/connectors/<kind>/routes.json` and never against a live API.
  A fixture is a list of routes; each route is matched against the outgoing
  request and answers with the recorded status, headers and body.

      {
        "kind": "stripe",
        "routes": [
          {
            "name": "customers_page_1",
            "match": {"method": "GET", "contains": "/v1/customers"},
            "status": 200,
            "body": {"data": [{"id": "cus_0001"}]},
            "times": 1
          }
        ]
      }

  Matching:

    * `match.method` — the HTTP method, upper case and optional
    * `match.contains` — a substring of the request URL
    * `match.absolute` — the whole request URL, when a test needs to pin it
    * `match.headers` — header name and value pairs that must be present

  When several routes match, the most specific wins: the longest `contains`
  string, with the file order breaking ties. `times` bounds how often a route
  may answer, which is how a paginated recording advances from one page to the
  next. `"unreachable": true` makes the route answer with a network error
  instead of a response.

  A route's `headers` is an object of extra response headers, such as
  `{"retry-after": "3"}`.

  The route may also be overridden per call through `install/2`:

      install(:gmail, status: 401)

  which answers every request with that status and no body. Use it for the
  error paths a recording does not carry. `headers:` takes the same name and
  value pairs as a route, for a `429` that names its `Retry-After`.

  To fail one call rather than all of them, name it:

      install(:gmail, fail: {"/messages/msg-0004", 500})

  Every request whose URL contains the fragment answers that status, and every
  other request is answered from the recording. This is how a test drives a
  failure part-way through a pull, where the calls before it have to succeed.
  """

  @fixtures_root "test/fixtures/connectors"
  @calls_table :connector_fixture_stub_calls
  @counters_table :connector_fixture_stub_counters

  @type handle :: %{kind: atom(), table: :ets.tid(), override: keyword()}

  @doc """
  Installs the fixture as the process-global HTTP mock and returns a handle.
  Tests that use it must be `async: false`: the mock seam is application-wide.
  """
  @spec install(atom(), keyword()) :: handle()
  def install(kind, override \\ []) when is_atom(kind) do
    table = ensure_table(@calls_table)
    counters = ensure_table(@counters_table)
    routes = kind |> load_routes() |> index_routes()
    reset_counters(counters, kind, routes)
    install_mock(kind, routes, counters, table, override)

    %{kind: kind, table: table, override: override}
  end

  @doc "Removes the mock and clears the recorded calls."
  @spec uninstall(handle()) :: :ok
  def uninstall(%{table: table}) do
    Application.delete_env(:optimal_engine, :http_mock)

    # `:ets.delete/2` removes one object by key; the whole table is what this
    # wants, so that a test reading `calls/1` after `uninstall/1` sees nothing.
    if :ets.whereis(@calls_table) != :undefined, do: :ets.delete_all_objects(table)
    :ok
  end

  @doc "Requests the stub answered, oldest first: `[%{url:, method:, headers:, body:}]`."
  @spec calls(handle()) :: [map()]
  def calls(%{table: table}) do
    table
    |> :ets.tab2list()
    |> Enum.sort_by(fn {index, _call} -> index end)
    |> Enum.map(fn {_index, call} -> call end)
  end

  @doc "The recorded calls whose URL contains `fragment`."
  @spec calls_matching(handle(), String.t()) :: [map()]
  def calls_matching(handle, fragment) do
    handle
    |> calls()
    |> Enum.filter(&String.contains?(&1.url, fragment))
  end

  @doc "A decoded fixture file, for asserting against the recording itself."
  @spec fixture(atom(), String.t()) :: map()
  def fixture(kind, name) do
    path = Path.join([@fixtures_root, to_string(kind), name])
    path |> File.read!() |> Jason.decode!()
  end

  @doc "The absolute path of a fixture directory."
  @spec fixture_dir(atom()) :: String.t()
  def fixture_dir(kind), do: Path.join(@fixtures_root, to_string(kind))

  # ─── mock ────────────────────────────────────────────────────────────────

  defp install_mock(kind, routes, counters, table, override) do
    mock = fn url, opts ->
      call = %{
        url: url,
        method: opts |> Keyword.get(:method, :get) |> to_string() |> String.upcase(),
        headers: Keyword.get(opts, :headers, []),
        body: Keyword.get(opts, :body)
      }

      record(table, call)
      respond(kind, routes, counters, call, override)
    end

    Application.put_env(:optimal_engine, :http_mock, mock)
  end

  defp record(table, call) do
    index = :ets.info(table, :size)
    :ets.insert(table, {index, call})
  end

  defp respond(_kind, _routes, _counters, _call, [{:unreachable, true} | _rest]) do
    {:error, :econnrefused}
  end

  # A named failure answers only the calls it names; every other call in the
  # same test is answered from the recording, which is what lets a test fail a
  # request part-way through a pull whose earlier calls had to succeed.
  defp respond(kind, routes, counters, call, override) when override != [] do
    case Keyword.get(override, :fail) do
      {fragment, status} ->
        if String.contains?(call.url, fragment),
          do: httpc_ok(%{}, status),
          else: respond_from_recording(kind, routes, counters, call)

      nil ->
        httpc_ok(
          Keyword.get(override, :body, %{}),
          Keyword.get(override, :status, 200),
          response_headers(Keyword.get(override, :headers))
        )
    end
  end

  defp respond(kind, routes, counters, call, _no_override) do
    respond_from_recording(kind, routes, counters, call)
  end

  defp respond_from_recording(kind, routes, counters, call) do
    case match(kind, routes, counters, call) do
      nil ->
        raise "no recorded fixture for #{call.method} #{call.url}"

      route ->
        if route["unreachable"] == true do
          {:error, :econnrefused}
        else
          httpc_ok(
            route["body"] || %{},
            route["status"] || 200,
            response_headers(route["headers"])
          )
        end
    end
  end

  # Most specific matching route wins; a route with `times` runs out of answers,
  # which is how a paginated recording advances from one page to the next.
  defp match(kind, routes, counters, call) do
    routes
    |> Enum.filter(&(eligible?(&1, call) and not consumed?(kind, counters, &1)))
    |> Enum.max_by(&String.length(match_contains(&1)), fn -> nil end)
    |> tap(&consume(kind, counters, &1))
  end

  defp eligible?(route, call) do
    matches?(route["match"] || %{}, call)
  end

  defp consumed?(kind, counters, route) do
    times = route["times"]

    if is_nil(times) do
      false
    else
      lookup_count(counters, kind, route) >= times
    end
  end

  defp consume(_kind, _counters, nil), do: :ok

  defp consume(kind, counters, route) do
    :ets.update_counter(counters, {kind, route["index"]}, 1, {{kind, route["index"]}, 0})
    :ok
  end

  defp lookup_count(counters, kind, route) do
    case :ets.lookup(counters, {kind, route["index"]}) do
      [{{^kind, _index}, count}] -> count
      _ -> 0
    end
  end

  defp matches?(match, call) do
    method_ok? =
      case match["method"] do
        nil -> true
        method -> String.upcase(method) == call.method
      end

    absolute_ok? =
      case match["absolute"] do
        nil -> true
        absolute -> absolute == call.url
      end

    contains_ok? =
      case match["contains"] do
        nil -> true
        fragment -> String.contains?(call.url, fragment)
      end

    headers_ok? =
      (match["headers"] || %{})
      |> Enum.all?(fn {name, value} ->
        Enum.any?(call.headers, fn {k, v} ->
          String.downcase(to_string(k)) == String.downcase(name) and v == value
        end)
      end)

    method_ok? and absolute_ok? and contains_ok? and headers_ok?
  end

  defp match_contains(route), do: (route["match"] || %{})["contains"] || ""

  # A recording is JSON, so extra headers arrive as an object or a list of
  # name and value pairs; the HTTP layer wants `{name, value}` tuples.
  defp response_headers(nil), do: []

  defp response_headers(headers) when is_map(headers) or is_list(headers) do
    Enum.map(headers, fn
      {name, value} -> {to_string(name), to_string(value)}
      [name, value] -> {to_string(name), to_string(value)}
    end)
  end

  defp httpc_ok(body, status, extra_headers \\ []) do
    headers =
      [{"content-type", "application/json"}, {"date", "Mon, 01 Jan 2026 00:00:00 GMT"}] ++
        extra_headers

    charlist_headers =
      Enum.map(headers, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)

    body_binary = if is_binary(body), do: body, else: Jason.encode!(body || %{})

    {:ok, {{~c"HTTP/1.1", status, ~c"OK"}, charlist_headers, body_binary}}
  end

  # ─── fixture loading ──────────────────────────────────────────────────────

  defp load_routes(kind) do
    path = Path.join([@fixtures_root, to_string(kind), "routes.json"])

    case File.read(path) do
      {:ok, json} ->
        json |> Jason.decode!() |> Map.get("routes", [])

      {:error, reason} ->
        raise "connector fixture missing at #{path}: #{inspect(reason)}"
    end
  end

  defp ensure_table(name) do
    case :ets.whereis(name) do
      :undefined -> :ets.new(name, [:named_table, :public, :set])
      _ -> name
    end
  end

  defp index_routes(routes) do
    routes
    |> Enum.with_index()
    |> Enum.map(fn {route, index} -> Map.put(route, "index", index) end)
  end

  defp reset_counters(counters, kind, routes) do
    Enum.each(routes, fn route ->
      :ets.insert(counters, {{kind, route["index"]}, 0})
    end)
  end
end
