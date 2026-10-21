defmodule OptimalEngine.ReleaseIdentity do
  @moduledoc """
  The checks a release must pass before it is tagged or promoted
  (`scripts/check_release_version.exs`, run by CI and by step 3 of
  docs/guides/versioning-and-releases.md).

  The version is valid SemVer; the client CLI (`OPTIMAL_CLI_VERSION` in
  `apps/cli/optimal`) and the MCP server (`MCP_VERSION` in
  `apps/mcp/src/version.ts` and `version` in `apps/mcp/package.json`) carry the
  same version; and the build is not the failing-migration test release of the
  upgrade rollback drill (`OptimalEngine.Store.FailingMigration`), by its
  version suffix or by the build flag that makes it.
  """

  @failing_suffix "-failing-migration"
  @failing_flag "OPTIMAL_BUILD_FAILING_MIGRATION"

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
      | Enum.map(client_versions(root), &client(&1, version))
    ]
    |> Enum.reject(&is_nil/1)
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

  defp client({file, found}, version) do
    cond do
      found == nil -> "#{file}: no version found"
      found != version -> "#{file} carries #{found}, not #{version}"
      true -> nil
    end
  end

  # {file, version found in it, or nil}
  defp client_versions(root) do
    [
      {"apps/cli/optimal", &matched(&1, ~r/^OPTIMAL_CLI_VERSION=(\S+)$/m)},
      {"apps/mcp/src/version.ts", &matched(&1, ~r/^export const MCP_VERSION = "([^"]+)";$/m)},
      {"apps/mcp/package.json", &package_version/1}
    ]
    |> Enum.map(fn {file, read} ->
      found =
        case File.read(Path.join(root, file)) do
          {:ok, text} -> read.(text)
          {:error, _reason} -> nil
        end

      {file, found}
    end)
  end

  defp matched(text, pattern) do
    case Regex.run(pattern, text) do
      [_, value] -> value
      _ -> nil
    end
  end

  defp package_version(text) do
    case Jason.decode(text) do
      {:ok, %{"version" => version}} when is_binary(version) -> version
      _ -> nil
    end
  end
end
