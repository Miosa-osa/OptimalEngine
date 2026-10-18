defmodule OptimalEngine.Authority.Settings do
  @moduledoc """
  Per-tenant authority mode for the Engine's own data routes.

  * `off` (default) - routes behave as before; authority APIs still work.
  * `observe` - every route decision is evaluated and refusals are recorded
    as evidence, but nothing is blocked. Use it to tune packs before
    enforcing.
  * `enforce` - a route runs only if the decision allows it or the request
    presents a grant that admits it.

  The deployment default can be set with `OPTIMAL_AUTHORITY_MODE`; a tenant
  row overrides it.
  """

  alias OptimalEngine.Store

  @modes ~w(off observe enforce)

  @doc "The modes, least to most strict."
  @spec modes() :: [String.t()]
  def modes, do: @modes

  @doc """
  The tenant's mode. Read on every API request, so it is cached in a
  persistent term and refreshed by `put_mode/3`.
  """
  @spec mode(String.t()) :: String.t()
  def mode(tenant_id) do
    case :persistent_term.get({__MODULE__, tenant_id}, nil) do
      nil ->
        mode = stored_mode(tenant_id)
        :persistent_term.put({__MODULE__, tenant_id}, mode)
        mode

      mode ->
        mode
    end
  end

  defp stored_mode(tenant_id) do
    case Store.raw_query("SELECT mode FROM authority_settings WHERE tenant_id = ?1", [tenant_id]) do
      {:ok, [[mode]]} when mode in @modes -> mode
      _ -> default_mode()
    end
  end

  @doc "Sets the tenant's mode."
  @spec put_mode(String.t(), String.t(), String.t()) :: :ok | {:error, :invalid_mode}
  def put_mode(tenant_id, mode, updated_by) when mode in @modes do
    {:ok, _} =
      Store.raw_query(
        """
        INSERT INTO authority_settings (tenant_id, mode, updated_by, updated_at)
        VALUES (?1, ?2, ?3, datetime('now'))
        ON CONFLICT(tenant_id) DO UPDATE SET
          mode = excluded.mode, updated_by = excluded.updated_by, updated_at = excluded.updated_at
        """,
        [tenant_id, mode, updated_by]
      )

    :persistent_term.put({__MODULE__, tenant_id}, mode)
    :ok
  end

  def put_mode(_tenant_id, _mode, _updated_by), do: {:error, :invalid_mode}

  defp default_mode do
    case Application.get_env(:optimal_engine, :authority_mode) do
      mode when mode in @modes -> mode
      _ -> "off"
    end
  end
end
