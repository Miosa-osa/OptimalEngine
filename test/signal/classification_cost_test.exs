defmodule OptimalEngine.Signal.ClassificationCostTest do
  @moduledoc """
  Classifying caller text costs time in proportion to its length, whatever its
  shape. `POST /api/ingest` classifies the text it is given, so a pattern that
  backtracks quadratically on one crafted line would hold a worker for
  minutes: a 1 MiB line with no spaces took about ten minutes.

  Each case runs in a task and must finish within its bound; the old patterns
  took seconds to hours on the same inputs.
  """

  use ExUnit.Case, async: true

  alias OptimalEngine.Pipeline.{Classifier, Intake}
  alias OptimalEngine.Signal.{GenreDetector, ModeDetector}

  @mib 1_048_576

  # Shapes that each made one pattern backtrack quadratically.
  defp crafted(n) do
    [
      letters: String.duplicate("a", n),
      underscores: String.duplicate("a_", div(n, 2)),
      letters_and_digits: String.duplicate("a1", div(n, 2)),
      dotted_names: String.duplicate("ab.", div(n, 3)),
      unclosed_braces: "{" <> String.duplicate("a,", div(n, 2)),
      image_openers: String.duplicate("![", div(n, 2)),
      if_without_colon: "if " <> String.duplicate("a==", div(n, 3)),
      for_without_colon: "for x in " <> String.duplicate("a in ", div(n, 5)),
      unclosed_fences: String.duplicate("```a\n", div(n, 5)),
      status_headings: String.duplicate("Status\n", div(n, 7))
    ]
  end

  defp within(ms, label, fun) do
    task = Task.async(fun)

    case Task.yield(task, ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _ -> flunk("#{label} took longer than #{ms} ms")
    end
  end

  test "a 1 MiB line of any crafted shape is classified in well under a second" do
    for {shape, text} <- crafted(@mib) do
      within(1_000, "Intake.classify on 1 MiB of #{shape}", fn -> Intake.classify(text) end)
    end
  end

  test "mode and genre detection are linear without the intake cap" do
    for {shape, text} <- crafted(div(@mib, 4)) do
      within(1_000, "ModeDetector.detect on 256 KiB of #{shape}", fn ->
        ModeDetector.detect(text)
      end)

      within(1_000, "GenreDetector.detect on 256 KiB of #{shape}", fn ->
        GenreDetector.detect(text)
      end)
    end
  end

  test "a long text is classified by its head, with entities and content from all of it" do
    head = "# Rollout notes\n\nThe team met to plan the rollout.\n\n"
    filler = String.duplicate("The rollout continues as planned for the week. ", 2_000)
    text = head <> filler <> "\nLater the Northwind account signed."
    assert byte_size(text) > 65_536

    signal = Intake.classify(text, known_entities: ["Northwind"])

    assert signal.content == text
    assert "Northwind" in signal.entities
    assert signal.title == "Rollout notes"
    assert signal.mode == :linguistic
  end

  test "entities a caller names are kept for a long text" do
    text = String.duplicate("plain words in a long note ", 4_000)
    signal = Intake.classify(text, entities: ["Contoso"])
    assert "Contoso" in signal.entities
    assert signal.content == text
  end

  test "the classifier's entity extraction reads the whole text" do
    text = String.duplicate("filler ", 20_000) <> "Northwind"
    assert Classifier.extract_entities(text, ["Northwind", "Contoso"]) == ["Northwind"]
  end
end
