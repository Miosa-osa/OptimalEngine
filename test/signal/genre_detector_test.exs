defmodule OptimalEngine.Signal.GenreDetectorTest do
  use ExUnit.Case, async: true

  alias OptimalEngine.Signal.GenreDetector

  defp genre(text), do: GenreDetector.detect(text)

  describe "notes" do
    test "a plain note stays a note" do
      assert genre(
               "Observed that the nightly export ran long again.\nWorth checking the index window."
             ) ==
               "note"
    end

    test "one common word never decides through the registry" do
      assert genre("Idea: group the results by region so the weekly review is faster to read.") ==
               "note"

      assert genre("Reminder to self: renew the license before the end of the month.") == "note"
    end
  end

  describe "transcripts" do
    test "speaker turns with and without timestamps" do
      assert genre("Alice: We start with hiring.\nBob: Two roles are open.\nAlice: Any blockers?") ==
               "transcript"

      assert genre(
               "[00:00:05] Alice: Welcome.\n[00:00:09] Bob: Thanks.\n[00:00:15] Alice: First item."
             ) ==
               "transcript"

      assert genre("Q: How did you start?\nA: In a small shop.\nQ: And now?\nA: A business.") ==
               "transcript"
    end

    test "subtitles and caption markers" do
      assert genre(
               "1\n00:00:01,000 --> 00:00:03,000\nWelcome.\n\n2\n00:00:03,500 --> 00:00:06,000\nLet's begin."
             ) ==
               "transcript"

      assert genre(">> Thanks for coming.\n>> First item is hiring.\n>> Sure, two roles are open.") ==
               "transcript"
    end

    test "field labels are not speakers" do
      refute genre("Owner: Alice\nStatus: open\nDate: 2026-03-01\nPriority: high") == "transcript"

      refute genre("Monday: draft the proposal\nTuesday: customer calls\nWednesday: writing day") ==
               "transcript"
    end
  end

  describe "emails" do
    test "headers, a greeting with a sign-off, and quoted replies" do
      assert genre("From: a@example.com\nTo: b@example.com\nSubject: Renewal\n\nSee attached.") ==
               "email"

      assert genre("Hi Sam,\n\nPlease return the laptop by Friday.\n\nWarmly,\nPat") == "email"

      assert genre(
               "> can you send the deck?\n\nyep, attached.\n\n> is the customer joining?\n\nnot sure yet"
             ) ==
               "email"
    end
  end

  describe "standups" do
    test "labels, abbreviations and inline labels" do
      assert genre("Yesterday: drafted the spec\nToday: review it\nBlockers: none") == "standup"

      assert genre("Priya\nY: paired on search\nT: write up findings\nB: need sample queries") ==
               "standup"

      assert genre("y: on-call, two pages. t: write up the disk issue. b: none") == "standup"
    end
  end

  describe "documents" do
    test "specs by heading, plain heading, title or RFC 2119 keywords" do
      assert genre("# Export\n\n## Requirements\n- Fast.\n\n## Acceptance Criteria\n- Done.") ==
               "spec"

      assert genre("Export\n\nRequirements\n1. Fast.\n2. Small.") == "spec"

      assert genre("Notification Preferences - Requirements\n\nR1. Users choose a channel.") ==
               "spec"

      assert genre(
               "1. Deliveries MUST succeed within 10 seconds.\n2. Failures MUST be retried.\n3. Receivers SHOULD deduplicate."
             ) == "spec"
    end

    test "postmortems, plans, briefs and decisions" do
      assert genre("Postmortem - duplicate records\n\nSummary: the import duplicated contacts.") ==
               "postmortem"

      assert genre(
               "What happened: reports used stale data.\n\nWhy: the refresh ran late.\n\nWhat we changed: a freshness check."
             ) ==
               "postmortem"

      assert genre("Q4 Hiring Plan\n\nObjective: grow the team to 11.") == "plan"
      assert genre("Brief for the board - April\n\nObjective: approve the pilot.") == "brief"
      assert genre("DECISION - 2026-05-20\nWe will ship with email login only.") == "decision-log"
    end
  end

  describe "messages" do
    test "short text addressed to someone" do
      assert genre("hey @sam, can you look at the checklist before lunch? thanks!") == "message"
      assert genre(":eyes: looking now") == "message"
      assert genre("lgtm, ship it") == "message"
    end

    test "a pasted code block does not make a message a document" do
      text = """
      hey @bob, the helper returns the wrong total, can you take a look?

      ```js
      const parsed = parseDuration("1h30m");
      console.log(parsed);
      console.log(typeof parsed);
      ```
      """

      assert genre(text) == "message"
    end
  end
end
