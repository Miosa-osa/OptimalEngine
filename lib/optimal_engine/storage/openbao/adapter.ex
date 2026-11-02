defmodule OptimalEngine.Storage.OpenBao.Adapter do
  @moduledoc """
  Storage provider adapter for OpenBao.

  Implements the `OptimalEngine.Storage.Provider` contract so the inventory
  reports `openbao` as implemented, configured and healthy instead of
  `adapter_missing`. Health is claimed only on evidence: an unsealed server
  that accepted the token. Nothing here returns, logs or embeds the token.
  """

  @behaviour OptimalEngine.Storage.Provider

  alias OptimalEngine.Storage.OpenBao

  @capabilities ~w(secrets kms pki)a

  @impl OptimalEngine.Storage.Provider
  def id, do: "openbao"

  @impl OptimalEngine.Storage.Provider
  def capabilities, do: @capabilities

  @impl OptimalEngine.Storage.Provider
  def describe do
    %{
      id: id(),
      name: "OpenBao",
      kind: "service",
      role: "secrets",
      capabilities: Enum.map(@capabilities, &Atom.to_string/1),
      operations: ~w(health lookup_self kv_write kv_read kv_delete),
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
      kv_mount: mount()
    }
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

  defp mount do
    case OpenBao.config() do
      {:ok, %{mount: mount}} -> mount
      _ -> nil
    end
  end
end
