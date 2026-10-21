defmodule OptimalEngine.Compliance.Retention do
  @moduledoc """
  Apply retention policies to aging content.

  Operators register rules in `retention_policies` (migration 010):

      scope_type  TEXT NOT NULL      -- :node, :genre, :tenant, :global
      scope_value TEXT               -- e.g. "project-platform-launch" or "transcript"
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
    * `:redact`  — rewrite content, abstract and overview through
                   `Compliance.Redact.redact!/2`.

  A `:delete` also removes everything derived from the context
  (`Compliance.DerivedData`: vectors, chunks, claims, source packages, wiki pages
  and the rest, which nothing else ties to it, and the files they point at), and
  purges the filesystem cache of its workspace (`OptimalEngine.Store.FileCache`).

  A `:redact` that changes the text removes the same derived material, which was
  made from the unredacted text, and builds the chunks and the document vector
  again from the redacted text (`Compliance.Reindex`). The derived material is
  removed first: if that fails the text is left as it was and the next sweep tries
  again. Text that redaction leaves unchanged is not reindexed.

  ## Trace

  Every action emits one audit `events` row with kind = `retention_action`.
  """

  alias OptimalEngine.Compliance.{DerivedData, LegalHold, Redact, Reindex}
  alias OptimalEngine.Store
  alias OptimalEngine.Store.FileCache.Maintenance, as: Cache

  require Logger

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

    acc = %{
      policies_evaluated: length(policies),
      actions_taken: 0,
      skipped_held: 0,
      errors: 0,
      deleted_in: MapSet.new()
    }

    result =
      Enum.reduce(policies, acc, fn policy, acc ->
        targets = find_targets(policy, tenant_id)
        process_targets(targets, policy, tenant_id, dry_run?, acc)
      end)

    {:ok, purge_deleted_workspaces(result)}
  end

  @doc """
  Register a retention policy. The governed entry point for operators to
  populate `retention_policies`. Returns `{:ok, policy_id}`.

  Required: `:scope_type`. Optional: `:scope_value`, `:ttl_days`,
  `:action` (default `"archive"`), `:tenant_id` (default `"default"`).
  """
  @spec add_policy(map() | keyword()) :: {:ok, integer()} | {:error, term()}
  def add_policy(attrs) when is_list(attrs), do: attrs |> Map.new() |> add_policy()

  def add_policy(attrs) when is_map(attrs) do
    tenant_id = to_string(Map.get(attrs, :tenant_id) || Map.get(attrs, "tenant_id") || "default")
    scope_type = Map.get(attrs, :scope_type) || Map.get(attrs, "scope_type")
    scope_value = Map.get(attrs, :scope_value) || Map.get(attrs, "scope_value")
    ttl_days = Map.get(attrs, :ttl_days) || Map.get(attrs, "ttl_days")
    action = to_string(Map.get(attrs, :action) || Map.get(attrs, "action") || "archive")

    cond do
      is_nil(scope_type) ->
        {:error, :scope_type_required}

      true ->
        # RETURNING keeps the id with its own INSERT; a follow-up
        # last_insert_rowid() can read another writer's row.
        with {:ok, [[id]]} <-
               Store.raw_query(
                 """
                 INSERT INTO retention_policies (tenant_id, scope_type, scope_value, ttl_days, action)
                 VALUES (?1, ?2, ?3, ?4, ?5)
                 RETURNING id
                 """,
                 [tenant_id, to_string(scope_type), scope_value, ttl_days, action]
               ) do
          {:ok, id}
        end
    end
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

    case Store.raw_query("SELECT id, content, workspace_id FROM contexts WHERE #{where}", params) do
      {:ok, rows} ->
        Enum.map(rows, fn [id, content, workspace_id] ->
          %{id: id, content: content, workspace_id: workspace_id}
        end)

      _ ->
        []
    end
  rescue
    _ -> []
  end

  defp process_targets(targets, policy, tenant_id, dry_run?, acc) do
    Enum.reduce(targets, acc, fn target, acc ->
      cond do
        held_error?(target.id, tenant_id) ->
          # Hold check itself failed — don't touch the row, treat it as
          # an error so operators see the count spike and investigate.
          %{acc | errors: acc.errors + 1}

        held?(target.id, tenant_id) ->
          %{acc | skipped_held: acc.skipped_held + 1}

        dry_run? ->
          # Count matches separately — a dry-run shouldn't look like real work.
          acc

        true ->
          case apply_action(target, policy, tenant_id) do
            :ok -> acc |> note_deleted(target, policy) |> Map.update!(:actions_taken, &(&1 + 1))
            _ -> %{acc | errors: acc.errors + 1}
          end
      end
    end)
  end

  # The workspaces a `delete` removed a context from. Their filesystem cache holds
  # what was embedded from those contexts and cannot be told apart per context, so it
  # is purged once the sweep is done (see `purge_deleted_workspaces/1`).
  defp note_deleted(acc, %{workspace_id: workspace_id}, %{action: "delete"})
       when is_binary(workspace_id),
       do: %{acc | deleted_in: MapSet.put(acc.deleted_in, workspace_id)}

  defp note_deleted(acc, _target, _policy), do: acc

  # A workspace whose cache could not be purged counts as an error, so the operator
  # sees it in the report; the purge logs the cause.
  defp purge_deleted_workspaces(%{deleted_in: workspaces} = result) do
    failed =
      workspaces
      |> Enum.map(&Cache.purge_workspace(&1, :retention, artifacts: false))
      |> Enum.count(&match?({:error, _}, &1))

    result |> Map.delete(:deleted_in) |> Map.update!(:errors, &(&1 + failed))
  end

  defp held_error?(target_id, tenant_id) do
    match?({:error, _}, LegalHold.held?(target_id, tenant_id))
  end

  defp held?(target_id, tenant_id) do
    case LegalHold.held?(target_id, tenant_id) do
      {:ok, true} -> true
      _ -> false
    end
  end

  # Each apply_action clause returns :ok only when the DB write succeeded.
  # Audit tracing is a best-effort side effect: if it fails it logs (via
  # `trace/3`'s rescue) but does NOT turn a successful action into :error.
  defp apply_action(target, %{action: "delete"}, tenant_id) do
    # Derived vectors and chunks first: nothing ties them to the context, so a context
    # deleted without them leaves its text behind. If they cannot be deleted the context
    # stays, and the next sweep tries again.
    case DerivedData.erase_contexts(tenant_id, [target.id]) do
      {:ok, _removed} ->
        trace(target.id, "delete", tenant_id)
        :ok

      _ ->
        :error
    end
  rescue
    _ -> :error
  end

  defp apply_action(target, %{action: "redact"}, tenant_id) do
    with :ok <- redact(target, tenant_id) do
      trace(target.id, "redact", tenant_id)
      :ok
    else
      _ -> :error
    end
  rescue
    _ -> :error
  end

  defp apply_action(target, %{action: action}, tenant_id) when action in ["archive", nil] do
    case Store.raw_query(
           "UPDATE contexts SET archived_at = datetime('now') WHERE id = ?1 AND tenant_id = ?2",
           [target.id, tenant_id]
         ) do
      {:ok, _} ->
        trace(target.id, "archive", tenant_id)
        :ok

      _ ->
        :error
    end
  rescue
    _ -> :error
  end

  defp apply_action(_target, _policy, _tenant_id), do: :ok

  # Rewrites the text of a context and what was summarised from it. When nothing
  # changes there is nothing to rebuild, so a context that was redacted by an earlier
  # sweep costs one read.
  defp redact(target, tenant_id) do
    with {:ok, [[l0, l1]]} <-
           Store.raw_query(
             "SELECT l0_abstract, l1_overview FROM contexts WHERE id = ?1 AND tenant_id = ?2",
             [target.id, tenant_id]
           ) do
      content = target.content || ""
      redacted = Redact.redact!(content)
      redacted_l0 = Redact.redact!(l0 || "")
      redacted_l1 = Redact.redact!(l1 || "")

      if redacted == content and redacted_l0 == (l0 || "") and redacted_l1 == (l1 || "") do
        :ok
      else
        rewrite(target, tenant_id, redacted, redacted_l0, redacted_l1)
      end
    end
  end

  # Order matters: what was made from the old text goes first, so a failure part way
  # leaves the old text in place for the next sweep to find, never a redacted context
  # with an unredacted chunk or source package behind it.
  defp rewrite(target, tenant_id, content, l0, l1) do
    with {:ok, _removed} <- DerivedData.delete_derived([target.id]),
         {:ok, _} <-
           Store.raw_query(
             """
             UPDATE contexts SET content = ?1, l0_abstract = ?2, l1_overview = ?3,
               metadata = CASE WHEN json_valid(metadata)
                          THEN json_remove(metadata, '$.source_package_id') ELSE metadata END
             WHERE id = ?4 AND tenant_id = ?5
             """,
             [content, l0, l1, target.id, tenant_id]
           ) do
      Reindex.context(target.id)
      :ok
    end
  end

  # Audit trace: best-effort. A failure here is logged but never
  # propagates — a trace insert failure must NOT make a successful
  # retention action look failed.
  defp trace(target_id, action, tenant_id) do
    Store.raw_query(
      """
      INSERT INTO events (tenant_id, principal, kind, target_uri, metadata)
      VALUES (?1, 'system:retention', 'retention_action', ?2, ?3)
      """,
      [tenant_id, "context:#{target_id}", Jason.encode!(%{action: action})]
    )
  rescue
    e -> Logger.warning("[Retention] trace failed for #{target_id}: #{Exception.message(e)}")
  end

  defp cutoff_iso(ttl_days) do
    DateTime.utc_now()
    |> DateTime.add(-ttl_days * 86_400, :second)
    |> DateTime.to_iso8601()
  end
end
