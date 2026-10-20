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
  @businessos_routes [
    {"POST", "/api/reindex"},
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
