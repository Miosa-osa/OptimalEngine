defmodule OptimalEngine.Signal.ClassificationCostTest do
  @moduledoc """
  Classifying caller text costs bounded time, whatever its shape and length.
  `POST /api/ingest` classifies the text it is given and the pre-send check
  reads a whole draft, so a pattern that backtracks quadratically on one
  crafted line would hold a worker for minutes: a 1 MiB line with no spaces
  took about ten minutes.

  The bound is on how the cost grows, not on the clock: each case is run on a
  quarter of the input and on all of it, and the whole must cost no more than
  10 times the quarter (linear work costs 4 times, the quadratic patterns
  cost 16 and more). Both runs share the runner's load at that moment, so a
  busy runner slows both. A case under 50 ms on the whole input passes
  outright, since there the timer's resolution is the ratio, and every run
  has a 30 second ceiling that catches an exponential pattern.
  The classification time limit (`OptimalEngine.Signal.TimeLimit`), which
  caps a slow detection, is lifted here, so the bounds measure the detectors
  themselves.
  """

  use ExUnit.Case, async: false

  alias OptimalEngine.Pipeline.{Classifier, Intake}
  alias OptimalEngine.Signal.{GenreDetector, ModeDetector, PreSend}

  @mib 1_048_576
  @limits [:classification_timeout_ms, :classification_budget_ms]

  setup do
    previous = Map.new(@limits, &{&1, Application.fetch_env(:optimal_engine, &1)})
    Enum.each(@limits, &Application.put_env(:optimal_engine, &1, 600_000))
    on_exit(fn -> Enum.each(previous, &restore/1) end)
  end

  defp restore({key, {:ok, value}}), do: Application.put_env(:optimal_engine, key, value)
  defp restore({key, :error}), do: Application.delete_env(:optimal_engine, key)

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
      css_declaration_with_spaces: "a:" <> spaces <> "x",
      json_comment_openers: "[" <> String.duplicate("/*", div(n, 2)),
      if_with_spaces_then_colon: "if" <> spaces <> ":",
      while_with_spaces_then_colon: "while" <> spaces <> ":",
      with_with_spaces_then_colon: "with" <> spaces <> ":",
      quotes_after_a_letter: "a" <> String.duplicate("'", n) <> "1",
      timestamp_with_spaces: "[00:00]" <> spaces <> "x"
    ]
  end

  # Multi-line shapes that each made a pattern backtrack quadratically, or
  # (HTML attributes) exponentially on every line.
  defp documents(n) do
    blank_lines = String.duplicate(" \n", div(n, 2))
    html_line = "<a " <> String.duplicate(~s(x="a=b c=d" ), 20) <> "!>\n"
    css_line = "a:" <> String.duplicate(" ", 60_000) <> "x\n"

    [
      unclosed_fences: String.duplicate("```a\n", div(n, 5)),
      status_headings: String.duplicate("Status\n", div(n, 7)),
      standup_spaces: "notes. " <> String.duplicate(" ", n) <> "x",
      blank_lines: "a" <> blank_lines <> "a",
      fence_then_blank_lines: "```a" <> blank_lines <> "a",
      json_then_blank_lines: "{" <> blank_lines <> "x",
      html_attribute_lines: String.duplicate(html_line, div(n, byte_size(html_line))),
      css_declaration_lines: String.duplicate(css_line, div(n, byte_size(css_line)))
    ]
  end

  # A JSON object with one to five tags, so its lines do not line up as the
  # rows of a comma-separated table.
  defp record(n) do
    tags = Enum.take(~w(alpha beta gamma delta epsilon), rem(n, 5) + 1)
    Jason.encode!(%{"id" => n, "note" => "what happened to record #{n}", "tags" => tags})
  end

  defp detectors do
    [
      {"ModeDetector.detect", &ModeDetector.detect/1},
      {"GenreDetector.detect", &GenreDetector.detect/1}
    ]
  end

  # The result of `fun` and the labels of the steps the time limit stopped.
  defp timeouts(fun) do
    id = {__MODULE__, make_ref()}
    event = [:optimal_engine, :signal, :classification_timeout]
    :ok = :telemetry.attach(id, event, &__MODULE__.send_timeout/4, self())

    try do
      result = fun.()
      {result, collect_timeouts([])}
    after
      :telemetry.detach(id)
    end
  end

  @doc false
  def send_timeout(_event, _measurements, %{label: label}, test),
    do: send(test, {:stopped, label})

  defp collect_timeouts(labels) do
    receive do
      {:stopped, label} -> collect_timeouts([label | labels])
    after
      0 -> labels
    end
  end

  @ceiling_ms 30_000
  @max_ratio 10
  @floor_ms 50

  # Microseconds `fun` took, in a task with the ceiling.
  defp timed(label, fun) do
    task = Task.async(fn -> elem(:timer.tc(fun), 0) end)

    case Task.yield(task, @ceiling_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, us} -> us
      _ -> flunk("#{label} took longer than #{@ceiling_ms} ms")
    end
  end

  # `run.(input)` on a quarter of the input and on all of it: the whole may
  # cost at most @max_ratio times the quarter. Measured up to three times,
  # keeping the fastest of each, before it fails.
  defp grows_linearly(label, quarter, whole, run, tries \\ 3, best \\ {nil, nil}) do
    small = min_us(elem(best, 0), timed(label, fn -> run.(quarter) end))
    big = min_us(elem(best, 1), timed(label, fn -> run.(whole) end))

    cond do
      div(big, 1000) <= @floor_ms ->
        :ok

      big <= @max_ratio * max(small, 1) ->
        :ok

      tries > 1 ->
        grows_linearly(label, quarter, whole, run, tries - 1, {small, big})

      true ->
        flunk(
          "#{label}: the whole input cost #{big} us, the quarter #{small} us (more than #{@max_ratio} times)"
        )
    end
  end

  defp min_us(nil, us), do: us
  defp min_us(a, b), do: min(a, b)

  defp pairs(shapes) do
    quarters = Map.new(shapes.(div(@mib, 4)))
    for {shape, whole} <- shapes.(@mib), do: {shape, Map.fetch!(quarters, shape), whole}
  end

  # The measure itself: work that grows with the square of the input fails it.
  test "work quadratic in its input does not pass as linear" do
    quadratic = fn text ->
      chunks = div(byte_size(text), 2048)
      for i <- 1..chunks, do: :binary.copy(binary_part(text, 0, i * 2048))
      :ok
    end

    text = String.duplicate("a", @mib)

    assert_raise ExUnit.AssertionError, ~r/more than 10 times/, fn ->
      grows_linearly("quadratic", binary_part(text, 0, div(@mib, 4)), text, quadratic)
    end
  end

  test "classifying a crafted line grows linearly with its length, up to 1 MiB" do
    for {shape, quarter, whole} <- pairs(&lines/1) do
      grows_linearly("Intake.classify of #{shape}", quarter, whole, &Intake.classify/1)
    end
  end

  test "classifying a crafted document grows linearly with its length, up to 1 MiB" do
    for {shape, quarter, whole} <- pairs(&documents/1) do
      grows_linearly("Intake.classify of #{shape}", quarter, whole, &Intake.classify/1)
    end
  end

  test "mode and genre detection of a crafted text grow linearly with its length" do
    for {shape, quarter, whole} <- pairs(&lines/1) ++ pairs(&documents/1),
        {name, detect} <- detectors() do
      grows_linearly("#{name} of #{shape}", quarter, whole, detect)
    end
  end

  test "a pre-send check of a crafted draft grows linearly with its length" do
    for {shape, quarter, whole} <- pairs(&lines/1) ++ pairs(&documents/1) do
      grows_linearly("PreSend.check of #{shape}", quarter, whole, fn text ->
        PreSend.check(text, %{"channel" => "email"})
      end)
    end
  end

  test "a JSON Lines document longer than the head is data" do
    text = Enum.map_join(1..1_500, "\n", &record/1)

    assert byte_size(text) > 65_536
    assert ModeDetector.detect(text) == {:data, :strong}
    assert Intake.classify(text).mode == :data
  end

  test "a JSON array longer than the head is data" do
    text = "[\n" <> Enum.map_join(1..1_500, ",\n", &record/1) <> "\n]"

    assert byte_size(text) > 65_536
    assert ModeDetector.detect(text) == {:data, :strong}
    assert Intake.classify(text).mode == :data
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

  test "past the classification limit, a long text's entities come from its head" do
    Application.put_env(:optimal_engine, :classification_timeout_ms, 1)
    head = "Contoso asked for the rollout plan.\n\n"
    filler = String.duplicate("The rollout continues as planned for the week. ", 20_000)
    text = head <> filler <> "\nLater the Northwind account signed."
    # 676 names the text never mentions, each starting like "planned", so no
    # quick check rules one out: reading the whole body for them takes far
    # longer than the 1 ms limit on any runner.
    absent = for a <- ?a..?z, b <- ?a..?z, do: "Plannx" <> <<a, b>>
    names = ["Contoso", "Northwind" | absent]

    {signal, stopped} = timeouts(fn -> Intake.classify(text, known_entities: names) end)

    assert "entity extraction" in stopped
    assert "Contoso" in signal.entities
    refute "Northwind" in signal.entities
  end

  test "a long text's entities come from its body, as a short text's do" do
    frontmatter = "---\ntitle: Contoso review\n---\n"
    body = "The rollout continues as planned for the week. "

    for text <- [frontmatter <> body, frontmatter <> String.duplicate(body, 2_000)] do
      refute "Contoso" in Intake.classify(text, known_entities: ["Contoso"]).entities
    end
  end

  test "the classifier's entity extraction reads the whole text" do
    text = String.duplicate("filler ", 20_000) <> "Northwind"
    assert Classifier.extract_entities(text, ["Northwind", "Contoso"]) == ["Northwind"]
  end
end
