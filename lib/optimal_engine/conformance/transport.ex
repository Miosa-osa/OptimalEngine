defmodule OptimalEngine.Conformance.Transport do
  @moduledoc """
  One request in, one response out.

  The conformance runner talks to an Engine through a transport, so it can
  reach a server over HTTP or, in tests, this node's own router without
  binding a socket. A transport receives:

      %{method: :get | :post | :delete, url: url, headers: [{name, value}],
        body: iodata | nil, timeout: milliseconds}

  and answers `{:ok, %{status: status, headers: headers, body: body}}` where
  `body` is the raw response binary, or `{:error, reason}` when no HTTP
  response arrived at all.
  """

  @type request :: %{
          method: :get | :post | :delete,
          url: String.t(),
          headers: [{String.t(), String.t()}],
          body: iodata() | nil,
          timeout: pos_integer()
        }

  @type response :: %{
          status: non_neg_integer(),
          headers: [{String.t(), String.t()}],
          body: binary() | nil
        }

  @callback request(request()) :: {:ok, response()} | {:error, term()}
end
