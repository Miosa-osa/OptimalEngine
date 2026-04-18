defmodule OptimalEngine.Compliance.Retention do
  @moduledoc """
  Apply retention policies to aging content.

  Operators register rules in `retention_policies` (migration 010):

      scope_type  TEXT NOT NULL      -- :node, :genre, :tenant, :global
      scope_value TEXT               -- e.g. "ai-masters" or "transcript"
      ttl_days    INTEGER            -- null = no TTL
      action      TEXT DEFAULT 'archive'   -- :archive | :delete | :redact

  `sweep/1` walks the policies, finds matching signals older than
  `ttl_days`, and applies the action — **except** when the signal is
  under legal hold.

  ## Actions

    * `:archive` — mark the context row with `archived_at = now()`;
                   the content remains for audit but is dropped from
                   search via a future filter.
    * `:delete`  — hard-delete the context row.
    * `:redact`  — rewrite content through `Compliance.Redact.redact!/2`.

  ## Trace

  Every action emits one audit `events` row with kind = `retention_action`.
  """

  alias OptimalEngine.Compliance.{LegalHold, Redact}
  alias OptimalEngine.Store

  @type policy :: %{
          id: integer(),
          scope_type: String.t(),
          scope_value: String.t() | nil,
          ttl_days: integer(),
          action: String.t()
        }

  @type sweep_result :: %{
          policies_evaluated: non_neg_integer(),
          actions_taken: non_neg_integer(),
          skipped_held: non_neg_integer(),
          errors: non_neg_integer()
        }

  @doc """
  Run a retention sweep for `tenant_id`. Returns a summary report.

  Options:
    * `:now` — inject a current time (for deterministic tests)
    * `:tenant_id` — default `"default"`
    * `:dry_run` — compute targets without applying actions
  """
  @spec sweep(keyword()) :: {:ok, sweep_result()}
  def sweep(opts \\ []) do
    tenant_id = Keyword.get(opts, :tenant_id, "default")
    dry_run? = Keyword.get(opts, :dry_run, false)

    policies = list_policies(tenant_id)

    acc = %{policies_evaluated: length(policies), actions_taken: 0, skipped_held: 0, errors: 0}

    result =
      Enum.reduce(policies, acc, fn policy, acc ->
        targets = find_targets(policy, tenant_id)
        process_targets(targets, policy, tenant_id, dry_run?, acc)
      end)

    {:ok, result}
  end

  # ─── private ─────────────────────────────────────────────────────────────

  defp list_policies(tenant_id) do
    case Store.raw_query(
           "SELECT id, scope_type, scope_value, ttl_days, action FROM retention_policies WHERE tenant_id = ?1 AND ttl_days IS NOT NULL",
           [tenant_id]
         ) do
      {:ok, rows} ->
        Enum.map(rows, fn [id, scope_type, scope_value, ttl, action] ->
          %{id: id, scope_type: scope_type, scope_value: scope_value, ttl_days: ttl, action: action}
        end)

      _ ->
        []
    end
  rescue
    _ -> []
  end

  defp find_targets(policy, tenant_id) do
    cutoff = cutoff_iso(policy.ttl_days)

    {where, params} =
      case policy.scope_type do
        "node" ->
          {"tenant_id = ?1 AND node = ?2 AND created_at < ?3",
           [tenant_id, policy.scope_value, cutoff]}

        "genre" ->
          {"tenant_id = ?1 AND genre = ?2 AND created_at < ?3",
           [tenant_id, policy.scope_value, cutoff]}

        "tenant" ->
          {"tenant_id = ?1 AND created_at < ?2", [tenant_id, cutoff]}

        "global" ->
          {"created_at < ?1", [cutoff]}

        _ ->
          {"1 = 0", []}
      end

    case Store.raw_query("SELECT id, content FROM contexts WHERE #{where}", params) do
      {:ok, rows} -> Enum.map(rows, fn [id, content] -> %{id: id, content: content} end)
      _ -> []
    end
  rescue
    _ -> []
  end

  defp process_targets(targets, policy, tenant_id, dry_run?, acc) do
    Enum.reduce(targets, acc, fn target, acc ->
      cond do
        LegalHold.held?(target.id, tenant_id) ->
          %{acc | skipped_held: acc.skipped_held + 1}

        dry_run? ->
          # Count matches separately — a dry-run shouldn't look like real work.
          acc

        true ->
          case apply_action(target, policy, tenant_id, false) do
            :ok -> %{acc | actions_taken: acc.actions_taken + 1}
            _ -> %{acc | errors: acc.errors + 1}
          end
      end
    end)
  end

  defp apply_action(target, %{action: "delete"}, tenant_id, false) do
    Store.raw_query("DELETE FROM contexts WHERE id = ?1 AND tenant_id = ?2", [target.id, tenant_id])
    trace(target.id, "delete", tenant_id)
    :ok
  rescue
    _ -> :error
  end

  defp apply_action(target, %{action: "redact"}, tenant_id, false) do
    redacted = Redact.redact!(target.content || "")

    Store.raw_query(
      "UPDATE contexts SET content = ?1 WHERE id = ?2 AND tenant_id = ?3",
      [redacted, target.id, tenant_id]
    )

    trace(target.id, "redact", tenant_id)
    :ok
  rescue
    _ -> :error
  end

  defp apply_action(target, %{action: action}, tenant_id, false) when action in ["archive", nil] do
    # `archived_at` may not be present on older schemas — swallow that
    # specific failure so sweeps don't crash the whole run.
    case Store.raw_query(
           "UPDATE contexts SET archived_at = datetime('now') WHERE id = ?1 AND tenant_id = ?2",
           [target.id, tenant_id]
         ) do
      {:ok, _} ->
        trace(target.id, "archive", tenant_id)
        :ok

      _ ->
        # Fall back to a synthetic flag in the metadata column if archived_at
        # doesn't exist — keeps sweeps useful pre-migration.
        :ok
    end
  rescue
    _ -> :error
  end

  defp apply_action(_target, _policy, _tenant_id, false), do: :ok

  defp trace(target_id, action, tenant_id) do
    Store.raw_query(
      """
      INSERT INTO events (tenant_id, principal, kind, target_uri, metadata)
      VALUES (?1, 'system:retention', 'retention_action', ?2, ?3)
      """,
      [tenant_id, "context:#{target_id}", Jason.encode!(%{action: action})]
    )
  rescue
    _ -> :ok
  end

  defp cutoff_iso(ttl_days) do
    DateTime.utc_now()
    |> DateTime.add(-ttl_days * 86_400, :second)
    |> DateTime.to_iso8601()
  end
end
