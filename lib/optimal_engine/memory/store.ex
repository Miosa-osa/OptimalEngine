defmodule OptimalEngine.Memory.Store do
  @moduledoc """
  Storage backend behaviour for OptimalEngine.Memory.

  Defines the contract that all storage implementations must fulfill.
  The default implementation is `OptimalEngine.Memory.Store.ETS`.
  """

  @type collection :: String.t()
  @type key :: String.t()
  @type value :: term()
  @type metadata :: %{
          created_at: DateTime.t(),
          updated_at: DateTime.t(),
          access_count: non_neg_integer(),
          tags: [String.t()]
        }
  @type entry :: %{
          key: key(),
          value: value(),
          metadata: metadata()
        }
  @type opts :: keyword()

  @doc "Store a value under collection + key with metadata."
  @callback put(collection(), key(), value(), metadata()) :: :ok | {:error, term()}

  @doc "Retrieve an entry by collection + key."
  @callback get(collection(), key()) :: {:ok, entry()} | {:error, :not_found}

  @doc "Delete an entry by collection + key."
  @callback delete(collection(), key()) :: :ok

  @doc "List all entries in a collection. Supports opts like `limit`."
  @callback list(collection(), opts()) :: {:ok, [entry()]}

  @doc "Search entries in a collection matching query."
  @callback search(collection(), String.t()) :: {:ok, [entry()]}

  @doc "List all collection names."
  @callback collections() :: {:ok, [collection()]}

  # The metadata keys an entry has, as the entry type names them.
  @metadata_keys %{
    "created_at" => :created_at,
    "updated_at" => :updated_at,
    "access_count" => :access_count,
    "tags" => :tags
  }

  # The keys of the maps the engine itself stores (episodes and events), as atoms.
  @value_keys %{
    "type" => :type,
    "description" => :description,
    "context" => :context,
    "outcome" => :outcome,
    "tags" => :tags,
    "created_at" => :created_at,
    "data" => :data,
    "session_id" => :session_id
  }

  @doc """
  Decodes one entry of an exported collection.

  `raw` is the JSON object an export wrote, decoded with string keys. A file is
  data, so no atom is created from it: the keys of the entry and of its
  metadata, and the top-level keys of a map `value` that the engine's own
  writers use, are looked up in fixed tables and read as atoms. Every other key
  stays a string. Values are JSON data: an atom value, a `DateTime` or a tuple
  that was exported comes back as the string or list it was written as.

  Raises when `raw` is not an entry or a timestamp is not ISO 8601.
  """
  @spec decode_entry(map()) :: entry()
  def decode_entry(%{"key" => key, "value" => value, "metadata" => %{} = raw_metadata}) do
    metadata =
      raw_metadata
      |> Map.new(fn {name, item} -> {Map.get(@metadata_keys, name, name), item} end)
      |> Map.update!(:created_at, &parse_datetime!/1)
      |> Map.update!(:updated_at, &parse_datetime!/1)
      |> Map.put_new(:access_count, 0)
      |> Map.put_new(:tags, [])

    %{key: key, value: decode_value(value), metadata: metadata}
  end

  defp decode_value(%{} = value),
    do: Map.new(value, fn {name, item} -> {Map.get(@value_keys, name, name), item} end)

  defp decode_value(value), do: value

  defp parse_datetime!(dt) when is_binary(dt) do
    {:ok, parsed, _offset} = DateTime.from_iso8601(dt)
    parsed
  end

  defp parse_datetime!(%DateTime{} = dt), do: dt

  @doc """
  Returns the configured store backend.

  Defaults to `OptimalEngine.Memory.Store.ETS`.
  """
  @spec backend() :: module()
  def backend do
    Application.get_env(:optimal_engine, :store_backend, OptimalEngine.Memory.Store.ETS)
  end

  @doc """
  Recall all memory content as a single string.

  Retrieves all entries from the default "memory" collection and concatenates
  their values. Used by `OptimalEngine.Memory.Cortex` for synthesis.
  """
  @spec recall() :: String.t()
  def recall do
    case backend().list("memory", []) do
      {:ok, entries} ->
        entries
        |> Enum.map(fn entry ->
          case entry do
            %{value: v} when is_binary(v) -> v
            %{value: v} -> inspect(v)
            _ -> ""
          end
        end)
        |> Enum.join("\n")

      _ ->
        ""
    end
  rescue
    _ -> ""
  end

  @doc """
  List all sessions with metadata. Delegates to `OptimalEngine.Memory.SessionStore.list_sessions/0`.
  """
  @spec list_sessions() :: [map()]
  def list_sessions do
    OptimalEngine.Memory.SessionStore.list_sessions()
  end

  @doc """
  Load a session's message history by ID. Delegates to `OptimalEngine.Memory.SessionStore.load/1`.
  """
  @spec load_session(String.t()) :: [map()]
  def load_session(session_id) do
    OptimalEngine.Memory.SessionStore.load(session_id)
  end
end
