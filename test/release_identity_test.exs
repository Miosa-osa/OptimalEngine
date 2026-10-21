defmodule OptimalEngine.ReleaseIdentityTest do
  @moduledoc """
  The release check (`scripts/check_release_version.exs`): the clients carry
  the Engine's version, and the failing-migration test release can never be
  released or promoted.
  """

  use ExUnit.Case, async: true

  alias OptimalEngine.ReleaseIdentity

  @root Path.expand("..", __DIR__)

  defp version, do: to_string(Mix.Project.config()[:version])

  test "the checkout's clients carry the Engine version" do
    assert ReleaseIdentity.problems(@root, version(), %{}) == []
  end

  test "the failing-migration test release is refused, by version and by build flag" do
    for suffix <- ["-failing-migration", "-passing-then-failing-migration"] do
      problems = ReleaseIdentity.problems(@root, version() <> suffix, %{})
      assert Enum.any?(problems, &(&1 =~ "failing-migration test release")), inspect(problems)
    end

    for value <- ["1", "2", "yes"] do
      problems =
        ReleaseIdentity.problems(@root, version(), %{"OPTIMAL_BUILD_FAILING_MIGRATION" => value})

      assert Enum.any?(problems, &(&1 =~ "OPTIMAL_BUILD_FAILING_MIGRATION is set")),
             inspect(problems)
    end

    assert ReleaseIdentity.problems(@root, version(), %{"OPTIMAL_BUILD_FAILING_MIGRATION" => ""}) ==
             []
  end

  test "a client that carries another version is named" do
    root = Path.join(System.tmp_dir!(), "release-identity-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)

    write = fn relative, content ->
      path = Path.join(root, relative)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, content)
    end

    write.("apps/cli/optimal", "#!/bin/sh\nOPTIMAL_CLI_VERSION=9.9.9\n")
    write.("apps/mcp/src/version.ts", ~s(export const MCP_VERSION = "9.9.8";\n))
    write.("apps/mcp/package.json", ~s({"name": "@optimal-engine/mcp", "version": "9.9.7"}\n))

    problems = ReleaseIdentity.problems(root, "1.2.3", %{})

    for {file, found} <- [
          {"apps/cli/optimal", "9.9.9"},
          {"apps/mcp/src/version.ts", "9.9.8"},
          {"apps/mcp/package.json", "9.9.7"}
        ] do
      assert Enum.any?(problems, &(&1 =~ file and &1 =~ found)), inspect(problems)
    end
  end

  test "a version that is not SemVer is refused" do
    assert Enum.any?(ReleaseIdentity.problems(@root, "1.2", %{}), &(&1 =~ "not valid SemVer"))
  end
end
