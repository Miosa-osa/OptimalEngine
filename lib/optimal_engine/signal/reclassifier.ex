defmodule OptimalEngine.Signal.Reclassifier do
  @moduledoc """
  Recomputes the Mode of stored signals, and the genre where it is the
  Signal Theory bridge's default, so data classified before the bridge
  stopped overwriting the pipeline matches what intake produces today.

  Older intake let the bridge replace every `:linguistic` mode (it read the
  text's map wrapper as code) and every `"note"` genre (with the analyzer's
  `:chat` fallback). Nothing else in the engine writes `"chat"`, so a stored
  `"chat"` genre is treated as that default and re-detected; every other
  genre is kept and informs Mode when the text alone is too weak to decide.

  A mode in engine-written frontmatter (the Writer always emits a `tiers:`
  block) is a cached classification, possibly the old bridge's, so it is
  recomputed. A mode declared in any other frontmatter is the author's and
  is kept.

  `plan/2` reads and computes without writing; `apply_changes/2` updates
  the `contexts` rows in one transaction, evicts them from the read cache,
  and by default rewrites the `mode:`/`genre:` lines of engine-written
  signal files on disk so a later re-index does not restore the old values.
  """

  alias OptimalEngine.Pipeline.Classifier
  alias OptimalEngine.Signal.{GenreDetector, ModeDetector, TimeLimit}
  alias OptimalEngine.Store

  @bridge_default_genre "chat"
  @batch_size 500
  @frontmatter ~r/\A(---\r?\n)(.*?)(\r?\n---\r?\n?)(.*)\z/s

  @type change :: %{
          id: String.t(),
          path: String.t() | nil,
          from: {String.t() | nil, String.t() | nil},
          to: {String.t(), String.t() | nil},
          l0_abstract: String.t()
        }

  @doc """
  Computes the Mode and Genre a stored signal should carry.

  Takes a map with `:content`, `:mode` and `:genre`; returns
  `%{mode: String.t(), genre: String.t() | nil}`.
  """
  @spec reclassify(map()) :: %{mode: String.t(), genre: String.t() | nil}
  def reclassify(%{content: _content, genre: _genre} = row),
    do: TimeLimit.with_budget(fn -> reclassify_row(row) end)

  defp reclassify_row(%{content: content, genre: genre} = row) do
    {frontmatter, body} = Classifier.parse_frontmatter(content || "")
    trusted = if engine_written?(frontmatter), do: %{}, else: frontmatter

    new_genre =
      if genre == @bridge_default_genre,
        do: valid_declared_genre(trusted) || GenreDetector.detect(body),
        else: genre

    new_mode =
      if String.trim(body) == "",
        do: row[:mode] || "linguistic",
        else:
          body
          |> ModeDetector.resolve(declared: declared(trusted, "mode"), genre: new_genre)
          |> to_string()

    %{mode: new_mode, genre: new_genre}
  end

  @doc """
  Scans every signal in `workspace_id` and returns the changes to make.
  Options: `:tenant_id` (only that tenant's signals), `:batch_size`.

  Returns `{:ok, %{scanned: n, changes: [change]}}`, or `{:error, reason}`
  when the Store does not answer (`:busy` when it did not in time).
  """
  @spec plan(String.t(), keyword()) ::
          {:ok, %{scanned: non_neg_integer(), changes: [change()]}} | {:error, term()}
  def plan(workspace_id, opts \\ []) when is_binary(workspace_id) do
    batch_size = Keyword.get(opts, :batch_size, @batch_size)
    scope = scope(workspace_id, opts[:tenant_id])
    scan(scope, "", batch_size, %{scanned: 0, changes: []})
  end

  @doc """
  Writes `changes` to the store (and, unless `files: false`, to engine-written
  signal files). Returns `{:ok, %{rows: n, files: n}}`.
  """
  @spec apply_changes([change()], keyword()) ::
          {:ok, %{rows: non_neg_integer(), files: non_neg_integer()}} | {:error, term()}
  def apply_changes(changes, opts \\ []) do
    with {:ok, rows} <- update_rows(changes) do
      Store.evict_cached(Enum.map(changes, & &1.id))
      files = if Keyword.get(opts, :files, true), do: sync_files(changes), else: 0
      {:ok, %{rows: rows, files: files}}
    end
  end

  @doc """
  Counts the stored signals of `workspace_id` by genre and mode, for
  example `%{"transcript" => %{"linguistic" => 12, "code" => 3}}`. A missing
  genre or mode counts as `"none"`. Options: `:tenant_id` (only that
  tenant's signals). Reads only.
  """
  @spec distribution(String.t(), keyword()) ::
          {:ok, %{optional(String.t()) => %{optional(String.t()) => pos_integer()}}}
          | {:error, term()}
  def distribution(workspace_id, opts \\ []) when is_binary(workspace_id) do
    {where, params} = scope(workspace_id, opts[:tenant_id])

    with {:ok, rows} <-
           query(
             "SELECT genre, mode, COUNT(*) FROM contexts WHERE #{where} GROUP BY genre, mode",
             params
           ) do
      {:ok,
       Enum.reduce(rows, %{}, fn [genre, mode, count], acc -> add(acc, genre, mode, count) end)}
    end
  end

  # A Store that does not answer within its call timeout is busy, not a crash
  # (as in `Retrieval.Search`): the caller may retry.
  defp query(sql, params) do
    Store.raw_query(sql, params)
  catch
    :exit, {:timeout, _} -> {:error, :busy}
  end

  # The signals of one workspace, and of one tenant when it is given:
  # workspace ids that are not registered can be shared by tenants.
  defp scope(workspace_id, nil), do: {"type = 'signal' AND workspace_id = ?1", [workspace_id]}

  defp scope(workspace_id, tenant_id),
    do: {"type = 'signal' AND workspace_id = ?1 AND tenant_id = ?2", [workspace_id, tenant_id]}

  @doc """
  The `distribution/1` a workspace would have once `changes` (from `plan/2`)
  were applied: what re-running classification produces, without writing it.

  With `keep_genre: true` every Signal stays under the genre it is stored
  with and only its mode moves, which answers how the Signals stored as one
  genre (for example `"chat"`) would be read once re-run.
  """
  @spec apply_to_distribution(map(), [change()], keyword()) :: map()
  def apply_to_distribution(distribution, changes, opts \\ []) do
    keep_genre? = Keyword.get(opts, :keep_genre, false)

    Enum.reduce(changes, distribution, fn %{from: {mode, genre}, to: {new_mode, new_genre}}, acc ->
      acc |> add(genre, mode, -1) |> add(if(keep_genre?, do: genre, else: new_genre), new_mode, 1)
    end)
  end

  defp add(distribution, genre, mode, n) do
    genre = to_string(genre || "none")
    mode = to_string(mode || "none")
    modes = distribution |> Map.get(genre, %{}) |> Map.update(mode, n, &(&1 + n))
    modes = if modes[mode] == 0, do: Map.delete(modes, mode), else: modes

    if modes == %{}, do: Map.delete(distribution, genre), else: Map.put(distribution, genre, modes)
  end

  @doc "Counts `{from, to}` transitions for mode and for genre."
  @spec summarize([change()]) :: %{mode: map(), genre: map()}
  def summarize(changes) do
    %{
      mode:
        changes
        |> Enum.filter(fn %{from: {m, _}, to: {m2, _}} -> m != m2 end)
        |> Enum.frequencies_by(fn %{from: {m, _}, to: {m2, _}} -> {m, m2} end),
      genre:
        changes
        |> Enum.filter(fn %{from: {_, g}, to: {_, g2}} -> g != g2 end)
        |> Enum.frequencies_by(fn %{from: {_, g}, to: {_, g2}} -> {g, g2} end)
    }
  end

  @doc """
  Rewrites the `mode:` line, and a bridge-default `genre:` line, inside an
  engine-written frontmatter block. Returns the content unchanged when the
  frontmatter is absent or not engine-written.
  """
  @spec sync_frontmatter(String.t(), String.t(), String.t() | nil) :: String.t()
  def sync_frontmatter(content, mode, genre) do
    with [_, open, fm, close, body] <- Regex.run(@frontmatter, content),
         {:ok, parsed} when is_map(parsed) <- YamlElixir.read_from_string(fm),
         true <- engine_written?(parsed) do
      fm =
        fm
        |> replace_signal_field("mode", fn _current -> mode end)
        |> replace_signal_field("genre", fn
          @bridge_default_genre when is_binary(genre) -> genre
          current -> current
        end)

      open <> fm <> close <> body
    else
      _ -> content
    end
  end

  # ── Scan ────────────────────────────────────────────────────────────────

  defp scan({where, params} = scope, after_id, batch_size, acc) do
    next = length(params) + 1

    case query(
           """
           SELECT id, content, mode, genre, path, l0_abstract
           FROM contexts
           WHERE #{where} AND id > ?#{next}
           ORDER BY id
           LIMIT ?#{next + 1}
           """,
           params ++ [after_id, batch_size]
         ) do
      {:ok, rows} ->
        changes =
          rows
          |> Enum.map(&change_for/1)
          |> Enum.reject(&is_nil/1)

        acc = %{scanned: acc.scanned + length(rows), changes: acc.changes ++ changes}

        case rows do
          [] -> {:ok, acc}
          rows when length(rows) < batch_size -> {:ok, acc}
          rows -> scan(scope, rows |> List.last() |> hd(), batch_size, acc)
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp change_for([id, content, mode, genre, path, l0]) do
    %{mode: new_mode, genre: new_genre} = reclassify(%{content: content, mode: mode, genre: genre})

    if {new_mode, new_genre} != {mode, genre} do
      %{
        id: id,
        path: path,
        from: {mode, genre},
        to: {new_mode, new_genre},
        l0_abstract: relabel_l0(l0 || "", genre, new_genre)
      }
    end
  end

  # The L0 abstract leads with the upper-cased genre ("NOTE | node | title").
  defp relabel_l0(l0, genre, genre), do: l0

  defp relabel_l0(l0, _old, new) when is_binary(new),
    do: Regex.replace(~r/\A[A-Z0-9-]+ \|/, l0, String.upcase(new) <> " |")

  defp relabel_l0(l0, _old, _new), do: l0

  # ── Apply ───────────────────────────────────────────────────────────────

  defp update_rows([]), do: {:ok, 0}

  defp update_rows(changes) do
    Store.transaction(fn txn ->
      count =
        Enum.reduce(changes, 0, fn %{id: id, to: {mode, genre}, l0_abstract: l0}, n ->
          {:ok, changed} =
            Store.txn_execute(
              txn,
              "UPDATE contexts SET mode = ?1, genre = ?2, l0_abstract = ?3 WHERE id = ?4",
              [mode, genre, l0, id]
            )

          n + changed
        end)

      {:ok, count}
    end)
  end

  defp sync_files(changes) do
    Enum.count(changes, fn %{path: path, to: {mode, genre}} ->
      with true <- is_binary(path) and File.regular?(path),
           {:ok, content} <- File.read(path),
           updated when updated != content <- sync_frontmatter(content, mode, genre),
           :ok <- File.write(path, updated) do
        true
      else
        _ -> false
      end
    end)
  end

  # ── Frontmatter helpers ─────────────────────────────────────────────────

  defp engine_written?(frontmatter), do: Map.has_key?(frontmatter, "tiers")

  defp declared(frontmatter, key) do
    case frontmatter do
      %{"signal" => %{} = signal} when is_map_key(signal, key) -> signal[key]
      _ -> Map.get(frontmatter, key)
    end
  end

  defp valid_declared_genre(frontmatter) do
    case declared(frontmatter, "genre") do
      genre when is_binary(genre) and genre not in ["", @bridge_default_genre] -> genre
      _ -> nil
    end
  end

  # Only the two-space-indented field directly under `signal:`.
  defp replace_signal_field(fm, field, fun) do
    Regex.replace(~r/^(signal:\r?\n(?:  .*\r?\n)*?  #{field}:[ \t]*)([^\r\n]*)/m, fm, fn _,
                                                                                         prefix,
                                                                                         current ->
      prefix <> fun.(String.trim(current))
    end)
  end
end
