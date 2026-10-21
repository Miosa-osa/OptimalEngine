version = Mix.Project.config() |> Keyword.fetch!(:version) |> to_string()

# SemVer, the client and MCP server versions, and never the failing-migration
# test release (OptimalEngine.ReleaseIdentity).
case OptimalEngine.ReleaseIdentity.problems(File.cwd!(), version, System.get_env()) do
  [] -> :ok
  problems -> Mix.raise("release check failed:\n  " <> Enum.join(problems, "\n  "))
end

case {System.get_env("GITHUB_REF_TYPE"), System.get_env("GITHUB_REF_NAME")} do
  {"tag", tag} when is_binary(tag) ->
    expected = "v#{version}"

    if tag != expected do
      Mix.raise("release tag #{tag} does not match application version #{expected}")
    end

    IO.puts("release identity valid: #{tag}")

  _ ->
    IO.puts("application version valid: #{version}")
end
