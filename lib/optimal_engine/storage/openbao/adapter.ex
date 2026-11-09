defmodule OptimalEngine.Storage.OpenBao.Adapter do
  @moduledoc """
  Storage provider adapter for OpenBao.

  Implements the `OptimalEngine.Storage.Provider` contract so the inventory
  reports `openbao` as implemented, configured and healthy instead of
  `adapter_missing`. Health is claimed only on evidence: an unsealed server
  that accepted the token. Nothing here returns, logs or embeds the token.

  The status also says what the Engine uses OpenBao for, without reading a
  secret: which of the Engine's secrets are OpenBao references
  (`OptimalEngine.Secrets`), where connector credentials are written
  (`OptimalEngine.Connectors.CredentialVault`) and the transit key backups are
  sealed under, if any.
  """

  @behaviour OptimalEngine.Storage.Provider

  alias OptimalEngine.Backup.Envelope
  alias OptimalEngine.Connectors.CredentialVault
  alias OptimalEngine.Secrets
  alias OptimalEngine.Storage.OpenBao

  @capabilities ~w(secrets kms pki)a

  @impl OptimalEngine.Storage.Provider
  def id, do: "openbao"

  @impl OptimalEngine.Storage.Provider
  def capabilities, do: @capabilities

  @doc """
  What the Engine routes through OpenBao now, from the configuration alone:
  `secret_references` when one of the Engine's secrets is an OpenBao
  reference, `connector_credentials` when
  `OPTIMAL_CONNECTOR_CREDENTIAL_STORE=openbao`, and `backup_key_wrapping`
  when a transit key wraps backup data keys. Empty when OpenBao is only
  probed, so it is reported `probe_only`.
  """
  @spec serves() :: [String.t()]
  def serves do
    [
      {"secret_references", Secrets.references() != []},
      {"connector_credentials", CredentialVault.mode() == :openbao},
      {"backup_key_wrapping", OpenBao.transit_key() != nil}
    ]
    |> Enum.filter(&elem(&1, 1))
    |> Enum.map(&elem(&1, 0))
  end

  @impl OptimalEngine.Storage.Provider
  def describe do
    %{
      id: id(),
      name: "OpenBao",
      kind: "service",
      role: "secrets",
      capabilities: Enum.map(@capabilities, &Atom.to_string/1),
      operations:
        ~w(health lookup_self kv_write kv_read kv_delete secret_reference connector_credentials transit_datakey transit_decrypt),
      protocol: "HTTP(S) API with X-Vault-Token; KV version 2 at OPTIMAL_OPENBAO_KV_MOUNT (secret)",
      durability: "holds managed secrets; recovery follows the secret manager's policy"
    }
  end

  @impl OptimalEngine.Storage.Provider
  def status(opts \\ []) do
    configured = OpenBao.configured?()

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
      kv_mount: mount(),
      secret_references: Secrets.references(),
      connector_credentials: Atom.to_string(CredentialVault.mode()),
      backup_transit_key: transit_key_id()
    }
  end

  @doc """
  Whether OpenBao is reachable, initialized and sealed, for the provider
  inventory (`runtime`). With `probe: true` it asks `sys/health` once
  (`checked: "live"`); otherwise it reports what the last data-path call found
  while its outage window is open (`checked: "last_call"`) or nothing
  (`checked: "not_checked"`), and asks OpenBao nothing. Never the token or the
  address.
  """
  @spec runtime(keyword()) :: map()
  def runtime(opts \\ []) do
    cond do
      not OpenBao.configured?() ->
        %{reachable: nil, initialized: nil, sealed: nil, checked: "not_configured"}

      Keyword.get(opts, :probe, false) ->
        opts |> OpenBao.server_state() |> Map.put(:checked, "live")

      true ->
        case OpenBao.last_outage() do
          :openbao_sealed ->
            %{reachable: true, initialized: nil, sealed: true, checked: "last_call"}

          :openbao_unreachable ->
            %{reachable: false, initialized: nil, sealed: nil, checked: "last_call"}

          nil ->
            %{reachable: nil, initialized: nil, sealed: nil, checked: "not_checked"}
        end
    end
  end

  @doc "Provider health: initialized, unsealed, token accepted. Never raises."
  @spec health(keyword()) :: OptimalEngine.Storage.Provider.health()
  def health(opts \\ []) do
    case OpenBao.health(opts) do
      :healthy -> :healthy
      :not_configured -> :not_configured
      _ -> :unreachable
    end
  end

  @doc "The full proof: a secret written, read back and deleted."
  @spec probe(keyword()) :: {:ok, map()} | {:error, term()}
  def probe(opts \\ []) do
    if OpenBao.configured?() do
      with {:ok, evidence} <- OpenBao.round_trip(opts) do
        {:ok, Map.put(evidence, :provider, id())}
      end
    else
      {:error, :not_configured}
    end
  end

  defp lifecycle_state(false, _health), do: "not_configured"
  defp lifecycle_state(true, :healthy), do: "available"
  defp lifecycle_state(true, :unknown), do: "configured_unverified"
  defp lifecycle_state(true, _health), do: "unavailable"

  defp transit_key_id do
    case OpenBao.transit_key() do
      nil -> nil
      transit -> Envelope.key_id(%{transit: transit})
    end
  end

  defp mount do
    case OpenBao.config() do
      {:ok, %{mount: mount}} -> mount
      _ -> nil
    end
  end
end
