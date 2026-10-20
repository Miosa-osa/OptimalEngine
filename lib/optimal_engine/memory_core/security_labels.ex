defmodule OptimalEngine.MemoryCore.SecurityLabels do
  @moduledoc """
  Security labels as they are stored and read across the Engine: a JSON list
  of strings in a `security_labels` column, or the same list under the
  `security_labels` key of a row's `metadata`.

  Four labels name a data class, lowest to highest: `public`, `internal`,
  `confidential`, `restricted`. Any other label (`private`, a team name) is
  an access label and carries no class. The class of a thing is the highest
  class among its labels; a thing with no class label has no class of its
  own.

  Reading is fail-closed: a value that is not a list of labels (malformed
  JSON, a map, a number) ranks as `restricted`, never as unlabelled.
  """

  @classes ~w(public internal confidential restricted)

  @typedoc "Position in `classes/0`: 0 is `public`, 3 is `restricted`."
  @type rank :: 0..3

  @doc "The data classes, lowest to highest."
  @spec classes() :: [String.t()]
  def classes, do: @classes

  @doc "The rank of a class name, or nil for a label that is not a class."
  @spec class_rank(term()) :: rank() | nil
  def class_rank(label) do
    name = normalize(label)
    Enum.find_index(@classes, &(&1 == name))
  end

  @doc "The rank of the highest class among `labels`, or nil when none is a class."
  @spec highest_rank([term()]) :: rank() | nil
  def highest_rank(labels) when is_list(labels) do
    labels |> Enum.map(&class_rank/1) |> Enum.reject(&is_nil/1) |> Enum.max(fn -> nil end)
  end

  @doc "The name of the highest class among `labels`, or nil."
  @spec highest_class([term()]) :: String.t() | nil
  def highest_class(labels) do
    case highest_rank(labels) do
      nil -> nil
      rank -> Enum.at(@classes, rank)
    end
  end

  @doc """
  The labels in a stored value: a list, a JSON list, nil or an empty string.
  `:invalid` for anything else.
  """
  @spec decode(term()) :: {:ok, [term()]} | :invalid
  def decode(nil), do: {:ok, []}
  def decode(""), do: {:ok, []}
  def decode(list) when is_list(list), do: {:ok, list}

  def decode(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, list} when is_list(list) -> {:ok, list}
      _ -> :invalid
    end
  end

  def decode(_other), do: :invalid

  @doc """
  The class rank of a stored `security_labels` value, nil when it names no
  class, `3` (restricted) when it cannot be read.
  """
  @spec rank(term()) :: rank() | nil
  def rank(value) do
    case decode(value) do
      {:ok, labels} -> highest_rank(labels)
      :invalid -> 3
    end
  end

  @doc """
  The class rank carried by a `metadata` value (a map or its JSON): its
  `security_labels`, read as `rank/1` does. Metadata that cannot be read
  names no class (it is free-form), but readable metadata with unreadable
  labels ranks `restricted`.
  """
  @spec metadata_rank(term()) :: rank() | nil
  def metadata_rank(metadata) do
    case metadata_map(metadata) do
      %{"security_labels" => labels} -> rank(labels)
      _ -> nil
    end
  end

  @doc "A `metadata` value as a map with string keys (empty when unreadable)."
  @spec metadata_map(term()) :: map()
  def metadata_map(metadata) when is_map(metadata) and not is_struct(metadata),
    do: Map.new(metadata, fn {key, value} -> {to_string(key), value} end)

  def metadata_map(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end

  def metadata_map(_other), do: %{}

  @doc "The labels of two values joined, each once, in order."
  @spec merge(term(), term()) :: [String.t()]
  def merge(left, right) do
    (strings(left) ++ strings(right)) |> Enum.uniq()
  end

  @doc """
  `metadata` with `labels` joined into its `security_labels`. Unchanged when
  there is nothing to add, so unlabelled rows keep the metadata they had.
  """
  @spec put(term(), term()) :: map()
  def put(metadata, labels) do
    existing = metadata_map(metadata)

    case merge(Map.get(existing, "security_labels"), labels) do
      [] -> if is_map(metadata) and not is_struct(metadata), do: metadata, else: existing
      merged -> Map.put(existing, "security_labels", merged)
    end
  end

  defp strings(value) do
    case decode(value) do
      {:ok, labels} ->
        for label <- labels, is_binary(label) or is_atom(label), label not in [nil, ""] do
          to_string(label)
        end

      :invalid when is_binary(value) ->
        [value]

      :invalid ->
        []
    end
  end

  defp normalize(label) when is_binary(label), do: label |> String.trim() |> String.downcase()

  defp normalize(label) when is_atom(label) and not is_nil(label),
    do: normalize(Atom.to_string(label))

  defp normalize(_other), do: nil
end
