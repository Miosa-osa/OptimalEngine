defmodule OptimalEngine.API.SetupAPI do
  @moduledoc """
  Handlers for size profiles, usage gauges, and use-case presets, called
  from `OptimalEngine.API.Router`.

  | Route | Scope |
  | --- | --- |
  | `GET /api/storage` (profile, usage gauges, recommendation, boot time) | read |
  | `GET /api/storage/profiles` | read |
  | `GET /api/init/presets` | read |
  | `POST /api/init {for, slug, name}` | admin |
  """

  import Plug.Conn

  alias OptimalEngine.API.Actor
  alias OptimalEngine.{Presets, Sizing}

  def usage(conn), do: json(conn, 200, Sizing.usage())

  def profiles(conn),
    do: json(conn, 200, %{profiles: Sizing.profiles(), active: Sizing.profile().id})

  def presets(conn), do: json(conn, 200, %{presets: Presets.list()})

  def init(conn) do
    body =
      case conn.body_params do
        %{} = params when not is_struct(params) -> params
        _ -> %{}
      end

    opts =
      [slug: body["slug"], name: body["name"], actor: Actor.of(conn, body)]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    case Presets.apply_preset(conn.assigns[:current_tenant] || "default", body["for"] || "", opts) do
      {:ok, result} ->
        json(conn, 200, result)

      {:error, :unknown_preset} ->
        json(conn, 422, %{error: "unknown_preset", presets: Enum.map(Presets.list(), & &1.id)})

      {:error, reason} ->
        json(conn, 422, %{error: inspect(reason)})
    end
  end

  defp json(conn, status, data) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(data))
  end
end
