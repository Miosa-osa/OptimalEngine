defmodule OptimalEngine.API.BootReadOnlyTest do
  @moduledoc """
  `GET /api/boot?generate=false` answers today's rhythm note without writing
  it, so a read-only reader leaves the store as it found it.
  """

  use ExUnit.Case, async: false

  import Plug.Test

  alias OptimalEngine.API.Router
  alias OptimalEngine.{Store, Workspace}

  defp boot(query) do
    response = Router.call(conn(:get, "/api/boot?" <> query), Router.init([]))
    {response.status, Jason.decode!(response.resp_body)}
  end

  defp notes(workspace_id) do
    {:ok, [[count]]} =
      Store.raw_query("SELECT COUNT(*) FROM rhythm_notes WHERE workspace_id = ?1", [workspace_id])

    count
  end

  test "generate=false reads the note without writing it" do
    n = System.unique_integer([:positive])
    {:ok, workspace} = Workspace.create(%{slug: "boot-read-#{n}", name: "Boot read"})
    query = URI.encode_query(%{workspace: workspace.id})

    assert {200, unwritten} = boot(query <> "&generate=false")
    assert unwritten["rhythm"]["stored"] == false
    assert unwritten["rhythm"]["period"] == unwritten["date"]
    assert unwritten["rhythm"]["content"] != ""
    assert notes(workspace.id) == 0

    assert {200, written} = boot(query)
    assert written["rhythm"]["stored"] == true
    assert notes(workspace.id) == 1

    assert {200, again} = boot(query <> "&generate=false")
    assert again["rhythm"]["stored"] == true
    assert notes(workspace.id) == 1
  end
end
