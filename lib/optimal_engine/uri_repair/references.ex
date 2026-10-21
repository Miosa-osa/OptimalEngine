defmodule OptimalEngine.UriRepair.References do
  @moduledoc """
  What else names a context by its `optimal://` URI, for `OptimalEngine.UriRepair`.

  A URI that several contexts shared pointed at all of them. After the repair it
  names the one that keeps it, so every record keyed by that URI needs a look:

    * `acls` (`resource_uri`): the rows are **copied** to each repaired context's
      new URI in the repair's transaction, so a context keeps the access rules it
      had while the URI was shared.
    * `memories` (`citation_uri`, with `source_chunk_id`) and `open_loops`
      (`source_uri`, with `source_context_id`) name the context by id as well,
      so they are **moved** to the new URI of the context they belong to.
    * `events` (`target_uri`), the closing source of an open loop and
      `{{cite: uri}}` directives in wiki pages carry no context id: they keep
      resolving to the context that keeps the address. They are counted so the
      owner sees them before the repair.
  """

  alias OptimalEngine.Store

  @type counts :: %{
          acls: non_neg_integer(),
          memories: non_neg_integer(),
          open_loops: non_neg_integer(),
          events: non_neg_integer(),
          wiki_citations: non_neg_integer()
        }

  @doc "How many records of each kind name `uri` in the tenant and workspace."
  @spec counts(String.t(), String.t(), String.t()) :: counts()
  def counts(tenant_id, workspace_id, uri) do
    %{
      acls:
        count("SELECT COUNT(*) FROM acls WHERE tenant_id = ?1 AND resource_uri = ?2", [
          tenant_id,
          uri
        ]),
      memories:
        count(
          """
          SELECT COUNT(*) FROM memories
          WHERE tenant_id = ?1 AND workspace_id = ?2 AND citation_uri = ?3
          """,
          [tenant_id, workspace_id, uri]
        ),
      open_loops:
        count(
          """
          SELECT COUNT(*) FROM open_loops
          WHERE tenant_id = ?1 AND workspace_id = ?2 AND (source_uri = ?3 OR close_source_uri = ?3)
          """,
          [tenant_id, workspace_id, uri]
        ),
      events:
        count("SELECT COUNT(*) FROM events WHERE tenant_id = ?1 AND target_uri = ?2", [
          tenant_id,
          uri
        ]),
      wiki_citations:
        count("SELECT COUNT(*) FROM wiki_pages WHERE tenant_id = ?1 AND body LIKE ?2 ESCAPE '\\'", [
          tenant_id,
          "%{{cite: " <> escape_like(uri) <> "}}%"
        ])
    }
  end

  @doc """
  Inside the repair's transaction: copies the ACL rows of `old_uri` to
  `new_uri`, and moves the memories and open loops that name the context by id.
  Answers how many of each.
  """
  @spec move(term(), String.t(), String.t(), String.t(), String.t(), String.t()) ::
          {:ok, %{acls_copied: integer(), memories_moved: integer(), open_loops_moved: integer()}}
          | {:error, term()}
  def move(txn, tenant_id, workspace_id, context_id, old_uri, new_uri) do
    with {:ok, acls} <-
           Store.txn_execute(
             txn,
             """
             INSERT INTO acls (tenant_id, resource_uri, principal_id, group_id, permission, granted_at)
             SELECT a.tenant_id, ?1, a.principal_id, a.group_id, a.permission, a.granted_at
             FROM acls a
             WHERE a.tenant_id = ?2 AND a.resource_uri = ?3
               AND NOT EXISTS (
                 SELECT 1 FROM acls b
                 WHERE b.tenant_id = a.tenant_id AND b.resource_uri = ?1
                   AND b.permission = a.permission
                   AND COALESCE(b.principal_id, '') = COALESCE(a.principal_id, '')
                   AND COALESCE(b.group_id, '') = COALESCE(a.group_id, '')
               )
             """,
             [new_uri, tenant_id, old_uri]
           ),
         {:ok, memories} <-
           Store.txn_execute(
             txn,
             """
             UPDATE memories SET citation_uri = ?1
             WHERE tenant_id = ?2 AND workspace_id = ?3 AND citation_uri = ?4
               AND source_chunk_id IN (SELECT id FROM chunks WHERE signal_id = ?5)
             """,
             [new_uri, tenant_id, workspace_id, old_uri, context_id]
           ),
         {:ok, loops} <-
           Store.txn_execute(
             txn,
             """
             UPDATE open_loops SET source_uri = ?1
             WHERE tenant_id = ?2 AND workspace_id = ?3 AND source_uri = ?4
               AND source_context_id = ?5
             """,
             [new_uri, tenant_id, workspace_id, old_uri, context_id]
           ) do
      {:ok, %{acls_copied: acls, memories_moved: memories, open_loops_moved: loops}}
    end
  end

  defp count(sql, params) do
    case Store.raw_query(sql, params) do
      {:ok, [[n]]} when is_integer(n) -> n
      _ -> 0
    end
  end

  # A URI holds `_` and may hold `%`; both are wildcards in LIKE.
  defp escape_like(text) do
    text
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end
end
