defmodule OptimalEngine.Memory.Versioned.RetrievalDocument do
  @moduledoc """
  Versioned searchable representation of a durable Memory.

  The projection enriches first-person content with identity and time fields
  while excluding benchmark labels and evidence addresses. Canonical Memory
  content remains unchanged.
  """

  alias OptimalEngine.Memory.Versioned

  @profile "retrieval-document-v1"
  @excluded_metadata ~w[benchmark category evidence evidence_tag gold answer expected_answer]
  @header ~r/^\[[^\]]+\]\s+\[([^\]]*)\]\s+(.+?)\s+to\s+(.+?):\s*(.*)$/su

  @spec profile() :: String.t()
  def profile, do: @profile

  @spec serialize(Versioned.t()) :: String.t()
  def serialize(%Versioned{} = memory) do
    metadata = stringify_keys(memory.metadata || %{})
    parsed = parse_header(memory.content)

    fields = [
      {"profile", @profile},
      {"speaker", metadata["speaker"] || parsed.speaker},
      {"recipient", metadata["recipient"] || parsed.recipient},
      {"date", metadata["timestamp"] || parsed.timestamp},
      {"session", metadata["session"]},
      {"content", parsed.content}
    ]

    fields
    |> Enum.reject(fn {_name, value} -> blank?(value) end)
    |> Enum.map_join("\n", fn {name, value} -> "#{name}: #{normalize(value)}" end)
  end

  @spec hash(Versioned.t()) :: String.t()
  def hash(%Versioned{} = memory), do: serialize(memory) |> sha256()

  @spec searchable_metadata(Versioned.t()) :: map()
  def searchable_metadata(%Versioned{} = memory) do
    memory.metadata
    |> stringify_keys()
    |> Map.drop(@excluded_metadata)
  end

  defp parse_header(content) do
    case Regex.run(@header, content || "", capture: :all_but_first) do
      [timestamp, speaker, recipient, body] ->
        %{timestamp: timestamp, speaker: speaker, recipient: recipient, content: body}

      _ ->
        %{timestamp: nil, speaker: nil, recipient: nil, content: content || ""}
    end
  end

  defp stringify_keys(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp stringify_keys(_), do: %{}
  defp blank?(nil), do: true
  defp blank?(value), do: String.trim(to_string(value)) == ""
  defp normalize(value), do: value |> to_string() |> String.replace(~r/\s+/u, " ") |> String.trim()
  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
