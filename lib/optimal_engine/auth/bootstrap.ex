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

  A bootstrap key whose scopes include `*` or `admin` is the operator's own
  root, which may mint any grant, so it also holds every label and partition
  grant (`allowed_security_labels` and `allowed_partitions` of `["*"]`) and
  reads what the exports and conflict records show in full. A key with only
  `read,write` gets no grants at all and reads what carries no label and no
  partition. A key minted from the bootstrap key gets only the grants it is
  minted with, never the minter's by omission.

  A bootstrap key registered before the grants existed is given them once,
  with a warning in the log, and marked `grants_initialized`, so that narrowing
  them later (to a list, or `[]` for none) is never undone at the next boot.

  The scopes and the workspaces of the environment are the key's at every boot:
  when they differ from what the key holds (the operator changed the list and
  kept the token), the key is brought to them, with a warning in the log. A key
  that stops being root loses its `"*"` grants (the other grants stay); a key
  that becomes root is given them once, like a key that predates the grants.
  Boot is idempotent. Changing the token (rotation) registers a new key with
  the defaults for its scopes and revokes the previous bootstrap key: grants an
  operator narrowed on the old key are not carried over, so set them again on
  the new one. A malformed token fails the boot; it is never ignored, because
  the instance would then be unreachable.
  """

  require Logger

  alias OptimalEngine.Auth.ApiKey
  alias OptimalEngine.Store

  @source "bootstrap"
  @root_scopes ["*", "admin"]

  @spec run(%{optional(String.t()) => String.t()}) :: :ok | {:error, term()}
  def run(env \\ System.get_env()) do
    case blank(env["OPTIMAL_BOOTSTRAP_KEY"]) do
      nil -> :ok
      token -> register(token, env)
    end
  end

  defp register(token, env) do
    tenant = blank(env["OPTIMAL_BOOTSTRAP_TENANT"]) || "default"

    scopes = list(env["OPTIMAL_BOOTSTRAP_SCOPES"], ["read", "write"])

    metadata =
      if root?(scopes),
        do: Map.put(all_grants(), "source", @source),
        else: %{"source" => @source}

    workspaces = list(env["OPTIMAL_BOOTSTRAP_WORKSPACES"], ["*"])

    attrs = %{
      tenant_id: tenant,
      name: "bootstrap",
      scopes: scopes,
      workspace_scope: workspaces,
      metadata: metadata
    }

    with {:ok, outcome} <- ApiKey.ensure(token, attrs),
         {:ok, id} <- id_of(token),
         :ok <- reconcile(id, scopes, workspaces),
         :ok <- grant_reads(id),
         :ok <- ApiKey.revoke_source(tenant, @source, id) do
      Logger.info("[Bootstrap] bootstrap key #{outcome} (id #{id})")
      :ok
    else
      {:error, reason} ->
        Logger.error("[Bootstrap] bootstrap key rejected: #{inspect(reason)}")
        {:error, {:bootstrap_key, reason}}
    end
  end

  defp root?(scopes), do: Enum.any?(scopes, &(&1 in @root_scopes))

  # `ApiKey.ensure/2` leaves a key that exists as it is. The environment is the
  # operator's statement of what the key may do, so a key that holds something
  # else (the list was edited and the token kept) is brought to it. A key that
  # stops being root gives up its wildcard grants; the others stay.
  defp reconcile(id, scopes, workspaces) do
    with {:ok, [[held_scopes, held_workspaces, metadata]]} <-
           Store.raw_query(
             "SELECT scopes, workspace_scope, metadata FROM api_keys WHERE id = ?1 AND json_extract(metadata, '$.source') = ?2",
             [id, @source]
           ) do
      held_scopes = decode_list(held_scopes)

      if held_scopes == scopes and decode_list(held_workspaces) == workspaces do
        :ok
      else
        Logger.warning(
          "[Bootstrap] the bootstrap key (id #{id}) held scopes #{inspect(held_scopes)} and workspaces " <>
            "#{inspect(decode_list(held_workspaces))}; it now holds scopes #{inspect(scopes)} and " <>
            "workspaces #{inspect(workspaces)}, as the environment says."
        )

        with {:ok, _} <-
               Store.raw_query(
                 "UPDATE api_keys SET scopes = ?2, workspace_scope = ?3 WHERE id = ?1",
                 [
                   id,
                   Jason.encode!(scopes),
                   Jason.encode!(workspaces)
                 ]
               ) do
          if root?(held_scopes) and not root?(scopes), do: drop_wildcards(id, metadata), else: :ok
        end
      end
    else
      {:ok, []} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp drop_wildcards(id, metadata) do
    metadata = decode_map(metadata)

    grants =
      for field <- ["allowed_security_labels", "allowed_partitions"],
          is_list(metadata[field]) and "*" in metadata[field],
          do: {field, Enum.reject(metadata[field], &(&1 == "*"))}

    if grants == [] do
      :ok
    else
      Logger.warning(
        "[Bootstrap] the bootstrap key (id #{id}) is no longer root, so it no longer holds the " <>
          "wildcard grant of #{Enum.map_join(grants, " and ", &elem(&1, 0))}."
      )

      Enum.reduce_while(grants, :ok, fn {field, kept}, :ok ->
        case Store.raw_query(
               "UPDATE api_keys SET metadata = json_set(COALESCE(metadata, '{}'), '$.' || ?2, json(?3)) WHERE id = ?1",
               [id, field, Jason.encode!(kept)]
             ) do
          {:ok, _} -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp decode_list(json) do
    case Jason.decode(json || "") do
      {:ok, list} when is_list(list) -> list
      _ -> []
    end
  end

  defp decode_map(json) do
    case Jason.decode(json || "") do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end

  defp all_grants do
    %{
      "allowed_security_labels" => ["*"],
      "allowed_partitions" => ["*"],
      "grants_initialized" => true
    }
  end

  # A root bootstrap key registered before the grants existed gets them once.
  # One that has been through here, or has grants of its own (a list, or `[]`
  # for none), keeps what it has; a key without a root scope never gets them.
  defp grant_reads(id) do
    where = """
    WHERE id = ?1 AND json_extract(metadata, '$.source') = ?2
      AND json_extract(metadata, '$.grants_initialized') IS NULL
      AND json_extract(metadata, '$.allowed_security_labels') IS NULL
      AND json_extract(metadata, '$.allowed_partitions') IS NULL
      AND EXISTS (SELECT 1 FROM json_each(api_keys.scopes) WHERE value IN ('*', 'admin'))
    """

    with {:ok, rows} <- Store.raw_query("SELECT 1 FROM api_keys " <> where, [id, @source]),
         true <- rows != [] do
      Logger.warning(
        "[Bootstrap] the bootstrap key (id #{id}) was registered before label and partition grants existed; " <>
          "it now holds every label and every partition. Narrow allowed_security_labels and allowed_partitions " <>
          "in its metadata (a list, or [] for none) to change that; it is not widened again."
      )

      update = """
      UPDATE api_keys
      SET metadata = json_set(COALESCE(metadata, '{}'),
                              '$.allowed_security_labels', json('["*"]'),
                              '$.allowed_partitions', json('["*"]'),
                              '$.grants_initialized', json('true'))
      """

      case Store.raw_query(update <> where, [id, @source]) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      false -> :ok
      {:error, reason} -> {:error, reason}
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
