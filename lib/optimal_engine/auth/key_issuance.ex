defmodule OptimalEngine.Auth.KeyIssuance do
  @moduledoc """
  Rules for minting an API key through the HTTP API.

  Delegation only narrows. A key minted by another key can never hold an
  operation scope, a workspace, a governed grant, or a lifetime its minter
  lacks; a field the request omits is inherited from the minter instead of
  falling back to the unrestricted default (except label and partition grants,
  below, where omitted means none). A minter whose scopes include
  `"*"` is the tenant's root authority and may issue any scopes and
  `permissions`, but never a workspace or lifetime outside its own, and never
  a label or partition grant it does not hold itself.

  Operation scopes are never unrestricted by omission: when a request leaves
  out `scopes` and the minter is root or there is no minter, the request is
  refused with `scopes_required`. A root minter that means `*` says so.

  The principal a new key acts as must already exist in the minter's tenant.
  An anonymous trusted local caller (authentication not required, no key)
  mints without a parent and is bound only by the principal check.

  Governed grants are the key metadata lists that governed recall reads:
  `allowed_partitions`, `allowed_security_labels`, and `permissions`.
  Label and partition grants are never inherited by omission: a request that
  leaves them out mints a key with none, which reads only what carries no label
  and no partition, and a request that names them gets them only if the minter
  holds them (a minter that holds `"*"` may give any). Without this a key minted
  from the bootstrap key would carry its `"*"`. A grant the request leaves out is
  written as an empty list, so a key minted here always carries both fields: the
  key grant backfill (migration 85) gives grants only to a key that carries
  neither, and must never reach one that was minted with none. `permissions` is
  inherited when omitted, as the operation scopes are.

  `rate_limit_per_minute` (a positive integer) gives the key its own rate
  limit bucket instead of the size profile's (`OptimalEngine.API.RateLimitPlug`).
  Like a lifetime it only narrows: a minter with a limit issues keys at or
  under it, and a key it mints without one inherits it.
  """

  alias OptimalEngine.Auth.ApiKey
  alias OptimalEngine.Identity.Principal

  @grant_fields ~w(allowed_partitions allowed_security_labels permissions)

  @doc "The governed grant fields a key may carry in its metadata."
  @spec grant_fields() :: [String.t()]
  def grant_fields, do: @grant_fields

  @doc """
  Builds `ApiKey.mint/1` attrs for a request `body` minted by `parent` (the
  caller's verified key, or nil for an anonymous local caller) in
  `tenant_id`.

  Returns `{:ok, attrs}` or `{:error, reason}` where `reason` is a stable
  string suitable for an API error body.
  """
  @spec attrs(ApiKey.t() | nil, String.t(), map()) :: {:ok, map()} | {:error, String.t()}
  def attrs(parent, tenant_id, body) when is_binary(tenant_id) and is_map(body) do
    with {:ok, name} <- name(body),
         {:ok, scopes} <- scopes(parent, body),
         {:ok, workspace_scope} <- workspace_scope(parent, body),
         {:ok, expires_at} <- expires_at(parent, body),
         {:ok, principal_id} <- principal(tenant_id, body),
         {:ok, grants} <- grants(parent, body),
         {:ok, rate_limit} <- rate_limit(parent, body) do
      attrs =
        %{
          tenant_id: tenant_id,
          name: name,
          scopes: scopes,
          workspace_scope: workspace_scope,
          expires_at: expires_at,
          principal_id: principal_id,
          metadata: put_rate_limit(grants, rate_limit)
        }
        |> Map.reject(fn {_field, value} -> is_nil(value) end)

      {:ok, attrs}
    end
  end

  defp name(%{"name" => name}) when is_binary(name) do
    if String.trim(name) == "", do: {:error, "name is required"}, else: {:ok, name}
  end

  defp name(_body), do: {:error, "name is required"}

  defp scopes(parent, body) do
    inherited = inherited(parent, :scopes)

    if is_nil(Map.get(body, "scopes")) and (is_nil(inherited) or "*" in inherited) do
      {:error, "scopes_required"}
    else
      with {:ok, requested} <- string_list(body, "scopes", inherited) do
        if root?(parent) or subset?(requested, parent && parent.scopes),
          do: {:ok, requested},
          else: {:error, "scope_exceeds_minter"}
      end
    end
  end

  defp workspace_scope(parent, body) do
    with {:ok, requested} <-
           string_list(body, "workspace_scope", inherited(parent, :workspace_scope)) do
      if subset?(requested, parent && parent.workspace_scope),
        do: {:ok, requested},
        else: {:error, "workspace_scope_exceeds_minter"}
    end
  end

  defp expires_at(parent, body) do
    parent_expiry = parent && parent.expires_at

    case {Map.get(body, "expires_at"), parent_expiry} do
      {nil, nil} ->
        {:ok, nil}

      {nil, inherited} ->
        {:ok, inherited}

      {requested, nil} ->
        with {:ok, _dt} <- parse_time(requested), do: {:ok, requested}

      {requested, ceiling} ->
        with {:ok, requested_dt} <- parse_time(requested),
             {:ok, ceiling_dt} <- parse_time(ceiling) do
          if DateTime.compare(requested_dt, ceiling_dt) == :gt,
            do: {:error, "expiry_exceeds_minter"},
            else: {:ok, requested}
        end
    end
  end

  defp rate_limit(parent, body) do
    held = parent_rate_limit(parent)

    case {Map.get(body, "rate_limit_per_minute"), held} do
      {nil, held} ->
        {:ok, held}

      {requested, _held} when not is_integer(requested) or requested < 1 ->
        {:error, "invalid rate_limit_per_minute"}

      {requested, nil} ->
        {:ok, requested}

      {requested, held} when requested <= held ->
        {:ok, requested}

      _ ->
        {:error, "rate_limit_exceeds_minter"}
    end
  end

  defp parent_rate_limit(%ApiKey{metadata: %{"rate_limit_per_minute" => limit}})
       when is_integer(limit) and limit > 0,
       do: limit

  defp parent_rate_limit(_parent), do: nil

  defp put_rate_limit(metadata, nil), do: metadata
  defp put_rate_limit(metadata, limit), do: Map.put(metadata, "rate_limit_per_minute", limit)

  defp principal(_tenant_id, body) when not is_map_key(body, "principal_id"), do: {:ok, nil}
  defp principal(_tenant_id, %{"principal_id" => nil}), do: {:ok, nil}

  defp principal(tenant_id, %{"principal_id" => id}) when is_binary(id) and id != "" do
    case Principal.get(id, tenant_id) do
      {:ok, _principal} -> {:ok, id}
      _ -> {:error, "principal_not_found"}
    end
  end

  defp principal(_tenant_id, _body), do: {:error, "invalid principal_id"}

  defp grants(parent, body) do
    result =
      Enum.reduce_while(@grant_fields, {:ok, %{}}, fn field, {:ok, acc} ->
        case grant(parent, body, field) do
          {:ok, nil} -> {:cont, {:ok, acc}}
          {:ok, values} -> {:cont, {:ok, Map.put(acc, field, values)}}
          {:error, _} = error -> {:halt, error}
        end
      end)

    with {:ok, granted} <- result, do: {:ok, Map.merge(@no_grants, granted)}
  end

  @inherited_grants ~w(permissions)

  # What a mint that names no label or partition grants writes: none, explicitly.
  @no_grants %{"allowed_partitions" => [], "allowed_security_labels" => []}

  # A root minter issues any operation scope and any `permissions`, but label
  # and partition grants only as far as it holds them: a "*" scope is not a
  # "*" grant, so a root-scoped key minted without grants cannot mint one.
  @held_grants ~w(allowed_partitions allowed_security_labels)

  defp grant(parent, body, field) do
    held = parent_grant(parent, field)
    default = if field in @inherited_grants, do: held

    with {:ok, requested} <- string_list(body, field, default) do
      cond do
        is_nil(requested) -> {:ok, nil}
        is_nil(parent) -> {:ok, requested}
        root?(parent) and field not in @held_grants -> {:ok, requested}
        subset?(requested, held || []) -> {:ok, requested}
        true -> {:error, "#{field}_exceeds_minter"}
      end
    end
  end

  defp parent_grant(nil, _field), do: nil

  defp parent_grant(%ApiKey{metadata: %{} = metadata}, field) do
    case Map.get(metadata, field) do
      values when is_list(values) -> Enum.map(values, &to_string/1)
      _ -> nil
    end
  end

  defp parent_grant(_parent, _field), do: nil

  defp inherited(nil, _field), do: nil
  defp inherited(parent, field), do: Map.get(parent, field)

  # A requested list must be strings only; absent means the given default.
  defp string_list(body, field, default) do
    case Map.get(body, field) do
      nil ->
        {:ok, default}

      values when is_list(values) ->
        if Enum.all?(values, &(is_binary(&1) and &1 != "")),
          do: {:ok, Enum.uniq(values)},
          else: {:error, "invalid #{field}"}

      _ ->
        {:error, "invalid #{field}"}
    end
  end

  defp root?(nil), do: false
  defp root?(parent), do: "*" in (parent.scopes || [])

  # Every requested value must be held; a held "*" covers anything, and a
  # requested "*" is only covered by a held "*". No minter means no bound.
  defp subset?(nil, _held), do: true
  defp subset?(_requested, nil), do: true

  defp subset?(requested, held) do
    "*" in held or Enum.all?(requested, &(&1 != "*" and &1 in held))
  end

  defp parse_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> {:ok, dt}
      _ -> {:error, "invalid expires_at"}
    end
  end

  defp parse_time(_value), do: {:error, "invalid expires_at"}
end
