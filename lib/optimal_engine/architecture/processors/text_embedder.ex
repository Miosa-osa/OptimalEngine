defmodule OptimalEngine.Architecture.Processors.TextEmbedder do
  @moduledoc """
  Text embedding processor: wraps the Engine's text embedder
  (`OptimalEngine.Embed.Text`) under the generic Processor contract.

  Emits: `:embedding` with a 768-d vector (aligned with the engine's
  multi-modal space).
  """

  @behaviour OptimalEngine.Architecture.Processor

  alias OptimalEngine.Embed

  @impl true
  def id, do: :text_embedder

  @impl true
  def modality, do: :text

  @impl true
  def emits, do: [:embedding]

  @impl true
  def init(_config), do: {:ok, %{}}

  @impl true
  def process(_field, value, _state) when is_binary(value) do
    case Embed.Text.embed(value, model: "nomic-embed-text") do
      {:ok, vector} ->
        {:ok,
         %{
           kind: :embedding,
           value: vector,
           metadata: %{dim: length(vector), model: "nomic-embed-text"}
         }}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  def process(_field, _value, _state), do: {:error, :not_a_string}
end
