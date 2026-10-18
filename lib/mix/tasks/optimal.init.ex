defmodule Mix.Tasks.Optimal.Init do
  @shortdoc "Sets an Engine up for its use: agent, workspace, business, app, tenant-per-customer"

  @moduledoc """
  Applies a use-case preset on the local Engine store (`OptimalEngine.Presets`).

  ## Usage

      mix optimal.init --for agent|workspace|business|app|tenant-per-customer [--slug ops --name Ops] [--tenant default]
      mix optimal.init --list

  Prints what was applied, what was kept, the size profile, and the
  environment to set for the deployment. The same is `POST /api/init`.
  """

  use Mix.Task

  alias OptimalEngine.Presets

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _rest, _} =
      OptionParser.parse(args,
        strict: [for: :string, slug: :string, name: :string, tenant: :string, list: :boolean],
        aliases: [t: :tenant]
      )

    cond do
      opts[:list] ->
        print(%{
          presets:
            Enum.map(Presets.list(), &Map.take(&1, [:id, :label, :profile, :scope, :summary]))
        })

      opts[:for] ->
        preset_opts =
          [slug: opts[:slug], name: opts[:name], actor: "local:operator"]
          |> Enum.reject(fn {_key, value} -> is_nil(value) end)

        case Presets.apply_preset(opts[:tenant] || "default", opts[:for], preset_opts) do
          {:ok, result} -> print(result)
          {:error, reason} -> Mix.raise("init failed: #{inspect(reason)}")
        end

      true ->
        Mix.shell().info(@moduledoc)
    end
  end

  defp print(data), do: Mix.shell().info(Jason.encode!(data, pretty: true))
end
