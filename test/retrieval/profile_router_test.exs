defmodule OptimalEngine.Retrieval.ProfileRouterTest do
  use ExUnit.Case, async: true

  alias OptimalEngine.Retrieval.ProfileRouter

  test "routes deterministic inference language to the specialized profile" do
    route =
      ProfileRouter.select(
        "What career might Maria pursue in the future?",
        "task,multimodal",
        "contextual"
      )

    assert route.intent == "inference"
    assert route.models == "contextual"
    assert route.reason == "inference_profile"
  end

  test "keeps temporal and recall questions on the default profiles" do
    temporal = ProfileRouter.select("When did Maria move?", "task,multimodal", "contextual")
    recall = ProfileRouter.select("What city does Maria live in?", "task,multimodal", "contextual")

    assert temporal.models == "task,multimodal"
    assert recall.models == "task,multimodal"
  end

  test "fails back to default profiles when specialization is not configured" do
    route = ProfileRouter.select("What might Maria enjoy?", "task", nil)

    assert route.models == "task"
    assert route.reason == "default_profile"
  end
end
