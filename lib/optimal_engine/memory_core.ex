defmodule OptimalEngine.MemoryCore do
  @moduledoc """
  Public facade for the Memory Core backend layer.

  This module names the architecture boundary explicitly. It exposes the first
  production slices for source evidence, truth promotion, governed recall, and
  task-scoped working memory while keeping low-level persistence behind typed
  Memory Core services.
  """

  alias OptimalEngine.MemoryCore.{
    ActiveMemoryPool,
    KnowledgeLifecycle,
    RetrievalCoordinator,
    SourcePackage
  }

  @spec source_package_from_text(String.t(), keyword()) :: SourcePackage.t()
  defdelegate source_package_from_text(raw_text, opts \\ []), to: SourcePackage, as: :from_text

  defdelegate extract_claim(source_package, opts \\ []), to: KnowledgeLifecycle
  defdelegate promote_claim_to_fact(claim, opts \\ []), to: KnowledgeLifecycle
  defdelegate build_memory_object(fact, opts \\ []), to: KnowledgeLifecycle
  defdelegate retrieve(query, opts \\ []), to: RetrievalCoordinator
  defdelegate open_active_pool(opts \\ []), to: ActiveMemoryPool, as: :open

  defdelegate load_context_package(pool_id, context_package, opts \\ []),
    to: ActiveMemoryPool,
    as: :load_context_package

  defdelegate publish_pool_observation(pool_id, observation_text, opts \\ []),
    to: ActiveMemoryPool,
    as: :publish_observation

  defdelegate close_active_pool(pool_id, opts \\ []), to: ActiveMemoryPool, as: :close
end
