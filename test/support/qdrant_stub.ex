defmodule OptimalEngine.TestSupport.QdrantStub do
  @moduledoc """
  A local Qdrant REST endpoint for tests: the slice the provider and the
  projection use (list, read, create and delete a collection, create a payload
  index, upsert points by id, search with a filter, offset and score
  threshold, count, scroll, delete points by id or filter), with an in-memory
  collection table and a record of every request. Filters support `must` of
  `match.value` and `match.any`. When started with `:api_key`, every request
  without a matching `api-key` header is refused with 401, as Qdrant does. No
  test here talks to a real Qdrant.
  """

  @behaviour Plug

  import Plug.Conn

  @doc """
  Starts a listener on a free port. Options: `:api_key`, `fail: :search` (the
  search answers 500), `fail: :delete` (deleting a collection answers 403,
  as for a key without the permission) and `fail: :points` (every request
  under `/points` answers 503). `set_fail/2` changes it while running. Returns
  `{:ok, %{endpoint:, ref:, agent:}}`.
  """
  @spec start(keyword()) :: {:ok, map()}
  def start(opts \\ []) do
    {:ok, agent} =
      Agent.start_link(fn ->
        %{
          collections: %{},
          requests: [],
          api_key: Keyword.get(opts, :api_key),
          fail: Keyword.get(opts, :fail)
        }
      end)

    ref = :"#{__MODULE__}.HTTP#{System.unique_integer([:positive])}"
    {:ok, _pid} = Plug.Cowboy.http(__MODULE__, [agent: agent], port: 0, ref: ref)
    port = :ranch.get_port(ref)
    {:ok, %{endpoint: "http://127.0.0.1:#{port}", ref: ref, agent: agent}}
  end

  @doc "Stops the listener."
  @spec stop(map()) :: :ok | {:error, :not_found}
  def stop(%{ref: ref}), do: Plug.Cowboy.shutdown(ref)

  @doc "Every request served, oldest first, as `{method, path}`."
  @spec requests(map()) :: [{String.t(), String.t()}]
  def requests(%{agent: agent}), do: agent |> Agent.get(& &1.requests) |> Enum.reverse()

  @doc "Changes the failure mode (`nil` for none) of a running stub."
  @spec set_fail(map(), atom() | nil) :: :ok
  def set_fail(%{agent: agent}, mode), do: Agent.update(agent, &%{&1 | fail: mode})

  @doc "Delays every answer under `/points` by `ms` (0 for none)."
  @spec set_delay(map(), non_neg_integer()) :: :ok
  def set_delay(%{agent: agent}, ms), do: Agent.update(agent, &Map.put(&1, :delay, ms))

  @doc "Puts a point straight into a collection (created when missing), as another writer would."
  @spec put_point(map(), String.t(), map()) :: :ok
  def put_point(%{agent: agent}, collection, %{"id" => id} = point) do
    Agent.update(agent, fn state ->
      state
      |> update_in([:collections], &Map.put_new(&1, collection, %{config: %{}, points: %{}}))
      |> put_in([:collections, collection, :points, to_string(id)], point)
    end)
  end

  @doc "Forgets the requests recorded so far."
  @spec clear_requests(map()) :: :ok
  def clear_requests(%{agent: agent}), do: Agent.update(agent, &%{&1 | requests: []})

  @doc "The points of a collection, by id."
  @spec points(map(), String.t()) :: %{String.t() => map()}
  def points(%{agent: agent}, collection) do
    case Agent.get(agent, &get_in(&1, [:collections, collection])) do
      nil -> %{}
      %{points: points} -> points
    end
  end

  @doc "The collections the stub holds now."
  @spec collections(map()) :: map()
  def collections(%{agent: agent}), do: Agent.get(agent, & &1.collections)

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, opts) do
    agent = Keyword.fetch!(opts, :agent)
    Agent.update(agent, &%{&1 | requests: [{conn.method, conn.request_path} | &1.requests]})
    {:ok, raw, conn} = read_body(conn)
    body = if raw == "", do: %{}, else: Jason.decode!(raw)

    fail = Agent.get(agent, & &1.fail)

    case {conn.path_info, Agent.get(agent, &Map.get(&1, :delay, 0))} do
      {["collections", _, "points" | _], ms} when ms > 0 -> Process.sleep(ms)
      _ -> :ok
    end

    case {authorized?(conn, agent), conn.method, conn.path_info} do
      {false, _, _} ->
        json(conn, 401, %{
          status: %{error: "Must provide an API key or an Authorization bearer token"}
        })

      {_, "GET", ["collections"]} ->
        json(conn, 200, %{result: %{collections: names(agent)}})

      {_, _, ["collections", _name, "points" | _]} when fail == :points ->
        json(conn, 503, %{status: %{error: "Service unavailable"}})

      {_, "GET", ["collections", name]} ->
        case collection(agent, name) do
          nil -> json(conn, 404, %{status: %{error: "Collection `#{name}` doesn't exist!"}})
          %{config: config} -> json(conn, 200, %{result: %{status: "green", config: config}})
        end

      {_, "PUT", ["collections", name]} ->
        if collection(agent, name) do
          json(conn, 409, %{status: %{error: "Collection `#{name}` already exists!"}})
        else
          Agent.update(agent, &put_in(&1, [:collections, name], %{config: body, points: %{}})) &&
            json(conn, 200, %{result: true})
        end

      {_, "PUT", ["collections", name, "index"]} ->
        with_collection(conn, agent, name, fn _ ->
          json(conn, 200, %{result: %{status: "completed"}})
        end)

      {_, "POST", ["collections", name, "points", "count"]} ->
        with_collection(conn, agent, name, fn %{points: points} ->
          n = points |> Map.values() |> Enum.count(&matches?(&1, body["filter"]))
          json(conn, 200, %{result: %{count: n}})
        end)

      {_, "POST", ["collections", name, "points", "scroll"]} ->
        scroll(conn, agent, name, body)

      {_, "POST", ["collections", name, "points", "delete"]} ->
        delete_points(conn, agent, name, body)

      {_, "DELETE", ["collections", _name]} when fail == :delete ->
        json(conn, 403, %{status: %{error: "Forbidden"}})

      {_, "POST", ["collections", _name, "points", "search"]} when fail == :search ->
        json(conn, 500, %{status: %{error: "Service internal error"}})

      {_, "DELETE", ["collections", name]} ->
        Agent.update(agent, &%{&1 | collections: Map.delete(&1.collections, name)}) &&
          json(conn, 200, %{result: true})

      {_, "PUT", ["collections", name, "points"]} ->
        upsert(conn, agent, name, body)

      {_, "POST", ["collections", name, "points", "search"]} ->
        search(conn, agent, name, body)

      _ ->
        json(conn, 404, %{status: %{error: "Not found"}})
    end
  end

  defp authorized?(conn, agent) do
    case Agent.get(agent, & &1.api_key) do
      nil -> true
      key -> get_req_header(conn, "api-key") == [key]
    end
  end

  defp names(agent),
    do: agent |> Agent.get(& &1.collections) |> Map.keys() |> Enum.map(&%{name: &1})

  defp collection(agent, name), do: Agent.get(agent, &Map.get(&1.collections, name))

  defp with_collection(conn, agent, name, fun) do
    case collection(agent, name) do
      nil -> json(conn, 404, %{status: %{error: "Collection `#{name}` doesn't exist!"}})
      found -> fun.(found)
    end
  end

  # Points are kept by id, so an upsert of an id already there replaces it.
  defp upsert(conn, agent, name, %{"points" => points}) do
    with_collection(conn, agent, name, fn %{config: config} ->
      size = get_in(config, ["vectors", "size"])

      if Enum.all?(points, &(size == nil or length(&1["vector"]) == size)) do
        Agent.update(
          agent,
          &update_in(&1, [:collections, name, :points], fn existing ->
            Enum.into(points, existing, fn point -> {to_string(point["id"]), point} end)
          end)
        ) && json(conn, 200, %{result: %{status: "completed"}})
      else
        json(conn, 400, %{status: %{error: "Wrong input: Vector dimension error"}})
      end
    end)
  end

  defp search(conn, agent, name, %{"vector" => vector, "limit" => limit} = body) do
    with_collection(conn, agent, name, fn %{points: points} ->
      threshold = body["score_threshold"]

      result =
        points
        |> Map.values()
        |> Enum.filter(&matches?(&1, body["filter"]))
        |> Enum.map(&{&1, cosine(&1["vector"], vector)})
        |> Enum.filter(fn {_point, score} -> threshold == nil or score >= threshold end)
        |> Enum.sort_by(fn {point, score} -> {-score, to_string(point["id"])} end)
        |> Enum.drop(body["offset"] || 0)
        |> Enum.take(limit)
        |> Enum.map(fn {point, score} ->
          %{id: point["id"], score: score, payload: point["payload"]}
        end)

      json(conn, 200, %{result: result})
    end)
  end

  defp scroll(conn, agent, name, body) do
    with_collection(conn, agent, name, fn %{points: points} ->
      limit = body["limit"] || 10
      offset = body["offset"]

      ordered =
        points
        |> Map.values()
        |> Enum.filter(&matches?(&1, body["filter"]))
        |> Enum.sort_by(&to_string(&1["id"]))
        |> Enum.drop_while(&(offset != nil and to_string(&1["id"]) < offset))

      {page, rest} = Enum.split(ordered, limit)

      json(conn, 200, %{
        result: %{
          points: Enum.map(page, &%{id: &1["id"], payload: &1["payload"]}),
          next_page_offset:
            case rest do
              [next | _] -> next["id"]
              [] -> nil
            end
        }
      })
    end)
  end

  defp delete_points(conn, agent, name, body) do
    with_collection(conn, agent, name, fn %{points: points} ->
      keep =
        case body do
          %{"points" => ids} ->
            Map.drop(points, Enum.map(ids, &to_string/1))

          %{"filter" => filter} ->
            points |> Enum.reject(fn {_id, point} -> matches?(point, filter) end) |> Map.new()
        end

      Agent.update(agent, &put_in(&1, [:collections, name, :points], keep)) &&
        json(conn, 200, %{result: %{status: "completed"}})
    end)
  end

  defp matches?(_point, nil), do: true

  defp matches?(point, %{"must" => conditions}) do
    Enum.all?(conditions, fn %{"key" => key, "match" => match} ->
      value = get_in(point, ["payload", key])

      case match do
        %{"value" => expected} -> value == expected
        %{"any" => options} -> value in options
      end
    end)
  end

  defp cosine(a, b) do
    dot = Enum.zip(a, b) |> Enum.map(fn {x, y} -> x * y end) |> Enum.sum()
    norm = fn v -> :math.sqrt(Enum.map(v, &(&1 * &1)) |> Enum.sum()) end
    dot / max(norm.(a) * norm.(b), 1.0e-9)
  end

  defp json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
