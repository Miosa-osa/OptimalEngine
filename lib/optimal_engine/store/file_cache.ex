defmodule OptimalEngine.Store.FileCache do
  @moduledoc """
  Rebuildable filesystem cache under `:optimal_engine, :cache_path`.

  Entries are content-addressed by `namespace` and key, written atomically
  (temporary file plus rename), and carry their own key so a hash collision
  or a partially written file can never be returned as a hit. Anything unreadable is
  deleted and reported as a miss: the cache only accelerates work, it never
  holds truth, and deleting the whole directory is always safe.

  The embedder uses the `"embeddings"` namespace so identical text is only
  embedded once per model across restarts.
  """

  @version 1
  @namespace_pattern ~r/^[a-z0-9][a-z0-9_-]*$/

  @doc "Absolute cache root."
  @spec root() :: String.t()
  def root do
    :optimal_engine
    |> Application.get_env(:cache_path, ".optimal/cache")
    |> Path.expand()
  end

  @spec put(String.t(), binary(), term()) :: :ok | {:error, term()}
  def put(namespace, key, value) when is_binary(key) do
    with {:ok, path} <- entry_path(namespace, key) do
      tmp = "#{path}.tmp-#{System.unique_integer([:positive])}"
      body = :erlang.term_to_binary({@version, key, value})

      with :ok <- File.mkdir_p(Path.dirname(path)),
           :ok <- File.write(tmp, body),
           :ok <- File.rename(tmp, path) do
        :ok
      else
        {:error, reason} ->
          File.rm(tmp)
          {:error, reason}
      end
    end
  end

  @spec get(String.t(), binary()) :: {:ok, term()} | :miss | {:error, term()}
  def get(namespace, key) when is_binary(key) do
    with {:ok, path} <- entry_path(namespace, key) do
      case File.read(path) do
        {:ok, body} -> decode(path, key, body)
        {:error, :enoent} -> :miss
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Return the cached value or compute, cache, and return it. `fun` must
  return `{:ok, value}`; errors are returned uncached. Cache write failures
  never fail the computation.
  """
  @spec fetch(String.t(), binary(), (-> {:ok, term()} | {:error, term()})) ::
          {:ok, term()} | {:error, term()}
  def fetch(namespace, key, fun) when is_function(fun, 0) do
    case get(namespace, key) do
      {:ok, value} ->
        {:ok, value}

      _miss_or_error ->
        with {:ok, value} <- fun.() do
          _ = put(namespace, key, value)
          {:ok, value}
        end
    end
  end

  @spec delete(String.t(), binary()) :: :ok | {:error, term()}
  def delete(namespace, key) when is_binary(key) do
    with {:ok, path} <- entry_path(namespace, key) do
      case File.rm(path) do
        :ok -> :ok
        {:error, :enoent} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc "Delete every entry in a namespace."
  @spec clear(String.t()) :: :ok | {:error, term()}
  def clear(namespace) do
    with :ok <- validate_namespace(namespace),
         {:ok, _} <- File.rm_rf(Path.join(root(), namespace)) do
      :ok
    end
  end

  @doc "Entry count and bytes per namespace."
  @spec stats() :: %{String.t() => %{entries: non_neg_integer(), bytes: non_neg_integer()}}
  def stats do
    root()
    |> Path.join("*/*/*.bin")
    |> Path.wildcard()
    |> Enum.group_by(&(&1 |> Path.dirname() |> Path.dirname() |> Path.basename()))
    |> Map.new(fn {namespace, files} ->
      bytes = files |> Enum.map(&file_size/1) |> Enum.sum()
      {namespace, %{entries: length(files), bytes: bytes}}
    end)
  end

  defp decode(path, key, body) do
    case safe_binary_to_term(body) do
      {:ok, {@version, ^key, value}} ->
        {:ok, value}

      _ ->
        File.rm(path)
        :miss
    end
  end

  defp safe_binary_to_term(body) do
    {:ok, :erlang.binary_to_term(body, [:safe])}
  rescue
    ArgumentError -> :error
  end

  defp entry_path(namespace, key) do
    with :ok <- validate_namespace(namespace) do
      digest = :crypto.hash(:sha256, key) |> Base.encode16(case: :lower)
      {:ok, Path.join([root(), namespace, binary_part(digest, 0, 2), digest <> ".bin"])}
    end
  end

  defp validate_namespace(namespace) when is_binary(namespace) do
    if Regex.match?(@namespace_pattern, namespace),
      do: :ok,
      else: {:error, {:invalid_namespace, namespace}}
  end

  defp validate_namespace(namespace), do: {:error, {:invalid_namespace, namespace}}

  defp file_size(path) do
    case File.stat(path) do
      {:ok, %{size: size}} -> size
      _ -> 0
    end
  end
end
