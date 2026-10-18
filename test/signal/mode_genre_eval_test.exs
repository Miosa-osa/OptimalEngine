defmodule OptimalEngine.Signal.ModeGenreEvalTest do
  @moduledoc """
  Mode and Genre accuracy of the intake classification path
  (`OptimalEngine.Pipeline.Intake.classify/2`, the exact Mode and Genre that
  `Intake.process/2` stores) against labeled corpora:

    * `OptimalEngine.SignalEvalCorpus` - 500+ generated samples across
      genres and modes (the primary set)
    * `OptimalEngine.SignalEvalHoldout` and `OptimalEngine.SignalEvalBlind` -
      independently written sets whose authors never saw the classifier

  Set `SIGNAL_EVAL_REPORT=1` to print the measured accuracy per set.
  """
  use ExUnit.Case, async: true

  alias OptimalEngine.Pipeline.Intake
  alias OptimalEngine.{SignalEvalBlind, SignalEvalCorpus, SignalEvalHoldout}

  @mode_target 0.95
  @genre_target 0.85

  setup_all do
    sets = %{
      corpus: measure(SignalEvalCorpus.samples()),
      holdout: measure(SignalEvalHoldout.samples()),
      blind: measure(SignalEvalBlind.samples())
    }

    if System.get_env("SIGNAL_EVAL_REPORT") do
      for {name, set} <- sets, do: IO.puts("\n#{name}: #{describe(set)}")
    end

    %{sets: sets}
  end

  test "the primary corpus has at least 500 labeled samples", %{sets: sets} do
    assert sets.corpus.n >= 500
    assert MapSet.size(MapSet.new(sets.corpus.results, & &1.id)) == sets.corpus.n
  end

  test "primary corpus: mode accuracy >= 95% and genre accuracy >= 85%", %{sets: sets} do
    assert_targets(sets.corpus)
  end

  test "independent sets combined: mode >= 95% and genre >= 85%", %{sets: sets} do
    assert_targets(merge(sets.holdout, sets.blind))
  end

  test "each independent set keeps mode accuracy >= 95%", %{sets: sets} do
    for set <- [sets.holdout, sets.blind] do
      assert set.mode_accuracy >= @mode_target, describe(set) <> misses(set, :mode)
    end
  end

  defp assert_targets(set) do
    assert set.mode_accuracy >= @mode_target, describe(set) <> misses(set, :mode)
    assert set.genre_accuracy >= @genre_target, describe(set) <> misses(set, :genre)
  end

  defp measure(samples) do
    results =
      Enum.map(samples, fn sample ->
        signal = Intake.classify(sample.text)
        Map.merge(sample, %{got_mode: signal.mode, got_genre: signal.genre})
      end)

    summarize(results)
  end

  defp merge(a, b), do: summarize(a.results ++ b.results)

  defp summarize(results) do
    labeled = Enum.filter(results, & &1.genre)

    %{
      results: results,
      n: length(results),
      labeled: length(labeled),
      mode_hits: Enum.count(results, &(&1.got_mode == &1.mode)),
      genre_hits: Enum.count(labeled, &(&1.got_genre == &1.genre)),
      mode_accuracy: Enum.count(results, &(&1.got_mode == &1.mode)) / max(length(results), 1),
      genre_accuracy: Enum.count(labeled, &(&1.got_genre == &1.genre)) / max(length(labeled), 1)
    }
  end

  defp describe(set) do
    "mode #{set.mode_hits}/#{set.n} (#{percent(set.mode_accuracy)}), " <>
      "genre #{set.genre_hits}/#{set.labeled} (#{percent(set.genre_accuracy)})"
  end

  defp percent(ratio), do: "#{Float.round(ratio * 100, 2)}%"

  defp misses(set, :mode) do
    set.results
    |> Enum.reject(&(&1.got_mode == &1.mode))
    |> Enum.map_join("", &"\n  #{&1.id}: expected #{&1.mode}, got #{&1.got_mode}")
  end

  defp misses(set, :genre) do
    set.results
    |> Enum.filter(&(&1.genre && &1.got_genre != &1.genre))
    |> Enum.map_join("", &"\n  #{&1.id}: expected #{&1.genre}, got #{&1.got_genre}")
  end
end
