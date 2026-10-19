defmodule OptimalEngine.API.ClientCompatibilityPlug do
  @moduledoc """
  Refuses, or warns about, an Engine client that does not match this Engine.

  The client sends `User-Agent: optimal-cli/<version>` (and the MCP server the
  same shape with its own name). This plug compares its major.minor with the
  Engine's own application version:

    * a different **major** is refused with `426 Upgrade Required` and a JSON
      body naming both versions, because a major release may remove or change
      a contract the client relies on;
    * a different **minor** is allowed and marked with
      `x-optimal-client-outdated: client=<v> engine=<v>`, so a client can warn
      without being locked out mid-task;
    * a patch difference is silent, and a request with no recognizable client
      header is untouched.

  `GET /api/version`, `/api/health` and `/api/status` are exempt: an outdated
  client must still be able to discover why it was refused.

  This is release compatibility, not authentication: the request still goes
  through the normal key and authority checks after this plug.
  """

  @behaviour Plug

  import Plug.Conn

  @exempt_paths ["/api/version", "/api/health", "/api/status"]
  @client_pattern ~r{\A(optimal-cli|optimal-mcp|optimal)/(\d+)\.(\d+)\.(\d+)}

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    with false <- exempt_path?(conn.request_path),
         [user_agent | _rest] <- get_req_header(conn, "user-agent"),
         {:ok, client} <- parse_client(user_agent),
         {:ok, engine} <- parse_version(OptimalEngine.Version.application_version()) do
      compare(conn, client, engine)
    else
      _other -> conn
    end
  end

  defp exempt_path?(path) when is_binary(path) do
    path in @exempt_paths or String.starts_with?(path, "/api/version?")
  end

  defp parse_client(user_agent) when is_binary(user_agent) do
    case Regex.run(@client_pattern, user_agent) do
      [_, name, major, minor, patch] ->
        {:ok,
         %{
           name: name,
           raw: "#{name}/#{major}.#{minor}.#{patch}",
           version: "#{major}.#{minor}.#{patch}",
           major: String.to_integer(major),
           minor: String.to_integer(minor)
         }}

      _other ->
        :error
    end
  end

  defp parse_version(version) when is_binary(version) do
    case Regex.run(~r{\A(\d+)\.(\d+)\.(\d+)}, version) do
      [_, major, minor, _patch] ->
        {:ok, %{version: version, major: String.to_integer(major), minor: String.to_integer(minor)}}

      _other ->
        :error
    end
  end

  defp compare(conn, client, engine) do
    cond do
      client.major != engine.major ->
        refuse(conn, client, engine)

      client.minor != engine.minor ->
        put_resp_header(
          conn,
          "x-optimal-client-outdated",
          "client=#{client.version} engine=#{engine.version}"
        )

      true ->
        conn
    end
  end

  defp refuse(conn, client, engine) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(
      426,
      Jason.encode!(%{
        error: "client_incompatible",
        message:
          "This client (#{client.raw}) is not compatible with this Engine (#{engine.version}); " <>
            "upgrade the client to a #{engine.major}.x release.",
        client: client.raw,
        engine: engine.version,
        required: "major:#{engine.major}"
      })
    )
    |> halt()
  end
end
