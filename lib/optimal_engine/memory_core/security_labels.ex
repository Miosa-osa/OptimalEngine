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

  @typedoc """
  What a thing carries that a reader's grants are compared with:

    * `{:label, name}` a label; the four class names are lowercased, other
      labels are compared exactly;
    * `{:partition_set, ids}` the partitions of one row (sorted); a reader
      must share at least one of them for each such row (see `permits?/2`);
    * `{:partition_all, id}` a partition the reader must hold in full (see
      `permits?/2`);
    * `:unresolved` something that could not be read or found;
    * `:unresolved_partition` partitions that could not be read: the same, on
      the partition axis (a reader that may see every label does not see past it).
  """
  @type token ::
          {:label, String.t()}
          | {:partition_set, [String.t()]}
          | {:partition_all, String.t()}
          | :unresolved
          | :unresolved_partition

  @typedoc """
  A reader's grants: the labels and partitions it may see, and whether it may
  see any (`"*"`, which a key holds only when it may mint any).
  """
  @type grants :: %{
          labels: MapSet.t(String.t()),
          partitions: MapSet.t(String.t()),
          all_labels?: boolean(),
          all_partitions?: boolean()
        }

  @doc """
  The token for something that could not be read or found. It is never in a
  reader's grants, so whatever carries it is read by no one.
  """
  @spec unresolved() :: :unresolved
  def unresolved, do: :unresolved

  @doc """
  The labels of a stored `security_labels` value as tokens. A value that
  cannot be read, and an element that is not a non-blank string, are
  `unresolved`: they are never taken for no label.
  """
  @spec tokens(term()) :: [token()]
  def tokens(value) do
    case decode(value) do
      {:ok, labels} -> Enum.map(labels, &label_token(&1, :label))
      :invalid -> [:unresolved]
    end
  end

  @doc """
  The partitions of a stored `partition_ids` value as tokens: one
  `{:partition_set, ids}` for the row (none when it has none), and
  `unresolved_partition` when the value or an element cannot be read.
  """
  @spec partition_tokens(term()) :: [token()]
  def partition_tokens(value) do
    case decode(value) do
      {:ok, ids} ->
        tokens = Enum.map(ids, &label_token(&1, :partition))
        names = for {:partition, id} <- tokens, do: id
        unreadable = if :unresolved in tokens, do: [:unresolved_partition], else: []

        if names == [],
          do: unreadable,
          else: [{:partition_set, names |> Enum.uniq() |> Enum.sort()} | unreadable]

      :invalid ->
        [:unresolved_partition]
    end
  end

  @doc "The label and partition tokens in the `metadata` of a row."
  @spec metadata_tokens(term()) :: [token()]
  def metadata_tokens(metadata) do
    metadata = metadata_map(metadata)

    labels =
      case Map.fetch(metadata, "security_labels") do
        {:ok, value} -> tokens(value)
        :error -> []
      end

    partitions =
      case Map.fetch(metadata, "partition_ids") do
        {:ok, value} -> partition_tokens(value)
        :error -> []
      end

    labels ++ partitions
  end

  @doc """
  Whether a list of grants holds `"*"`, which is every label (or every
  partition) when it is in `allowed_security_labels` (or `allowed_partitions`),
  as `Auth.KeyIssuance` reads it. A key holds it only when it may mint any
  grant. The retrieval coordinator, the associative projection and the
  readers of exports all read it through here.
  """
  @spec wildcard?(term()) :: boolean()
  def wildcard?(grants) when is_list(grants), do: Enum.any?(grants, &(&1 == "*"))
  def wildcard?(_grants), do: false

  @doc """
  The grants of a reader from the labels and partitions its key is allowed.
  Blank entries are dropped, class names are lowercased, and `"*"` grants all
  of its kind.
  """
  @spec grants(term(), term()) :: grants()
  def grants(labels, partitions) do
    labels = strings(labels)
    partitions = strings(partitions)

    %{
      labels: grant_set(labels, :label),
      partitions: grant_set(partitions, :partition),
      all_labels?: "*" in labels,
      all_partitions?: "*" in partitions
    }
  end

  @doc """
  Whether a reader with `grants` may see a thing that carries `tokens` (nil
  for a thing that carries none). This is the rule of governed retrieval:

    * labels: every label the thing carries is among the reader's labels, so
      a reader with none sees only what has none;
    * partitions: with no partition granted only what has none is seen; with
      some granted, what shares at least one is seen and what has none is
      not. A thing derived from other rows carries the partitions of each of
      them as a `{:partition_set, ids}` of its own, and the reader must share
      one of every set: a row that is partitioned to `a` and drawn from a row
      partitioned to `b` is not seen by a reader that holds only `a`;
    * `{:partition_all, id}` tokens (an aggregate, which is written from
      every partition of its workspace) must all be granted;
    * `unresolved` is never granted, except to a reader that may see all
      labels; `unresolved_partition` (partitions that could not be read) is
      never granted, except to a reader that may see all partitions: a reader
      of every label does not see past a partition it cannot read.
  """
  @spec permits?(grants(), MapSet.t(token()) | nil) :: boolean()
  def permits?(grants, nil), do: permits?(grants, MapSet.new())

  def permits?(grants, tokens) do
    labels = for {:label, name} <- tokens, do: name
    sets = for {:partition_set, ids} <- tokens, do: ids
    required = for {:partition_all, id} <- tokens, do: id

    labels_ok? =
      grants.all_labels? or
        (not MapSet.member?(tokens, :unresolved) and subset?(labels, grants.labels))

    partitions_ok? =
      grants.all_partitions? or
        (not MapSet.member?(tokens, :unresolved_partition) and
           partitions_ok?(grants.partitions, sets, required))

    labels_ok? and partitions_ok?
  end

  # Nothing granted: only what carries nothing. Something granted: it must be
  # carried (as retrieval, a row with no partition is not shown), every row's
  # set must share one, and every partition of an aggregate must be held.
  defp partitions_ok?(granted, sets, required) do
    if MapSet.size(granted) == 0 do
      sets == [] and required == []
    else
      (sets != [] or required != []) and
        Enum.all?(sets, fn ids -> Enum.any?(ids, &MapSet.member?(granted, &1)) end) and
        subset?(required, granted)
    end
  end

  defp subset?(names, granted), do: Enum.all?(names, &MapSet.member?(granted, &1))

  @doc """
  The class rank of a set of tokens: the highest class named, restricted for
  an `unresolved` one (of either axis), nil for none.
  """
  @spec token_rank(MapSet.t(token()) | nil) :: rank() | nil
  def token_rank(nil), do: nil

  def token_rank(tokens) do
    if MapSet.member?(tokens, :unresolved) or MapSet.member?(tokens, :unresolved_partition),
      do: 3,
      else: highest_rank(for({:label, name} <- tokens, do: name))
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

  @doc """
  The labels in a stored value, as strings. A value that cannot be read
  holds `restricted`, so joining it with another value never drops the class.
  """
  @spec labels(term()) :: [String.t()]
  def labels(value) do
    case decode(value) do
      {:ok, _} -> strings(value)
      :invalid -> ["restricted"]
    end
  end

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

  defp label_token(label, kind) when is_binary(label) do
    case String.trim(label) do
      "" -> :unresolved
      text -> {kind, canonical(text, kind)}
    end
  end

  defp label_token(label, kind) when is_atom(label) and label not in [nil, true, false],
    do: label_token(Atom.to_string(label), kind)

  defp label_token(_other, _kind), do: :unresolved

  # The four class names are not case sensitive; any other label is exact.
  defp canonical(text, :label) do
    lowered = String.downcase(text)
    if lowered in @classes, do: lowered, else: text
  end

  defp canonical(text, :partition), do: text

  defp grant_set(values, kind) do
    for value <- values,
        value != "*",
        trimmed = String.trim(value),
        trimmed != "",
        into: MapSet.new() do
      canonical(trimmed, kind)
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
