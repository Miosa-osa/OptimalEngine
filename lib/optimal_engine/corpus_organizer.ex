defmodule OptimalEngine.CorpusOrganizer do
  @moduledoc """
  Deterministic, evidence-preserving routing for Knowledge Intake contexts.

  Records are placed by name markers (`rules/0`) and, when enabled, by
  meaning (`semantic_settings/0`): a record's document vector is compared
  with the centroid of each workspace's filed documents, with its nearest
  filed documents, or both. A placed record keeps the evidence of its
  placement in `metadata.routing_placement`; one that is not placed gets a
  routing review entry with the best proposal.
  """

  require Logger

  alias OptimalEngine.Store

  @default_source_workspace "default:knowledge-intake"
  @minimum_score 8
  @minimum_margin 5
  @semantic_margin 0.04
  @semantic_min_examples 5
  @semantic_k 10
  @semantic_share 0.8

  @doc """
  The routing rules: a map of target workspace id to `{marker, weight}`
  pairs. Rules are deployment data, not code. They come from
  `config :optimal_engine, :corpus_routing_rules` when set, else from the
  `rules` section of the routing rules file (`OptimalEngine.RoutingRules`,
  env `OPTIMAL_CORPUS_RULES`):

      rules:
        default:example-client:
          - {marker: "example client", weight: 10}
          - {marker: "example project", weight: 5}

  With no rules configured every record stays in routing review.
  """
  @spec rules() :: %{String.t() => [{String.t(), pos_integer()}]}
  def rules do
    case Application.get_env(:optimal_engine, :corpus_routing_rules) do
      rules when is_map(rules) -> normalize_rules(rules)
      _ -> normalize_rules(OptimalEngine.RoutingRules.section("rules"))
    end
  end

  @doc "The intake workspace the organizer routes from (configurable)."
  @spec source_workspace() :: String.t()
  def source_workspace do
    case Application.get_env(:optimal_engine, :corpus_source_workspace) do
      id when is_binary(id) and id != "" -> id
      _ -> @default_source_workspace
    end
  end

  @doc """
  Placement by meaning, off unless enabled in `config :optimal_engine,
  :corpus_semantic_placement` or the `semantic` section of the routing rules
  file:

      semantic:
        enabled: true
        method: centroid      # centroid (the default), knn, or agree
        margin: 0.04          # centroid, agree: best centroid similarity minus the runner-up
        k: 10                 # knn, agree: the nearest filed documents that vote
        share: 0.8            # knn, agree: least share of the vote to win (0 < share <= 1)
        min_similarity: 0.0   # floor for the best similarity (below)
        min_examples: 5       # filed documents with vectors a target needs
        exclude: [default:example-private]

  Targets are the active workspaces of the intake workspace's tenant with at
  least `min_examples` document vectors, other than the intake itself and
  the excluded ones; there must be two, so there is a choice.

    * `centroid` compares the record's vector with the centroid of each
      target's filed vectors. The record is placed when the closest centroid
      clears `min_similarity` and beats the runner-up by `margin`.
    * `knn` takes the `k` filed documents closest to the record, from every
      active workspace of the tenant, and each votes for its workspace with
      its similarity. Documents of small or excluded workspaces vote, but
      only a target can win. The record is placed when the leading target
      holds at least `share` of the vote and its closest document clears
      `min_similarity`. Votes are weighted by similarity, so a workspace
      with fewer than `share * k` of the neighbours can still win when its
      documents are much closer than the others; in practice a workspace
      needs most of the neighbours, and a small one rarely attracts records.
    * `agree` places only when `knn` places and the closest centroid is the
      same workspace, at least `margin` ahead of the runner-up.

  In every method a name marker proposing another workspace blocks the
  placement. An unknown method, or a `k` or `share` out of range, turns
  placement by meaning off with a warning. Returns the settings, or `nil`.
  """
  @spec semantic_settings() :: map() | nil
  def semantic_settings do
    raw =
      case Application.get_env(:optimal_engine, :corpus_semantic_placement) do
        nil -> OptimalEngine.RoutingRules.section("semantic")
        settings when is_map(settings) or is_list(settings) -> settings
        _ -> %{}
      end
      |> Map.new(fn {key, value} -> {to_string(key), value} end)

    if raw["enabled"] == true do
      with {:ok, method} <- semantic_method(raw["method"]),
           {:ok, k} <- vote_size(raw["k"]),
           {:ok, share} <- vote_share(raw["share"]) do
        %{
          method: method,
          margin: number(raw["margin"], @semantic_margin),
          min_similarity: number(raw["min_similarity"], 0.0),
          min_examples: number(raw["min_examples"], @semantic_min_examples),
          exclude: raw["exclude"] |> List.wrap() |> Enum.map(&to_string/1),
          k: k,
          share: share
        }
      else
        {:error, setting, value} ->
          Logger.warning(
            "[CorpusOrganizer] semantic #{setting} #{inspect(value)} is not valid; placement by meaning is off"
          )

          nil
      end
    end
  end

  defp semantic_method(nil), do: {:ok, :centroid}
  defp semantic_method(method) when method in [:centroid, :knn, :agree], do: {:ok, method}

  defp semantic_method(method) when is_binary(method) do
    case String.downcase(method) do
      "centroid" -> {:ok, :centroid}
      "knn" -> {:ok, :knn}
      "agree" -> {:ok, :agree}
      _ -> {:error, "method", method}
    end
  end

  defp semantic_method(method), do: {:error, "method", method}

  defp vote_size(nil), do: {:ok, @semantic_k}
  defp vote_size(k) when is_integer(k) and k > 0, do: {:ok, k}
  defp vote_size(k), do: {:error, "k", k}

  defp vote_share(nil), do: {:ok, @semantic_share}
  defp vote_share(share) when is_number(share) and share > 0 and share <= 1, do: {:ok, share}
  defp vote_share(share), do: {:error, "share", share}

  defp number(value, _default) when is_number(value), do: value
  defp number(_value, default), do: default

  defp normalize_rules(rules) do
    for {workspace_id, markers} <- rules, is_list(markers), into: %{} do
      {to_string(workspace_id), Enum.flat_map(markers, &normalize_marker/1)}
    end
  end

  defp normalize_marker({marker, weight}) when is_binary(marker) and is_integer(weight),
    do: [{String.downcase(marker), weight}]

  defp normalize_marker(%{"marker" => marker, "weight" => weight})
       when is_binary(marker) and is_integer(weight),
       do: [{String.downcase(marker), weight}]

  defp normalize_marker(_marker), do: []

  def classify(text) when is_binary(text) do
    classify_fields(text, text, "")
  end

  def classify_fields(title, abstract, content),
    do: classify_fields(title, abstract, content, rules())

  @doc false
  def classify_fields(title, abstract, content, rules) do
    prominent = normalize("#{title}\n#{abstract}")
    body = normalize(content)

    ranked =
      rules
      |> Enum.map(fn {workspace_id, markers} ->
        hits =
          markers
          |> Enum.map(fn {marker, weight} ->
            cond do
              String.contains?(prominent, marker) -> {marker, weight}
              occurrence_count(body, marker) >= 3 -> {marker, div(weight + 1, 2)}
              true -> nil
            end
          end)
          |> Enum.reject(&is_nil/1)

        {workspace_id, Enum.sum(Enum.map(hits, &elem(&1, 1))), Enum.map(hits, &elem(&1, 0))}
      end)
      |> Enum.sort_by(fn {_workspace, score, _hits} -> score end, :desc)

    {workspace_id, score, hits, rest} =
      case ranked do
        [{workspace_id, score, hits} | rest] -> {workspace_id, score, hits, rest}
        [] -> {nil, 0, [], []}
      end

    second_score =
      rest |> List.first() |> then(fn entry -> if entry, do: elem(entry, 1), else: 0 end)

    confidence = confidence(score, second_score)

    %{
      workspace_id: if(confidence == :high, do: workspace_id, else: nil),
      proposed_workspace_id: if(score > 0, do: workspace_id, else: nil),
      score: score,
      margin: score - second_score,
      confidence: confidence,
      markers: hits
    }
  end

  # Intake is read and written in pages and batches so the Store, which
  # serializes every query, is free for other callers between them.
  @page_size 50
  @batch_size 200

  def preview(opts \\ []) do
    limit = Keyword.get(opts, :limit, 10_000)
    page_size = Keyword.get(opts, :page_size, @page_size)
    rules = rules()
    source = source_workspace()

    with {:ok, rows} <- intake_rows(source, "", limit, page_size, []),
         {:ok, placer} <- semantic_placer(source, semantic_settings(), Enum.map(rows, &hd/1)) do
      proposals =
        Enum.map(rows, fn [id, title, l0, content] ->
          title
          |> classify_fields(l0, content, rules)
          |> by_meaning(id, placer)
          |> Map.merge(%{id: id, title: title})
        end)

      {:ok, summarize(proposals)}
    end
  end

  # -- placement by meaning ----------------------------------------------------

  defp semantic_placer(_source, nil, _ids), do: {:ok, %{settings: nil}}

  # Compares only the records the preview read (`ids`), so a preview with a
  # `:limit` costs that many comparisons on the request path.
  defp semantic_placer(source, settings, ids) do
    tenant_id =
      case Store.raw_query("SELECT tenant_id FROM workspaces WHERE id = ?1", [source]) do
        {:ok, [[tenant_id]]} -> tenant_id
        _ -> "default"
      end

    vote? = settings.method in [:knn, :agree]

    with {:ok, {sums, documents}} <- filed_vectors(tenant_id, source, vote?, "", {%{}, []}),
         {:ok, vectors} <- intake_vectors(ids) do
      targets =
        for {{workspace_id, dims}, {_sum, count}} <- sums,
            count >= settings.min_examples,
            workspace_id not in settings.exclude,
            reduce: %{} do
          targets ->
            Map.update(targets, dims, MapSet.new([workspace_id]), &MapSet.put(&1, workspace_id))
        end

      centroids =
        for {{workspace_id, dims}, {sum, _count}} <- sums,
            MapSet.member?(Map.get(targets, dims, MapSet.new()), workspace_id),
            do: %{workspace_id: workspace_id, dims: dims, centroid: unit(sum)}

      {:ok,
       %{
         settings: settings,
         centroids: centroids,
         targets: targets,
         vectors: vectors,
         neighbours: if(vote?, do: nearest(vectors, documents, settings.k), else: %{})
       }}
    end
  end

  # Sums of unit document vectors per {workspace, dimensions} over the
  # tenant's active, filed documents, read in pages. With `keep_documents`
  # each document is also kept as a voter for `nearest/3`.
  defp filed_vectors(tenant_id, source, keep_documents, after_id, {sums, documents}) do
    case Store.raw_query(
           """
           SELECT c.id, c.workspace_id, v.embedding
           FROM vectors v
           JOIN contexts c ON c.id = v.context_id
           JOIN workspaces w ON w.id = c.workspace_id
           WHERE c.tenant_id = ?1 AND c.workspace_id <> ?2 AND c.archived_at IS NULL
             AND w.status = 'active' AND c.id > ?3
           ORDER BY c.id
           LIMIT ?4
           """,
           [tenant_id, source, after_id, @page_size * 10]
         ) do
      {:ok, []} ->
        {:ok, {sums, documents}}

      {:ok, rows} ->
        acc =
          Enum.reduce(rows, {sums, documents}, fn [_id, workspace_id, blob], {sums, documents} ->
            values = floats(blob)
            norm = norm(values)
            vector = scale(values, norm)

            sums =
              Map.update(sums, {workspace_id, length(vector)}, {vector, 1}, fn {sum, count} ->
                {add(sum, vector), count + 1}
              end)

            {sums, voter(documents, keep_documents, workspace_id, blob, values, norm)}
          end)

        [last_id | _] = List.last(rows)
        filed_vectors(tenant_id, source, keep_documents, last_id, acc)

      {:error, _} = error ->
        error
    end
  end

  # A filed document as a voter: its workspace, its stored vector (compared
  # as stored, so thousands of documents cost their bytes rather than float
  # lists), and the inverse of its norm. A vector that does not decode whole
  # does not vote.
  defp voter(documents, true, workspace_id, blob, values, norm)
       when norm > 0.0 and length(values) * 4 == byte_size(blob),
       do: [{workspace_id, blob, 1.0 / norm} | documents]

  defp voter(documents, _keep, _workspace_id, _blob, _values, _norm), do: documents

  # The document vectors of the previewed intake records by id, read in
  # batches and kept as stored bytes until compared.
  defp intake_vectors(ids) do
    ids
    |> Enum.chunk_every(@batch_size)
    |> Enum.reduce_while({:ok, %{}}, fn batch, {:ok, vectors} ->
      placeholders = Enum.map_join(1..length(batch), ", ", &"?#{&1}")

      case Store.raw_query(
             "SELECT context_id, embedding FROM vectors WHERE context_id IN (#{placeholders})",
             batch
           ) do
        {:ok, rows} ->
          vectors = Enum.reduce(rows, vectors, fn [id, blob], acc -> Map.put(acc, id, blob) end)
          {:cont, {:ok, vectors}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
  end

  # The `k` filed documents closest to each intake vector, by intake id, as
  # `{dimensions, [{workspace_id, similarity}]}` nearest first. The records
  # are split over all schedulers but one, which stays free for requests and
  # the Store; each part compares its records with every filed document of
  # the same dimensions.
  defp nearest(vectors, documents, k) do
    parts = max(System.schedulers_online() - 1, 1)
    size = max(div(map_size(vectors) + parts - 1, parts), 1)

    vectors
    |> Enum.chunk_every(size)
    |> Task.async_stream(
      fn part -> Enum.map(part, fn {id, blob} -> {id, nearest_to(blob, documents, k)} end) end,
      max_concurrency: parts,
      ordered: false,
      timeout: :infinity
    )
    |> Enum.reduce(%{}, fn {:ok, part}, acc -> Enum.into(part, acc) end)
  end

  defp nearest_to(blob, documents, k) do
    query = blob |> floats() |> unit()
    bytes = byte_size(blob)

    similarities =
      if length(query) * 4 == bytes do
        for {workspace_id, stored, inverse_norm} <- documents,
            byte_size(stored) == bytes,
            do: {workspace_id, dot_stored(stored, query, 0.0) * inverse_norm}
      else
        []
      end

    {length(query), similarities |> Enum.sort_by(&elem(&1, 1), :desc) |> Enum.take(k)}
  end

  defp by_meaning(result, id, %{settings: %{} = settings} = placer) do
    case meaning(settings.method, id, placer) do
      {semantic, floor?, rule?} ->
        result
        |> place_by_meaning(semantic, floor?, rule?)
        |> Map.put(:semantic, semantic)

      nil ->
        by_meaning(result, id, nil)
    end
  end

  defp by_meaning(result, _id, _placer) do
    Map.merge(result, %{method: marker_method(result), semantic: nil})
  end

  # `{proposal, clears min_similarity?, clears the method's rule?}` for an
  # intake record, or nil when it has no vector or nothing to compare with.
  defp meaning(:centroid, id, %{settings: settings, centroids: centroids, vectors: vectors}) do
    with blob when is_binary(blob) <- Map.get(vectors, id),
         [{workspace_id, similarity}, {_, second} | _] <- ranked(blob, centroids) do
      margin = similarity - second

      semantic = %{
        method: :centroid,
        workspace_id: workspace_id,
        similarity: Float.round(similarity, 4),
        margin: Float.round(margin, 4)
      }

      {semantic, similarity >= settings.min_similarity, margin >= settings.margin}
    else
      _ -> nil
    end
  end

  defp meaning(:knn, id, %{settings: settings, targets: targets, neighbours: neighbours}) do
    with {dims, [_ | _] = voters} <- Map.get(neighbours, id),
         eligible = Map.get(targets, dims, MapSet.new()),
         true <- MapSet.size(eligible) >= 2,
         {workspace_id, weight, votes, closest} <- leading(voters, eligible) do
      share = weight / (voters |> Enum.map(&max(elem(&1, 1), 0.0)) |> Enum.sum())

      semantic = %{
        method: :knn,
        workspace_id: workspace_id,
        similarity: Float.round(closest, 4),
        share: Float.round(share, 4),
        votes: votes,
        neighbours: length(voters)
      }

      {semantic, closest >= settings.min_similarity, share >= settings.share}
    else
      _ -> nil
    end
  end

  defp meaning(:agree, id, placer) do
    with {vote, floor?, voted?} <- meaning(:knn, id, placer) do
      case meaning(:centroid, id, placer) do
        {centroid, _floor?, margin?} ->
          semantic =
            Map.merge(vote, %{
              method: :agree,
              centroid_workspace_id: centroid.workspace_id,
              centroid_similarity: centroid.similarity,
              margin: centroid.margin
            })

          agreed? = voted? and margin? and centroid.workspace_id == vote.workspace_id
          {semantic, floor?, agreed?}

        nil ->
          {Map.put(vote, :method, :agree), floor?, false}
      end
    end
  end

  # The target with the largest vote among the nearest documents: its
  # weight (the sum of its documents' similarities, none below zero), its
  # votes, and its closest document's similarity. Documents of other
  # workspaces count only in the total.
  defp leading(voters, eligible) do
    voters
    |> Enum.filter(fn {workspace_id, _similarity} -> MapSet.member?(eligible, workspace_id) end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.map(fn {workspace_id, similarities} ->
      weight = similarities |> Enum.map(&max(&1, 0.0)) |> Enum.sum()
      {workspace_id, weight, length(similarities), Enum.max(similarities)}
    end)
    |> Enum.filter(fn {_workspace_id, weight, _votes, _closest} -> weight > 0.0 end)
    |> Enum.max_by(&elem(&1, 1), &>=/2, fn -> nil end)
  end

  # Targets of the vector's dimensions by similarity of their centroid,
  # closest first.
  defp ranked(blob, centroids) do
    vector = blob |> floats() |> unit()
    dims = length(vector)

    for(
      %{dims: ^dims} = centroid <- centroids,
      do: {centroid.workspace_id, dot(vector, centroid.centroid)}
    )
    |> Enum.sort_by(&elem(&1, 1), :desc)
  end

  defp place_by_meaning(%{confidence: :high} = result, _semantic, _floor, _rule),
    do: Map.put(result, :method, :markers)

  defp place_by_meaning(result, semantic, true, true)
       when result.proposed_workspace_id in [nil, semantic.workspace_id] do
    Map.merge(result, %{
      workspace_id: semantic.workspace_id,
      proposed_workspace_id: semantic.workspace_id,
      confidence: :high,
      method: :semantic
    })
  end

  defp place_by_meaning(%{proposed_workspace_id: nil} = result, semantic, true, _rule) do
    Map.merge(result, %{
      proposed_workspace_id: semantic.workspace_id,
      confidence: :review,
      method: nil
    })
  end

  defp place_by_meaning(result, _semantic, _floor, _rule), do: Map.put(result, :method, nil)

  defp marker_method(%{confidence: :high}), do: :markers
  defp marker_method(_result), do: nil

  defp floats(blob), do: for(<<value::float-little-32 <- blob>>, do: value)

  defp unit(vector), do: scale(vector, norm(vector))

  defp norm(vector), do: vector |> Enum.reduce(0.0, &(&1 * &1 + &2)) |> :math.sqrt()

  defp scale(vector, norm) when norm == 0.0, do: vector
  defp scale(vector, norm), do: Enum.map(vector, &(&1 / norm))

  defp add(a, b), do: Enum.zip_with(a, b, &(&1 + &2))

  defp dot(a, b), do: Enum.zip_reduce(a, b, 0.0, &(&1 * &2 + &3))

  # A stored little-endian float32 vector against a float list of the same
  # length, without decoding the stored one into a list first.
  defp dot_stored(<<value::float-little-32, rest::binary>>, [x | xs], acc),
    do: dot_stored(rest, xs, acc + value * x)

  defp dot_stored(<<>>, [], acc), do: acc

  # `:preview` reuses a preview the caller already read, so one run reads
  # the intake once.
  defp given_or_fresh_preview(opts) do
    case Keyword.get(opts, :preview) do
      %{high_confidence: _, review: _, unresolved: _} = preview -> {:ok, preview}
      _ -> preview(opts)
    end
  end

  defp intake_rows(_workspace, _after_id, remaining, _page_size, acc) when remaining <= 0,
    do: {:ok, acc |> Enum.reverse() |> Enum.concat()}

  defp intake_rows(workspace, after_id, remaining, page_size, acc) do
    case Store.raw_query(
           "SELECT id, title, l0_abstract, content FROM contexts WHERE workspace_id = ?1 AND archived_at IS NULL AND id > ?2 ORDER BY id LIMIT ?3",
           [workspace, after_id, min(page_size, remaining)]
         ) do
      {:ok, []} ->
        {:ok, acc |> Enum.reverse() |> Enum.concat()}

      {:ok, rows} ->
        [last_id | _] = List.last(rows)
        intake_rows(workspace, last_id, remaining - length(rows), page_size, [rows | acc])

      {:error, _} = error ->
        error
    end
  end

  def apply_high_confidence(opts \\ []) do
    with {:ok, preview} <- given_or_fresh_preview(opts) do
      results =
        Enum.map(preview.high_confidence, fn proposal ->
          {proposal, move_context(proposal.id, proposal.workspace_id, evidence(proposal))}
        end)

      errors = Enum.filter(results, fn {_proposal, result} -> not match?({:ok, _}, result) end)

      if errors == [] do
        {:ok, %{moved: length(results), by_workspace: preview.by_workspace}}
      else
        {:error, %{moved: length(results) - length(errors), errors: errors}}
      end
    end
  end

  @doc """
  Writes a routing review entry on every intake record that is not placed
  automatically. A record already queued with the same state and proposal
  is left alone, so a daily run rewrites nothing that did not change.
  Writes run in transactions of `:batch_size` (default 200). Returns the
  number of entries written.
  """
  def queue_remaining(opts \\ []) do
    batch_size = Keyword.get(opts, :batch_size, @batch_size)

    with {:ok, preview} <- given_or_fresh_preview(opts) do
      (preview.review ++ preview.unresolved)
      |> Enum.chunk_every(batch_size)
      |> Enum.reduce_while({:ok, 0}, fn batch, {:ok, count} ->
        case queue_batch(batch) do
          {:ok, written} -> {:cont, {:ok, count + written}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp queue_batch(proposals) do
    queued_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    Store.transaction(fn txn ->
      Enum.reduce_while(proposals, {:ok, 0}, fn proposal, {:ok, count} ->
        state = Atom.to_string(proposal.confidence)

        routing_review =
          Jason.encode!(%{
            "state" => state,
            "proposed_workspace_id" => proposal.proposed_workspace_id,
            "score" => proposal.score,
            "margin" => proposal.margin,
            "markers" => proposal.markers,
            "semantic" => Map.get(proposal, :semantic),
            "queued_at" => queued_at
          })

        case Store.txn_execute(
               txn,
               """
               UPDATE contexts SET metadata = json_set(COALESCE(metadata, '{}'), '$.routing_review', json(?1))
               WHERE id = ?2 AND workspace_id = ?3 AND archived_at IS NULL
                 AND (json_extract(metadata, '$.routing_review.state') IS NOT ?4
                      OR json_extract(metadata, '$.routing_review.proposed_workspace_id') IS NOT ?5)
               """,
               [
                 routing_review,
                 proposal.id,
                 source_workspace(),
                 state,
                 proposal.proposed_workspace_id
               ]
             ) do
          {:ok, changed} -> {:cont, {:ok, count + changed}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end)
  end

  def deduplicate_exact do
    Store.transaction(fn txn ->
      Store.txn_execute(
        txn,
        """
        WITH ranked AS (
          SELECT id,
                 ROW_NUMBER() OVER (
                   PARTITION BY workspace_id, content
                   ORDER BY modified_at DESC, created_at DESC, id DESC
                 ) AS duplicate_rank
          FROM contexts
          WHERE archived_at IS NULL AND trim(content) <> ''
        )
        UPDATE contexts
        SET archived_at = datetime('now'),
            metadata = json_set(COALESCE(metadata, '{}'), '$.cleanup_reason', 'exact_duplicate_context')
        WHERE id IN (SELECT id FROM ranked WHERE duplicate_rank > 1)
        """,
        []
      )
      |> case do
        {:ok, count} -> {:ok, %{archived_exact_duplicates: count}}
        {:error, _} = error -> error
      end
    end)
  end

  @doc """
  Moves an intake context and everything derived from it to
  `target_workspace_id`. `evidence`, when given, is kept on the context as
  `metadata.routing_placement` with the time of the move.
  """
  def move_context(context_id, target_workspace_id, evidence \\ nil) do
    source = source_workspace()

    Store.transaction(fn txn ->
      with {:ok, [[^source]]} <-
             Store.txn_query(
               txn,
               "SELECT workspace_id FROM contexts WHERE id = ?1 AND archived_at IS NULL",
               [context_id]
             ),
           {:ok, _} <- update(txn, "contexts", "id", context_id, target_workspace_id),
           {:ok, _} <- record_placement(txn, context_id, evidence),
           {:ok, _} <- update(txn, "chunks", "signal_id", context_id, target_workspace_id),
           {:ok, _} <- update(txn, "vectors", "context_id", context_id, target_workspace_id),
           {:ok, _} <- update(txn, "entities", "context_id", context_id, target_workspace_id),
           {:ok, _} <- update_edges(txn, context_id, target_workspace_id),
           {:ok, _} <- update_claims(txn, context_id, target_workspace_id),
           {:ok, _} <- update_source_packages(txn, context_id, target_workspace_id),
           {:ok, _} <- update_entity_mentions(txn, context_id, target_workspace_id),
           {:ok, _} <- update_chunk_embeddings(txn, context_id, target_workspace_id) do
        {:ok, %{context_id: context_id, workspace_id: target_workspace_id}}
      else
        {:ok, []} -> {:error, :not_found_or_not_in_intake}
        {:error, _} = error -> error
      end
    end)
  end

  # Placement by meaning keeps the method and its numbers: similarity and
  # margin (centroid); similarity, share, votes and neighbours (knn); all of
  # them with the centroid's workspace and similarity (agree).
  defp evidence(%{method: :semantic, semantic: semantic, workspace_id: workspace_id}) do
    semantic
    |> Map.drop([:method, :workspace_id])
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
    |> Map.merge(%{
      "method" => "semantic",
      "semantic_method" => Atom.to_string(semantic.method),
      "workspace_id" => workspace_id
    })
  end

  defp evidence(proposal) do
    %{
      "method" => "markers",
      "workspace_id" => proposal.workspace_id,
      "score" => proposal.score,
      "margin" => proposal.margin,
      "markers" => proposal.markers
    }
  end

  defp record_placement(_txn, _context_id, nil), do: {:ok, 0}

  defp record_placement(txn, context_id, evidence) do
    placed_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    Store.txn_execute(
      txn,
      "UPDATE contexts SET metadata = json_set(COALESCE(metadata, '{}'), '$.routing_placement', json(?1)) WHERE id = ?2",
      [Jason.encode!(Map.put(evidence, "placed_at", placed_at)), context_id]
    )
  end

  defp update(txn, table, key, id, workspace_id) do
    Store.txn_execute(txn, "UPDATE #{table} SET workspace_id = ?1 WHERE #{key} = ?2", [
      workspace_id,
      id
    ])
  end

  defp update_edges(txn, context_id, workspace_id) do
    Store.txn_execute(
      txn,
      "UPDATE edges SET workspace_id = ?1 WHERE source_id = ?2 OR target_id = ?2",
      [workspace_id, context_id]
    )
  end

  defp update_claims(txn, context_id, workspace_id) do
    Store.txn_execute(txn, "UPDATE claims SET workspace_id = ?1 WHERE signal_id = ?2", [
      workspace_id,
      context_id
    ])
  end

  defp update_source_packages(txn, context_id, workspace_id) do
    Store.txn_execute(
      txn,
      "UPDATE source_packages SET workspace_id = ?1 WHERE id IN (SELECT source_package_id FROM claims WHERE signal_id = ?2)",
      [workspace_id, context_id]
    )
  end

  # The mentions found in the context or in a source package of its claims,
  # and the decisions made on them, go where they were found.
  defp update_entity_mentions(txn, context_id, workspace_id) do
    mentions = """
    SELECT id FROM entity_mentions
    WHERE context_id = ?2
       OR source_package_id IN (SELECT source_package_id FROM claims WHERE signal_id = ?2)
    """

    with {:ok, _} <-
           Store.txn_execute(
             txn,
             "UPDATE resolution_decisions SET workspace_id = ?1 WHERE mention_id IN (#{mentions})",
             [workspace_id, context_id]
           ) do
      Store.txn_execute(
        txn,
        "UPDATE entity_mentions SET workspace_id = ?1 WHERE id IN (#{mentions})",
        [workspace_id, context_id]
      )
    end
  end

  defp update_chunk_embeddings(txn, context_id, workspace_id) do
    Store.txn_execute(
      txn,
      "UPDATE chunk_embeddings SET workspace_id = ?1 WHERE chunk_id IN (SELECT id FROM chunks WHERE signal_id = ?2)",
      [workspace_id, context_id]
    )
  end

  defp confidence(score, second_score)
       when score >= @minimum_score and score - second_score >= @minimum_margin do
    :high
  end

  defp confidence(score, _second_score) when score > 0, do: :review
  defp confidence(_, _), do: :unresolved

  defp normalize(value) do
    value |> to_string() |> String.downcase() |> String.replace(~r/\s+/u, " ")
  end

  defp occurrence_count(text, marker), do: text |> :binary.matches(marker) |> length()

  defp summarize(proposals) do
    high = Enum.filter(proposals, &(&1.confidence == :high))

    %{
      total: length(proposals),
      high_confidence: high,
      review: Enum.filter(proposals, &(&1.confidence == :review)),
      unresolved: Enum.filter(proposals, &(&1.confidence == :unresolved)),
      by_workspace: Enum.frequencies_by(high, & &1.workspace_id),
      by_method: Enum.frequencies_by(high, &Map.get(&1, :method))
    }
  end
end
