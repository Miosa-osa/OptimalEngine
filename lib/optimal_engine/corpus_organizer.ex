defmodule OptimalEngine.CorpusOrganizer do
  @moduledoc """
  Deterministic, evidence-preserving routing for Knowledge Intake contexts.

  Records are placed by name markers (`rules/0`) and, when enabled, by
  meaning (`semantic_settings/0`): a record's document vector is compared
  with the centroid of each workspace's filed documents. A placed record
  keeps the evidence of its placement in `metadata.routing_placement`; one
  that is not placed gets a routing review entry with the best proposal.
  """

  alias OptimalEngine.Store

  @default_source_workspace "default:knowledge-intake"
  @minimum_score 8
  @minimum_margin 5
  @semantic_margin 0.04
  @semantic_min_examples 5

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
        margin: 0.04          # best workspace similarity minus the runner-up
        min_similarity: 0.0   # floor for the best workspace's similarity
        min_examples: 5       # filed documents with vectors a target needs
        exclude: [default:example-private]

  Targets are the active workspaces of the intake workspace's tenant with at
  least `min_examples` document vectors, other than the intake itself and
  the excluded ones; there must be two, so a margin exists. A record is
  placed when its best workspace clears the floor and the margin, and no
  name marker proposes another workspace. Returns the settings, or `nil`.
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
      %{
        margin: number(raw["margin"], @semantic_margin),
        min_similarity: number(raw["min_similarity"], 0.0),
        min_examples: number(raw["min_examples"], @semantic_min_examples),
        exclude: raw["exclude"] |> List.wrap() |> Enum.map(&to_string/1)
      }
    end
  end

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
         {:ok, placer} <- semantic_placer(source, semantic_settings()) do
      proposals =
        Enum.map(rows, fn [id, title, l0, content] ->
          title
          |> classify_fields(l0, content, rules)
          |> by_meaning(Map.get(placer.vectors, id), placer)
          |> Map.merge(%{id: id, title: title})
        end)

      {:ok, summarize(proposals)}
    end
  end

  # -- placement by meaning ----------------------------------------------------

  defp semantic_placer(_source, nil), do: {:ok, %{settings: nil, centroids: [], vectors: %{}}}

  defp semantic_placer(source, settings) do
    tenant_id =
      case Store.raw_query("SELECT tenant_id FROM workspaces WHERE id = ?1", [source]) do
        {:ok, [[tenant_id]]} -> tenant_id
        _ -> "default"
      end

    with {:ok, sums} <- filed_vectors(tenant_id, source, "", %{}),
         {:ok, vectors} <- intake_vectors(source, "", %{}) do
      centroids =
        for {{workspace_id, dims}, {sum, count}} <- sums,
            count >= settings.min_examples,
            workspace_id not in settings.exclude,
            do: %{workspace_id: workspace_id, dims: dims, centroid: unit(sum)}

      {:ok, %{settings: settings, centroids: centroids, vectors: vectors}}
    end
  end

  # Sums of unit document vectors per {workspace, dimensions} over the
  # tenant's active, filed documents, read in pages.
  defp filed_vectors(tenant_id, source, after_id, sums) do
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
        {:ok, sums}

      {:ok, rows} ->
        sums =
          Enum.reduce(rows, sums, fn [_id, workspace_id, blob], sums ->
            vector = blob |> floats() |> unit()

            Map.update(sums, {workspace_id, length(vector)}, {vector, 1}, fn {sum, count} ->
              {add(sum, vector), count + 1}
            end)
          end)

        [last_id | _] = List.last(rows)
        filed_vectors(tenant_id, source, last_id, sums)

      {:error, _} = error ->
        error
    end
  end

  # Intake document vectors by id, kept as stored bytes until compared.
  defp intake_vectors(source, after_id, vectors) do
    case Store.raw_query(
           """
           SELECT c.id, v.embedding
           FROM vectors v
           JOIN contexts c ON c.id = v.context_id
           WHERE c.workspace_id = ?1 AND c.archived_at IS NULL AND c.id > ?2
           ORDER BY c.id
           LIMIT ?3
           """,
           [source, after_id, @page_size * 10]
         ) do
      {:ok, []} ->
        {:ok, vectors}

      {:ok, rows} ->
        vectors = Enum.reduce(rows, vectors, fn [id, blob], acc -> Map.put(acc, id, blob) end)
        [last_id | _] = List.last(rows)
        intake_vectors(source, last_id, vectors)

      {:error, _} = error ->
        error
    end
  end

  defp by_meaning(result, blob, %{settings: settings, centroids: centroids})
       when is_binary(blob) and not is_nil(settings) do
    vector = blob |> floats() |> unit()
    dims = length(vector)

    ranked =
      for(
        %{dims: ^dims} = centroid <- centroids,
        do: {centroid.workspace_id, dot(vector, centroid.centroid)}
      )
      |> Enum.sort_by(&elem(&1, 1), :desc)

    case ranked do
      [{workspace_id, similarity}, {_, second} | _] ->
        margin = similarity - second

        semantic = %{
          workspace_id: workspace_id,
          similarity: Float.round(similarity, 4),
          margin: Float.round(margin, 4)
        }

        result
        |> place_by_meaning(
          semantic,
          similarity >= settings.min_similarity,
          margin >= settings.margin
        )
        |> Map.put(:semantic, semantic)

      _ ->
        by_meaning(result, nil, nil)
    end
  end

  defp by_meaning(result, _blob, _placer) do
    Map.merge(result, %{method: marker_method(result), semantic: nil})
  end

  defp place_by_meaning(%{confidence: :high} = result, _semantic, _floor, _margin),
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

  defp place_by_meaning(%{proposed_workspace_id: nil} = result, semantic, true, _margin) do
    Map.merge(result, %{
      proposed_workspace_id: semantic.workspace_id,
      confidence: :review,
      method: nil
    })
  end

  defp place_by_meaning(result, _semantic, _floor, _margin), do: Map.put(result, :method, nil)

  defp marker_method(%{confidence: :high}), do: :markers
  defp marker_method(_result), do: nil

  defp floats(blob), do: for(<<value::float-little-32 <- blob>>, do: value)

  defp unit(vector) do
    norm = vector |> Enum.reduce(0.0, &(&1 * &1 + &2)) |> :math.sqrt()
    if norm == 0.0, do: vector, else: Enum.map(vector, &(&1 / norm))
  end

  defp add(a, b), do: Enum.zip_with(a, b, &(&1 + &2))

  defp dot(a, b), do: Enum.zip_reduce(a, b, 0.0, &(&1 * &2 + &3))

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
           {:ok, _} <- update_chunk_embeddings(txn, context_id, target_workspace_id) do
        {:ok, %{context_id: context_id, workspace_id: target_workspace_id}}
      else
        {:ok, []} -> {:error, :not_found_or_not_in_intake}
        {:error, _} = error -> error
      end
    end)
  end

  defp evidence(%{method: :semantic, semantic: semantic, workspace_id: workspace_id}) do
    %{
      "method" => "semantic",
      "workspace_id" => workspace_id,
      "similarity" => semantic.similarity,
      "margin" => semantic.margin
    }
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
