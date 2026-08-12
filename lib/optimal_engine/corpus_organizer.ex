defmodule OptimalEngine.CorpusOrganizer do
  @moduledoc "Deterministic, evidence-preserving routing for Knowledge Intake contexts."

  alias OptimalEngine.Store

  @source_workspace "default:knowledge-intake"
  @minimum_score 8
  @minimum_margin 5

  @rules %{
    "default:clinic-iq" => [
      {"cliniciq", 10},
      {"clinic iq", 10},
      {"colt morton", 5},
      {"ryan cole", 4},
      {"the health institute", 4}
    ],
    "default:agency-delivery" => [
      {"betterstem", 10},
      {"better stem", 10},
      {"miami stem cell", 10},
      {"faster way", 10},
      {"pro trade staffing", 10},
      {"greice murphy", 6},
      {"amanda tress", 6},
      {"steven decesare", 6}
    ],
    "default:ai-masters" => [
      {"ai masters", 10},
      {"ai university", 8},
      {"ed honour", 6},
      {"kinetic seas", 5}
    ],
    "agency-miosa" => [
      {"agency miosa", 10},
      {"growth systems audit", 10},
      {"book a solutions call", 8}
    ],
    "default:businessos" => [
      {"businessos", 10},
      {"business os", 8},
      {"module installation", 5},
      {"desktop canvas", 5}
    ],
    "default:compute" => [
      {"firecracker", 10},
      {"microvm", 8},
      {"bring-your-own-cloud", 8},
      {"bring your own cloud", 8}
    ],
    "default:osa-agent" => [
      {"osa agent", 10},
      {"osa harness", 10},
      {"miosa cli", 8}
    ],
    "default:agency-accelerants" => [
      {"agency accelerants", 10},
      {"aa community", 8}
    ],
    "default:consortium-ai" => [
      {"consortium ai", 10},
      {"my custom os", 8},
      {"govcon", 5}
    ],
    "default:pe-investors" => [
      {"pe investors", 10},
      {"private equity", 7},
      {"investor deck", 6}
    ],
    "default:personal-brand" => [
      {"personal brand", 8},
      {"builder content", 8}
    ],
    "default:signal-theory-research" => [
      {"signal theory", 10},
      {"optimal system", 8},
      {"signal-to-noise", 5}
    ],
    "default:canopy" => [
      {"canopy protocol", 10},
      {"canopy workspace", 8}
    ],
    "default:miosa" => [
      {"miosa platform", 8},
      {"optimal engine", 8},
      {"miosa.app", 8},
      {"fanbasis", 5},
      {"fan basis", 5}
    ]
  }

  def classify(text) when is_binary(text) do
    classify_fields(text, text, "")
  end

  def classify_fields(title, abstract, content) do
    prominent = normalize("#{title}\n#{abstract}")
    body = normalize(content)

    ranked =
      @rules
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

    [{workspace_id, score, hits} | rest] = ranked

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

  def preview(opts \\ []) do
    limit = Keyword.get(opts, :limit, 10_000)

    with {:ok, rows} <-
           Store.raw_query(
             "SELECT id, title, l0_abstract, content FROM contexts WHERE workspace_id = ?1 AND archived_at IS NULL LIMIT ?2",
             [@source_workspace, limit]
           ) do
      proposals =
        Enum.map(rows, fn [id, title, l0, content] ->
          result = classify_fields(title, l0, content)
          Map.merge(result, %{id: id, title: title})
        end)

      {:ok, summarize(proposals)}
    end
  end

  def apply_high_confidence(opts \\ []) do
    with {:ok, preview} <- preview(opts) do
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

  def queue_remaining(opts \\ []) do
    with {:ok, preview} <- preview(opts) do
      proposals = preview.review ++ preview.unresolved

      Store.transaction(fn txn ->
        Enum.reduce_while(proposals, {:ok, 0}, fn proposal, {:ok, count} ->
          routing_review =
            Jason.encode!(%{
              "state" => Atom.to_string(proposal.confidence),
              "proposed_workspace_id" => proposal.proposed_workspace_id,
              "score" => proposal.score,
              "margin" => proposal.margin,
              "markers" => proposal.markers,
              "queued_at" =>
                DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
            })

          case Store.txn_execute(
                 txn,
                 "UPDATE contexts SET metadata = json_set(COALESCE(metadata, '{}'), '$.routing_review', json(?1)) WHERE id = ?2 AND workspace_id = ?3 AND archived_at IS NULL",
                 [routing_review, proposal.id, @source_workspace]
               ) do
            {:ok, changed} -> {:cont, {:ok, count + changed}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
      end)
    end
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
    Store.transaction(fn txn ->
      with {:ok, [[@source_workspace]]} <-
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
       when score >= @minimum_score and score - second_score >= @minimum_margin, do: :high

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
