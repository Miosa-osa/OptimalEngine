defmodule OptimalEngine.TestSupport.QdrantStub do
  @moduledoc """
  A local Qdrant REST endpoint for tests: the slice the provider uses
  (list collections, create and delete a collection, upsert points, search),
  with an in-memory collection table and a record of every request. When
  started with `:api_key`, every request without a matching `api-key` header
  is refused with 401, as Qdrant does. No test here talks to a real Qdrant.
  """

  @behaviour Plug

  import Plug.Conn

  @doc "Starts a listener on a free port. Options: `:api_key`. Returns `{:ok, %{endpoint:, ref:, agent:}}`."
  @spec start(keyword()) :: {:ok, map()}
  def start(opts \\ []) do
    {:ok, agent} =
      Agent.start_link(fn ->
        %{collections: %{}, requests: [], api_key: Keyword.get(opts, :api_key)}
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

    case {authorized?(conn, agent), conn.method, conn.path_info} do
      {false, _, _} ->
        json(conn, 401, %{
          status: %{error: "Must provide an API key or an Authorization bearer token"}
        })

      {_, "GET", ["collections"]} ->
        json(conn, 200, %{result: %{collections: names(agent)}})

      {_, "PUT", ["collections", name]} ->
        Agent.update(agent, &put_in(&1, [:collections, name], %{config: body, points: []})) &&
          json(conn, 200, %{result: true})

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

  defp upsert(conn, agent, name, %{"points" => points}) do
    case Agent.get(agent, &Map.get(&1.collections, name)) do
      nil ->
        json(conn, 404, %{status: %{error: "Collection #{name} not found"}})

      _ ->
        Agent.update(
          agent,
          &update_in(&1, [:collections, name, :points], fn existing -> existing ++ points end)
        ) && json(conn, 200, %{result: %{status: "completed"}})
    end
  end

  defp search(conn, agent, name, %{"vector" => vector, "limit" => limit}) do
    case Agent.get(agent, &Map.get(&1.collections, name)) do
      nil ->
        json(conn, 404, %{status: %{error: "Collection #{name} not found"}})

      %{points: points} ->
        result =
          points
          |> Enum.sort_by(&(-cosine(&1["vector"], vector)))
          |> Enum.take(limit)
          |> Enum.map(&%{id: &1["id"], score: cosine(&1["vector"], vector), payload: &1["payload"]})

        json(conn, 200, %{result: result})
    end
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
