defmodule OptimalEngine.Storage.Assets do
  @moduledoc """
  Backend selection and byte transfer for raw workspace assets.

  The local filesystem is the default backend and stays the default: an
  embedded engine keeps every asset on its own disk. A workspace whose storage
  policy selects S3, or an engine configured with `OPTIMAL_ASSET_STORAGE=s3`,
  stores asset bytes in the bucket under a tenant and workspace prefix instead,
  and reads them back from there.

  Selection order, first match wins:

    1. `:storage_backend` in the caller's options (`:filesystem` or `:s3`)
    2. the workspace storage policy `provider_overrides` naming `s3` for `assets`
    3. `OPTIMAL_ASSET_STORAGE` (engine-wide default)

  A selected S3 backend that is unconfigured or unreachable never loses the
  file: the bytes are written to the local filesystem, the asset records
  `storage_fallback_reason`, and the fallback is raised as an alert (an error
  log line and the `optimal_engine.storage.asset_fallback` counter) rather than
  reported as a successful remote store.
  """

  require Logger

  alias OptimalEngine.Storage.{PolicyStore, S3}
  alias OptimalEngine.Workspace.Filesystem

  @backends ~w(filesystem s3)

  @type backend :: :filesystem | :s3

  @doc "The backends an asset can be stored on."
  @spec backends() :: [String.t()]
  def backends, do: @backends

  @doc "True when a storage reference names an object rather than a local path."
  @spec remote?(term()) :: boolean()
  def remote?(storage_path), do: S3.uri?(storage_path)

  @doc """
  The backend selected for a workspace, without proving it is usable.
  Use `store/3` to write, which applies the fallback rule. A workspace policy
  that cannot be read counts as no policy here; `resolve_backend/1` reports it.
  """
  @spec selected_backend(keyword()) :: backend()
  def selected_backend(opts \\ []) do
    case resolve_backend(opts) do
      {:ok, backend} -> backend
      {:error, _reason} -> backend_for(%{})
    end
  end

  @doc """
  The backend selected for a workspace, as `selected_backend/1`, except that a
  workspace policy which cannot be read (a database error, not an absent
  policy) is `{:error, reason}`. A caller that records a lasting decision from
  the answer must not take the Engine default for a policy it never saw.
  """
  @spec resolve_backend(keyword()) :: {:ok, backend()} | {:error, term()}
  def resolve_backend(opts \\ []) do
    case Keyword.get(opts, :storage_backend) do
      backend when backend in [:s3, "s3"] ->
        {:ok, :s3}

      backend when backend in [:filesystem, "filesystem"] ->
        {:ok, :filesystem}

      _ ->
        with {:ok, overrides} <- policy_overrides(opts), do: {:ok, backend_for(overrides)}
    end
  end

  defp policy_overrides(opts) do
    case Keyword.get(opts, :workspace_id) do
      nil ->
        {:ok, %{}}

      workspace_id ->
        case PolicyStore.get_policy(workspace_id) do
          {:ok, policy} -> {:ok, policy.provider_overrides}
          {:error, :not_found} -> {:ok, %{}}
          {:error, reason} -> {:error, {:storage_policy_unreadable, reason}}
        end
    end
  end

  defp backend_for(overrides) do
    cond do
      s3_override_for_assets?(overrides) -> :s3
      configured_default() == :s3 -> :s3
      true -> :filesystem
    end
  end

  # A policy override for s3 either claims the whole provider (true) or names
  # the roles it takes over, for example %{"assets" => true}.
  defp s3_override_for_assets?(overrides) when is_map(overrides) do
    case Map.get(overrides, "s3") do
      true ->
        true

      %{} = roles ->
        Map.get(roles, "assets") == true or "assets" in List.wrap(Map.get(roles, "roles"))

      roles when is_list(roles) ->
        "assets" in Enum.map(roles, &to_string/1)

      _ ->
        false
    end
  end

  defp s3_override_for_assets?(_overrides), do: false

  defp configured_default do
    case System.get_env("OPTIMAL_ASSET_STORAGE") do
      value when is_binary(value) ->
        if(String.downcase(String.trim(value)) == "s3", do: :s3, else: :filesystem)

      _ ->
        :filesystem
    end
  end

  @doc """
  Store the bytes of `source_path` for an asset.

  `attrs` carries the identity the key layout needs: `:tenant_id`,
  `:workspace_id`, `:hash` (the asset content hash), and `:extension`.

  Returns `{:ok, %{storage_path: path_or_uri, backend: backend, metadata: map}}`.
  The metadata records the backend and, for an object, its URI and checksum, so
  a reader can tell where the bytes live without opening the file.
  """
  @spec store(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def store(source_path, attrs, opts \\ []) do
    with {:ok, %{size: _}} <- stat_source(source_path) do
      case selected_backend(opts) do
        :s3 -> store_on_s3(source_path, attrs, opts)
        :filesystem -> store_on_filesystem(source_path, attrs, opts)
      end
    end
  end

  defp store_on_s3(source_path, attrs, opts) do
    key = object_key(attrs)

    if S3.configured?() do
      case S3.put_file(key, source_path, Keyword.take(opts, [:part_size, :timeout, :content_type])) do
        {:ok, object} ->
          {:ok,
           %{
             storage_path: object.uri,
             backend: :s3,
             metadata: %{
               "storage_backend" => "s3",
               "object_uri" => object.uri,
               "object_key" => object.key,
               "object_checksum_sha256" => object.checksum_sha256,
               "object_size_bytes" => object.size_bytes
             }
           }}

        {:error, reason} ->
          alert(
            "asset object upload failed, keeping the file on the local filesystem",
            :s3_upload_failed,
            %{key: key, reason: inspect(reason)}
          )

          store_on_filesystem(source_path, attrs, opts, "s3_upload_failed")
      end
    else
      alert(
        "s3 is selected for assets but not configured, keeping the file on the local filesystem",
        :s3_not_configured,
        %{key: key}
      )

      store_on_filesystem(source_path, attrs, opts, "s3_not_configured")
    end
  end

  defp store_on_filesystem(source_path, attrs, _opts, fallback_reason \\ nil) do
    target = local_path(attrs)

    with :ok <- File.mkdir_p(Path.dirname(target)),
         :ok <- copy_if_absent(source_path, target) do
      metadata =
        %{"storage_backend" => "filesystem", "local_path" => target}
        |> maybe_put("storage_fallback_reason", fallback_reason)

      {:ok, %{storage_path: target, backend: :filesystem, metadata: metadata}}
    end
  end

  defp stat_source(path) do
    case File.stat(path) do
      {:ok, %{type: :regular} = stat} -> {:ok, stat}
      {:ok, %{type: type}} -> {:error, {:asset_source_not_a_file, type}}
      {:error, reason} -> {:error, {:asset_source_unreadable, reason}}
    end
  end

  defp copy_if_absent(source, target) do
    if File.exists?(target), do: :ok, else: File.cp(source, target)
  end

  @doc """
  The local filesystem path an asset would be stored at: sharded by content
  hash inside the workspace asset directory.
  """
  @spec local_path(map()) :: String.t()
  def local_path(attrs) do
    root = Application.get_env(:optimal_engine, :root_path, File.cwd!())
    workspace_key = Map.get(attrs, :workspace_key) || Map.get(attrs, :workspace_id, "default")
    hash_slug = attrs |> Map.get(:hash, "") |> String.replace_prefix("sha256:", "")
    shard = String.slice(hash_slug, 0, 2) || "00"
    extension = attrs |> Map.get(:extension, "") |> to_string() |> String.downcase()

    Path.join([
      Filesystem.path(root, workspace_key),
      "assets",
      shard,
      "#{hash_slug}#{extension}"
    ])
  end

  @doc """
  The object key an asset is stored under: the configured prefix, then the
  tenant and workspace, then the same shard and content-hash name the
  filesystem backend uses.
  """
  @spec object_key(map()) :: String.t()
  def object_key(attrs) do
    tenant_id = Map.get(attrs, :tenant_id, "default")
    workspace_id = Map.get(attrs, :workspace_id, "default")
    hash_slug = attrs |> Map.get(:hash, "") |> String.replace_prefix("sha256:", "")
    shard = String.slice(hash_slug, 0, 2) || "00"
    extension = attrs |> Map.get(:extension, "") |> to_string() |> String.downcase()

    S3.object_key([tenant_id, workspace_id, "assets", shard, "#{hash_slug}#{extension}"])
  end

  @doc """
  Read the bytes of an asset from whichever backend holds them.
  """
  @spec read(String.t(), keyword()) :: {:ok, binary()} | {:error, term()}
  def read(storage_path, opts \\ []) when is_binary(storage_path) do
    if remote?(storage_path) do
      with {:ok, _bucket, key} <- S3.parse_uri(storage_path),
           {:ok, object} <- S3.get_object(key, Keyword.take(opts, [:timeout])) do
        {:ok, object.body}
      end
    else
      with :ok <- confine(storage_path) do
        case File.read(storage_path) do
          {:ok, bytes} -> {:ok, bytes}
          {:error, reason} -> {:error, {:asset_unreadable, storage_path, reason}}
        end
      end
    end
  end

  # A stored asset path is data, and rows reach the table from a bundle import
  # as well as from an upload: a local asset is read only from under this
  # Engine's root, never from wherever the row says.
  defp confine(storage_path) do
    root = root_path()
    path = Path.expand(storage_path)

    if not String.contains?(storage_path, <<0>>) and String.starts_with?(path, root <> "/"),
      do: :ok,
      else: {:error, {:asset_outside_root, storage_path}}
  end

  defp root_path, do: Path.expand(Application.get_env(:optimal_engine, :root_path, File.cwd!()))

  @max_symlink_hops 40

  @doc """
  The file a stored local asset path names, for code that opens the path
  itself.

  The path must lie under this Engine's root, the check `read/2` and
  `materialize/2` apply; it must still lie there once every symlink on it is
  followed; and it must be a regular file. A FIFO blocks a reader until a writer
  appears and a device such as `/dev/zero` never ends, so those, and
  directories, are refused. Nothing is opened, so checking a path never blocks.

  Returns `{:ok, path}` with the symlinks followed, or an error:

    * `{:error, {:asset_outside_root, stored_path}}`
    * `{:error, {:asset_not_a_file, type}}` for a directory, FIFO, device or socket
    * `{:error, {:asset_unreadable, stored_path, reason}}` when the path cannot
      be examined, for example `:enoent` for a missing file or `:eloop` for a
      symlink loop
  """
  @spec confine_local(String.t()) :: {:ok, String.t()} | {:error, term()}
  def confine_local(storage_path) when is_binary(storage_path) do
    with :ok <- confine(storage_path),
         {:ok, resolved} <- follow_symlinks(storage_path, storage_path),
         {:ok, root} <- follow_symlinks(root_path(), storage_path),
         :ok <- inside_root(resolved, root, storage_path) do
      regular_file(resolved, storage_path)
    end
  end

  defp inside_root(resolved, root, storage_path) do
    if String.starts_with?(resolved, root <> "/"),
      do: :ok,
      else: {:error, {:asset_outside_root, storage_path}}
  end

  defp regular_file(path, storage_path) do
    case File.stat(path) do
      {:ok, %{type: :regular}} -> {:ok, path}
      {:ok, %{type: type}} -> {:error, {:asset_not_a_file, type}}
      {:error, reason} -> {:error, {:asset_unreadable, storage_path, reason}}
    end
  end

  # The path with every symlink on it followed, read link by link so that
  # nothing is opened.
  defp follow_symlinks(path, storage_path) do
    case follow(Path.split(Path.expand(path)), "/", 0) do
      {:ok, resolved} -> {:ok, resolved}
      {:error, reason} -> {:error, {:asset_unreadable, storage_path, reason}}
    end
  end

  defp follow([], resolved, _hops), do: {:ok, resolved}
  defp follow(_parts, _resolved, hops) when hops > @max_symlink_hops, do: {:error, :eloop}
  defp follow(["/" | rest], _resolved, hops), do: follow(rest, "/", hops)

  defp follow([part | rest], resolved, hops) do
    candidate = Path.join(resolved, part)

    case File.read_link(candidate) do
      {:ok, target} ->
        follow(Path.split(Path.expand(target, resolved)) ++ rest, "/", hops + 1)

      {:error, _not_a_link} ->
        follow(rest, candidate, hops)
    end
  end

  @doc """
  A local path holding the asset's bytes, for tools and parsers that take a
  file argument and cannot read an object store. A local asset resolves to
  itself; an object asset is downloaded once into the engine cache and reused.
  """
  @spec materialize(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def materialize(storage_path, opts \\ []) when is_binary(storage_path) do
    if remote?(storage_path) do
      with {:ok, _bucket, key} <- S3.parse_uri(storage_path) do
        target = cached_path(key)

        if File.regular?(target) do
          {:ok, target}
        else
          case S3.get_object_to_file(key, target, Keyword.take(opts, [:timeout])) do
            {:ok, _object} -> {:ok, target}
            {:error, reason} -> {:error, reason}
          end
        end
      end
    else
      with :ok <- confine(storage_path) do
        if File.regular?(storage_path),
          do: {:ok, storage_path},
          else: {:error, {:asset_unreadable, storage_path}}
      end
    end
  end

  defp cached_path(key), do: Path.join(cache_dir(), key)

  @doc false
  # Where the copies of object-store assets are kept: `<cache_path>/assets`.
  @spec cache_dir() :: String.t()
  def cache_dir do
    cache = Application.get_env(:optimal_engine, :cache_path, System.tmp_dir!())
    Path.join(cache, "assets")
  end

  @doc """
  Classify stored asset locations for an audit: local paths that exist, object
  URIs, and object URIs that could not be confirmed. `{:ok, map()}` when every
  asset is accounted for; `{:error, map()}` when something is missing.
  """
  @spec inventory([String.t()], keyword()) :: {:ok, map()} | {:error, map()}
  def inventory(storage_paths, opts \\ []) do
    local = Enum.reject(storage_paths, &remote?/1)
    objects = Enum.filter(storage_paths, &remote?/1)

    missing_local = Enum.reject(local, &File.regular?/1)

    {verified, unverified} =
      if objects != [] and Keyword.get(opts, :verify_remote, S3.configured?()) do
        objects
        |> Enum.map(&verify_object/1)
        |> Enum.split_with(fn {_uri, result} -> result == :ok end)
      else
        {[], Enum.map(objects, &{&1, :unverified})}
      end

    summary = %{
      cataloged: length(storage_paths),
      local: length(local),
      local_missing: length(missing_local),
      objects: length(objects),
      objects_verified: length(verified),
      objects_unverified: length(unverified)
    }

    cond do
      missing_local != [] ->
        {:error, Map.put(summary, :missing, missing_local)}

      objects != [] and unverified != [] ->
        {:error, Map.put(summary, :unverified, Enum.map(unverified, &elem(&1, 0)))}

      true ->
        {:ok, summary}
    end
  end

  defp verify_object(uri) do
    with {:ok, _bucket, key} <- S3.parse_uri(uri),
         {:ok, _object} <- S3.head_object(key, max_retries: 0) do
      {uri, :ok}
    else
      _ -> {uri, :unverified}
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # An asset that did not reach its configured backend is an operator problem,
  # so it is logged at error level, counted in the Engine's metrics
  # (`optimal_engine.storage.asset_fallback` in /api/metrics and Prometheus),
  # and never reported as a successful upload.
  # The log line names the object key and the error; the metric carries only
  # the fallback reason, so nothing about the object reaches a metrics sink.
  defp alert(message, reason, fields) do
    Logger.error(fn ->
      "asset storage alert: #{message} " <>
        Enum.map_join(fields, " ", fn {key, value} -> "#{key}=#{value}" end)
    end)

    :telemetry.execute([:optimal_engine, :storage, :asset_fallback], %{count: 1}, %{
      reason: reason
    })
  end
end
