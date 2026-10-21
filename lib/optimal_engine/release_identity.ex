defmodule OptimalEngine.ReleaseIdentity do
  @moduledoc """
  The checks a release must pass before it is tagged or promoted
  (`scripts/check_release_version.exs`, run by CI and by step 3 of
  docs/guides/versioning-and-releases.md).

  The version is valid SemVer; every file that carries the version by hand
  carries the same one (`version_files/0`: the Engine contract, the client CLI,
  the MCP server and its lockfile, and the client installer's default); and the
  build is not the failing-migration test release of the upgrade rollback drill
  (`OptimalEngine.Store.FailingMigration`), by its version suffix or by the
  build flag that makes it.
  """

  @failing_suffix "-failing-migration"
  @failing_flag "OPTIMAL_BUILD_FAILING_MIGRATION"
  @failing_variants %{"1" => "-failing-migration", "2" => "-passing-then-failing-migration"}

  @doc """
  What stops `version`, built from the checkout at `root` with environment
  `env`, from being released: an empty list when nothing does.
  """
  @spec problems(Path.t(), String.t(), %{optional(String.t()) => String.t()}) :: [String.t()]
  def problems(root, version, env) do
    [
      semver(version),
      failing_release(version),
      failing_flag(env)
      | Enum.map(found_versions(root), &carried(&1, version))
    ]
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  The files that carry the release version by hand, as
  `{file, what in it carries the version}`; step 2 of "Creating a release"
  (docs/guides/versioning-and-releases.md) names the same list.
  """
  @spec version_files() :: [{String.t(), String.t()}]
  def version_files, do: Enum.map(version_readers(), fn {file, what, _read} -> {file, what} end)

  @doc """
  Why a build with `OPTIMAL_BUILD_FAILING_MIGRATION=flag` cannot carry
  `version`, or nil when it can. Each flag value builds exactly `<x.y.z>` and
  its variant's suffix; an empty or absent flag builds no test release.
  `OptimalEngine.Store.FailingMigration` stops compilation on a problem.
  """
  @spec failing_build_problem(String.t() | nil, String.t()) :: String.t() | nil
  def failing_build_problem(flag, _version) when flag in [nil, ""], do: nil

  def failing_build_problem(flag, version) do
    case Map.fetch(@failing_variants, flag) do
      {:ok, suffix} ->
        base = String.replace_suffix(version, suffix, "")

        unless String.ends_with?(version, suffix) and Regex.match?(~r/^\d+\.\d+\.\d+$/, base) do
          "#{@failing_flag}=#{flag} builds a test release whose migrations fail on purpose; " <>
            "its version must be <x.y.z>#{suffix}, and #{version} is not"
        end

      :error ->
        "#{@failing_flag}=#{flag} is not 1 or 2"
    end
  end

  defp semver(version) do
    unless Regex.match?(~r/^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/, version),
      do: "mix.exs version is not valid SemVer: #{version}"
  end

  defp failing_release(version) do
    if String.ends_with?(version, @failing_suffix),
      do:
        "#{version} is the failing-migration test release; it exists for the upgrade rollback drill and is never released or promoted"
  end

  defp failing_flag(env) do
    if Map.get(env, @failing_flag, "") != "",
      do:
        "#{@failing_flag} is set; it builds the failing-migration test release, which is never released"
  end

  defp carried({file, what, found}, version) do
    cond do
      found == nil -> "#{file}: no #{what} found"
      found != version -> "#{file} carries #{found} in #{what}, not #{version}"
      true -> nil
    end
  end

  # {file, what carries the version, how to read it from the file's text}
  defp version_readers do
    [
      {"engine-contract.json", "version", &json_at(&1, ["version"])},
      {"apps/cli/optimal", "OPTIMAL_CLI_VERSION", &matched(&1, ~r/^OPTIMAL_CLI_VERSION=(\S+)$/m)},
      {"apps/mcp/src/version.ts", "MCP_VERSION",
       &matched(&1, ~r/^export const MCP_VERSION = "([^"]+)";$/m)},
      {"apps/mcp/package.json", "version", &json_at(&1, ["version"])},
      {"apps/mcp/package-lock.json", "version", &json_at(&1, ["version"])},
      {"apps/mcp/package-lock.json", ~s(packages."".version),
       &json_at(&1, ["packages", "", "version"])},
      {"deploy/miosa-template/install-client.sh", "DEFAULT_VERSION",
       &matched(&1, ~r/^DEFAULT_VERSION=(\S+)$/m)}
    ]
  end

  # {file, what, the version found, or nil}
  defp found_versions(root) do
    Enum.map(version_readers(), fn {file, what, read} ->
      found =
        case File.read(Path.join(root, file)) do
          {:ok, text} -> read.(text)
          {:error, _reason} -> nil
        end

      {file, what, found}
    end)
  end

  defp matched(text, pattern) do
    case Regex.run(pattern, text) do
      [_, value] -> value
      _ -> nil
    end
  end

  defp json_at(text, path) do
    with {:ok, decoded} <- Jason.decode(text),
         version when is_binary(version) <- get_in(decoded, path) do
      version
    else
      _ -> nil
    end
  end
end
