defmodule OptimalEngine.API.BootReadOnlyTest do
  @moduledoc """
  `GET /api/boot` and `GET /api/rhythm/current` write today's rhythm note
  the first time they are asked, for a caller who may write. `generate=false`
  (or `0`) reads it without writing, and a key that holds only `read` never
  writes, whatever it asks.
  """

  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias OptimalEngine.API.Router
  alias OptimalEngine.Auth.ApiKey
  alias OptimalEngine.Identity.Principal
  alias OptimalEngine.{Store, Workspace}

  defp get(path, token) do
    connection = conn(:get, path)

    connection =
      if token,
        do: put_req_header(connection, "authorization", "Bearer " <> token),
        else: connection

    response = Router.call(connection, Router.init([]))
    {response.status, Jason.decode!(response.resp_body)}
  end

  defp boot(query, token \\ nil), do: get("/api/boot?" <> query, token)
  defp rhythm(query, token \\ nil), do: get("/api/rhythm/current?" <> query, token)

  defp notes(workspace_id) do
    {:ok, [[count]]} =
      Store.raw_query("SELECT COUNT(*) FROM rhythm_notes WHERE workspace_id = ?1", [workspace_id])

    count
  end

  defp workspace(prefix) do
    n = System.unique_integer([:positive])
    {:ok, workspace} = Workspace.create(%{slug: "#{prefix}-#{n}", name: "Boot #{n}"})
    {workspace, URI.encode_query(%{workspace: workspace.id})}
  end

  defp key(workspace, scopes) do
    principal = "user:boot-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Principal.upsert(%{id: principal, tenant_id: "default", kind: :user, display_name: principal})

    {:ok, %{key: key}} =
      ApiKey.mint(%{
        tenant_id: "default",
        name: "boot",
        scopes: scopes,
        workspace_scope: [workspace.id],
        principal_id: principal
      })

    key
  end

  test "generate=false reads the note without writing it" do
    {workspace, query} = workspace("boot-read")

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

  test "generate=0 and generate=false both read without writing, on both routes" do
    {workspace, query} = workspace("boot-zero")

    for value <- ["0", "false"] do
      assert {200, body} = boot(query <> "&generate=#{value}")
      assert body["rhythm"]["stored"] == false

      assert {200, note} = rhythm(query <> "&generate=#{value}")
      assert note["stored"] == false
    end

    assert notes(workspace.id) == 0

    # Anything else, or nothing, generates.
    assert {200, note} = rhythm(query <> "&generate=1")
    assert note["stored"] == true
    assert notes(workspace.id) == 1
  end

  test "a read key never writes the note, even when it asks to generate" do
    {workspace, query} = workspace("boot-key")
    reader = key(workspace, ["read"])

    for extra <- ["", "&generate=true", "&generate=1"] do
      assert {200, body} = boot(query <> extra, reader)
      assert body["rhythm"]["stored"] == false
      assert body["rhythm"]["content"] != ""

      assert {200, note} = rhythm(query <> extra, reader)
      assert note["stored"] == false
    end

    assert notes(workspace.id) == 0

    # A key that holds write generates, as before.
    writer = key(workspace, ["read", "write"])
    assert {200, body} = boot(query, writer)
    assert body["rhythm"]["stored"] == true
    assert notes(workspace.id) == 1

    # And the read key then reads what was written.
    assert {200, body} = boot(query, reader)
    assert body["rhythm"]["stored"] == true
    assert notes(workspace.id) == 1
  end

  test "an unrestricted key generates; a write key can still ask not to" do
    {workspace, query} = workspace("boot-star")
    unrestricted = key(workspace, ["*"])
    writer = key(workspace, ["read", "write"])

    assert {200, body} = boot(query <> "&generate=false", writer)
    assert body["rhythm"]["stored"] == false
    assert notes(workspace.id) == 0

    assert {200, body} = boot(query, unrestricted)
    assert body["rhythm"]["stored"] == true
    assert notes(workspace.id) == 1
  end
end
