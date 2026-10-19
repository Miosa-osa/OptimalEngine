defmodule Mix.Tasks.Optimal.Api.Reference do
  @shortdoc "Render docs/reference/api.md from the routers, or check it for drift"
  @moduledoc """
  Writes the public API reference from the route definitions.

      mix optimal.api.reference           # rewrite docs/reference/api.md
      mix optimal.api.reference --check   # exit 1 when the file is stale

  The reference is generated, never hand-edited: see
  `OptimalEngine.API.Reference`. Conformance runs the same check, so a route
  that ships without a reference update fails the release gate.
  """

  use Mix.Task

  alias OptimalEngine.API.Reference

  @impl Mix.Task
  def run(args) do
    {opts, _argv, _invalid} = OptionParser.parse(args, strict: [check: :boolean])
    root = root()

    if Keyword.get(opts, :check, false) do
      check(root)
    else
      write(root)
    end
  end

  defp write(root) do
    path = Reference.output_path(root)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Reference.render(root))

    Mix.shell().info(
      "wrote #{Path.relative_to_cwd(path)} (#{length(Reference.routes(root))} routes)"
    )
  end

  defp check(root) do
    case Reference.check(root) do
      :ok ->
        Mix.shell().info("api reference is current (#{length(Reference.routes(root))} routes)")

      {:drift, drift} ->
        Mix.shell().error(
          "api reference is stale: #{drift.documented} documented, #{drift.actual} served"
        )

        Enum.each(Enum.take(drift.missing, 20), fn route ->
          Mix.shell().error("  missing from the document: #{route.method} #{route.path}")
        end)

        Enum.each(Enum.take(drift.extra, 20), fn route ->
          Mix.shell().error("  documented but not served: #{route.method} #{route.path}")
        end)

        Mix.shell().error("run mix optimal.api.reference and commit docs/reference/api.md")
        exit({:shutdown, 1})
    end
  end

  defp root do
    if Code.ensure_loaded?(Mix.Project) and Mix.Project.get() do
      Mix.Project.project_file() |> Path.dirname()
    else
      File.cwd!()
    end
  end
end
