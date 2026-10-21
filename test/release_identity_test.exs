defmodule OptimalEngine.ReleaseIdentityTest do
  @moduledoc """
  The release check (`scripts/check_release_version.exs`): every file that
  carries the version by hand carries the Engine's version, and the
  failing-migration test release can never be built under another version,
  released or promoted.
  """

  use ExUnit.Case, async: true

  alias OptimalEngine.ReleaseIdentity

  @root Path.expand("..", __DIR__)

  defp version, do: to_string(Mix.Project.config()[:version])

  test "every file of the checkout that carries the version carries the Engine version" do
    assert ReleaseIdentity.problems(@root, version(), %{}) == []
  end

  test "step 2 of creating a release names every file the check reads" do
    step2 =
      @root
      |> Path.join("docs/guides/versioning-and-releases.md")
      |> File.read!()
      |> String.split("\n")
      |> Enum.find(&String.starts_with?(&1, "2. Update `@version` in `mix.exs`"))

    assert step2

    for {file, what} <- ReleaseIdentity.version_files() do
      assert step2 =~ "`#{file}`", "step 2 does not name #{file}"
      what = what |> String.split(".") |> hd()
      assert step2 =~ what, "step 2 does not name #{what} in #{file}"
    end
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

    write.("engine-contract.json", ~s({"version": "9.9.1"}\n))
    write.("apps/cli/optimal", "#!/bin/sh\nOPTIMAL_CLI_VERSION=9.9.2\n")
    write.("apps/mcp/src/version.ts", ~s(export const MCP_VERSION = "9.9.3";\n))
    write.("apps/mcp/package.json", ~s({"name": "@optimal-engine/mcp", "version": "9.9.4"}\n))

    write.(
      "apps/mcp/package-lock.json",
      ~s({"version": "9.9.5", "packages": {"": {"version": "9.9.6"}}}\n)
    )

    write.("deploy/miosa-template/install-client.sh", "#!/bin/sh\nDEFAULT_VERSION=9.9.7\n")

    problems = ReleaseIdentity.problems(root, "1.2.3", %{})

    for {file, found} <- [
          {"engine-contract.json", "9.9.1"},
          {"apps/cli/optimal", "9.9.2"},
          {"apps/mcp/src/version.ts", "9.9.3"},
          {"apps/mcp/package.json", "9.9.4"},
          {"apps/mcp/package-lock.json", "9.9.5"},
          {"apps/mcp/package-lock.json", "9.9.6"},
          {"deploy/miosa-template/install-client.sh", "9.9.7"}
        ] do
      assert Enum.any?(problems, &(&1 =~ file and &1 =~ found)), inspect(problems)
    end

    assert length(problems) == length(ReleaseIdentity.version_files())
  end

  test "each build flag value builds only its exact test version" do
    ok = [
      {nil, "1.2.3"},
      {"", "1.2.3"},
      {"1", "1.2.3-failing-migration"},
      {"2", "1.2.3-passing-then-failing-migration"}
    ]

    for {flag, version} <- ok do
      assert ReleaseIdentity.failing_build_problem(flag, version) == nil, inspect({flag, version})
    end

    refused = [
      {"1", "1.2.3"},
      {"1", "1.2.3-passing-then-failing-migration"},
      {"1", "1.2.3-rc.1-failing-migration"},
      {"2", "1.2.3-failing-migration"},
      {"2", "1.2.3"},
      {"3", "1.2.3-failing-migration"}
    ]

    for {flag, version} <- refused do
      assert ReleaseIdentity.failing_build_problem(flag, version), inspect({flag, version})
    end
  end

  test "the release build script refuses the failing-migration build flag" do
    out = Path.join(System.tmp_dir!(), "build-release-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(out) end)
    script = Path.join(@root, "deploy/miosa-template/build-release.sh")
    env = [{"DRY_RUN", "1"}, {"ALLOW_NON_X86", "1"}]

    {output, status} =
      System.cmd("bash", [script, out],
        env: [{"OPTIMAL_BUILD_FAILING_MIGRATION", "1"} | env],
        stderr_to_stdout: true
      )

    assert status != 0
    assert output =~ "OPTIMAL_BUILD_FAILING_MIGRATION"
    refute output =~ "docker build"

    # Without it, the real build passes the flag to the image as empty.
    {output, 0} =
      System.cmd("bash", [script, out],
        env: [{"OPTIMAL_BUILD_FAILING_MIGRATION", nil} | env],
        stderr_to_stdout: true
      )

    assert output =~ "OPTIMAL_BUILD_FAILING_MIGRATION="
  end

  test "a version that is not SemVer is refused" do
    assert Enum.any?(ReleaseIdentity.problems(@root, "1.2", %{}), &(&1 =~ "not valid SemVer"))
  end
end
