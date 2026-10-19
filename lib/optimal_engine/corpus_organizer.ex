defmodule OptimalEngine.CorpusOrganizer do
  @moduledoc "Deterministic, evidence-preserving routing for Knowledge Intake contexts."

  alias OptimalEngine.Store

  @default_source_workspace "default:knowledge-intake"
  @minimum_score 8
  @minimum_margin 5

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

    with {:ok, rows} <- intake_rows(source_workspace(), "", limit, page_size, []) do
      proposals =
        Enum.map(rows, fn [id, title, l0, content] ->
          result = classify_fields(title, l0, content, rules)
          Map.merge(result, %{id: id, title: title})
        end)

      {:ok, summarize(proposals)}
    end
  end

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
          {proposal, move_context(proposal.id, proposal.workspace_id)}
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

  def move_context(context_id, target_workspace_id) do
    source = source_workspace()

    Store.transaction(fn txn ->
      with {:ok, [[^source]]} <-
             Store.txn_query(
               txn,
               "SELECT workspace_id FROM contexts WHERE id = ?1 AND archived_at IS NULL",
               [context_id]
             ),
           {:ok, _} <- update(txn, "contexts", "id", context_id, target_workspace_id),
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
      by_workspace: Enum.frequencies_by(high, & &1.workspace_id)
    }
  end
end
