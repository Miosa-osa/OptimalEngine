defmodule OptimalEngine.Memory.Versioned.Erasure do
  @moduledoc """
  What forgetting a memory erases (`OptimalEngine.Memory.Versioned.forget/2`).

  A forgotten memory keeps its row, flagged `is_forgotten` with its reason and
  `forget_after`, so the forget is on record. Its text goes from everywhere
  the Engine put it or derived it, in the same transaction as the flag
  (`forget/3`), so a forget that cannot erase is not done at all and is not
  left flagged with its text in place:

    * the row's `content` (emptied) and its full-text entry (`memories_fts`;
      on PostgreSQL the posting lists are refreshed after the commit);
    * its embedding row (`memory_embeddings`);
    * the source package the create and remember bridges staged the text in
      (`source_packages`, its id is the text's content id in the workspace,
      plus any package that names the memory in its metadata or URI), with the
      claims made from it, pending or reviewed, the facts that accepted those
      claims, and the package's episodes and decomposition runs.

  A package another live memory or a context of the workspace still holds the
  same text in is shared, and stays: that text is theirs.

  The replication ledger still holds the text: `sync_mutations` keeps every
  change's whole row, the memory's create and the flagging update included,
  and a peer pulling the workspace is served those rows. Redacting the ledger
  for every erasure path is a change of its own (pending, in the ledger
  redaction PR); `test/memory/memory_forget_erasure_test.exs` asserts it under
  the `:ledger_redaction` tag, excluded until then.

  On PostgreSQL the posting lists are refreshed after the commit; a refresh
  that fails is the forget's error (`{:memory_erasure_failed, :fts_refresh,
  reason}`), never silence, though the rows are already erased and the next
  refresh, which runs before any search reads the index, catches up.
  """

  alias OptimalEngine.MemoryCore.ID
  alias OptimalEngine.Store
  alias OptimalEngine.Store.FullText

  @timeout 60_000

  @doc """
  Flags `memory` (a `OptimalEngine.Memory.Versioned` struct read before the
  forget) forgotten with `reason` and `forget_after`, and erases its text, in
  one transaction: either both happen or neither does. What to remove is
  looked up inside the transaction too, so a package or claim written
  meanwhile is either seen or serializes after the forget. Returns how many
  rows each step changed.
  """
  @spec forget(map(), String.t() | nil, String.t() | nil) ::
          {:ok, %{atom() => non_neg_integer()}} | {:error, term()}
  def forget(%{id: id, content: content} = memory, reason, forget_after)
      when is_binary(id) and is_binary(content) do
    result =
      Store.transaction(
        fn txn ->
          with {:ok, _} <-
                 Store.txn_execute(
                   txn,
                   """
                   UPDATE memories
                   SET is_forgotten = 1, forget_reason = ?2, forget_after = ?3,
                       updated_at = datetime('now')
                   WHERE id = ?1
                   """,
                   [id, reason, forget_after]
                 ),
               {:ok, packages} <- packages(txn, memory),
               {:ok, claims} <- claims(txn, packages, memory),
               {:ok, facts} <- facts(txn, claims),
               {:ok, episodes} <- episodes(txn, packages) do
            found = %{packages: packages, claims: claims, facts: facts, episodes: episodes}
            run(txn, steps(memory, found), %{})
          end
        end,
        @timeout
      )

    with {:ok, removed} <- result do
      refresh = Application.get_env(:optimal_engine, :memory_erasure_refresh, &FullText.refresh/1)

      case refresh.(["memories_fts"]) do
        :ok -> {:ok, removed}
        {:error, reason} -> {:error, {:memory_erasure_failed, :fts_refresh, reason}}
      end
    end
  end

  # The packages that hold this memory's text and nothing that stays.
  defp packages(txn, memory) do
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
        case shared?(txn, package, memory) do
          {:ok, true} -> {:cont, {:ok, acc}}
          {:ok, false} -> {:cont, {:ok, [package | acc]}}
          {:error, _} = error -> {:halt, error}
        end
      end)
    end
  end

  # Another live memory, or a context, of the package's workspace holds its text.
  defp shared?(txn, package, memory) do
    with {:ok, rows} <-
           query(
             txn,
             """
             SELECT 1 FROM source_packages p
              WHERE p.id = ?1
                AND (EXISTS (SELECT 1 FROM memories m
                              WHERE m.workspace_id = p.workspace_id AND m.id != ?2
                                AND m.is_forgotten = 0 AND m.content = p.raw_text)
                     OR EXISTS (SELECT 1 FROM contexts c
                                 WHERE c.workspace_id = p.workspace_id
                                   AND (CASE WHEN json_valid(c.metadata) THEN json_extract(c.metadata, '$.source_package_id') END) = p.id))
             """,
             [package, memory.id]
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
  defp steps(memory, found) do
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
      [
        {:memories, "UPDATE memories SET content = '' WHERE id = ?1", [memory.id]},
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

  defp query(txn, sql, params), do: Store.txn_query(txn, sql, params)

  defp run(_txn, [], removed), do: {:ok, removed}

  defp run(txn, [{key, sql, params} | rest], removed) do
    case Store.txn_execute(txn, sql, params) do
      {:ok, count} -> run(txn, rest, Map.put(removed, key, count))
      {:error, reason} -> {:error, {:memory_erasure_failed, key, reason}}
    end
  end
end
