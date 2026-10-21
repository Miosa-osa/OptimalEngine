defmodule OptimalEngine.Retrieval.SearchFailure do
  @moduledoc """
  What a search that failed leaves behind.

  An exception message can carry SQL, a path or a value from the data, so it
  never reaches the caller. It goes to the log, with its stack trace, and a
  telemetry event counts it. The caller gets `{:search_failed, ref}`, where
  `ref` is an opaque id that is also in the log line: an operator finds the
  failure from the id the caller reports.
  """

  require Logger

  @type ref :: String.t()

  @doc """
  Logs a failed search, emits `[:optimal_engine, :search, :failed]` and returns
  the id to hand to the caller.

  `detail` is the formatted exception or exit reason. `meta` names the request
  without quoting it: `:workspace_id` and `:query_length`.
  """
  @spec record(String.t(), %{workspace_id: term(), query_length: non_neg_integer()}) :: ref()
  def record(detail, %{workspace_id: workspace_id, query_length: query_length} = meta)
      when is_binary(detail) do
    ref = new_ref()

    Logger.error(
      "[Search] search failed ref=#{ref} workspace=#{inspect(workspace_id)} query_length=#{query_length}\n" <>
        detail
    )

    :telemetry.execute(
      [:optimal_engine, :search, :failed],
      %{count: 1},
      Map.put(meta, :ref, ref)
    )

    ref
  end

  defp new_ref, do: 6 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
end
