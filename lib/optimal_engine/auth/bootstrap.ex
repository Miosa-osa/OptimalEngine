defmodule OptimalEngine.Auth.Bootstrap do
  @moduledoc """
  Registers the operator-supplied bootstrap key at boot.

  A shared instance runs with `OPTIMAL_AUTH_REQUIRED=true`, which also locks the
  endpoint that mints keys. An unattended deployment (a sandbox started by a
  control plane) has no human to mint the first key, so the operator generates
  a token and passes it in:

      OPTIMAL_BOOTSTRAP_KEY         oe_<24 hex>_<secret of 32+ chars>   (required to enable)
      OPTIMAL_BOOTSTRAP_TENANT      tenant id            (default "default")
      OPTIMAL_BOOTSTRAP_SCOPES      comma list           (default "read,write")
      OPTIMAL_BOOTSTRAP_WORKSPACES  comma list of slugs  (default "*")

  The scopes are explicit on purpose: an omitted list on a key means `*`.
  Boot is idempotent. Changing the token (rotation) registers the new key and
  revokes the previous bootstrap key. A malformed token fails the boot; it is
  never ignored, because the instance would then be unreachable.
  """

  require Logger

  alias OptimalEngine.Auth.ApiKey

  @source "bootstrap"

  @spec run(%{optional(String.t()) => String.t()}) :: :ok | {:error, term()}
  def run(env \\ System.get_env()) do
    case blank(env["OPTIMAL_BOOTSTRAP_KEY"]) do
      nil -> :ok
      token -> register(token, env)
    end
  end

  defp register(token, env) do
    tenant = blank(env["OPTIMAL_BOOTSTRAP_TENANT"]) || "default"

    attrs = %{
      tenant_id: tenant,
      name: "bootstrap",
      scopes: list(env["OPTIMAL_BOOTSTRAP_SCOPES"], ["read", "write"]),
      workspace_scope: list(env["OPTIMAL_BOOTSTRAP_WORKSPACES"], ["*"]),
      metadata: %{"source" => @source}
    }

    with {:ok, outcome} <- ApiKey.ensure(token, attrs),
         {:ok, id} <- id_of(token),
         :ok <- ApiKey.revoke_source(tenant, @source, id) do
      Logger.info("[Bootstrap] bootstrap key #{outcome} (id #{id})")
      :ok
    else
      {:error, reason} ->
        Logger.error("[Bootstrap] bootstrap key rejected: #{inspect(reason)}")
        {:error, {:bootstrap_key, reason}}
    end
  end

  defp id_of("oe_" <> <<id::binary-size(24), "_", _::binary>>), do: {:ok, id}
  defp id_of(_), do: {:error, :invalid_token}

  defp list(nil, default), do: default

  defp list(value, default) do
    case value
         |> String.split(",", trim: true)
         |> Enum.map(&String.trim/1)
         |> Enum.reject(&(&1 == "")) do
      [] -> default
      items -> items
    end
  end

  defp blank(nil), do: nil

  defp blank(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
