defmodule OptimalEngine.API.ReferenceTest do
  @moduledoc """
  The public API reference is generated from the routers, so it cannot drift
  from the code without failing here, and every endpoint BusinessOS calls is
  in it.
  """

  use ExUnit.Case, async: true

  alias OptimalEngine.API.Reference

  @root Path.expand("../..", __DIR__)

  # Engine routes the BusinessOS client calls, by path: its optimal proxy
  # allowlist (desktop/backend-go/internal/handlers/optimal_proxy.go), its
  # typed client (internal/optimalengine/client.go), and the Engine fake its
  # tests run against (internal/optimalengine/enginetest). Kept equal to
  # scripts/proof_operating_layer.py.
  @businessos_routes [
    {"GET", "/api/health"},
    {"POST", "/api/memory"},
    {"GET", "/api/memory"},
    {"POST", "/api/memory/:id/forget"},
    {"POST", "/api/rag"},
    {"GET", "/api/recall/actions"},
    {"GET", "/api/recall/who"},
    {"GET", "/api/recall/when"},
    {"GET", "/api/recall/where"},
    {"GET", "/api/recall/owns"},
    {"GET", "/api/search"},
    {"GET", "/api/workspaces"},
    {"POST", "/api/workspaces"},
    {"GET", "/api/optimal/nodes"},
    {"GET", "/api/optimal/nodes/:slug/files"},
    {"POST", "/api/ingest"},
    {"GET", "/api/auth/whoami"}
  ]

  # Paths the proxy passes for any method, and the prefixes it passes.
  @businessos_paths ~w(/api/health /api/status /api/version /api/search /api/grep /api/graph
                       /api/rag /api/rag/stream /api/wiki /api/memory /api/assemble /api/boot
                       /api/brief /api/loops)
  @businessos_prefixes ~w(/api/memory/ /api/recall/ /api/wiki/ /api/graph/ /api/loops/)

  test "the checked-in reference matches the routers" do
    assert Reference.check(@root) == :ok,
           "run mix optimal.api.reference and commit docs/reference/api.md"
  end

  test "every endpoint BusinessOS calls is in the public reference" do
    documented =
      @root
      |> Reference.routes()
      |> MapSet.new(&{&1.method, &1.path})

    paths = MapSet.new(documented, &elem(&1, 1))

    missing =
      Enum.reject(@businessos_routes, &MapSet.member?(documented, &1)) ++
        Enum.reject(@businessos_paths, &MapSet.member?(paths, &1)) ++
        Enum.reject(@businessos_prefixes, fn prefix ->
          Enum.any?(paths, &String.starts_with?(&1, prefix))
        end)

    assert missing == [], "undocumented Engine endpoints called by BusinessOS: #{inspect(missing)}"
  end

  test "every documented route names its grant and its workspace scope" do
    rows =
      @root
      |> Reference.output_path()
      |> File.read!()
      |> String.split("\n")
      |> Enum.filter(&String.starts_with?(&1, "| "))
      # The header row and the separator row.
      |> Enum.drop(2)
      |> Enum.map(fn row -> row |> String.split("|") |> Enum.map(&String.trim/1) end)

    assert length(rows) > 200

    for ["", methods, path, _router, grant, workspace, ""] <- rows do
      assert grant != "", "#{methods} #{path} has no grant"
      assert workspace in ["workspace", "tenant"], "#{methods} #{path} has no workspace scope"
    end

    assert Enum.all?(rows, &(length(&1) == 7))
  end

  test "the classification is the one the plugs enforce" do
    assert Reference.classify("/api/memory-core/claims/:id/promote", ["POST"]) ==
             %{grant: "claims:review", workspace: "workspace"}

    assert Reference.classify("/api/auth/whoami", ["GET"]) ==
             %{grant: "any key", workspace: "tenant"}

    assert Reference.classify("/api/boot", ["GET"]) == %{grant: "read", workspace: "workspace"}

    assert Reference.classify("/api/topology/export", ["GET"]) ==
             %{grant: "admin", workspace: "tenant"}

    assert Reference.classify("/api/loops", ["GET", "POST"]) ==
             %{grant: "GET: read; POST: write", workspace: "workspace"}

    assert Reference.classify("/api/connectors/:id", ["GET", "PATCH", "DELETE"]).grant ==
             "GET: read; PATCH: connectors:write or admin; DELETE: connectors:write or admin"

    assert Reference.classify("/api/agent-actions", ["POST"]).grant ==
             "write; stages approval and denial: authority:enforce"

    assert Reference.classify("/api/workspaces", ["GET", "POST"]).workspace == "tenant"
    assert Reference.classify("/api/workspaces/:id", ["GET"]).workspace == "workspace"
  end

  test "the reference covers the forwarded app-data and authority routers" do
    routes = Reference.routes(@root)
    paths = Enum.map(routes, & &1.path)

    assert Enum.any?(paths, &String.starts_with?(&1, "/api/data/"))
    assert Enum.any?(paths, &String.starts_with?(&1, "/api/authority/"))
  end
end
