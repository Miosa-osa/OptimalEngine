defmodule OptimalEngine.Compliance.DerivedData do
  @moduledoc """
  Retrieval material derived from contexts, removed when the contexts are.

  A context's document vector (`vectors.context_id`) and its chunks
  (`chunks.signal_id`, with the chunk vectors in `chunk_embeddings`) are not tied
  to the context by a foreign key, so deleting a context row leaves the text
  of its chunks and every vector behind. Erasure and retention deletion call
  this before they delete the contexts, selecting them the same way.

  The three deletes are one transaction: either all of a context's derived rows
  go, or none do and the caller does not go on to delete the context.
  """

  alias OptimalEngine.Store

  @type removed :: %{
          vectors: non_neg_integer(),
          chunk_embeddings: non_neg_integer(),
          chunks: non_neg_integer()
        }

  @doc """
  Delete what is derived from the contexts `context_ids_sql` selects (a query
  returning context ids, with its `params`). Returns how many rows went from each table.
  """
  @spec delete_for_contexts(String.t(), [term()]) :: {:ok, removed()} | {:error, term()}
  def delete_for_contexts(context_ids_sql, params)
      when is_binary(context_ids_sql) and is_list(params) do
    chunk_ids_sql = "SELECT id FROM chunks WHERE signal_id IN (#{context_ids_sql})"

    Store.transaction(fn txn ->
      with {:ok, vectors} <-
             Store.txn_execute(
               txn,
               "DELETE FROM vectors WHERE context_id IN (#{context_ids_sql})",
               params
             ),
           {:ok, chunk_embeddings} <-
             Store.txn_execute(
               txn,
               "DELETE FROM chunk_embeddings WHERE chunk_id IN (#{chunk_ids_sql})",
               params
             ),
           {:ok, chunks} <-
             Store.txn_execute(
               txn,
               "DELETE FROM chunks WHERE signal_id IN (#{context_ids_sql})",
               params
             ) do
        {:ok, %{vectors: vectors, chunk_embeddings: chunk_embeddings, chunks: chunks}}
      end
    end)
  end
end
