defmodule OptimalEngine.API.ReferenceTest do
  @moduledoc """
  The public API reference is generated from the routers, so it cannot drift
  from the code without failing here, and every endpoint BusinessOS calls is
  in it.
  """

  use ExUnit.Case, async: true

  alias OptimalEngine.API.Reference

  @root Path.expand("../..", __DIR__)

  # Endpoints BusinessOS calls today, from the 2026-10-19 audit:
  # desktop/backend-go/internal/optimalengine/client.go,
  # internal/services/engine_sync.go, and desktop/src/main/ipc/index.ts.
  # POST /api/reindex is added by the companion route change and joins this
  # list when that lands.
  @businessos_routes [
    {"GET", "/api/health"},
    {"POST", "/api/memory"},
    {"GET", "/api/memory"},
    {"POST", "/api/memory/:id/forget"},
    {"POST", "/api/memory/remember"},
    {"POST", "/api/rag"},
    {"GET", "/api/recall/actions"},
    {"GET", "/api/recall/who"},
    {"GET", "/api/recall/when"},
    {"GET", "/api/recall/where"},
    {"GET", "/api/recall/owns"},
    {"GET", "/api/workspaces"},
    {"POST", "/api/workspaces"},
    {"GET", "/api/search"},
    {"GET", "/api/graph"},
    {"GET", "/api/grep"},
    {"GET", "/api/wiki"}
  ]

  test "the checked-in reference matches the routers" do
    assert Reference.check(@root) == :ok,
           "run mix optimal.api.reference and commit docs/reference/api.md"
  end

  test "every endpoint BusinessOS calls is in the public reference" do
    documented =
      @root
      |> Reference.routes()
      |> MapSet.new(&{&1.method, &1.path})

    missing = Enum.reject(@businessos_routes, &MapSet.member?(documented, &1))

    assert missing == [], "undocumented Engine endpoints called by BusinessOS: #{inspect(missing)}"
  end

  test "the reference covers the forwarded app-data and authority routers" do
    routes = Reference.routes(@root)
    paths = Enum.map(routes, & &1.path)

    assert Enum.any?(paths, &String.starts_with?(&1, "/api/data/"))
    assert Enum.any?(paths, &String.starts_with?(&1, "/api/authority/"))
  end
end
