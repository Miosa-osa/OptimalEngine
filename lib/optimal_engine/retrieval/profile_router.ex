defmodule OptimalEngine.Retrieval.ProfileRouter do
  @moduledoc """
  Deterministic semantic projection selection from an Evidence Plan intent.

  Callers provide projection names. The router never reads benchmark labels,
  answers, or retrieval results, so its decision is reproducible and auditable.
  """

  alias OptimalEngine.MemoryCore.EvidencePlan
  @version "profile-router-v1"

  @doc "Returns the deterministic routing policy version."
  @spec version() :: String.t()
  def version, do: @version

  @spec select(String.t(), String.t(), String.t() | nil) :: map()
  def select(query, default_models, inference_models \\ nil) do
    intent = EvidencePlan.classify(query)

    {models, reason} =
      if intent == "inference" and present?(inference_models) do
        {inference_models, "inference_profile"}
      else
        {default_models, "default_profile"}
      end

    %{intent: intent, models: models, reason: reason, router_version: @version}
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false
end
