defmodule OptimalEngine.Signal.ClassificationCostTest do
  @moduledoc """
  Classifying caller text costs time in proportion to its length, whatever its
  shape. `POST /api/ingest` classifies the text it is given, so a pattern that
  backtracks quadratically on one crafted line would hold a worker for
  minutes: a 1 MiB line with no spaces took about ten minutes.

  Each case runs in a task and must finish within its bound; the old patterns
  took seconds to hours on the same inputs. The module runs alone (not
  async), so the bounds measure this work and not the rest of the suite.
  """

  use ExUnit.Case, async: false

  alias OptimalEngine.Pipeline.{Classifier, Intake}
  alias OptimalEngine.Signal.{GenreDetector, ModeDetector}

  @mib 1_048_576

  # One-line shapes that each made a mode pattern backtrack quadratically.
  defp lines(n) do
    spaces = String.duplicate(" ", n)

    [
      letters: String.duplicate("a", n),
      underscores: String.duplicate("a_", div(n, 2)),
      letters_and_digits: String.duplicate("a1", div(n, 2)),
      dotted_names: String.duplicate("ab.", div(n, 3)),
      unclosed_braces: "{" <> String.duplicate("a,", div(n, 2)),
      image_openers: String.duplicate("![", div(n, 2)),
      if_without_colon: "if " <> String.duplicate("a==", div(n, 3)),
      for_without_colon: "for x in " <> String.duplicate("a in ", div(n, 5)),
      for_with_spaces: "for x" <> spaces <> "y:",
      function_with_spaces: "function" <> spaces <> "x",
      import_with_spaces: "import" <> spaces <> "!",
      return_with_spaces: "return a" <> spaces <> "!",
      const_with_spaces: "const a: b" <> spaces <> "!",
      if_paren_with_spaces: "if (a)" <> spaces <> "!",
      end_with_spaces: "end" <> spaces <> "!",
      selector_with_spaces: "a" <> spaces <> "(",
      json_comment_openers: "[" <> String.duplicate("/*", div(n, 2))
    ]
  end

  # Multi-line shapes that each made a pattern backtrack quadratically.
  defp documents(n) do
    blank_lines = String.duplicate(" \n", div(n, 2))

    [
      unclosed_fences: String.duplicate("```a\n", div(n, 5)),
      status_headings: String.duplicate("Status\n", div(n, 7)),
      standup_spaces: "notes. " <> String.duplicate(" ", n) <> "x",
      blank_lines: "a" <> blank_lines <> "a",
      fence_then_blank_lines: "```a" <> blank_lines <> "a",
      json_then_blank_lines: "{" <> blank_lines <> "x"
    ]
  end

  defp detectors do
    [
      {"ModeDetector.detect", &ModeDetector.detect/1},
      {"GenreDetector.detect", &GenreDetector.detect/1}
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
    for {shape, text} <- lines(@mib) do
      within(1_000, "Intake.classify on 1 MiB of #{shape}", fn -> Intake.classify(text) end)
    end
  end

  test "a 1 MiB document of any crafted shape is classified within two seconds" do
    for {shape, text} <- documents(@mib) do
      within(2_000, "Intake.classify on 1 MiB of #{shape}", fn -> Intake.classify(text) end)
    end
  end

  test "mode and genre detection are linear on a long line without the intake cap" do
    for {shape, text} <- lines(div(@mib, 4)), {name, detect} <- detectors() do
      within(2_000, "#{name} on 256 KiB of #{shape}", fn -> detect.(text) end)
    end
  end

  test "mode and genre detection are linear on a long document without the intake cap" do
    for {shape, text} <- documents(div(@mib, 8)), {name, detect} <- detectors() do
      within(2_000, "#{name} on 128 KiB of #{shape}", fn -> detect.(text) end)
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

  test "a long text is cut at a character boundary" do
    # One byte, then two-byte characters: the cut falls inside a character.
    text = "a" <> String.duplicate("é", 40_000)
    assert byte_size(text) > 65_536
    signal = Intake.classify(text)
    assert signal.content == text
    assert String.valid?(signal.l1_description)
  end

  test "the classifier's entity extraction reads the whole text" do
    text = String.duplicate("filler ", 20_000) <> "Northwind"
    assert Classifier.extract_entities(text, ["Northwind", "Contoso"]) == ["Northwind"]
  end
end
