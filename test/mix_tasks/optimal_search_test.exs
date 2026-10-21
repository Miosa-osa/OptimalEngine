defmodule Mix.Tasks.OptimalSearchTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias OptimalEngine.{Context, Store}

  defp workspace_id(label) do
    "mix-search-#{label}-#{System.unique_integer([:positive])}"
  end

  test "search forwards workspace scope to retrieval" do
    Mix.Task.run("app.start")

    workspace_a = workspace_id("a")
    workspace_b = workspace_id("b")
    token = "scopedneedle#{System.unique_integer([:positive])}"
    now = DateTime.utc_now()

    :ok =
      Store.insert_context(%Context{
        id: "ctx-a-#{System.unique_integer([:positive])}",
        uri: "optimal://nodes/a/#{token}",
        type: :memory,
        path: "a.md",
        title: "Workspace A #{token}",
        content: "#{token} belongs to workspace A only",
        l0_abstract: "#{token} A",
        l1_overview: "#{token} A overview",
        node: "inbox",
        created_at: now,
        modified_at: now,
        workspace_id: workspace_a
      })

    :ok =
      Store.insert_context(%Context{
        id: "ctx-b-#{System.unique_integer([:positive])}",
        uri: "optimal://nodes/b/#{token}",
        type: :memory,
        path: "b.md",
        title: "Workspace B #{token}",
        content: "#{token} belongs to workspace B only",
        l0_abstract: "#{token} B",
        l1_overview: "#{token} B overview",
        node: "inbox",
        created_at: now,
        modified_at: now,
        workspace_id: workspace_b
      })

    Mix.Task.reenable("optimal.search")

    output =
      capture_io(fn ->
        Mix.Tasks.Optimal.Search.run([token, "--workspace", workspace_b, "--limit", "10"])
      end)

    assert output =~ "Workspace:   #{workspace_b}"
    assert output =~ "Workspace B #{token}"
    refute output =~ "Workspace A #{token}"
  end

  describe "--as-of and --mode" do
    setup do
      Mix.Task.run("app.start")
      workspace = workspace_id("modes")
      token = "modesneedle#{System.unique_integer([:positive])}"
      now = DateTime.utc_now()

      :ok =
        Store.insert_context(%Context{
          id: "ctx-modes-#{System.unique_integer([:positive])}",
          uri: "optimal://nodes/modes/#{token}",
          type: :memory,
          path: "modes.md",
          title: "Modes #{token}",
          content: "#{token} belongs to the modes workspace",
          l0_abstract: "#{token}",
          l1_overview: "#{token} overview",
          node: "inbox",
          created_at: now,
          modified_at: now,
          workspace_id: workspace
        })

      {:ok, workspace: workspace, token: token}
    end

    defp run_search(args) do
      Mix.Task.reenable("optimal.search")
      capture_io(fn -> Mix.Tasks.Optimal.Search.run(args) end)
    end

    test "search at a given instant in a pinned mode finds the context", ctx do
      output =
        run_search([
          ctx.token,
          "--workspace",
          ctx.workspace,
          "--as-of",
          "2026-10-20T12:00:00Z",
          "--mode",
          "lexical"
        ])

      assert output =~ "Modes #{ctx.token}"
    end

    test "an --as-of that is not valid is reported, not swallowed", ctx do
      output = run_search([ctx.token, "--workspace", ctx.workspace, "--as-of", "yesterday"])
      assert output =~ "invalid_as_of"
      refute output =~ "Modes #{ctx.token}"
    end

    test "a --mode that is not known is ignored with a warning", ctx do
      output = run_search([ctx.token, "--workspace", ctx.workspace, "--mode", "psychic"])
      assert output =~ "unknown mode 'psychic'"
      assert output =~ "Modes #{ctx.token}"
    end
  end
end
