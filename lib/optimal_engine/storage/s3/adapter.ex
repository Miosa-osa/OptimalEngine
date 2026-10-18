defmodule OptimalEngine.Storage.S3.Adapter do
  @moduledoc """
  Storage provider adapter for S3-compatible object storage.

  Implements the `OptimalEngine.Storage.Provider` contract so the provider
  inventory can report `s3` as implemented, configured, and healthy instead of
  `adapter_missing`. Health is only ever claimed on evidence: the probe makes
  one authenticated request against the bucket, so a configured but wrong key,
  wrong bucket, or unreachable endpoint reports `unreachable`, never `healthy`.

  Nothing here returns, logs, or embeds credentials or a connection string.
  """

  @behaviour OptimalEngine.Storage.Provider

  alias OptimalEngine.Storage.S3

  @capabilities ~w(objects assets backups)a

  @impl OptimalEngine.Storage.Provider
  def id, do: "s3"

  @impl OptimalEngine.Storage.Provider
  def capabilities, do: @capabilities

  @impl OptimalEngine.Storage.Provider
  def describe do
    %{
      id: id(),
      name: "S3-compatible object storage",
      kind: "service",
      role: "canonical_artifact",
      capabilities: Enum.map(@capabilities, &Atom.to_string/1),
      operations: ~w(put get head list delete multipart),
      addressing: "path-style unless OPTIMAL_S3_PATH_STYLE is false"
    }
  end

  @impl OptimalEngine.Storage.Provider
  def status(opts \\ []) do
    configured = S3.configured?()

    health =
      cond do
        not configured -> :not_configured
        Keyword.get(opts, :probe, false) -> health(opts)
        true -> :unknown
      end

    %{
      id: id(),
      configured: configured,
      health: Atom.to_string(health),
      lifecycle_state: lifecycle_state(configured, health),
      capabilities: Enum.map(@capabilities, &Atom.to_string/1),
      region_configured: present?("OPTIMAL_S3_REGION"),
      prefix_configured: present?("OPTIMAL_S3_PREFIX"),
      path_style: path_style_configured()
    }
  end

  @doc """
  Provider health from one authenticated request against the bucket.

  A list of one key proves the endpoint is reachable, the credentials sign
  correctly, and the bucket is readable. It never raises: a failure is health,
  not an exception, because the inventory is read on the request path.
  """
  @spec health(keyword()) :: OptimalEngine.Storage.Provider.health()
  def health(opts \\ []) do
    if S3.configured?() do
      opts = opts |> Keyword.take([:timeout, :max_retries]) |> Keyword.put(:max_pages, 1)

      case S3.list_objects(nil, opts) do
        {:ok, _listing} -> :healthy
        {:error, _reason} -> :unreachable
      end
    else
      :not_configured
    end
  rescue
    _ -> :unreachable
  catch
    _, _ -> :unreachable
  end

  @doc """
  The full provider proof: write, read back, verify the checksum, head, list,
  and delete. Used by the store reality proof and the offsite acceptance check,
  so a stored object is proven by a round trip rather than by a successful
  connection.
  """
  @spec probe(keyword()) :: {:ok, map()} | {:error, term()}
  def probe(opts \\ []) do
    if S3.configured?() do
      case S3.round_trip(opts) do
        {:ok, evidence} -> {:ok, Map.put(evidence, :provider, id())}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :not_configured}
    end
  end

  @doc """
  The bucket and key prefix the engine writes under, for callers that need to
  build an object URI. Returns `{:error, :not_configured}` without them, so a
  caller can never assemble a path from a partially configured endpoint.
  """
  @spec location() :: {:ok, map()} | {:error, :not_configured}
  def location do
    case S3.config() do
      {:ok, config} ->
        {:ok, %{bucket: config.bucket, prefix: config.prefix, region: config.region}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp lifecycle_state(false, _health), do: "not_configured"
  defp lifecycle_state(true, :healthy), do: "available"
  defp lifecycle_state(true, :unknown), do: "configured_unverified"
  defp lifecycle_state(true, _health), do: "unavailable"

  defp present?(name) do
    case System.get_env(name) do
      value when is_binary(value) -> String.trim(value) != ""
      _ -> false
    end
  end

  defp path_style_configured do
    case System.get_env("OPTIMAL_S3_PATH_STYLE") do
      value when value in ["false", "0", "no", "off"] -> false
      _ -> true
    end
  end
end
