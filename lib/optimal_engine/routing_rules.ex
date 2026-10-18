defmodule OptimalEngine.RoutingRules do
  @moduledoc """
  Deployment-specific routing vocabulary, kept out of the Engine's code.

  Which client, project, or person names route a record to which workspace
  or node is data about one deployment, so it lives in a file the operator
  owns. The file path comes from `config :optimal_engine,
  :corpus_routing_rules_path` (env `OPTIMAL_CORPUS_RULES`); YAML or JSON:

      rules:                      # CorpusOrganizer: target workspace => markers
        default:example-client:
          - {marker: "example client", weight: 10}
      intent_node_keywords:       # IntentAnalyzer: query keyword => node id
        example client: operation-delivery

  The parsed file is cached until its modification time changes. A missing
  or unreadable file yields an empty map, so an Engine with no rules simply
  routes nothing by name.
  """

  @cache_key {__MODULE__, :file}

  @doc "The parsed routing rules file, or `%{}` when none is configured."
  @spec load() :: map()
  def load do
    case Application.get_env(:optimal_engine, :corpus_routing_rules_path) do
      path when is_binary(path) and path != "" -> cached(path)
      _ -> %{}
    end
  end

  @doc "One section of the routing rules file (for example `\"rules\"`)."
  @spec section(String.t()) :: map()
  def section(name) when is_binary(name) do
    case Map.get(load(), name) do
      %{} = section -> section
      _ -> %{}
    end
  end

  defp cached(path) do
    mtime =
      case File.stat(path, time: :posix) do
        {:ok, %{mtime: mtime}} -> mtime
        _ -> nil
      end

    case :persistent_term.get(@cache_key, nil) do
      {^path, ^mtime, parsed} ->
        parsed

      _ ->
        parsed = read(path)
        :persistent_term.put(@cache_key, {path, mtime, parsed})
        parsed
    end
  end

  defp read(path) do
    with {:ok, content} <- File.read(path),
         {:ok, %{} = parsed} <- parse(path, content) do
      parsed
    else
      _ -> %{}
    end
  end

  defp parse(path, content) do
    if String.ends_with?(path, ".json"),
      do: Jason.decode(content),
      else: YamlElixir.read_from_string(content)
  end
end
