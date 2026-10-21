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
  the trusted local mode and is never reported. Only the interface the Engine
  binds is seen: a loopback Engine published to the network by a reverse
  proxy, a tunnel or a port map is not detected, and needs
  `OPTIMAL_AUTH_REQUIRED=true` like any other.

  An operator who opens the API on purpose, with authentication done in front
  of it (an authenticating proxy), says so with
  `OPTIMAL_OPEN_NETWORK_ACKNOWLEDGED=1`
  (`config :optimal_engine, :open_network_acknowledged`). Such an Engine logs
  one line at boot naming the interface and the setting, and is neither
  warned about again, degraded in `/api/health`, nor refused.
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

  @doc """
  The interface the API is open on and nobody acknowledged, or nil: what
  `/api/health` reports as `auth_open_on_network`.
  """
  @spec unacknowledged_interface() :: String.t() | nil
  def unacknowledged_interface do
    if acknowledged?(), do: nil, else: open_interface()
  end

  @doc "True when `OPTIMAL_OPEN_NETWORK_ACKNOWLEDGED` says the API is open on purpose."
  @spec acknowledged?() :: boolean()
  def acknowledged?,
    do: Application.get_env(:optimal_engine, :open_network_acknowledged, false) == true

  @doc "The line an open Engine logs."
  @spec message(String.t()) :: String.t()
  def message(interface),
    do: "API is open: auth is off on #{interface}; set OPTIMAL_AUTH_REQUIRED=true"

  @doc "The line an Engine open on purpose logs once at boot."
  @spec acknowledged_message(String.t()) :: String.t()
  def acknowledged_message(interface) do
    "API listens on #{interface} with auth off, acknowledged by OPTIMAL_OPEN_NETWORK_ACKNOWLEDGED: " <>
      "every request must be authenticated in front of the Engine"
  end

  @doc """
  What to do at boot: `:ok` when the API is not open, `{:acknowledged,
  interface}` when it is open on purpose (`OPTIMAL_OPEN_NETWORK_ACKNOWLEDGED`),
  `{:warn, interface}` when it is open, and `{:refuse, message}` when it is
  open and the refusal is turned on (`OPTIMAL_REFUSE_OPEN_NETWORK`,
  `config :optimal_engine, :refuse_open_network`).
  """
  @spec boot_check(keyword(), keyword(), boolean(), boolean()) ::
          :ok | {:acknowledged, String.t()} | {:warn, String.t()} | {:refuse, String.t()}
  def boot_check(
        api \\ Application.get_env(:optimal_engine, :api, []),
        auth \\ Application.get_env(:optimal_engine, :auth, []),
        refuse? \\ Application.get_env(:optimal_engine, :refuse_open_network, false),
        acknowledged \\ acknowledged?()
      ) do
    case open_interface(api, auth) do
      nil ->
        :ok

      interface when acknowledged == true ->
        {:acknowledged, interface}

      interface when refuse? == true ->
        {:refuse,
         message(interface) <>
           ", or bind 127.0.0.1; refusing to start because OPTIMAL_REFUSE_OPEN_NETWORK is set"}

      interface ->
        {:warn, interface}
    end
  end
end
