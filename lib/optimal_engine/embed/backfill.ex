defmodule OptimalEngine.Embed.Backfill do
  @moduledoc """
  Embeds documents that have no document vector yet.

  A document gets its vector when the semantic pipeline runs at intake. One
  indexed while the embedder was down, or written by a path that skips the
  pipeline, has none, so vector search and placement by meaning cannot see
  it. `run/1` finds active documents without a vector and embeds their title,
  abstract and content (the pipeline's input), one at a time, storing each
  vector in its document's tenant and workspace. Documents are read in pages
  so the single-writer Store stays free for other callers.

  Options for `run/1` and `status/1`:

    * `:workspace_id` or `:tenant_id` narrow the scope (default: every tenant);
    * `:limit` caps the documents one run tries (default 500);
    * `:embed` is a one-argument function returning `{:ok, vector}` (default:
      the Engine's text embedder, `OptimalEngine.Embed.Text`, bypassing the
      query cache, since each document is embedded once). The default embeds
      a page in one call (`OptimalEngine.Embed.Text.embed_many/2`), so an
      embedding endpoint gets a few requests per page instead of one per
      document.

  An embedder that is unreachable, refuses the key, is out of credit or is
  rate limiting stops the run with `{:error, {:embedder_unavailable, reason}}`
  (`OptimalEngine.Embed.Text.unavailable?/1`); a document the embedder rejects
  is counted as failed and the run goes on.
  """

  alias OptimalEngine.Embed.Text, as: TextEmbedder
  alias OptimalEngine.Store
  alias OptimalEngine.Store.Vectors

  @limit 500
  @page 50

  @type result :: %{
          embedded: non_neg_integer(),
          failed: non_neg_integer(),
          remaining: non_neg_integer()
        }

  @doc "How many active documents in scope have no vector."
  @spec status(keyword()) :: {:ok, %{missing: non_neg_integer()}} | {:error, term()}
  def status(opts \\ []) do
    {where, params} = scope(opts)

    case Store.raw_query("SELECT COUNT(*) FROM contexts c WHERE #{where}", params) do
      {:ok, [[missing]]} -> {:ok, %{missing: missing}}
      {:error, _} = error -> error
    end
  end

  @doc "Embeds up to `:limit` documents that have no vector. See the module doc."
  @spec run(keyword()) :: {:ok, result()} | {:error, term()}
  def run(opts \\ []) do
    limit = Keyword.get(opts, :limit, @limit)

    embed =
      case Keyword.get(opts, :embed) do
        nil -> &TextEmbedder.embed_many(&1, cache: false)
        one -> &TextEmbedder.embed_each(&1, one)
      end

    with {:ok, counts} <- pages(opts, embed, "", limit, %{embedded: 0, failed: 0}),
         {:ok, %{missing: remaining}} <- status(opts) do
      {:ok, Map.put(counts, :remaining, remaining)}
    end
  end

  defp pages(_opts, _embed, _after_id, remaining, counts) when remaining <= 0, do: {:ok, counts}

  defp pages(opts, embed, after_id, remaining, counts) do
    {where, params} = scope(opts)
    next = length(params) + 1

    sql = """
    SELECT c.id, c.workspace_id, c.title, c.l0_abstract, c.content
    FROM contexts c
    WHERE #{where} AND c.id > ?#{next}
    ORDER BY c.id
    LIMIT ?#{next + 1}
    """

    case Store.raw_query(sql, params ++ [after_id, min(@page, remaining)]) do
      {:ok, []} ->
        {:ok, counts}

      {:ok, rows} ->
        with {:ok, counts} <- embed_page(rows, embed, counts) do
          [last_id | _] = List.last(rows)
          pages(opts, embed, last_id, remaining - length(rows), counts)
        end

      {:error, _} = error ->
        error
    end
  end

  defp embed_page(rows, embed, counts) do
    inputs = Enum.map(rows, fn [_id, _ws, title, l0, content] -> input(title, l0, content) end)

    rows
    |> Enum.zip(embed.(inputs))
    |> Enum.reduce_while({:ok, counts}, fn {[id, workspace_id | _], result}, {:ok, counts} ->
      case result do
        {:ok, vector} ->
          case Vectors.store(id, vector, workspace_id: workspace_id) do
            :ok -> {:cont, {:ok, %{counts | embedded: counts.embedded + 1}}}
            {:error, _} -> {:cont, {:ok, %{counts | failed: counts.failed + 1}}}
          end

        {:error, reason} ->
          if TextEmbedder.unavailable?(reason),
            do: {:halt, {:error, {:embedder_unavailable, reason}}},
            else: {:cont, {:ok, %{counts | failed: counts.failed + 1}}}

        _ ->
          {:cont, {:ok, %{counts | failed: counts.failed + 1}}}
      end
    end)
  end

  defp input(title, l0, content) do
    [title, l0, content]
    |> Enum.map(&(&1 || ""))
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp scope(opts) do
    base = """
    c.archived_at IS NULL
      AND NOT EXISTS (SELECT 1 FROM vectors v WHERE v.context_id = c.id)
      AND trim(COALESCE(c.title, '') || COALESCE(c.l0_abstract, '') || COALESCE(c.content, '')) <> ''
    """

    cond do
      workspace_id = opts[:workspace_id] -> {base <> " AND c.workspace_id = ?1", [workspace_id]}
      tenant_id = opts[:tenant_id] -> {base <> " AND c.tenant_id = ?1", [tenant_id]}
      true -> {base, []}
    end
  end
end
