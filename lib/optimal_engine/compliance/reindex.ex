defmodule OptimalEngine.Compliance.Reindex do
  @moduledoc """
  Rebuilds the retrieval material of one context from the text it holds now:
  its chunks, with their vectors, and its document vector.

  Used after a context's text was rewritten in place (a retention `redact`) and
  everything derived from the old text was deleted
  (`OptimalEngine.Compliance.DerivedData.delete_derived/1`). The chunks carry
  the context's security class, as at intake. An embedder that is down is not an
  error for the rewrite: the context stays without vectors until
  `OptimalEngine.Embed.Backfill` or the next ingest embeds it, and the result
  says which step did not finish.
  """

  require Logger

  alias OptimalEngine.Embed.Backfill
  alias OptimalEngine.MemoryCore.SecurityLabels
  alias OptimalEngine.Pipeline.Decomposer
  alias OptimalEngine.Pipeline.Parser.ParsedDoc
  alias OptimalEngine.Store

  @type result :: %{chunks: :ok | {:error, term()}, vector: :ok | {:error, term()}}

  @spec context(String.t()) :: {:ok, result()} | {:error, term()}
  def context(context_id) when is_binary(context_id) do
    case Store.raw_query(
           "SELECT tenant_id, workspace_id, content, l1_overview, metadata FROM contexts WHERE id = ?1",
           [context_id]
         ) do
      {:ok, [[tenant_id, workspace_id, content, l1_overview, metadata]]} ->
        {:ok,
         %{
           chunks: chunks(context_id, tenant_id, workspace_id, content, l1_overview, metadata),
           vector: vector(context_id)
         }}

      {:ok, []} ->
        {:error, :not_found}

      {:error, _} = error ->
        error
    end
  end

  defp chunks(context_id, tenant_id, workspace_id, content, l1_overview, metadata) do
    doc =
      ParsedDoc.new(signal_id: context_id, text: content || l1_overview || "", modality: :text)

    class =
      metadata
      |> SecurityLabels.metadata_map()
      |> Map.get("security_labels", [])
      |> SecurityLabels.highest_class()

    opts =
      [tenant_id: tenant_id, workspace_id: workspace_id]
      |> Keyword.merge(if class, do: [classification_level: class], else: [])

    case Decomposer.decompose_and_store(doc, opts) do
      {:ok, _tree} ->
        :ok

      {:error, reason} ->
        Logger.warning("[Reindex] chunks of #{context_id} not rebuilt: #{inspect(reason)}")
        {:error, reason}
    end
  rescue
    error ->
      Logger.warning("[Reindex] chunks of #{context_id} not rebuilt: #{Exception.message(error)}")
      {:error, :chunking_failed}
  end

  defp vector(context_id) do
    case Backfill.reembed(context_id) do
      :ok ->
        :ok

      {:error, reason} = error ->
        Logger.warning("[Reindex] vector of #{context_id} not rebuilt: #{inspect(reason)}")
        error
    end
  rescue
    error ->
      Logger.warning("[Reindex] vector of #{context_id} not rebuilt: #{Exception.message(error)}")
      {:error, :embedding_failed}
  end
end
