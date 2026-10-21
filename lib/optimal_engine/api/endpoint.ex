defmodule OptimalEngine.API.Endpoint do
  @moduledoc """
  HTTP server that mounts the JSON API.

  Not started by default — operators opt in by setting
  `config :optimal_engine, :api,
     enabled: true, port: 4200, interface: "127.0.0.1"`

  Bind beyond loopback (`0.0.0.0`) only with `OPTIMAL_AUTH_REQUIRED=true`;
  cross-host traffic should also be TLS-terminated by a proxy in front. An API
  on a network interface with authentication off is reported loudly, or
  refused with `OPTIMAL_REFUSE_OPEN_NETWORK=1`; an operator whose proxy
  authenticates every request says so with
  `OPTIMAL_OPEN_NETWORK_ACKNOWLEDGED=1` (`OptimalEngine.API.Exposure`). A
  loopback Engine published by a proxy, tunnel or port map is not detected
  and needs `OPTIMAL_AUTH_REQUIRED=true` too.

  See `OptimalEngine.API.Router` for the endpoint list.
  """

  require Logger

  @default_port 4200
  @default_interface "127.0.0.1"

  @doc """
  Return the child spec(s) to include in `OptimalEngine.Application`'s
  supervision tree. When the API is disabled, returns an empty list
  so the supervisor gets nothing at all — cleaner than a noop child.
  """
  @spec children() :: [Supervisor.child_spec() | {module(), any()}]
  def children do
    config = Application.get_env(:optimal_engine, :api, [])

    if Keyword.get(config, :enabled, false) do
      port = Keyword.get(config, :port, @default_port)
      interface = Keyword.get(config, :interface, @default_interface)

      Logger.info("[API] Starting HTTP server on #{interface}:#{port}")

      [
        {Plug.Cowboy,
         scheme: :http,
         plug: OptimalEngine.API.Router,
         options: [
           port: port,
           ip: parse_ip(interface),
           protocol_options: [idle_timeout: 180_000]
         ]}
      ] ++ exposure_children()
    else
      []
    end
  end

  # Authentication off on a network interface (OptimalEngine.API.Exposure): an
  # error at start and every 10 minutes, one line when it is acknowledged, or no
  # start at all when the refusal is on.
  defp exposure_children do
    case OptimalEngine.API.Exposure.boot_check() do
      :ok ->
        []

      # The watcher logs the error when it starts, so the line also reaches the
      # recent log (GET /api/maintenance/log), which is not running yet here.
      {:warn, interface} ->
        [{OptimalEngine.API.ExposureMonitor, interface: interface}]

      {:acknowledged, interface} ->
        Logger.info(OptimalEngine.API.Exposure.acknowledged_message(interface))
        []

      {:refuse, message} ->
        raise ArgumentError, message
    end
  end

  defp parse_ip(interface) when is_binary(interface) do
    case :inet.parse_address(String.to_charlist(interface)) do
      {:ok, ip} -> ip
      _ -> {127, 0, 0, 1}
    end
  end
end
