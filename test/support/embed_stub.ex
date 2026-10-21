defmodule OptimalEngine.TestSupport.EmbedStub do
  @moduledoc """
  A stand-in embedding endpoint (OpenAI dialect) for tests. It answers every
  input with a four-dimension vector and reports each request to the process
  that started it as `{:embed_request, path, input}`, where `input` is the
  request's `input` field (a string, or a list for a batch). Test support only.
  """

  @behaviour Plug

  import Plug.Conn

  @vector [1.0, 0.0, 0.0, 0.0]

  @doc """
  Start a listener that reports to the calling process. Returns its base URL and
  a function that stops it; pair it with `on_exit/1`.
  """
  @spec start() :: {String.t(), (-> :ok)}
  def start do
    ref = :"#{__MODULE__}.#{System.unique_integer([:positive])}"
    {:ok, _pid} = Plug.Cowboy.http(__MODULE__, [test: self()], port: 0, ref: ref)
    {"http://127.0.0.1:#{:ranch.get_port(ref)}", fn -> Plug.Cowboy.shutdown(ref) end}
  end

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, opts) do
    {:ok, raw, conn} = read_body(conn)
    %{"input" => input} = Jason.decode!(raw)
    send(opts[:test], {:embed_request, conn.request_path, input})

    data =
      input
      |> List.wrap()
      |> Enum.with_index()
      |> Enum.map(fn {_text, index} ->
        %{"object" => "embedding", "index" => index, "embedding" => @vector}
      end)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(%{"object" => "list", "data" => data}))
  end
end
