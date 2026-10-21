defmodule OptimalEngine.Signal.ClassificationTimeLimitTest do
  # A detection past the classification limit, or past what is left of a
  # document's budget, costs its caller at most that and returns its fallback,
  # and intake keeps serving everyone else. The detectors are linear now, so
  # the tests that need the limit to fire set it to 1 ms on an ordinary text
  # and count the time-limit events.
  use ExUnit.Case, async: false

  alias OptimalEngine.Pipeline.{Classifier, Intake}
  alias OptimalEngine.Pipeline.Decomposer.{Chunk, ChunkTree}
  alias OptimalEngine.Signal.{GenreDetector, ModeDetector, PreSend, TimeLimit}

  @limit_ms 300
  @budget_ms 1_000

  # An HTML-looking tag whose attribute alternation overlaps under repetition.
  @html_line "<a " <> String.duplicate(~s(x="a=b c=d" ), 20) <> "!>"

  setup do
    previous = Application.fetch_env(:optimal_engine, :classification_timeout_ms)
    previous_budget = Application.fetch_env(:optimal_engine, :classification_budget_ms)
    Application.put_env(:optimal_engine, :classification_timeout_ms, @limit_ms)
    Application.put_env(:optimal_engine, :classification_budget_ms, @budget_ms)

    on_exit(fn ->
      restore(:classification_timeout_ms, previous)
      restore(:classification_budget_ms, previous_budget)
    end)
  end

  defp restore(key, {:ok, value}), do: Application.put_env(:optimal_engine, key, value)
  defp restore(key, :error), do: Application.delete_env(:optimal_engine, key)

  defp html_text(lines), do: Enum.map_join(1..lines, "\n", fn _ -> @html_line end)

  # Ordinary code: no detector takes anywhere near a millisecond less than it
  # needs for this much of it.
  defp code_text(bytes) do
    line = "def handle(event, state), do: {:noreply, Map.put(state, :last, event)}\n"
    String.duplicate(line, div(bytes, byte_size(line)))
  end

  @limit_events [
    [:optimal_engine, :signal, :classification_timeout],
    [:optimal_engine, :signal, :classification_budget_spent]
  ]

  # The result of `fun` and the time-limit events it raised, counted by kind.
  defp limit_events(fun) do
    id = {__MODULE__, make_ref()}
    :ok = :telemetry.attach_many(id, @limit_events, &__MODULE__.send_limit_event/4, self())

    try do
      result = fun.()
      {result, collect_limit_events(%{})}
    after
      :telemetry.detach(id)
    end
  end

  @doc false
  def send_limit_event([_, _, kind], _measurements, _metadata, test),
    do: send(test, {:limit_event, kind})

  defp collect_limit_events(counts) do
    receive do
      {:limit_event, kind} -> collect_limit_events(Map.update(counts, kind, 1, &(&1 + 1)))
    after
      0 -> counts
    end
  end

  defp elapsed_ms(fun) do
    {microseconds, result} = :timer.tc(fun)
    {div(microseconds, 1000), result}
  end

  describe "TimeLimit.run/3" do
    test "returns the result of a step that finishes" do
      assert TimeLimit.run(fn -> {:code, :strong} end, :fallback) == {:code, :strong}
    end

    test "stops a step past the limit and returns the fallback" do
      test = self()

      {ms, result} =
        elapsed_ms(fn ->
          TimeLimit.run(
            fn ->
              send(test, {:worker, self()})
              Process.sleep(:infinity)
            end,
            :fallback,
            timeout_ms: 50
          )
        end)

      assert result == :fallback
      assert ms < 1_000
      assert_received {:worker, worker}
      refute Process.alive?(worker)
    end

    test "inside a budget, detections share it and the rest get the fallback" do
      {ms, results} =
        elapsed_ms(fn ->
          TimeLimit.with_budget(
            fn ->
              for _ <- 1..10 do
                TimeLimit.run(fn -> Process.sleep(:infinity) end, :fallback, timeout_ms: 200)
              end
            end,
            budget_ms: 300
          )
        end)

      assert Enum.all?(results, &(&1 == :fallback))
      assert ms < 1_000, "ten detections in a 300 ms budget took #{ms} ms"
    end

    test "a budget opened inside another never extends it" do
      {ms, _} =
        elapsed_ms(fn ->
          TimeLimit.with_budget(
            fn ->
              TimeLimit.with_budget(
                fn ->
                  TimeLimit.run(fn -> Process.sleep(:infinity) end, :fallback, timeout_ms: 5_000)
                end,
                budget_ms: 5_000
              )
            end,
            budget_ms: 100
          )
        end)

      assert ms < 1_000
    end

    test "a worker dies with its caller" do
      test = self()

      caller =
        spawn(fn ->
          TimeLimit.run(
            fn ->
              send(test, {:worker, self()})
              Process.sleep(:infinity)
            end,
            :fallback,
            timeout_ms: 10_000
          )
        end)

      assert_receive {:worker, worker}, 1_000
      monitor = Process.monitor(worker)
      Process.exit(caller, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^worker, _reason}, 1_000
    end

    test "leaves nothing in the caller's mailbox, even when the step ends at the deadline" do
      for _ <- 1..20 do
        TimeLimit.run(
          fn ->
            Process.sleep(20)
            :late
          end,
          :fallback,
          timeout_ms: 20
        )
      end

      Process.sleep(100)
      assert {:messages, []} = Process.info(self(), :messages)
    end

    test "a budget is given back when its work raises" do
      assert_raise RuntimeError, fn ->
        TimeLimit.with_budget(fn -> raise "boom" end, budget_ms: 1)
      end

      # Past the 1 ms budget: a leaked deadline would leave nothing to run with.
      Process.sleep(5)
      assert TimeLimit.run(fn -> :ran end, :fallback) == :ran
    end

    test "returns the fallback when the step fails" do
      assert TimeLimit.run(fn -> raise ArgumentError, "secret text" end, :fallback) == :fallback
    end
  end

  describe "the detectors" do
    test "past the limit, each detector returns its fallback" do
      Application.put_env(:optimal_engine, :classification_timeout_ms, 1)

      for text <- [code_text(64 * 1024), html_text(300)] do
        {{mode, genre}, events} =
          limit_events(fn -> {ModeDetector.detect(text), GenreDetector.detect(text)} end)

        assert mode == {:linguistic, :weak}
        assert genre == "note"
        assert events == %{classification_timeout: 2}
      end
    end

    test "an ordinary text is classified as before" do
      assert ModeDetector.detect(~s({"a": 1, "b": [1, 2]})) == {:data, :strong}

      assert ModeDetector.detect(nil) == {:linguistic, :weak}
      assert GenreDetector.detect(nil) == "note"
    end
  end

  describe "callers" do
    test "a document of many chunks is classified within one budget, the rest by fallback" do
      Application.put_env(:optimal_engine, :classification_budget_ms, 200)

      chunks =
        for i <- 1..30, do: %Chunk{id: "chunk-#{i}", text: code_text(64 * 1024), modality: :text}

      {{ms, {:ok, classifications}}, events} =
        limit_events(fn ->
          elapsed_ms(fn -> Classifier.classify_tree(%ChunkTree{chunks: chunks}) end)
        end)

      assert length(classifications) == 30
      assert events[:classification_budget_spent] >= 1
      assert ms < 200 + 2_000, "30 chunks took #{ms} ms"
    end

    test "a pre-send check of a crafted 8 MB draft returns within the bound" do
      draft = html_text(div(8 * 1024 * 1024, byte_size(@html_line) + 1))

      {ms, report} = elapsed_ms(fn -> PreSend.check(draft, %{}) end)
      assert is_map(report)
      assert ms < @budget_ms + 2_000, "pre-send check took #{ms} ms"
    end

    test "past the limit, a pre-send check reports the detectors' fallbacks" do
      Application.put_env(:optimal_engine, :classification_timeout_ms, 1)

      {report, events} = limit_events(fn -> PreSend.check(code_text(64 * 1024), %{}) end)

      assert report.detected.mode == "linguistic"
      assert events == %{classification_timeout: 2}
    end

    test "an ingest past the limit does not hold up the next ingest, whoever sends it" do
      Application.put_env(:optimal_engine, :classification_timeout_ms, 1)

      {{ms, result, crafted}, events} =
        limit_events(fn ->
          crafted = Task.async(fn -> Intake.process(code_text(64 * 1024), genre: nil) end)
          # Let the crafted ingest reach the intake process first.
          Process.sleep(20)

          {ms, result} =
            elapsed_ms(fn -> Intake.process("A short note about the weekly plan.", []) end)

          {ms, result, Task.await(crafted, 30_000)}
        end)

      assert {:ok, _} = result
      assert {:ok, _} = crafted
      assert ms < 10_000, "an ordinary ingest waited #{ms} ms"
      assert events[:classification_timeout] >= 2
    end
  end
end
