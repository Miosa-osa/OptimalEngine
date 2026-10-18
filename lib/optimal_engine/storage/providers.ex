defmodule OptimalEngine.Storage.Providers do
  @moduledoc """
  Registry and safe health inspection for physical storage providers.

  Optional providers are configured only through environment references. The
  returned inventory reports which variables are present but never returns
  their values.

  A provider is only usable when the engine ships an adapter for it. Providers
  listed without an implementing module report `adapter_implemented: false`
  and the `adapter_missing` lifecycle state, regardless of configuration or a
  reachable endpoint: a healthy remote service the engine cannot talk to is
  not available storage.
  """

  @providers [
    %{
      id: "sqlite",
      adapter: OptimalEngine.Store,
      name: "SQLite",
      kind: "embedded",
      role: "canonical",
      capabilities: ~w(relational temporal jobs metrics backups model_registry)a,
      activation: "default_local",
      probe: :store,
      required_env: [],
      optional_env: []
    },
    %{
      id: "fts5",
      adapter: OptimalEngine.Store,
      name: "SQLite FTS5",
      kind: "embedded",
      role: "projection",
      capabilities: ~w(full_text)a,
      activation: "default_local",
      probe: :store,
      required_env: [],
      optional_env: []
    },
    %{
      id: "embedded_vectors",
      adapter: OptimalEngine.Store.Vectors,
      name: "Embedded vectors",
      kind: "embedded",
      role: "projection",
      capabilities: ~w(vector)a,
      activation: "default_local",
      probe: :store,
      required_env: [],
      optional_env: []
    },
    %{
      id: "rocksdb",
      adapter: OptimalEngine.Knowledge.Backend.RocksDB,
      name: "RocksDB",
      kind: "embedded",
      role: "projection",
      capabilities: ~w(graph)a,
      activation: "default_local",
      probe: {:module, :rocksdb},
      required_env: [],
      optional_env: []
    },
    %{
      id: "filesystem",
      adapter: OptimalEngine.MemoryCore.AssetStore,
      name: "Local filesystem",
      kind: "embedded",
      role: "canonical_artifact",
      capabilities: ~w(objects assets)a,
      activation: "default_local",
      probe: :root_path,
      required_env: [],
      optional_env: []
    },
    %{
      id: "ets",
      adapter: OptimalEngine.Store,
      name: "Erlang ETS",
      kind: "embedded",
      role: "ephemeral",
      capabilities: ~w(cache coordination)a,
      activation: "default_local",
      probe: :runtime,
      required_env: [],
      optional_env: []
    },
    %{
      id: "postgres",
      adapter: nil,
      name: "PostgreSQL",
      kind: "service",
      role: "canonical",
      capabilities: ~w(relational temporal document geospatial time_series)a,
      activation: "cloud_team",
      probe: {:tcp_url, "OPTIMAL_POSTGRES_URL", 5432},
      required_env: ["OPTIMAL_POSTGRES_URL"],
      optional_env: []
    },
    %{
      id: "s3",
      adapter: OptimalEngine.Storage.S3.Adapter,
      name: "S3-compatible object storage",
      kind: "service",
      role: "canonical_artifact",
      capabilities: ~w(objects assets backups)a,
      activation: "cloud_team",
      probe: :s3,
      required_env:
        ~w(OPTIMAL_S3_ENDPOINT OPTIMAL_S3_BUCKET OPTIMAL_S3_ACCESS_KEY_ID OPTIMAL_S3_SECRET_ACCESS_KEY),
      optional_env:
        ~w(OPTIMAL_S3_REGION OPTIMAL_S3_PREFIX OPTIMAL_S3_PATH_STYLE OPTIMAL_S3_TIMEOUT_MS OPTIMAL_S3_MAX_RETRIES)
    },
    %{
      id: "nats_jetstream",
      adapter: nil,
      name: "NATS JetStream",
      kind: "service",
      role: "transport",
      capabilities: ~w(event_stream jobs replication coordination)a,
      activation: "distributed_runtime",
      probe: {:tcp_url, "OPTIMAL_NATS_URL", 4222},
      required_env: ["OPTIMAL_NATS_URL"],
      optional_env: []
    },
    %{
      id: "valkey",
      adapter: nil,
      name: "Valkey",
      kind: "service",
      role: "ephemeral",
      capabilities: ~w(cache coordination rate_limits)a,
      activation: "distributed_runtime",
      probe: {:tcp_url, "OPTIMAL_VALKEY_URL", 6379},
      required_env: ["OPTIMAL_VALKEY_URL"],
      optional_env: []
    },
    %{
      id: "qdrant",
      adapter: nil,
      name: "Qdrant",
      kind: "service",
      role: "projection",
      capabilities: ~w(vector)a,
      activation: "high_scale_semantic",
      probe: {:http, "OPTIMAL_QDRANT_URL", "/healthz"},
      required_env: ["OPTIMAL_QDRANT_URL"],
      optional_env: ["OPTIMAL_QDRANT_API_KEY"]
    },
    %{
      id: "duckdb",
      adapter: nil,
      name: "DuckDB and Parquet",
      kind: "embedded",
      role: "projection",
      capabilities: ~w(analytics columnar lakehouse)a,
      activation: "analytics",
      probe: {:executable, "duckdb"},
      required_env: ["OPTIMAL_ANALYTICS_PATH"],
      optional_env: []
    },
    %{
      id: "openbao",
      adapter: nil,
      name: "OpenBao",
      kind: "service",
      role: "secrets",
      capabilities: ~w(secrets kms pki)a,
      activation: "cloud_team",
      probe: {:http, "OPTIMAL_OPENBAO_ADDR", "/v1/sys/health"},
      required_env: ["OPTIMAL_OPENBAO_ADDR", "OPTIMAL_OPENBAO_TOKEN"],
      optional_env: []
    },
    %{
      id: "fractal",
      adapter: nil,
      name: "Fractal Computing",
      kind: "enterprise_partner",
      role: "enterprise_substrate",
      capabilities: ~w(digital_twin distributed_analytics ai_safe_structured_data)a,
      activation: "enterprise_ai",
      probe: {:http, "OPTIMAL_FRACTAL_ENDPOINT", "/"},
      required_env: ["OPTIMAL_FRACTAL_ENDPOINT", "OPTIMAL_FRACTAL_CREDENTIAL_REF"],
      optional_env: []
    }
  ]

  @spec list(keyword()) :: [map()]
  def list(opts \\ []) do
    Enum.map(@providers, &inspect_provider(&1, opts))
  end

  @spec get(String.t(), keyword()) :: {:ok, map()} | {:error, :not_found}
  def get(id, opts \\ []) do
    case Enum.find(@providers, &(&1.id == id)) do
      nil -> {:error, :not_found}
      provider -> {:ok, inspect_provider(provider, opts)}
    end
  end

  @spec provider_ids() :: [String.t()]
  def provider_ids, do: Enum.map(@providers, & &1.id)

  @doc """
  Round-trip proofs for the service providers, one entry per provider.

  A provider with an adapter is proved by writing and reading back an object;
  a provider without one is reported `adapter_missing`, which is the truth about
  it and not a passing grade. An unconfigured provider is `skipped`: nothing was
  attempted, so nothing is claimed.

  Embedded providers are absent here on purpose; their stores are proved by the
  logical store proofs instead of by a connection.
  """
  @spec proofs(keyword()) :: [map()]
  def proofs(opts \\ []) do
    @providers
    |> Enum.filter(&(&1.kind in ["service", "enterprise_partner"]))
    |> Enum.map(&proof_for(&1, opts))
  end

  defp proof_for(%{id: "s3"} = provider, opts) do
    if Enum.all?(provider.required_env, &present_env?/1) do
      case OptimalEngine.Storage.S3.Adapter.probe(opts) do
        {:ok, evidence} -> %{provider: "s3", status: "pass", evidence: evidence}
        {:error, reason} -> %{provider: "s3", status: "fail", evidence: %{error: inspect(reason)}}
      end
    else
      %{provider: "s3", status: "skipped", reason: "not configured"}
    end
  end

  defp proof_for(provider, _opts) do
    %{
      provider: provider.id,
      status: "adapter_missing",
      reason: "the engine ships no adapter for this provider"
    }
  end

  defp inspect_provider(provider, opts) do
    configured = Enum.all?(provider.required_env, &present_env?/1)
    missing = Enum.reject(provider.required_env, &present_env?/1)
    probe? = Keyword.get(opts, :probe, false)

    health =
      cond do
        provider.required_env != [] and not configured -> :not_configured
        probe? -> run_probe(provider.probe)
        provider.activation == "default_local" -> :healthy
        true -> :configured
      end

    adapter_implemented = adapter_implemented?(provider.adapter)
    lifecycle_state = lifecycle_state(provider, adapter_implemented, configured, health)

    provider
    |> Map.drop([:adapter, :probe, :required_env, :optional_env])
    |> Map.put(:adapter_implemented, adapter_implemented)
    |> Map.put(:adapter_module, adapter_name(provider.adapter, adapter_implemented))
    |> Map.put(:configured, configured)
    |> Map.put(:health, Atom.to_string(health))
    |> Map.put(:lifecycle_state, lifecycle_state)
    |> Map.put(:required_environment, provider.required_env)
    |> Map.put(:optional_environment, provider.optional_env)
    |> Map.put(:missing_environment, missing)
  end

  # A missing adapter outranks every configuration or probe result.
  defp lifecycle_state(_provider, false, _configured, _health), do: "adapter_missing"
  defp lifecycle_state(%{activation: "default_local"}, true, true, :healthy), do: "active"
  defp lifecycle_state(_provider, true, false, _health), do: "not_configured"
  defp lifecycle_state(_provider, true, true, :healthy), do: "available"
  defp lifecycle_state(_provider, true, true, :configured), do: "configured_unverified"
  defp lifecycle_state(_provider, true, true, _health), do: "unavailable"

  defp adapter_implemented?(nil), do: false
  defp adapter_implemented?(module) when is_atom(module), do: Code.ensure_loaded?(module)

  defp adapter_name(module, true), do: module |> Module.split() |> Enum.join(".")
  defp adapter_name(_module, false), do: nil

  defp run_probe(:runtime), do: :healthy

  defp run_probe(:store) do
    case safe_call(fn -> OptimalEngine.Store.raw_query("SELECT 1", []) end) do
      {:ok, [[1]]} -> :healthy
      _ -> :unreachable
    end
  end

  # The S3 probe is an authenticated request against the bucket, not a bare
  # connection test: an endpoint that answers an unauthenticated ping with 403
  # must not be reported as healthy storage.
  defp run_probe(:s3), do: OptimalEngine.Storage.S3.Adapter.health()

  defp run_probe(:root_path) do
    path = Application.get_env(:optimal_engine, :root_path, ".")
    if File.dir?(path), do: :healthy, else: :unreachable
  end

  defp run_probe({:module, module}) do
    if Code.ensure_loaded?(module), do: :healthy, else: :not_installed
  end

  defp run_probe({:executable, executable}) do
    if System.find_executable(executable), do: :healthy, else: :not_installed
  end

  defp run_probe({:tcp_url, env, default_port}) do
    with value when is_binary(value) <- System.get_env(env),
         {:ok, host, port} <- endpoint(value, default_port),
         {:ok, socket} <-
           :gen_tcp.connect(String.to_charlist(host), port, [:binary, active: false], 750) do
      :gen_tcp.close(socket)
      :healthy
    else
      _ -> :unreachable
    end
  end

  defp run_probe({:http, env, path}) do
    with base when is_binary(base) <- System.get_env(env),
         url <- String.trim_trailing(base, "/") <> path,
         {:ok, {{_, status, _}, _headers, _body}} when status in 200..499 <-
           safe_call(fn ->
             :httpc.request(:get, {String.to_charlist(url), []}, [timeout: 1_000], [])
           end) do
      :healthy
    else
      _ -> :unreachable
    end
  end

  defp endpoint(value, default_port) do
    uri = URI.parse(value)

    cond do
      is_binary(uri.host) -> {:ok, uri.host, uri.port || default_port}
      String.contains?(value, ":") -> parse_host_port(value, default_port)
      value != "" -> {:ok, value, default_port}
      true -> {:error, :invalid_endpoint}
    end
  end

  defp parse_host_port(value, default_port) do
    case String.split(value, ":", parts: 2) do
      [host, port] ->
        case Integer.parse(port) do
          {parsed, ""} -> {:ok, host, parsed}
          _ -> {:ok, host, default_port}
        end

      [host] ->
        {:ok, host, default_port}
    end
  end

  defp present_env?(name) do
    case System.get_env(name) do
      value when is_binary(value) -> String.trim(value) != ""
      _ -> false
    end
  end

  defp safe_call(fun) do
    fun.()
  rescue
    _ -> {:error, :probe_failed}
  catch
    :exit, _ -> {:error, :probe_failed}
  end
end
