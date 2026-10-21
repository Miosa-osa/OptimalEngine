defmodule OptimalEngine.API.Endpoint do
  @moduledoc """
  HTTP server that mounts the JSON API.

  Not started by default — operators opt in by setting
  `config :optimal_engine, :api,
     enabled: true, port: 4200, interface: "127.0.0.1"`

  Bind to `0.0.0.0` only when a reverse proxy is in front. The engine
  assumes localhost + same-host clients in dev; cross-host traffic
  should be authenticated + TLS-terminated by the upstream. An API on a
  network interface with authentication off is reported loudly, or refused
  with `OPTIMAL_REFUSE_OPEN_NETWORK=1` (`OptimalEngine.API.Exposure`).

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
  # error now and every 10 minutes, or no start at all when the refusal is on.
  defp exposure_children do
    case OptimalEngine.API.Exposure.boot_check() do
      :ok ->
        []

      {:warn, interface} ->
        Logger.error(OptimalEngine.API.Exposure.message(interface))
        [{OptimalEngine.API.ExposureMonitor, interface: interface}]

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
