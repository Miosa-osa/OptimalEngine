defmodule OptimalEngine.Conformance.Transport.HTTP do
  @moduledoc """
  The default conformance transport: Erlang's built-in HTTP client.

  It uses :inets and :ssl from the OTP distribution, so a conformance run
  against another machine's Engine needs no extra dependency. A response with
  a 4xx or 5xx status is a response, not a transport error: the checks decide
  what each status means.
  """

  @behaviour OptimalEngine.Conformance.Transport

  @impl true
  def request(%{method: method, url: url, headers: headers, body: body, timeout: timeout}) do
    with {:ok, _started} <- start_clients() do
      http_headers = Enum.map(headers, fn {name, value} -> {charlist(name), charlist(value)} end)
      http_opts = [timeout: timeout, connect_timeout: min(timeout, 5_000)]
      opts = [body_format: :binary]
      url_chars = charlist(url)

      # httpc takes a two-element request for methods that carry no body and a
      # four-element request otherwise; a POST with the two-element form is
      # rejected as :invalid_request.
      result =
        if body == nil and method in [:get, :head, :delete, :options, :trace] do
          :httpc.request(method, {url_chars, http_headers}, http_opts, opts)
        else
          :httpc.request(
            method,
            {url_chars, http_headers, ~c"application/json", body || ""},
            http_opts,
            opts
          )
        end

      case result do
        {:ok, {{_version, status, _reason}, resp_headers, resp_body}} ->
          {:ok, %{status: status, headers: normalize(resp_headers), body: resp_body}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp start_clients do
    with {:ok, _} <- Application.ensure_all_started(:inets) do
      Application.ensure_all_started(:ssl)
    end
  end

  defp normalize(headers) do
    Enum.map(headers, fn {name, value} -> {to_string(name), to_string(value)} end)
  end

  defp charlist(value) when is_binary(value), do: String.to_charlist(value)
end
