defmodule OptimalEngine.Connectors.TokenExchange do
  @moduledoc """
  The OAuth token exchange the adapters share: a form posted to a provider's
  token endpoint, and what each answer to it means for the sync.

  The form is encoded (`URI.encode_query/1`, so a secret with `&`, `=` or `+`
  in it arrives whole) and sent as `application/x-www-form-urlencoded`.

  | Answer | Becomes |
  | --- | --- |
  | `200` with an `access_token` | `{:ok, token}` |
  | `400`, `401` (a revoked or wrong grant) | `{:error, :auth_expired}` |
  | `429` | `{:error, :rate_limited}` |
  | `5xx` | `{:error, :transient}` |
  | anything else | `{:error, {:http, status}}` |
  | a transport failure | `{:error, reason}` |

  Those are the reasons the Runner acts on: it retries the throttled and the
  failing, and stops on the expired.
  """

  alias OptimalEngine.Connectors.HTTP

  @form "application/x-www-form-urlencoded"

  @doc """
  Posts `params` to `url` as a form and reads the answer as a token. Options:
  `:headers` (extra headers, such as `Authorization`). The call verifies TLS and
  follows no redirect.
  """
  @spec exchange(String.t(), Enumerable.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def exchange(url, params, opts \\ []) when is_binary(url) do
    headers = [{"content-type", @form} | Keyword.get(opts, :headers, [])]

    # The client's secret goes to the endpoint named and nowhere else.
    url
    |> HTTP.request(
      method: :post,
      body: URI.encode_query(params),
      headers: headers,
      follow_redirects: false,
      verify_tls: true
    )
    |> token()
  end

  @doc "Reads the answer of a token endpoint."
  @spec token({:ok, HTTP.response()} | {:error, term()}) :: {:ok, String.t()} | {:error, term()}
  def token({:ok, %{status: 200, body: %{"access_token" => token}}})
      when is_binary(token) and token != "",
      do: {:ok, token}

  def token({:ok, %{status: status}}) when status in [400, 401], do: {:error, :auth_expired}
  def token({:ok, %{status: 429}}), do: {:error, :rate_limited}
  def token({:ok, %{status: status}}) when status >= 500, do: {:error, :transient}
  def token({:ok, %{status: status}}), do: {:error, {:http, status}}
  def token({:error, reason}), do: {:error, reason}
end
