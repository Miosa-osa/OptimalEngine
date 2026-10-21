defmodule OptimalEngine.TestSupport.RetrievalFixtures do
  @moduledoc """
  Fixtures for the tests of ranked retrieval.

  The ranking tests store the same data twice, in two workspaces and in
  opposite orders. That is what separates two Engines (their rows have
  different rowids, so the database yields ties in a different order) without
  starting a second Engine. The workspaces must then answer alike.
  """

  import Plug.Test

  alias OptimalEngine.API.Router
  alias OptimalEngine.Context
  alias OptimalEngine.Store

  @stored_at ~U[2026-10-10 12:00:00Z]

  @doc "The instant contexts are stored at unless a test says otherwise."
  def stored_at, do: @stored_at

  @doc "A word the full text index sees as one token, new on every call."
  def token, do: "rk#{System.unique_integer([:positive])}"

  @doc """
  Stores one context whose title and content carry `token`, so every context of
  a test matches with the same BM25 score. Options: `:modified_at`, `:node`
  (not indexed, so it tells contexts of equal text apart in a grep match),
  `:content`, `:title`.
  """
  def insert_context(workspace, id, uri, token, opts \\ []) do
    at = Keyword.get(opts, :modified_at, @stored_at)

    :ok =
      Store.insert_context(%Context{
        id: id,
        uri: uri,
        type: :resource,
        path: "#{id}.md",
        title: Keyword.get(opts, :title, "Ranking #{token}"),
        content:
          Keyword.get(opts, :content, "#{token} shows how ties between equal contexts are broken"),
        l0_abstract: "abstract",
        l1_overview: "overview",
        node: Keyword.get(opts, :node, "ranking"),
        created_at: at,
        modified_at: at,
        workspace_id: workspace
      })
  end

  @doc "`count` URIs that sort in the order they are listed."
  def uris(token, count) do
    for n <- 1..count do
      "optimal://nodes/ranking/#{token}/doc-#{n |> Integer.to_string() |> String.pad_leading(2, "0")}"
    end
  end

  @doc "Removes everything the given workspaces hold that the fixtures create."
  def delete_workspaces(workspaces) do
    for workspace <- workspaces do
      Store.raw_query("DELETE FROM chunk_embeddings WHERE workspace_id = ?1", [workspace])
      Store.raw_query("DELETE FROM chunks WHERE workspace_id = ?1", [workspace])
      Store.raw_query("DELETE FROM vectors WHERE workspace_id = ?1", [workspace])
      Store.raw_query("DELETE FROM contexts WHERE workspace_id = ?1", [workspace])
      Store.raw_query("DELETE FROM memory_embeddings WHERE workspace_id = ?1", [workspace])
      Store.raw_query("DELETE FROM memories WHERE workspace_id = ?1", [workspace])
      Store.raw_query("DELETE FROM graph_edges WHERE workspace_id = ?1", [workspace])
    end

    :ok
  end

  @doc "A GET through the router, from an address of its own (the API rate-limits per address)."
  def get(path) do
    conn(:get, path)
    |> put_peer_data(%{address: unique_loopback_address(), port: 0, ssl_cert: nil})
    |> Router.call(Router.init([]))
  end

  @doc "A JSON POST through the router."
  def post(path, body) do
    conn(:post, path, Jason.encode!(body))
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> put_peer_data(%{address: unique_loopback_address(), port: 0, ssl_cert: nil})
    |> Router.call(Router.init([]))
  end

  defp unique_loopback_address do
    n = System.unique_integer([:positive])
    {127, rem(div(n, 65_536), 256), rem(div(n, 256), 256), rem(n, 254) + 1}
  end

  @doc """
  Points the text embedder at a local endpoint that answers every input with
  `vector_for.(text)`, and turns the vector hop of search on. Restored when the
  test ends. Returns the endpoint's base URL.
  """
  def use_embedder(vector_for, dimensions \\ 4) when is_function(vector_for, 1) do
    ref = :"embed_stub_#{System.unique_integer([:positive])}"

    {:ok, _pid} =
      Plug.Cowboy.http(OptimalEngine.TestSupport.RetrievalEmbedStub, [vector_for: vector_for],
        port: 0,
        ref: ref
      )

    base = "http://127.0.0.1:#{:ranch.get_port(ref)}"

    saved =
      Map.new([:text_embedding, :hybrid_search], &{&1, Application.get_env(:optimal_engine, &1)})

    hybrid = Application.get_env(:optimal_engine, :hybrid_search, [])

    Application.put_env(:optimal_engine, :text_embedding, url: base, dimensions: dimensions)
    Application.put_env(:optimal_engine, :hybrid_search, Keyword.put(hybrid, :vector_enabled, true))

    ExUnit.Callbacks.on_exit(fn ->
      Enum.each(saved, fn
        {name, nil} -> Application.delete_env(:optimal_engine, name)
        {name, value} -> Application.put_env(:optimal_engine, name, value)
      end)

      Plug.Cowboy.shutdown(ref)
    end)

    base
  end
end

defmodule OptimalEngine.TestSupport.RetrievalEmbedStub do
  @moduledoc false
  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, opts) do
    {:ok, raw, conn} = read_body(conn)
    %{"input" => input} = Jason.decode!(raw)
    vector_for = Keyword.fetch!(opts, :vector_for)

    data =
      input
      |> List.wrap()
      |> Enum.with_index()
      |> Enum.map(fn {text, index} ->
        %{"object" => "embedding", "index" => index, "embedding" => vector_for.(text)}
      end)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(
      200,
      Jason.encode!(%{
        "object" => "list",
        "data" => data,
        "model" => "nomic-embed-text",
        "usage" => %{"prompt_tokens" => 1, "total_tokens" => 1}
      })
    )
  end
end
