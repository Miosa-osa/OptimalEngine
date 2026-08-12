defmodule OptimalEngine.MemoryReconstructor do
  @moduledoc """
  Deprecated compatibility Adapter for governed reconstruction.

  New callers should use `OptimalEngine.MemoryCore.retrieve/2` with
  `strategy: :reconstructive`. This Adapter cannot bypass Scope Envelope,
  authorization, Context Package persistence, or evaluation governance.
  """

  alias OptimalEngine.MemoryCore
  alias OptimalEngine.MemoryCore.{ContextPackage, ReconstructionLearning, ScopeEnvelope}
  alias OptimalEngine.ReconstructionEvaluation

  @deprecated "Use OptimalEngine.MemoryCore.retrieve/2 with strategy: :reconstructive"
  def reconstruct(query, opts \\ []) do
    opts =
      opts
      |> Keyword.put(:strategy, :reconstructive)
      |> rename(:step_budget, :reconstruction_steps)
      |> rename(:token_budget, :reconstruction_tokens)

    case MemoryCore.retrieve(query, opts) do
      {:ok, package} -> {:ok, ContextPackage.to_map(package)}
      error -> error
    end
  end

  @deprecated "Use OptimalEngine.MemoryCore.ReconstructionLearning.record_outcome/4"
  def feedback(run_id, outcome, opts \\ []) do
    scope = scope(opts)
    ReconstructionLearning.record_outcome(run_id, outcome, scope, opts)
  end

  @deprecated "Use OptimalEngine.MemoryCore.ReconstructionLearning.propose_consolidation/2"
  def consolidate(opts \\ []), do: ReconstructionLearning.propose_consolidation(scope(opts), opts)

  @deprecated "Use OptimalEngine.MemoryCore.ReconstructionLearning.measure/1"
  def quality(opts \\ []), do: ReconstructionLearning.measure(scope(opts))

  @deprecated "Use OptimalEngine.ReconstructionEvaluation.run/2"
  def benchmark(questions, opts \\ []) do
    cases =
      Enum.with_index(questions, 1)
      |> Enum.map(fn {question, index} -> %{case_id: "compat-#{index}", question: question} end)

    ReconstructionEvaluation.run(cases, opts)
  end

  defp scope(opts) do
    ScopeEnvelope.resolve(%{
      tenant_id: Keyword.get(opts, :tenant_id, "default"),
      workspace_id: Keyword.get(opts, :workspace_id, "default"),
      actor_id: Keyword.get(opts, :actor_id, "user:roberto"),
      permissions: Keyword.get(opts, :permissions, [])
    })
  end

  defp rename(opts, old, new) do
    case Keyword.fetch(opts, old) do
      {:ok, value} -> opts |> Keyword.delete(old) |> Keyword.put(new, value)
      :error -> opts
    end
  end
end
