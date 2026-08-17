version = Mix.Project.config() |> Keyword.fetch!(:version) |> to_string()

unless Regex.match?(~r/^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/, version) do
  Mix.raise("mix.exs version is not valid SemVer: #{version}")
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
