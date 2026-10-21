defmodule OptimalEngine.API.Exposure do
  @moduledoc """
  Whether the HTTP API is open to the network: it listens on an interface other
  than loopback while authentication is off, so it answers anyone who can reach
  it with the trusted local operator's rights.

  Such an Engine says so loudly: an error log line when it starts and every 10
  minutes after (`OptimalEngine.API.ExposureMonitor`), and the
  `auth_open_on_network` warning in `/api/health`. With
  `OPTIMAL_REFUSE_OPEN_NETWORK=1` it refuses to start instead. The refusal is
  off by default in this release and becomes the default in the next one.

  An Engine on `127.0.0.1` (or `::1`, or `localhost`) with authentication off is
  the trusted local mode and is never reported.
  """

  @doc """
  The interface the API is open on, or nil when it is not open: the API is
  disabled, authentication is required, or it listens on loopback only.
  """
  @spec open_interface(keyword(), keyword()) :: String.t() | nil
  def open_interface(
        api \\ Application.get_env(:optimal_engine, :api, []),
        auth \\ Application.get_env(:optimal_engine, :auth, [])
      ) do
    interface = Keyword.get(api, :interface, "127.0.0.1")

    if Keyword.get(api, :enabled, false) and not Keyword.get(auth, :auth_required, false) and
         not loopback?(interface),
       do: interface
  end

  @doc """
  True for an interface that only this machine can reach. An address the
  Endpoint cannot parse is bound as `127.0.0.1`, so it counts as loopback too.
  """
  @spec loopback?(String.t()) :: boolean()
  def loopback?("localhost"), do: true

  def loopback?(interface) when is_binary(interface) do
    case :inet.parse_address(String.to_charlist(interface)) do
      {:ok, {127, _, _, _}} -> true
      {:ok, {0, 0, 0, 0, 0, 0, 0, 1}} -> true
      {:ok, _other} -> false
      {:error, _} -> true
    end
  end

  @doc "The line an open Engine logs."
  @spec message(String.t()) :: String.t()
  def message(interface),
    do: "API is open: auth is off on #{interface}; set OPTIMAL_AUTH_REQUIRED=true"

  @doc """
  What to do at boot: `:ok` when the API is not open, `{:warn, interface}` when
  it is, and `{:refuse, message}` when it is and the refusal is turned on
  (`OPTIMAL_REFUSE_OPEN_NETWORK`, `config :optimal_engine, :refuse_open_network`).
  """
  @spec boot_check(keyword(), keyword(), boolean()) ::
          :ok | {:warn, String.t()} | {:refuse, String.t()}
  def boot_check(
        api \\ Application.get_env(:optimal_engine, :api, []),
        auth \\ Application.get_env(:optimal_engine, :auth, []),
        refuse? \\ Application.get_env(:optimal_engine, :refuse_open_network, false)
      ) do
    case open_interface(api, auth) do
      nil ->
        :ok

      interface when refuse? == true ->
        {:refuse,
         message(interface) <>
           ", or bind 127.0.0.1; refusing to start because OPTIMAL_REFUSE_OPEN_NETWORK is set"}

      interface ->
        {:warn, interface}
    end
  end
end
