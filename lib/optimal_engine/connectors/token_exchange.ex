defmodule OptimalEngine.Connectors.TokenExchange do
  @moduledoc """
  The OAuth token exchange the adapters share: a form posted to a provider's
  token endpoint, and what each answer to it means for the sync.

  The form is encoded (`URI.encode_query/1`, so a secret with `&`, `=` or `+`
  in it arrives whole) and sent as `application/x-www-form-urlencoded`. The call
  verifies TLS, follows no redirect, and is made once on a connection of its
  own, so nothing sends the client's secret a second time or to another host.

  | Answer | Becomes |
  | --- | --- |
  | `200` with an `access_token` | `{:ok, token}` |
  | `400` naming `invalid_grant`, `invalid_client` or `unauthorized_client`; `401` | `{:error, :auth_expired}` |
  | any other `400` | `{:error, {:token_error, error_code}}`, the `error` field only, and only if it is 1 to 64 lower-case letters and underscores (else `"unknown"`) |
  | `429` | `{:error, {:rate_limited, ms}}` from `Retry-After` (at most 30 s), else `{:error, :rate_limited}` |
  | `5xx` | `{:error, :transient}` |
  | anything else | `{:error, {:http, status}}` |
  | a transport failure | `{:error, reason}` |

  Those are the reasons the Runner acts on: it retries the throttled and the
  failing, and stops on the expired. Nothing but the error code of a refused
  exchange is kept, since a provider may echo what it was sent.
  """

  alias OptimalEngine.Connectors.HTTP

  @form "application/x-www-form-urlencoded"
  @grant_errors ~w(invalid_grant invalid_client unauthorized_client)
  @max_retry_after_ms 30_000
  @error_code ~r/\A[a-z_]{1,64}\z/

  @doc """
  Posts `params` to `url` as a form and reads the answer as a token. Options:
  `:headers` (extra headers, such as `Authorization`).
  """
  @spec exchange(String.t(), Enumerable.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def exchange(url, params, opts \\ []) when is_binary(url) do
    headers = [{"content-type", @form} | Keyword.get(opts, :headers, [])]

    url
    |> HTTP.request(
      method: :post,
      body: URI.encode_query(params),
      headers: headers,
      follow_redirects: false,
      verify_tls: true,
      single_attempt: true
    )
    |> token()
  end

  @doc "Reads the answer of a token endpoint."
  @spec token({:ok, HTTP.response()} | {:error, term()}) :: {:ok, String.t()} | {:error, term()}
  def token({:ok, %{status: 200, body: %{"access_token" => token}}})
      when is_binary(token) and token != "",
      do: {:ok, token}

  def token({:ok, %{status: 401}}), do: {:error, :auth_expired}

  def token({:ok, %{status: 400, body: body}}) do
    case error_code(body) do
      code when code in @grant_errors -> {:error, :auth_expired}
      code -> {:error, {:token_error, code}}
    end
  end

  def token({:ok, %{status: 429, headers: headers}}) do
    case HTTP.retry_after(headers) do
      ms when is_integer(ms) -> {:error, {:rate_limited, min(ms, @max_retry_after_ms)}}
      _none -> {:error, :rate_limited}
    end
  end

  def token({:ok, %{status: status}}) when status >= 500, do: {:error, :transient}
  def token({:ok, %{status: status}}), do: {:error, {:http, status}}
  def token({:error, reason}), do: {:error, reason}

  # A provider's `error` is a short code (`invalid_request`). Anything else in
  # that field could be an echo of what was sent, so it is not kept.
  defp error_code(%{"error" => code}) when is_binary(code) do
    if Regex.match?(@error_code, code), do: code, else: "unknown"
  end

  defp error_code(_body), do: "unknown"
end
