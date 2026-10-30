defmodule OptimalEngine.Embed.ChunkBackfill do
  @moduledoc """
  Embeds chunks that have no `chunk_embeddings` row yet.

  Intake embeds a document's chunks after it stores them. A chunk stored while
  the embedder was down or slow, or in a batch that failed, keeps no
  embedding, so chunk-level vector search cannot see it. `run/1` finds those
  chunks and embeds them through the intake embedder
  (`OptimalEngine.Pipeline.Embedder`), storing each vector in its chunk's
  tenant and workspace. Embedding happens in the caller's process, never in
  the Store.

  A workspace's chunks are read in id order a window at a time through the
  `(workspace_id, id)` index, so no Store call examines more than `:window`
  chunks, even when only a few in a large workspace are missing; at most
  `:page` chunks are embedded and written together. A wider scope walks its
  workspaces one after another.

  Options for `run/1` and `status/1`:

    * `:workspace_id` or `:tenant_id` narrow the scope (default: every tenant);
    * `:limit` caps the chunks one run tries, or `:infinity` (default 500);
    * `:page` is how many chunks are embedded and written together (default 50);
    * `:window` is how many chunk ids one Store call examines (default 1,000);
    * `:after` resumes where a run stopped (`run/1` returns `:next`): a chunk
      id in a workspace scope, `{workspace_id, chunk_id}` in a wider one;
    * `:count` set to false leaves out `:remaining`, a count over the whole
      scope (default true);
    * `:pause_ms` sleeps after each page so other callers get the Store
      (default 0);
    * `:on_page` is called after each page with that page's counts and the
      run's counts so far;
    * `:embed` is a two-argument function taking a `ChunkTree` and options
      and returning what `OptimalEngine.Pipeline.Embedder.embed_tree/2`
      returns (default: that function, bypassing the embedding cache, since
      each chunk is embedded once).

  A run is idempotent: an embedded chunk is never read again. A chunk the
  embedder rejects is counted as failed and left for a later run. An
  unavailable embedder (`OptimalEngine.Embed.Text.unavailable?/1`) stops the
  run with `{:error, {:embedder_unavailable, reason}}` after storing what it
  had embedded, and marks nothing failed.

  The SQL is SQLite's: `?N` parameters and the `(workspace_id, id)` range
  seek. A Postgres store ports the same statements with `$N` parameters.
  """

  alias OptimalEngine.Embed.Text, as: TextEmbedder
  alias OptimalEngine.Pipeline.Decomposer.{Chunk, ChunkTree}
  alias OptimalEngine.Pipeline.Embedder
  alias OptimalEngine.Store

  @limit 500
  @page 50
  @window 1_000
  @probe_timeout_ms 15_000
  @probe_retry_ms 5_000

  @type counts :: %{embedded: non_neg_integer(), failed: non_neg_integer()}
  @type cursor :: String.t() | {String.t(), String.t()}

  @type result :: %{
          embedded: non_neg_integer(),
          failed: non_neg_integer(),
          remaining: non_neg_integer() | nil,
          next: cursor() | nil
        }

  @doc "How many chunks in scope have no embedding."
  @spec status(keyword()) :: {:ok, %{missing: non_neg_integer()}} | {:error, term()}
  def status(opts \\ []) do
    {where, params} = scope(opts)

    case Store.raw_query(
           "SELECT COUNT(*) FROM chunks c WHERE #{where} AND #{missing_sql()}",
           params
         ) do
      {:ok, [[missing]]} -> {:ok, %{missing: missing}}
      {:error, _} = error -> error
    end
  end

  @doc """
  Embeds up to `:limit` chunks that have no embedding. See the module doc.

  `:next` is where to resume when the run stopped at its limit, or nil when
  it read to the end of its scope.
  """
  @spec run(keyword()) :: {:ok, result()} | {:error, term()}
  def run(opts \\ []) do
    walk = %{
      opts: opts,
      embed: Keyword.get(opts, :embed, &Embedder.embed_tree/2),
      page: max(Keyword.get(opts, :page, @page), 1),
      window: max(Keyword.get(opts, :window, @window), 1),
      pause: Keyword.get(opts, :pause_ms, 0),
      on_page: Keyword.get(opts, :on_page, fn _page, _total -> :ok end)
    }

    limit = Keyword.get(opts, :limit, @limit)

    with {:ok, counts, next, _limit} <- scan_scope(walk, limit),
         {:ok, remaining} <- remaining(opts) do
      {:ok, Map.merge(counts, %{remaining: remaining, next: next})}
    end
  end

  @doc """
  The workspaces in scope (`:workspace_id` or `:tenant_id`, default every
  workspace) that have a chunk with no embedding. Each workspace is read a
  window at a time (`:window`) until its first missing chunk, with
  `:pause_ms` between windows.
  """
  @spec pending_workspaces(keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def pending_workspaces(opts \\ []) do
    window = max(Keyword.get(opts, :window, @window), 1)

    with {:ok, workspaces} <- workspaces(opts) do
      Enum.reduce_while(workspaces, {:ok, []}, fn workspace_id, {:ok, found} ->
        case first_missing(opts, workspace_id, "", window) do
          {:ok, true} -> {:cont, {:ok, [workspace_id | found]}}
          {:ok, false} -> {:cont, {:ok, found}}
          {:error, _} = error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, found} -> {:ok, Enum.reverse(found)}
        error -> error
      end
    end
  end

  @doc """
  Whether the text embedder answers an embedding probe, for maintenance.

  A model that is not loaded yet can take longer than the search path's probe
  allows, so each attempt may take `:timeout_ms` (default 15 s) and a failed
  attempt is retried once after `:retry_ms` (default 5 s). The first request
  is what makes the model load.
  """
  @spec embedder_healthy?(keyword()) :: boolean()
  def embedder_healthy?(opts \\ []) do
    timeout = Keyword.get(opts, :timeout_ms, @probe_timeout_ms)
    probe = Keyword.get(opts, :probe, fn -> TextEmbedder.embed("probe", cache: false) end)

    if probe_once(probe, timeout) do
      true
    else
      Process.sleep(Keyword.get(opts, :retry_ms, @probe_retry_ms))
      probe_once(probe, timeout)
    end
  end

  defp probe_once(probe, timeout) do
    task = Task.async(probe)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, [_ | _]}} -> true
      _ -> false
    end
  end

  @doc "Whether an embedding error means the embedder is unavailable, not the input."
  @spec unavailable?(term()) :: boolean()
  def unavailable?(reason), do: TextEmbedder.unavailable?(reason)

  # ── the scan ────────────────────────────────────────────────────────────

  defp scan_scope(walk, limit) do
    case walk.opts[:workspace_id] do
      nil ->
        {workspace_id, after_id} =
          case walk.opts[:after] do
            {workspace_id, after_id} -> {workspace_id, after_id}
            _ -> {nil, ""}
          end

        scan_workspaces(walk, workspace_id, after_id, limit, %{embedded: 0, failed: 0})

      workspace_id ->
        after_id = if is_binary(walk.opts[:after]), do: walk.opts[:after], else: ""
        scan(walk, workspace_id, after_id, limit, %{embedded: 0, failed: 0})
    end
  end

  # Every workspace in scope in id order, starting at `workspace_id` (nil for
  # the first one). The cursor names the workspace a limited run stopped in.
  defp scan_workspaces(walk, nil, _after_id, limit, counts) do
    case next_workspace(nil) do
      {:ok, nil} -> {:ok, counts, nil, limit}
      {:ok, workspace_id} -> scan_workspaces(walk, workspace_id, "", limit, counts)
      {:error, _} = error -> error
    end
  end

  defp scan_workspaces(walk, workspace_id, after_id, limit, counts) do
    case scan(walk, workspace_id, after_id, limit, counts) do
      {:ok, counts, nil, limit} ->
        case next_workspace(workspace_id) do
          {:ok, nil} -> {:ok, counts, nil, limit}
          {:ok, next} -> scan_workspaces(walk, next, "", limit, counts)
          {:error, _} = error -> error
        end

      {:ok, counts, next_id, limit} ->
        {:ok, counts, {workspace_id, next_id}, limit}

      {:error, _} = error ->
        error
    end
  end

  # One workspace from `after_id`. Returns the chunk id to resume after when
  # the limit stopped it, or nil at the end of the workspace.
  defp scan(_walk, _workspace_id, after_id, limit, counts)
       when is_integer(limit) and limit <= 0,
       do: {:ok, counts, after_id, limit}

  defp scan(walk, workspace_id, after_id, limit, counts) do
    with {:ok, last} <- window_end(workspace_id, after_id, walk.window) do
      if is_nil(last) do
        {:ok, counts, nil, limit}
      else
        take = if limit == :infinity, do: walk.page, else: min(walk.page, limit)

        with {:ok, rows} <- missing(walk.opts, workspace_id, after_id, last, take),
             {:ok, page} <- embed_page(rows, workspace_id, walk.embed) do
          counts = %{
            embedded: counts.embedded + page.embedded,
            failed: counts.failed + page.failed
          }

          if rows != [] do
            walk.on_page.(page, counts)
            if walk.pause > 0, do: Process.sleep(walk.pause)
          end

          # A full page may leave missing chunks in this window; resume after
          # the last one read. Otherwise the window is done.
          next = if length(rows) == take, do: rows |> List.last() |> hd(), else: last
          scan(walk, workspace_id, next, spend(limit, length(rows)), counts)
        end
      end
    end
  end

  defp spend(:infinity, _n), do: :infinity
  defp spend(limit, n), do: limit - n

  defp remaining(opts) do
    if Keyword.get(opts, :count, true) do
      with {:ok, %{missing: missing}} <- status(opts), do: {:ok, missing}
    else
      {:ok, nil}
    end
  end

  # The last chunk id of the workspace's next window after `after_id`, or nil
  # at the end. Read from the (workspace_id, id) index alone.
  defp window_end(workspace_id, after_id, window) do
    case Store.raw_query(window_end_sql(), [workspace_id, after_id, window]) do
      {:ok, [[last]]} -> {:ok, last}
      {:error, _} = error -> error
    end
  end

  defp missing(opts, workspace_id, after_id, last, take) do
    {tenant_sql, tenant_params} = tenant_filter(opts, 5)

    Store.raw_query(
      missing_rows_sql(tenant_sql),
      [workspace_id, after_id, last, take] ++ tenant_params
    )
  end

  # A window always reads one workspace through its (workspace_id, id) index.
  # INDEXED BY keeps that plan whatever the planner statistics say: statistics
  # that show few chunks per workspace otherwise lead SQLite to range over the
  # whole table's primary key. PostgreSQL drops the clause (Store.Dialect).
  defp window_end_sql do
    """
    SELECT MAX(w.id) FROM (
      SELECT id FROM chunks INDEXED BY idx_chunks_workspace_id
      WHERE workspace_id = ?1 AND id > ?2 ORDER BY id LIMIT ?3
    ) AS w
    """
  end

  defp missing_rows_sql(tenant_sql) do
    """
    SELECT c.id, c.tenant_id, c.workspace_id, c.signal_id, c.text, c.modality, c.asset_ref
    FROM chunks c INDEXED BY idx_chunks_workspace_id
    WHERE c.workspace_id = ?1 AND c.id > ?2 AND c.id <= ?3 AND #{missing_sql()}#{tenant_sql}
    ORDER BY c.id
    LIMIT ?4
    """
  end

  @doc false
  # The statements a window runs, with sample parameters, so a test can check
  # their query plans.
  @spec window_statements(String.t()) :: [{String.t(), [term()]}]
  def window_statements(workspace_id) do
    [
      {window_end_sql(), [workspace_id, "", @window]},
      {missing_rows_sql(""), [workspace_id, "", "~", @page]}
    ]
  end

  # Whether the workspace has a missing chunk at or after `after_id`, a
  # window at a time.
  defp first_missing(opts, workspace_id, after_id, window) do
    with {:ok, last} <- window_end(workspace_id, after_id, window) do
      if is_nil(last) do
        {:ok, false}
      else
        case missing(opts, workspace_id, after_id, last, 1) do
          {:ok, [_ | _]} ->
            {:ok, true}

          {:ok, []} ->
            pause = Keyword.get(opts, :pause_ms, 0)
            if pause > 0, do: Process.sleep(pause)
            first_missing(opts, workspace_id, last, window)

          {:error, _} = error ->
            error
        end
      end
    end
  end

  # The workspaces of the chunks in scope, one index seek each.
  defp workspaces(opts) do
    case opts[:workspace_id] do
      nil -> collect_workspaces(opts, nil, [])
      workspace_id -> {:ok, [workspace_id]}
    end
  end

  defp collect_workspaces(opts, after_workspace, acc) do
    case next_workspace(after_workspace) do
      {:ok, nil} -> {:ok, Enum.reverse(acc)}
      {:ok, workspace_id} -> collect_workspaces(opts, workspace_id, [workspace_id | acc])
      {:error, _} = error -> error
    end
  end

  # The first workspace with chunks after `after_workspace` (nil: the first
  # one), one index seek. A tenant scope visits every workspace too and
  # filters the rows: a chunk's own tenant decides, not its workspace's.
  defp next_workspace(after_workspace) do
    case Store.raw_query("SELECT MIN(workspace_id) FROM chunks WHERE workspace_id > ?1", [
           after_workspace || ""
         ]) do
      {:ok, [[workspace_id]]} -> {:ok, workspace_id}
      {:error, _} = error -> error
    end
  end

  # ── embedding ───────────────────────────────────────────────────────────

  # A page is one workspace's chunks, embedded with that workspace named so
  # the embedder's model-call records stay in it.
  defp embed_page([], _workspace_id, _embed), do: {:ok, %{embedded: 0, failed: 0}}

  defp embed_page(rows, workspace_id, embed) do
    chunks = Enum.map(rows, &chunk/1)

    {:ok, embeddings, %{errors: errors}} =
      embed.(%ChunkTree{chunks: chunks}, cache: false, workspace_id: workspace_id)

    by_id = Map.new(chunks, &{&1.id, &1})
    rows = Enum.map(embeddings, &Embedder.embedding_row(&1, by_id))

    with :ok <- Store.insert_embeddings(rows) do
      case Enum.find(errors, fn {_id, reason} -> unavailable?(reason) end) do
        nil -> {:ok, %{embedded: length(rows), failed: length(errors)}}
        {_id, reason} -> {:error, {:embedder_unavailable, reason}}
      end
    end
  end

  defp chunk([id, tenant_id, workspace_id, signal_id, text, modality, asset_ref]) do
    Chunk.new(
      id: id,
      tenant_id: tenant_id || "default",
      workspace_id: workspace_id || "default",
      signal_id: signal_id,
      text: text || "",
      modality: modality(modality),
      asset_ref: asset_ref
    )
  end

  @modalities %{
    "text" => :text,
    "code" => :code,
    "data" => :data,
    "mixed" => :mixed,
    "image" => :image,
    "audio" => :audio,
    "video" => :video
  }

  defp modality(value), do: Map.get(@modalities, value, :text)

  # ── scope ───────────────────────────────────────────────────────────────

  defp missing_sql do
    "c.text <> '' AND NOT EXISTS (SELECT 1 FROM chunk_embeddings e WHERE e.chunk_id = c.id)"
  end

  defp scope(opts) do
    cond do
      workspace_id = opts[:workspace_id] -> {"c.workspace_id = ?1", [workspace_id]}
      tenant_id = opts[:tenant_id] -> {"c.tenant_id = ?1", [tenant_id]}
      true -> {"1 = 1", []}
    end
  end

  defp tenant_filter(opts, index) do
    case opts[:workspace_id] == nil and opts[:tenant_id] do
      tenant_id when is_binary(tenant_id) -> {" AND c.tenant_id = ?#{index}", [tenant_id]}
      _ -> {"", []}
    end
  end
end
