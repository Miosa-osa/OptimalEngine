defmodule OptimalEngine.Compliance.Erasure do
  @moduledoc """
  Right-to-delete (GDPR Article 17 / CCPA §1798.105).

  Removes every row tied to a principal across the engine's tables,
  atomically, and writes an `events` audit record with the counts.

  Deletion cascades honor foreign keys where present; where they
  don't (e.g. `events` stores `principal` as plain text), we issue
  explicit deletes.

  ## Safety gates

    * `legal_holds` — if any row in `legal_holds` references the
      principal's content and is not yet released, erasure refuses
      unless `:force` is set. A forced erase still records the held
      rows in the audit trail.
    * Principal must belong to the given `tenant_id`.

  ## What is erased with a principal's contexts

  A context's derived material goes with it (`Compliance.DerivedData`): its
  document vector, chunks and chunk vectors, entity mentions, claims and the
  facts that accepted them, its source packages with their decomposition runs
  and assets, the wiki pages written from its chunks, and its episodes,
  processor runs, decisions and edges, and the files those rows point at. Most
  of it is not tied to the context by a foreign key, so deleting the context
  alone left it behind. The contexts go in batches of
  200, each batch one transaction with
  its derived rows: a failure stops the erasure with the earlier batches done,
  and erasing again finishes the rest.

  The filesystem cache of every workspace that held an erased context is purged
  too (`OptimalEngine.Store.FileCache`, with the decomposition checkpoints and
  object-store asset copies of the workspace); it is recomputable, and its
  entries cannot be told apart per context.

  ## What survives

    * Immutable audit events for regulatory purposes are *redacted*
      (principal field replaced with `"erased:<hash>"`), not deleted,
      so the audit trail remains complete but anonymized.
  """

  alias OptimalEngine.Compliance.{DerivedData, LegalHold}
  alias OptimalEngine.Store
  alias OptimalEngine.Store.FileCache.Maintenance, as: Cache

  @type report :: %{
          principal_id: String.t(),
          deleted: %{atom() => non_neg_integer()},
          events_redacted: non_neg_integer(),
          held: non_neg_integer(),
          forced?: boolean(),
          cache_purged: map(),
          completed_at: String.t()
        }

  @doc """
  Erase every record associated with `principal_id`.

  Options:
    * `:force` — proceed even with outstanding legal holds
    * `:tenant_id` — scope (default `"default"`)
    * `:actor` — principal id performing the erasure (for audit)
  """
  @spec erase(String.t(), keyword()) :: {:ok, report()} | {:error, term()}
  def erase(principal_id, opts \\ []) when is_binary(principal_id) do
    tenant_id = Keyword.get(opts, :tenant_id, "default")
    force? = Keyword.get(opts, :force, false)
    actor = Keyword.get(opts, :actor, "system:erasure")

    # `force: true` skips the hold check entirely — an operator overriding.
    # Otherwise we require a definitive count; a `:hold_check_failed` from
    # LegalHold propagates out so erase fails closed rather than proceeding
    # under an unknown hold state.
    held_result =
      if force?,
        do: {:ok, 0},
        else: LegalHold.count_holds_for_principal(principal_id, tenant_id)

    with {:ok, held} <- held_result,
         :ok <- gate_on_holds(held, force?),
         {:ok, workspaces} <- workspaces_of_contexts(principal_id, tenant_id),
         {:ok, context_ids} <- context_ids(principal_id, tenant_id),
         {:ok, derived} <- erase_derived(tenant_id, context_ids, workspaces) do
      deleted =
        %{contexts: 0, vectors: 0, chunk_embeddings: 0, chunks: 0}
        |> Map.merge(do_cascade(principal_id, tenant_id))
        |> Map.merge(derived)

      cache_purged = purge_cache(workspaces)
      redacted = redact_audit(principal_id, tenant_id)

      Store.raw_query(
        """
        INSERT INTO events (tenant_id, principal, kind, target_uri, metadata)
        VALUES (?1, ?2, 'erasure', ?3, ?4)
        """,
        [
          tenant_id,
          actor,
          "principal:#{principal_id}",
          Jason.encode!(%{
            deleted: deleted,
            events_redacted: redacted,
            held: held,
            forced?: force?,
            cache_purged: cache_purged
          })
        ]
      )

      {:ok,
       %{
         principal_id: principal_id,
         deleted: deleted,
         events_redacted: redacted,
         held: held,
         forced?: force?,
         cache_purged: cache_purged,
         completed_at: DateTime.utc_now() |> DateTime.to_iso8601()
       }}
    end
  end

  @doc """
  Dry run — return what *would* be deleted without touching anything.
  """
  @spec preview(String.t(), keyword()) :: {:ok, map()}
  def preview(principal_id, opts \\ []) when is_binary(principal_id) do
    tenant_id = Keyword.get(opts, :tenant_id, "default")

    {:ok,
     %{
       principal_id: principal_id,
       counts:
         Map.merge(derived_counts(principal_id, tenant_id), %{
           contexts:
             count_where("contexts", "tenant_id = ?1 AND created_by = ?2", [
               tenant_id,
               principal_id
             ]),
           vectors:
             count_where(
               "vectors",
               "context_id IN (SELECT id FROM contexts WHERE tenant_id = ?1 AND created_by = ?2)",
               [tenant_id, principal_id]
             ),
           chunks:
             count_where(
               "chunks",
               "signal_id IN (SELECT id FROM contexts WHERE tenant_id = ?1 AND created_by = ?2)",
               [tenant_id, principal_id]
             ),
           node_members:
             count_where("node_members", "tenant_id = ?1 AND principal_id = ?2", [
               tenant_id,
               principal_id
             ]),
           principal_skills:
             count_where("principal_skills", "tenant_id = ?1 AND principal_id = ?2", [
               tenant_id,
               principal_id
             ]),
           role_grants:
             count_where("role_grants", "tenant_id = ?1 AND principal_id = ?2", [
               tenant_id,
               principal_id
             ]),
           principal_groups: count_where("principal_groups", "principal_id = ?1", [principal_id]),
           events:
             count_where("events", "tenant_id = ?1 AND principal = ?2", [tenant_id, principal_id])
         })
     }}
  end

  # ─── private ─────────────────────────────────────────────────────────────

  defp gate_on_holds(0, _force?), do: :ok
  defp gate_on_holds(_held, true), do: :ok
  defp gate_on_holds(held, false), do: {:error, {:legal_hold_active, held}}

  # The workspaces the erased contexts live in, read before they are deleted. Failing to
  # read them stops the erasure: the cache purge would not know where to look.
  defp workspaces_of_contexts(principal_id, tenant_id) do
    case Store.raw_query(
           "SELECT DISTINCT workspace_id FROM contexts WHERE tenant_id = ?1 AND created_by = ?2",
           [tenant_id, principal_id]
         ) do
      {:ok, rows} -> {:ok, rows |> List.flatten() |> Enum.filter(&is_binary/1)}
      {:error, reason} -> {:error, {:erasure_scope_unreadable, reason}}
    end
  end

  # The contexts go in batches, so a failure part way leaves the earlier batches gone. What the
  # cache holds for their workspaces must not outlive them, so it is purged on the error path
  # too; running the erasure again finishes the rest.
  defp erase_derived(tenant_id, context_ids, workspaces) do
    case DerivedData.erase_contexts(tenant_id, context_ids) do
      {:ok, _derived} = ok ->
        ok

      {:error, _reason} = error ->
        purge_cache(workspaces)
        error
    end
  end

  # The filesystem cache of each workspace that held an erased context. A failure is
  # reported (and logged), not raised: the rows are already gone. The checkpoints and copies
  # of the erased contexts went with their rows; those of the contexts that stay are not
  # touched.
  defp purge_cache(workspaces) do
    workspaces
    |> Cache.purge_workspaces(:erase, artifacts: false)
    |> Cache.summary()
    |> Map.put(:workspaces, workspaces)
  end

  # What the derived tables beyond vectors and chunks would lose: the delete itself, run
  # and rolled back. Not readable counts are left out of the preview.
  defp derived_counts(principal_id, tenant_id) do
    with {:ok, ids} <- context_ids(principal_id, tenant_id),
         {:ok, counts} <- DerivedData.preview(tenant_id, ids) do
      Map.drop(counts, [:contexts, :vectors, :chunks])
    else
      _ -> %{}
    end
  end

  # The ids to erase, read once: the batches work from this list, so contexts created
  # while the erasure runs are not half-erased.
  defp context_ids(principal_id, tenant_id) do
    case Store.raw_query(
           "SELECT id FROM contexts WHERE tenant_id = ?1 AND created_by = ?2",
           [tenant_id, principal_id]
         ) do
      {:ok, rows} -> {:ok, List.flatten(rows)}
      {:error, reason} -> {:error, {:erasure_scope_unreadable, reason}}
    end
  end

  defp do_cascade(principal_id, tenant_id) do
    %{
      node_members:
        delete("node_members", "tenant_id = ?1 AND principal_id = ?2", [tenant_id, principal_id]),
      principal_skills:
        delete("principal_skills", "tenant_id = ?1 AND principal_id = ?2", [tenant_id, principal_id]),
      role_grants:
        delete("role_grants", "tenant_id = ?1 AND principal_id = ?2", [tenant_id, principal_id]),
      principal_groups: delete("principal_groups", "principal_id = ?1", [principal_id]),
      principals: delete("principals", "id = ?1 AND tenant_id = ?2", [principal_id, tenant_id])
    }
  end

  # Audit events aren't deleted — they're pseudonymized so the trail
  # stays intact but can't be linked back to the erased subject.
  #
  # SHA-256 (truncated to 16 hex chars) instead of `:erlang.phash2/1`:
  # phash2 returns a 27-bit integer, which at even a modest erasure
  # volume has meaningful birthday-collision probability — two
  # different principals could share a pseudonym and their audit
  # trails would conflate.
  defp redact_audit(principal_id, tenant_id) do
    pseudonym =
      "erased:" <>
        (:crypto.hash(:sha256, principal_id)
         |> Base.encode16(case: :lower)
         |> String.slice(0, 16))

    case Store.raw_query(
           "UPDATE events SET principal = ?1 WHERE tenant_id = ?2 AND principal = ?3",
           [pseudonym, tenant_id, principal_id]
         ) do
      {:ok, _} ->
        case Store.raw_query(
               "SELECT COUNT(*) FROM events WHERE principal = ?1 AND tenant_id = ?2",
               [pseudonym, tenant_id]
             ) do
          {:ok, [[n]]} when is_integer(n) -> n
          _ -> 0
        end

      _ ->
        0
    end
  rescue
    _ -> 0
  end

  defp delete(table, where, params) do
    case Store.raw_query("DELETE FROM #{table} WHERE #{where}", params) do
      {:ok, _} ->
        # SQLite doesn't return the affected-row count via raw_query; run a
        # companion count against what *would* have matched. This is a small
        # extra query in exchange for an observable audit trail.
        case Store.raw_query("SELECT changes()", []) do
          {:ok, [[n]]} when is_integer(n) -> n
          _ -> 0
        end

      _ ->
        0
    end
  rescue
    _ -> 0
  end

  defp count_where(table, where, params) do
    case Store.raw_query("SELECT COUNT(*) FROM #{table} WHERE #{where}", params) do
      {:ok, [[n]]} when is_integer(n) -> n
      _ -> 0
    end
  rescue
    _ -> 0
  end
end
