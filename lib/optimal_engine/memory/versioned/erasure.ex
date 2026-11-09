defmodule OptimalEngine.Memory.Versioned.Erasure do
  @moduledoc """
  What forgetting a memory erases (`OptimalEngine.Memory.Versioned.forget/2`).

  Forgetting one version forgets the memory: every version of its chain (the
  versions that share its `root_memory_id`, earlier and later). A memory that
  extends or derives from it is a memory of its own and stays.

  Each forgotten version keeps its row, flagged `is_forgotten` with its reason
  and `forget_after`, so the forget is on record. Its text goes from
  everywhere the Engine put it or derived it, in the same transaction as the
  flag (`forget/3`), so a forget that cannot erase is not done at all and is
  not left flagged with its text in place:

    * the row's `content` (emptied), `content_hash` (a hash of the text lets a
      guess of the text be checked), `citation_uri` and `source_chunk_id`
      (cleared), and its `metadata`, of which only the governance keys
      (`security_labels`, `partition_ids`) stay;
    * its full-text entry (`memories_fts`);
    * its embedding row (`memory_embeddings`);
    * its source chunk, unless the chunk's context still exists or another
      live memory names it (the chunk's classifications, intents and
      embeddings go with it);
    * the source package the create and remember bridges staged the text in
      (`source_packages`, its id is the text's content id in the workspace,
      plus any package that names the memory in its metadata or URI), with the
      claims made from it, pending or reviewed, the facts that accepted those
      claims, and the package's episodes and decomposition runs.

  A package another live memory or a context of the workspace still holds the
  same text in is shared, and stays: that text is theirs.

  On PostgreSQL the posting lists are rewritten after the commit. The row
  trigger queued each version's key in the forget's own transaction
  (`optimal_fts_queue`), so the rewrite is on record before the forget
  returns: a refresh that fails here is the forget's error
  (`{:memory_erasure_failed, :fts_refresh, reason}`), the key stays queued,
  and the store's background refresh, or the refresh every search makes
  before it reads the index, removes the postings.

  Not covered here: the replication ledger (`sync_mutations`) keeps every
  change's whole row, and a peer pulling the workspace is served those rows.
  Redacting it for every erasure path is the ledger redaction's change;
  `test/memory/memory_forget_erasure_test.exs` asserts it under the
  `:ledger_redaction` tag, excluded until then.
  """

  alias OptimalEngine.Memory.Versioned
  alias OptimalEngine.Memory.Versioned.Store, as: VStore
  alias OptimalEngine.MemoryCore.ID
  alias OptimalEngine.Store
  alias OptimalEngine.Store.FullText

  @timeout 60_000

  # The metadata keys a forgotten row keeps: they decide who may see the row.
  @governed_keys ["security_labels", "partition_ids"]

  @doc """
  Forgets the memory `id` and every version of its chain: flags each one
  forgotten with `reason` and `forget_after` and erases its text, in one
  transaction, so either all of it happens or none does. The chain, and what
  to remove, are read inside the transaction, so a version, package or claim
  written meanwhile is either seen or serializes after the forget.

  Returns the versions as they were before the forget (to drop what was
  cached from their text) and how many rows each step changed. An `id` that
  names no memory is `{:ok, %{memories: [], removed: %{}}}`.
  """
  @spec forget(String.t(), String.t() | nil, String.t() | nil) ::
          {:ok, done()} | {:error, term()}
  def forget(id, reason, forget_after) when is_binary(id),
    do: erase(id, reason, forget_after, :keep_rows)

  @doc """
  Erases what `forget/3` erases, for the memory `id` and every version of its
  chain, then deletes the chain's rows: a hard delete. Returns what `forget/3`
  returns.
  """
  @spec delete(String.t()) :: {:ok, done()} | {:error, term()}
  def delete(id) when is_binary(id), do: erase(id, nil, nil, :delete_rows)

  @typedoc """
  What a forget or delete did: the versions as they were before (to drop what
  was cached from their text), the rows each step changed, and the full-text
  refresh after the commit (`:ok`, or its error: the rows are erased and the
  key stays queued for the store's next refresh).
  """
  @type done :: %{
          memories: [Versioned.t()],
          removed: %{atom() => non_neg_integer()},
          refresh: :ok | {:error, term()}
        }

  defp erase(id, reason, forget_after, rows) do
    result =
      Store.transaction(
        fn txn ->
          with {:ok, versions} <- chain(txn, id),
               {:ok, removed} <- erase_all(txn, versions, reason, forget_after),
               {:ok, removed} <- delete_rows(txn, versions, removed, rows) do
            {:ok, %{memories: versions, removed: removed}}
          end
        end,
        @timeout
      )

    with {:ok, %{memories: versions} = done} <- result do
      refresh = if versions == [], do: :ok, else: FullText.refresh(["memories_fts"])
      {:ok, Map.put(done, :refresh, refresh)}
    end
  end

  defp delete_rows(_txn, _versions, removed, :keep_rows), do: {:ok, removed}
  defp delete_rows(_txn, [], removed, :delete_rows), do: {:ok, removed}

  defp delete_rows(txn, versions, removed, :delete_rows) do
    ids = Jason.encode!(Enum.map(versions, & &1.id))

    case Store.txn_execute(
           txn,
           "DELETE FROM memories WHERE id IN (SELECT value FROM json_each(?1))",
           [ids]
         ) do
      {:ok, count} -> {:ok, Map.put(removed, :memories_deleted, count)}
      {:error, reason} -> {:error, {:memory_erasure_failed, :memories_deleted, reason}}
    end
  end

  @doc """
  The root a memory's chain is held by: its `root_memory_id`, or for a chain
  an older build wrote without one, the first version up its
  `parent_memory_id` links. `{:ok, nil}` when there is no such memory.
  """
  @spec root(term(), String.t()) :: {:ok, String.t() | nil} | {:error, term()}
  def root(txn, id) do
    with {:ok, rows} <-
           query(
             txn,
             """
             WITH RECURSIVE up(id, parent, root, depth) AS (
               SELECT id, parent_memory_id, root_memory_id, 0 FROM memories WHERE id = ?1
               UNION ALL
               SELECT m.id, m.parent_memory_id, m.root_memory_id, up.depth + 1
                 FROM memories m JOIN up ON m.id = up.parent
                WHERE up.root IS NULL AND up.depth < 10000
             )
             SELECT COALESCE(root, id) FROM up WHERE root IS NOT NULL OR parent IS NULL
             ORDER BY depth ASC LIMIT 1
             """,
             [id]
           ) do
      case rows do
        [[root]] -> {:ok, root}
        [] -> {:ok, nil}
      end
    end
  end

  # The memory and every version of its chain, in its workspace: those that
  # share its root, and those linked to the root through `parent_memory_id`
  # (a chain an older build wrote without `root_memory_id`). The root's row is
  # held first (`FOR UPDATE` on PostgreSQL), so an update of the chain
  # (`Versioned.update/2`, which holds it too) runs wholly before or after.
  defp chain(txn, id) do
    with {:ok, root} when is_binary(root) <- root(txn, id),
         :ok <- Store.txn_lock_row(txn, "memories", "id", root),
         {:ok, [[workspace]]} <-
           query(txn, "SELECT workspace_id FROM memories WHERE id = ?1", [id]),
         {:ok, rows} <-
           query(
             txn,
             """
             WITH RECURSIVE down(id, depth) AS (
               SELECT id, 0 FROM memories WHERE id = ?2
               UNION ALL
               SELECT m.id, down.depth + 1 FROM memories m JOIN down ON m.parent_memory_id = down.id
                WHERE down.depth < 10000
             )
             SELECT #{VStore.select_cols()} FROM memories
              WHERE workspace_id = ?1
                AND (root_memory_id = ?2 OR id = ?3 OR id IN (SELECT id FROM down))
              ORDER BY version ASC
             """,
             [workspace, root, id]
           ) do
      {:ok, Enum.map(rows, &Versioned.row_to_struct/1)}
    else
      {:ok, nil} -> {:ok, []}
      {:ok, []} -> {:ok, []}
      {:error, _} = error -> error
    end
  end

  defp erase_all(txn, versions, reason, forget_after) do
    chain_ids = Jason.encode!(Enum.map(versions, & &1.id))

    Enum.reduce_while(versions, {:ok, %{}}, fn memory, {:ok, removed} ->
      with {:ok, packages} <- packages(txn, memory, chain_ids),
           {:ok, claims} <- claims(txn, packages, memory),
           {:ok, facts} <- facts(txn, claims),
           {:ok, episodes} <- episodes(txn, packages),
           found = %{packages: packages, claims: claims, facts: facts, episodes: episodes},
           {:ok, counts} <-
             run(txn, steps(memory, found, chain_ids, reason, forget_after), %{}) do
        {:cont, {:ok, Map.merge(removed, counts, fn _key, a, b -> a + b end)}}
      else
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  # The packages that hold this memory's text and nothing that stays.
  defp packages(_txn, %{content: ""}, _chain_ids), do: {:ok, []}

  defp packages(txn, memory, chain_ids) do
    tenant = memory.tenant_id || "default"
    workspace = memory.workspace_id || "default"
    by_text = ID.content_id("sp", [tenant, ":", workspace, ":", ID.sha256(memory.content)])

    with {:ok, rows} <-
           query(
             txn,
             """
             SELECT id FROM source_packages
              WHERE id = ?1
                 OR source_uri = ?2
                 OR (CASE WHEN json_valid(metadata) THEN json_extract(metadata, '$.versioned_memory_id') END) = ?3
             """,
             [by_text, "memory://" <> memory.id, memory.id]
           ) do
      Enum.reduce_while(List.flatten(rows), {:ok, []}, fn package, {:ok, acc} ->
        case shared?(txn, package, chain_ids) do
          {:ok, true} -> {:cont, {:ok, acc}}
          {:ok, false} -> {:cont, {:ok, [package | acc]}}
          {:error, _} = error -> {:halt, error}
        end
      end)
    end
  end

  # Another live memory (not of the chain), or a context, of the package's
  # workspace holds its text.
  defp shared?(txn, package, chain_ids) do
    with {:ok, rows} <-
           query(
             txn,
             """
             SELECT 1 FROM source_packages p
              WHERE p.id = ?1
                AND (EXISTS (SELECT 1 FROM memories m
                              WHERE m.workspace_id = p.workspace_id
                                AND m.id NOT IN (SELECT value FROM json_each(?2))
                                AND m.is_forgotten = 0 AND m.content = p.raw_text)
                     OR EXISTS (SELECT 1 FROM contexts c
                                 WHERE c.workspace_id = p.workspace_id
                                   AND (CASE WHEN json_valid(c.metadata) THEN json_extract(c.metadata, '$.source_package_id') END) = p.id))
             """,
             [package, chain_ids]
           ) do
      {:ok, rows != []}
    end
  end

  # The claims made from those packages, and any claim that names the memory.
  defp claims(txn, packages, memory) do
    with {:ok, rows} <-
           query(
             txn,
             """
             SELECT id FROM claims
              WHERE source_package_id IN (SELECT value FROM json_each(?1))
                 OR (CASE WHEN json_valid(metadata) THEN json_extract(metadata, '$.versioned_memory_id') END) = ?2
             """,
             [Jason.encode!(packages), memory.id]
           ) do
      {:ok, List.flatten(rows)}
    end
  end

  # The facts that accepted one of the claims.
  defp facts(_txn, []), do: {:ok, []}

  defp facts(txn, claims) do
    with {:ok, rows} <-
           query(
             txn,
             """
             SELECT f.id FROM facts f
              WHERE EXISTS (
                SELECT 1
                  FROM json_each(CASE WHEN json_valid(f.accepted_claim_ids) THEN f.accepted_claim_ids ELSE '[]' END) j
                 WHERE j.value IN (SELECT value FROM json_each(?1)))
             """,
             [Jason.encode!(claims)]
           ) do
      {:ok, List.flatten(rows)}
    end
  end

  # The episodes recorded from one of the packages.
  defp episodes(_txn, []), do: {:ok, []}

  defp episodes(txn, packages) do
    with {:ok, rows} <-
           query(
             txn,
             """
             SELECT id FROM episodes
              WHERE (CASE WHEN json_valid(provenance) THEN json_extract(provenance, '$.source_package_id') END)
                    IN (SELECT value FROM json_each(?1))
             """,
             [Jason.encode!(packages)]
           ) do
      {:ok, List.flatten(rows)}
    end
  end

  # Children before parents, each by key.
  defp steps(memory, found, chain_ids, reason, forget_after) do
    pkgs = Jason.encode!(found.packages)
    claim_set = Jason.encode!(found.claims)

    fts =
      if FullText.postgres?(),
        do: [],
        else: [
          {:memories_fts,
           "DELETE FROM memories_fts WHERE rowid IN (SELECT rowid FROM memories WHERE id = ?1)",
           [memory.id]}
        ]

    fts ++
      chunk_step(memory, chain_ids) ++
      [
        {:memories,
         """
         UPDATE memories
            SET is_forgotten = 1, forget_reason = ?2, forget_after = ?3,
                content = '', content_hash = NULL, citation_uri = NULL, source_chunk_id = NULL,
                metadata = ?4, updated_at = datetime('now')
          WHERE id = ?1
         """, [memory.id, reason, forget_after, governed_metadata(memory.metadata)]},
        {:memory_embeddings, "DELETE FROM memory_embeddings WHERE memory_id = ?1", [memory.id]},
        {:facts, "DELETE FROM facts WHERE id IN (SELECT value FROM json_each(?1))",
         [Jason.encode!(found.facts)]},
        {:claims, "DELETE FROM claims WHERE id IN (SELECT value FROM json_each(?1))", [claim_set]},
        {:episodes, "DELETE FROM episodes WHERE id IN (SELECT value FROM json_each(?1))",
         [Jason.encode!(found.episodes)]},
        {:decomposition_runs,
         "DELETE FROM decomposition_runs WHERE source_package_id IN (SELECT value FROM json_each(?1))",
         [pkgs]},
        {:source_packages,
         "DELETE FROM source_packages WHERE id IN (SELECT value FROM json_each(?1))", [pkgs]}
      ]
  end

  # The chunk the memory was taken from goes, unless its context still exists
  # or a live memory outside the chain names it.
  defp chunk_step(%{source_chunk_id: chunk}, chain_ids) when is_binary(chunk) and chunk != "" do
    [
      {:chunks,
       """
       DELETE FROM chunks
        WHERE id = ?1
          AND NOT EXISTS (SELECT 1 FROM contexts c WHERE c.id = chunks.signal_id)
          AND NOT EXISTS (SELECT 1 FROM memories m
                           WHERE m.source_chunk_id = ?1 AND m.is_forgotten = 0
                             AND m.id NOT IN (SELECT value FROM json_each(?2)))
       """, [chunk, chain_ids]}
    ]
  end

  defp chunk_step(_memory, _chain_ids), do: []

  defp governed_metadata(metadata) when is_map(metadata),
    do: metadata |> Map.take(@governed_keys) |> Jason.encode!()

  defp governed_metadata(metadata) when is_binary(metadata) do
    case Jason.decode(metadata) do
      {:ok, map} when is_map(map) -> governed_metadata(map)
      _ -> "{}"
    end
  end

  defp governed_metadata(_metadata), do: "{}"

  defp query(txn, sql, params), do: Store.txn_query(txn, sql, params)

  defp run(_txn, [], removed), do: {:ok, removed}

  defp run(txn, [{key, sql, params} | rest], removed) do
    case Store.txn_execute(txn, sql, params) do
      {:ok, count} -> run(txn, rest, Map.put(removed, key, count))
      {:error, reason} -> {:error, {:memory_erasure_failed, key, reason}}
    end
  end
end
