defmodule OptimalEngine.Connectors.CredentialVault do
  @moduledoc """
  Connector credentials kept in OpenBao instead of the Engine database.

  Only with `OPTIMAL_CONNECTOR_CREDENTIAL_STORE=openbao` (and OpenBao
  configured: `OPTIMAL_OPENBAO_ADDR` and `OPTIMAL_OPENBAO_TOKEN`) are a
  connector's credentials written to the KV version 2 secret
  `optimal/connectors/<tenant>/<connector id>` under
  `OPTIMAL_OPENBAO_KV_MOUNT`, with the connector row holding only the marker
  `"credentials_store": "openbao"`: no ciphertext, no key, nothing a copy of
  the database could open. Otherwise, OpenBao configured or not, they are
  sealed into the row with `CONNECTOR_KEY` as before
  (`OptimalEngine.Connectors.Credential`): configuring OpenBao for secret
  references does not move credentials anywhere.

  `openbao` with OpenBao not configured refuses the write. Rows written either
  way keep being read the way they were written, so switching never strands
  a connector.

  Engine backups do not include OpenBao: a backup of the Engine database holds
  the marker, not the credentials. Back up OpenBao's own storage (for its
  integrated storage, `bao operator raft snapshot save`; for file storage, its
  data directory) together with its unseal keys, or a restored Engine has
  connectors whose credentials are gone.

  The path is derived from the row's own tenant and id, never read from the
  row, so a config cannot point a connector at another connector's secret.

  A sync reads the secret just before the adapter starts and holds it only for
  that cycle. OpenBao sealed, unreachable or refusing the token fails the
  sync (or the write) with that reason; deleting the connector deletes the
  secret.
  """

  alias OptimalEngine.Storage.OpenBao

  @marker_key "credentials_store"
  @marker "openbao"
  @mode_env "OPTIMAL_CONNECTOR_CREDENTIAL_STORE"

  @doc "The config key that marks a row whose credentials live in OpenBao."
  @spec marker_key() :: String.t()
  def marker_key, do: @marker_key

  @doc """
  Where new credentials go: `:openbao` only when
  `OPTIMAL_CONNECTOR_CREDENTIAL_STORE` is `openbao`; otherwise `:engine`,
  whether or not OpenBao is configured. An unknown value is read as unset.
  """
  @spec mode() :: :openbao | :engine
  def mode do
    case System.get_env(@mode_env) |> to_string() |> String.trim() |> String.downcase() do
      "openbao" -> :openbao
      _engine_or_unset -> :engine
    end
  end

  @doc "True when `config` says its credentials are in OpenBao."
  @spec stored?(map()) :: boolean()
  def stored?(config) when is_map(config), do: Map.get(config, @marker_key) == @marker
  def stored?(_config), do: false

  @doc "The KV path (under the mount) for a connector's credentials."
  @spec path(String.t(), String.t()) :: String.t()
  def path(tenant_id, connector_id), do: "optimal/connectors/#{tenant_id}/#{connector_id}"

  @doc """
  Writes `credentials` (a map) for the connector and returns `config` marked
  as stored in OpenBao, with any older database envelope dropped.
  """
  @spec put(map(), String.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def put(config, tenant_id, connector_id, credentials) when is_map(credentials) do
    # KV version 2 stores any JSON object, so a nested credential (an OAuth
    # token set) reads back exactly as it was written.
    with :ok <- OpenBao.kv_write(path(tenant_id, connector_id), credentials) do
      {:ok, config |> Map.delete("credentials_ciphertext") |> Map.put(@marker_key, @marker)}
    end
  end

  @doc """
  The connector's credentials, merged into `config` in place of the marker.
  Nothing stored at the path is `{:error, :credentials_not_found}`.
  """
  @spec get(map(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def get(config, tenant_id, connector_id) do
    case OpenBao.kv_read(path(tenant_id, connector_id)) do
      {:ok, data} -> {:ok, config |> Map.delete(@marker_key) |> Map.merge(data)}
      {:error, :not_found} -> {:error, :credentials_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Deletes the connector's credentials (every version). Nothing stored is `:ok`."
  @spec delete(String.t(), String.t()) :: :ok | {:error, term()}
  def delete(tenant_id, connector_id), do: OpenBao.kv_delete(path(tenant_id, connector_id))

  @doc """
  Moves credentials already sealed into connector rows (`CONNECTOR_KEY`
  envelopes) into OpenBao. See `OptimalEngine.Connectors.CredentialVault.Migration`.
  """
  @spec migrate(keyword()) ::
          {:ok, OptimalEngine.Connectors.CredentialVault.Migration.report()} | {:error, term()}
  def migrate(opts \\ []), do: OptimalEngine.Connectors.CredentialVault.Migration.run(opts)
end
