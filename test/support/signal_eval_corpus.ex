defmodule OptimalEngine.SignalEvalCorpus do
  @moduledoc """
  Deterministic labeled corpus for Mode and Genre classification.

  Every sample is generated from generic templates (fictional topics, first
  names only, no organizations), so the corpus is identical on every run and
  safe to publish.

  Each sample is `%{id: String.t(), text: String.t(), mode: atom(), genre: String.t() | nil}`.

  Mode labels follow Signal Theory:

    * `:linguistic` - prose written for people: transcripts, emails, chat,
      notes, specs and other documents, including ones that mention code words
    * `:code` - source code, queries, scripts, markup and stylesheets
    * `:data` - structured records: JSON, JSON Lines, CSV/TSV, YAML config,
      markdown tables
    * `:visual` - images, SVG drawings and diagram definitions
    * `:mixed` - prose plus a substantive code block, data table or image

  `genre: nil` means the sample carries no genre label (source code, raw data
  payloads, and context-free acknowledgements such as "ok") and is scored
  for Mode only.
  """

  @topics [
    %{
      topic: "warehouse migration",
      thing: "inventory sync job",
      other: "the nightly backup",
      metric: "sync lag"
    },
    %{
      topic: "billing export",
      thing: "invoice export",
      other: "the ledger reconciliation",
      metric: "export time"
    },
    %{
      topic: "mobile release",
      thing: "release build",
      other: "the crash reporter",
      metric: "crash rate"
    },
    %{
      topic: "customer onboarding",
      thing: "welcome sequence",
      other: "the account setup form",
      metric: "activation rate"
    },
    %{
      topic: "support queue",
      thing: "ticket router",
      other: "the escalation rota",
      metric: "first response time"
    },
    %{
      topic: "pricing page refresh",
      thing: "pricing table",
      other: "the checkout flow",
      metric: "conversion rate"
    },
    %{
      topic: "hiring pipeline",
      thing: "interview scheduler",
      other: "the offer template",
      metric: "time to hire"
    },
    %{
      topic: "vendor renewal",
      thing: "license agreement",
      other: "the seat count review",
      metric: "annual cost"
    },
    %{
      topic: "security review",
      thing: "access audit",
      other: "the key rotation",
      metric: "open findings"
    },
    %{
      topic: "analytics dashboard",
      thing: "usage dashboard",
      other: "the event pipeline",
      metric: "query latency"
    },
    %{
      topic: "API rate limits",
      thing: "rate limiter",
      other: "the partner integration",
      metric: "rejected requests"
    },
    %{topic: "office move", thing: "desk plan", other: "the network install", metric: "move date"},
    %{
      topic: "data retention",
      thing: "archive job",
      other: "the cold storage bucket",
      metric: "storage cost"
    },
    %{
      topic: "search relevance",
      thing: "ranking model",
      other: "the synonym list",
      metric: "click-through rate"
    },
    %{
      topic: "payroll cutover",
      thing: "payroll import",
      other: "the tax tables",
      metric: "error count"
    }
  ]

  @people ~w(Alice Bob Carol Dan Erin Frank Grace Heidi Ivan Judy Ken Laura Mona Nate Olga Pete)

  @doc "All labeled samples, in a stable order."
  @spec samples() :: [map()]
  def samples do
    transcripts() ++
      emails() ++
      messages() ++
      notes() ++
      specs() ++
      decision_logs() ++
      standups() ++
      postmortems() ++
      runbooks() ++
      plans() ++
      briefs() ++
      changelogs() ++
      acknowledgements() ++
      code_samples() ++
      data_samples() ++
      mixed_samples() ++ visual_samples()
  end

  # ── Helpers ─────────────────────────────────────────────────────────────

  defp topic(i), do: Enum.at(@topics, rem(i, length(@topics)))
  defp person(i), do: Enum.at(@people, rem(i, length(@people)))
  defp pick(list, i), do: Enum.at(list, rem(i, length(list)))
  defp cap(text), do: String.capitalize(String.first(text)) <> String.slice(text, 1..-1//1)

  defp slug(text),
    do: text |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "_") |> String.trim("_")

  defp camel(text), do: text |> String.split(~r/[^A-Za-z0-9]+/, trim: true) |> Enum.map_join(&cap/1)
  defp ts(i), do: "00:#{pad(rem(i, 50))}:#{pad(rem(i * 7, 60))}"
  defp pad(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")

  defp fill(template, t, i) do
    template
    |> String.replace("{topic}", t.topic)
    |> String.replace("{Topic}", cap(t.topic))
    |> String.replace("{thing}", t.thing)
    |> String.replace("{Thing}", cap(t.thing))
    |> String.replace("{other}", t.other)
    |> String.replace("{metric}", t.metric)
    |> String.replace("{p}", person(i))
    |> String.replace("{p2}", person(i + 5))
    |> String.replace("{n}", Integer.to_string(20 + rem(i * 13, 70)))
  end

  defp sample(prefix, i, text, mode, genre),
    do: %{id: "#{prefix}-#{pad(i)}", text: text, mode: mode, genre: genre}

  # ── Linguistic genres ───────────────────────────────────────────────────

  @utterances [
    "Thanks for joining. Today we walk through the {topic} and the open risks.",
    "The {thing} is mostly done, but {other} still needs a review.",
    "What does the {metric} look like this week?",
    "It improved after the last change, roughly ten percent better than before.",
    "I think we should require a dry run before we switch anything in production.",
    "Can we import the old records first, or does that block {other}?",
    "That is a first class concern for the team, so let's keep it on the agenda.",
    "We decided last time to keep the budget flat, so no new tools this quarter.",
    "I'll take the action item to update {other} by Thursday.",
    "One question about the {thing}: who owns the rollback if it goes wrong?",
    "Let's make sure the {metric} is on the dashboard before the review.",
    "Agreed, and let's not ship until {other} is green.",
    "I can pair with you on the {thing} tomorrow morning.",
    "Sounds good. Anything else before we wrap up?"
  ]

  defp transcripts do
    for i <- 0..49 do
      t = topic(i)
      speakers = [person(i), person(i + 3), person(i + 7)]

      lines =
        for k <- 0..(5 + rem(i, 4)) do
          {pick(speakers, k), fill(pick(@utterances, i + k), t, i + k)}
        end

      text =
        case rem(i, 5) do
          0 ->
            Enum.map_join(Enum.with_index(lines), "\n", fn {{s, u}, k} ->
              "[#{ts(i + k * 9)}] #{s}: #{u}"
            end)

          1 ->
            Enum.map_join(lines, "\n", fn {s, u} -> "#{s}: #{u}" end)

          2 ->
            "## Participants\n" <>
              Enum.map_join(speakers, "\n", &"- #{&1}") <>
              "\n\n## Transcript\n" <> Enum.map_join(lines, "\n", fn {s, u} -> "#{s}: #{u}" end)

          3 ->
            Enum.map_join(Enum.with_index(lines), "\n\n", fn {{s, u}, k} ->
              "#{s}  #{rem(k * 3, 10)}:#{pad(rem(k * 17, 60))}\n#{u}"
            end)

          4 ->
            Enum.map_join(Enum.with_index(lines), "\n", fn {{s, u}, k} ->
              n = Enum.find_index(speakers, &(&1 == s)) + 1
              "Speaker #{n} (#{ts(i + k * 11)}): #{u}"
            end)
        end

      sample("transcript", i, text, :linguistic, "transcript")
    end
  end

  @email_sentences [
    "Following up on the {topic}: the {thing} is ready for review.",
    "We still need a decision on {other} before Friday.",
    "Could you confirm the {metric} numbers from last week?",
    "I attached the summary and highlighted the open questions.",
    "The vendor asked whether we can move the call to next Tuesday.",
    "If the plan works for everyone, I will import the final list on Monday.",
    "Let me know if anything looks off, and I can walk you through it."
  ]

  defp emails do
    for i <- 0..39 do
      t = topic(i)
      body = Enum.map_join(0..(2 + rem(i, 3)), " ", &fill(pick(@email_sentences, i + &1), t, i))
      body2 = fill(pick(@email_sentences, i + 4), t, i)

      text =
        case rem(i, 4) do
          0 ->
            "Subject: #{cap(t.topic)} next steps\n\nHi #{person(i + 1)},\n\n#{body}\n\n#{body2}\n\nBest regards,\n#{person(i)}"

          1 ->
            "From: #{String.downcase(person(i))}@example.com\nTo: team@example.com\nSubject: Update on the #{t.thing}\n\nHello team,\n\n#{body}\n\nThanks,\n#{person(i)}"

          2 ->
            "Hi all,\n\n#{body}\n\n#{body2}\n\nCheers,\n#{person(i)}"

          3 ->
            "Dear #{person(i + 2)},\n\n#{body}\n\nKind regards,\n#{person(i)}"
        end

      sample("email", i, text, :linguistic, "email")
    end
  end

  @chat [
    "hey @{p}, can you take a look at the {thing} before lunch? thanks!",
    "@{p} the {thing} is failing again, did you change anything?",
    "thanks for the quick review! I'll update the {thing} tonight",
    "anyone know why the {thing} is so slow today?",
    "lgtm, ship it 🚀",
    "can someone restart the {thing}? it's stuck again",
    "running 10 min late to the {topic} sync, start without me pls",
    "{p} do you have the latest numbers for the {metric}?",
    "np, I can cover the {thing} on-call this weekend if you need",
    "btw {other} moved to Thursday, fyi",
    "nice work on the {thing} 🎉 the {metric} looks way better",
    "did you get a chance to look at my comments on the {thing}?",
    "sgtm, let's go with option two",
    "ok, I'll ping you when the {thing} is back up",
    "quick one: are you still blocked on {other}?",
    "sorry, missed your message. yes, the {thing} is ready for you",
    "pls don't merge anything into main until the {thing} is fixed",
    "thank you! that fixed the {thing} for me",
    "@{p} @{p2} can you two sync on {other} today?",
    "you around? need a second pair of eyes on the {thing}"
  ]

  defp messages do
    for i <- 0..39 do
      text = fill(pick(@chat, i), topic(i * 7), i)

      text =
        if rem(i, 6) == 5, do: text <> "\n" <> fill(pick(@chat, i + 3), topic(i), i + 1), else: text

      sample("message", i, text, :linguistic, "message")
    end
  end

  @note_templates [
    "Observed that the {thing} took {n} minutes again.\nWorth checking whether {other} runs in the same window.",
    "Idea: group the {thing} results by region so the weekly review is faster to read.",
    "Reminder to self: renew the {thing} before the end of the month.",
    "Reading notes on the {topic}. The main point is that small batches fail less often and are easier to roll back.",
    "{Topic}: the vendor confirmed the new limits. Follow up on the contract wording next week.",
    "- {thing} is slower than last month\n- check whether {other} changed\n- ask {p} about access to the logs",
    "The {metric} dipped after the last release. Likely related to the new caching layer, not confirmed yet.",
    "Things to remember for the {topic}: bring the printed agenda, book the larger room, order lunch for twelve.",
    "Draft thought: the {thing} could run every hour instead of nightly, which would cut the {metric} in half.",
    "Met {p} at the conference; a good contact for {topic} questions.",
    "Keep an eye on the {metric} this week. If it keeps climbing, revisit the {thing} settings.",
    "Learned that {other} only accepts files under ten megabytes.",
    "Open question for later: should the {thing} move to the shared team account?",
    "Book recommendation from {p}: a short read on running effective meetings.",
    "TODO: clean up the old {thing} branches and archive the unused exports.",
    "Weekend project idea: a tiny script that summarizes the {metric} trend in plain text."
  ]

  defp notes do
    for i <- 0..47 do
      sample("note", i, fill(pick(@note_templates, i), topic(i * 4 + 1), i), :linguistic, "note")
    end
  end

  defp specs do
    for i <- 0..29 do
      t = topic(i)

      text =
        case rem(i, 3) do
          0 ->
            """
            # #{cap(t.thing)} Spec

            ## Goal
            Give operators a reliable #{t.thing} with a clear owner.

            ## Requirements
            - The #{t.thing} runs once per night and finishes within thirty minutes.
            - Each run writes a single summary per workspace.
            - Failed runs retry twice before alerting the on-call operator.

            ## Acceptance Criteria
            - [ ] A summary exists for every active workspace each morning.
            - [ ] Alerts fire within five minutes of the final failed retry.
            """

          1 ->
            """
            # #{cap(t.topic)}: requirements

            ## Context
            The current #{t.thing} depends on manual steps, and #{t.other} is often late.

            ## Requirements
            1. The #{t.thing} must start automatically after #{t.other} completes.
            2. Operators can pause and resume a run from the admin page.
            3. Every run records the #{t.metric} so trends are visible.

            ## Constraints
            - No new infrastructure this quarter.
            - The change must not require downtime.

            ## Out of Scope
            - Rewriting #{t.other}.
            """

          2 ->
            """
            # Spec: #{t.thing}

            The #{t.thing} must report its #{t.metric} every hour. It should keep the last ninety days of history and expose a weekly summary for the review meeting.

            ## Acceptance Criteria
            - Hourly values appear on the dashboard within ten minutes.
            - The weekly summary matches the hourly totals.
            """
        end

      sample("spec", i, text, :linguistic, "spec")
    end
  end

  defp decision_logs do
    for i <- 0..20 do
      t = topic(i)

      text =
        case rem(i, 3) do
          0 ->
            "# Decision: move the #{t.thing} to the shared account\n\n**Status:** accepted\n\n## Context\nThe #{t.thing} lives in a personal account, which blocks access during vacations.\n\n## Decision\nWe decided to move it to the shared team account before #{t.other}.\n\n## Consequences\nAccess requests go through the team lead from now on."

          1 ->
            "Decision: pause new work on the #{t.thing} until #{t.other} is complete.\nRationale: both changes touch the same records and the #{t.metric} is already unstable.\nOwner: #{person(i)}\nDate: 2026-0#{rem(i, 9) + 1}-1#{rem(i, 9)}"

          2 ->
            "## Key decisions from the #{t.topic} review\n\n- We decided to keep the current #{t.thing} for one more quarter.\n- #{t.other |> cap()} moves to a monthly schedule.\n- #{person(i)} owns the follow-up on the #{t.metric}."
        end

      sample("decision", i, text, :linguistic, "decision-log")
    end
  end

  defp standups do
    for i <- 0..20 do
      t = topic(i)

      text =
        case rem(i, 3) do
          0 ->
            "Yesterday: finished the first draft of the #{t.thing}\nToday: review #{t.other} with #{person(i)}\nBlockers: none"

          1 ->
            "**Yesterday**\n- Fixed the alert noise on the #{t.thing}\n\n**Today**\n- Pair with #{person(i)} on #{t.other}\n\n**Blockers**\n- Waiting on access to the #{t.metric} report"

          2 ->
            "## Standup notes\n\n### Yesterday\n- Shipped the #{t.thing} change to staging\n\n### Today\n- Watch the #{t.metric} and write up the results\n\n### Blockers\n- None right now"
        end

      sample("standup", i, text, :linguistic, "standup")
    end
  end

  defp postmortems do
    for i <- 0..14 do
      t = topic(i)

      text = """
      # Postmortem: #{t.thing} outage

      ## Summary
      The #{t.thing} stopped processing for two hours, which delayed #{t.other}.

      ## Timeline
      - 09:12 alerts fired for the #{t.thing}
      - 09:25 the on-call engineer paused new jobs
      - 11:05 the backlog cleared and normal service resumed

      ## Root Cause
      A configuration change lowered the worker limit, so jobs queued until they timed out.

      ## Action Items
      - Add a check that blocks worker limits below the safe minimum.
      - Page the owner when the #{t.metric} doubles within an hour.
      """

      sample("postmortem", i, text, :linguistic, "postmortem")
    end
  end

  defp runbooks do
    for i <- 0..14 do
      t = topic(i)
      name = slug(t.thing)

      {text, mode} =
        if rem(i, 3) == 2 do
          {"""
           # Runbook: restart the #{t.thing}

           ## Purpose
           Use this when the #{t.thing} stops reporting for more than fifteen minutes.

           ## Steps
           1. Announce the restart in the operations channel.
           2. Scale the worker down and wait for the rollout to finish:

           ```sh
           kubectl scale deployment/#{String.replace(name, "_", "-")} --replicas=0
           kubectl rollout status deployment/#{String.replace(name, "_", "-")}
           kubectl scale deployment/#{String.replace(name, "_", "-")} --replicas=2
           ```

           3. Confirm the #{t.metric} is back to normal on the dashboard.

           ## Rollback
           If errors continue, restore the previous release and page the owner.
           """, :mixed}
        else
          {"""
           # Runbook: restart the #{t.thing}

           ## Purpose
           Use this when the #{t.thing} stops reporting for more than fifteen minutes.

           ## Steps
           1. Announce the restart in the operations channel.
           2. Open the admin console and pause the #{t.thing}.
           3. Wait until the queue is empty, then resume it.
           4. Confirm the #{t.metric} is back to normal on the dashboard.

           ## Rollback
           If errors continue, restore the previous release and page the owner.
           """, :linguistic}
        end

      sample("runbook", i, text, mode, "runbook")
    end
  end

  defp plans do
    titles = ["# {Topic} plan", "# Execution plan: {topic}", "# Q3 plan for the {topic}"]

    for i <- 0..14 do
      t = topic(i)

      text =
        fill(pick(titles, i), t, i) <>
          """


          ## Objectives
          - Finish the #{t.thing} before the end of the quarter.
          - Bring the #{t.metric} back under the agreed target.

          ## Timeline
          - Week 1: agree on scope with #{person(i)}
          - Week 2: build and test the #{t.thing}
          - Week 3: roll out and watch #{t.other}

          ## Risks
          - The vendor may be slow to answer questions.
          """

      sample("plan", i, text, :linguistic, "plan")
    end
  end

  defp briefs do
    for i <- 0..9 do
      t = topic(i)

      text = """
      # #{cap(t.topic)} brief

      ## Objective
      Get every team lead to adopt the new #{t.thing} by next month.

      ## Audience
      Team leads and their deputies.

      ## Key Messages
      - The #{t.thing} saves an hour a week per team.
      - #{cap(t.other)} keeps working exactly as before.

      ## Call to Action
      Book a fifteen minute walkthrough with #{person(i)} before Friday.
      """

      sample("brief", i, text, :linguistic, "brief")
    end
  end

  defp changelogs do
    for i <- 0..9 do
      t = topic(i)

      text = """
      # Changelog

      ## [1.#{i + 1}.0] - 2026-0#{rem(i, 9) + 1}-12
      ### Added
      - Export of the #{t.metric} as a weekly summary.
      - A pause button for the #{t.thing}.

      ### Fixed
      - Crash when #{t.other} returned an empty list.

      ## [1.#{i}.2] - 2026-0#{rem(i, 9) + 1}-02
      ### Changed
      - The #{t.thing} now retries twice before failing.
      """

      sample("changelog", i, text, :linguistic, "changelog")
    end
  end

  defp acknowledgements do
    ["ok", "thanks!", "sounds good", "on it", "+1", "done", "will do", "nice", "noted", "👍"]
    |> Enum.with_index()
    |> Enum.map(fn {text, i} -> sample("ack", i, text, :linguistic, nil) end)
  end

  # ── Code ────────────────────────────────────────────────────────────────

  defp code_samples do
    for i <- 0..79 do
      t = topic(i)
      sample("code", i, code_snippet(rem(i, 16), t), :code, nil)
    end
  end

  defp code_snippet(0, t) do
    """
    defmodule #{camel(t.topic)}.Worker do
      @moduledoc "Runs the #{t.thing} on a schedule."
      use GenServer

      def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

      @impl true
      def init(opts), do: {:ok, Map.new(opts)}

      @impl true
      def handle_info(:tick, state) do
        Logger.info("running the #{t.thing} for every workspace")
        {:noreply, state}
      end
    end
    """
  end

  defp code_snippet(1, t) do
    """
    defmodule #{camel(t.thing)} do
      def summarize(rows) do
        rows
        |> Enum.filter(&(&1.active))
        |> Enum.group_by(& &1.region)
        |> Map.new(fn {region, items} -> {region, length(items)} end)
      end
    end
    """
  end

  defp code_snippet(2, t) do
    """
    import csv
    from pathlib import Path


    def load_#{slug(t.thing)}(path: Path) -> list[dict]:
        with path.open() as handle:
            return list(csv.DictReader(handle))


    def total(rows):
        return sum(float(row["amount"]) for row in rows)
    """
  end

  defp code_snippet(3, t) do
    """
    class #{camel(t.thing)}:
        \"\"\"Tracks the #{t.metric} for the #{t.topic}.\"\"\"

        def __init__(self, limit=100):
            self.limit = limit
            self.values = []

        def add(self, value):
            if len(self.values) >= self.limit:
                self.values.pop(0)
            self.values.append(value)
    """
  end

  defp code_snippet(4, t) do
    """
    export function total#{camel(t.thing)}(items) {
      const active = items.filter((item) => item.active);
      return active.reduce((sum, item) => sum + item.amount, 0);
    }

    export const LIMIT = 50;
    """
  end

  defp code_snippet(5, t) do
    """
    const express = require("express");
    const app = express();

    app.get("/#{String.replace(slug(t.thing), "_", "-")}", async (req, res) => {
      const rows = await db.query("select * from items limit 20");
      res.json({ count: rows.length, rows });
    });

    app.listen(3000);
    """
  end

  defp code_snippet(6, t) do
    """
    interface #{camel(t.thing)}Row {
      id: string;
      region: string;
      amount: number;
    }

    function totalByRegion(rows: #{camel(t.thing)}Row[]): Map<string, number> {
      const totals = new Map<string, number>();
      for (const row of rows) {
        totals.set(row.region, (totals.get(row.region) ?? 0) + row.amount);
      }
      return totals;
    }
    """
  end

  defp code_snippet(7, t) do
    """
    package main

    import (
    \t"fmt"
    \t"net/http"
    )

    func handler(w http.ResponseWriter, r *http.Request) {
    \tfmt.Fprintf(w, "#{t.thing} ok")
    }

    func main() {
    \thttp.HandleFunc("/health", handler)
    \thttp.ListenAndServe(":8080", nil)
    }
    """
  end

  defp code_snippet(8, t) do
    """
    use std::collections::HashMap;

    pub struct #{camel(t.thing)} {
        totals: HashMap<String, u64>,
    }

    impl #{camel(t.thing)} {
        pub fn add(&mut self, region: &str, amount: u64) {
            *self.totals.entry(region.to_string()).or_insert(0) += amount;
        }
    }
    """
  end

  defp code_snippet(9, t) do
    """
    require "json"

    class #{camel(t.thing)}
      def initialize(path)
        @path = path
      end

      def rows
        JSON.parse(File.read(@path)).select { |row| row["active"] }
      end
    end
    """
  end

  defp code_snippet(10, t) do
    """
    SELECT region,
           COUNT(*) AS orders,
           SUM(amount) AS revenue
    FROM #{slug(t.thing)}
    WHERE created_at >= DATE '2026-01-01'
    GROUP BY region
    ORDER BY revenue DESC
    LIMIT 10;
    """
  end

  defp code_snippet(11, t) do
    """
    CREATE TABLE #{slug(t.thing)} (
      id BIGSERIAL PRIMARY KEY,
      workspace_id TEXT NOT NULL,
      amount NUMERIC(12, 2) NOT NULL,
      created_at TIMESTAMPTZ NOT NULL DEFAULT now()
    );

    CREATE INDEX #{slug(t.thing)}_workspace_idx ON #{slug(t.thing)} (workspace_id);
    """
  end

  defp code_snippet(12, t) do
    """
    #!/usr/bin/env bash
    set -euo pipefail

    OUT_DIR="${OUT_DIR:-/tmp/#{slug(t.thing)}}"
    mkdir -p "$OUT_DIR"

    for file in data/*.csv; do
      echo "processing $file"
      gzip -c "$file" > "$OUT_DIR/$(basename "$file").gz"
    done
    """
  end

  defp code_snippet(13, t) do
    """
    public class #{camel(t.thing)} {
        private final int limit;

        public #{camel(t.thing)}(int limit) {
            this.limit = limit;
        }

        public boolean allow(int current) {
            return current < limit;
        }
    }
    """
  end

  defp code_snippet(14, t) do
    """
    .#{String.replace(slug(t.thing), "_", "-")} {
      display: flex;
      gap: 12px;
      padding: 16px;
    }

    .#{String.replace(slug(t.thing), "_", "-")} button {
      border-radius: 6px;
      background: #2d6cdf;
    }
    """
  end

  defp code_snippet(15, t) do
    """
    FROM elixir:1.17-alpine AS build
    WORKDIR /app
    COPY mix.exs mix.lock ./
    RUN mix deps.get --only prod
    COPY . .
    RUN MIX_ENV=prod mix release #{slug(t.thing)}
    CMD ["/app/_build/prod/rel/#{slug(t.thing)}/bin/#{slug(t.thing)}", "start"]
    """
  end

  # ── Data ────────────────────────────────────────────────────────────────

  @regions ~w(north south east west central)

  defp data_samples do
    for i <- 0..79 do
      t = topic(i)
      sample("data", i, data_snippet(rem(i, 10), t, i), :data, nil)
    end
  end

  defp data_snippet(0, _t, i) do
    rows =
      for k <- 0..(3 + rem(i, 4)) do
        "2026-01-0#{rem(k, 9) + 1},#{pick(@regions, k + i)},#{100 + k * 7},#{4000 + k * 113}.50"
      end

    Enum.join(["date,region,orders,revenue" | rows], "\n")
  end

  defp data_snippet(1, t, i) do
    rows =
      for k <- 0..(2 + rem(i, 3)) do
        "#{1000 + k},\"#{person(i + k)}, #{cap(t.topic)}\",#{pick(@regions, k)},#{rem(k * 37, 100)}"
      end

    Enum.join(["id,owner,region,score" | rows], "\n")
  end

  defp data_snippet(2, t, i) do
    rows =
      for k <- 0..(3 + rem(i, 3)),
          do: "#{person(i + k)}\t#{t.metric}\t#{10 + k}\t#{pick(@regions, k)}"

    Enum.join(["name\tmetric\tvalue\tregion" | rows], "\n")
  end

  defp data_snippet(3, t, i) do
    Jason.encode!(%{
      "event" => "#{slug(t.thing)}.completed",
      "id" => "evt_#{1000 + i}",
      "workspace" => "ws_#{rem(i, 9)}",
      "duration_ms" => 1200 + i,
      "items" => [%{"sku" => "A-#{i}", "qty" => 2}]
    })
  end

  defp data_snippet(4, t, i) do
    Jason.encode!(
      %{
        "name" => slug(t.thing),
        "enabled" => rem(i, 2) == 0,
        "limits" => %{"per_minute" => 60 + i, "burst" => 10},
        "regions" => Enum.take(@regions, 2 + rem(i, 3))
      },
      pretty: true
    )
  end

  defp data_snippet(5, _t, i) do
    Jason.encode!(
      for k <- 0..(2 + rem(i, 3)), do: %{"region" => pick(@regions, k), "value" => k * 11 + i}
    )
  end

  defp data_snippet(6, t, i) do
    for k <- 0..(2 + rem(i, 3)) do
      Jason.encode!(%{
        "ts" => "2026-02-0#{k + 1}T10:00:00Z",
        "metric" => t.metric,
        "value" => k + i
      })
    end
    |> Enum.join("\n")
  end

  defp data_snippet(7, t, i) do
    """
    service: #{String.replace(slug(t.thing), "_", "-")}
    replicas: #{1 + rem(i, 4)}
    resources:
      cpu: 500m
      memory: 512Mi
    env:
      - name: LOG_LEVEL
        value: info
      - name: REGION
        value: #{pick(@regions, i)}
    """
  end

  defp data_snippet(8, t, _i) do
    """
    name: #{t.topic} checks
    on:
      push:
        branches: [main]
    jobs:
      test:
        runs-on: linux-small
        steps:
          - uses: actions/checkout@v4
          - run: make test
    """
  end

  defp data_snippet(9, t, i) do
    rows =
      for k <- 0..(2 + rem(i, 3)) do
        "| #{cap(pick(@regions, k))} | #{100 + k * 9} | #{rem(k * 13 + i, 40)}% |"
      end

    Enum.join(["| Region | #{cap(t.metric)} | Change |", "|---|---|---|" | rows], "\n")
  end

  # ── Mixed ───────────────────────────────────────────────────────────────

  defp mixed_samples do
    for i <- 0..24 do
      t = topic(i)
      sample("mixed", i, mixed_snippet(rem(i, 4), t, i), :mixed, nil)
    end
  end

  defp mixed_snippet(0, t, _i) do
    """
    # #{cap(t.thing)} client

    Install the package and set the API key before the first call.

    ```bash
    npm install #{String.replace(slug(t.thing), "_", "-")}-client
    export CLIENT_API_KEY=changeme
    ```

    Then create a client and fetch the latest records:

    ```js
    const client = new Client(process.env.CLIENT_API_KEY);
    const records = await client.records.list({ limit: 20 });
    console.log(records.length);
    ```

    The client retries failed requests twice before raising an error.
    """
  end

  defp mixed_snippet(1, t, i) do
    """
    ## #{cap(t.metric)} by region

    The #{t.metric} improved in every region except the west, where the #{t.thing} was offline for two days.

    | Region | Value |
    |---|---|
    | North | #{12 + i} |
    | South | #{9 + i} |
    | West | #{4 + i} |

    We expect the west to recover once #{t.other} is back.
    """
  end

  defp mixed_snippet(2, t, _i) do
    """
    The new #{t.thing} layout groups related settings together, so people find them faster.

    ![Settings layout](images/#{slug(t.thing)}-layout.png)

    Feedback from the pilot was positive; the main request is a search box at the top.
    """
  end

  defp mixed_snippet(3, t, i) do
    """
    The #{t.thing} sends one event per completed run. Consumers should treat unknown fields as optional, because we add fields without a version bump.

    ```json
    {
      "event": "#{slug(t.thing)}.completed",
      "workspace": "ws_#{i}",
      "duration_ms": 1200,
      "status": "ok"
    }
    ```

    Events arrive at least once, so consumers must deduplicate on the event id.
    """
  end

  # ── Visual ──────────────────────────────────────────────────────────────

  defp visual_samples do
    for i <- 0..11 do
      t = topic(i)

      text =
        case rem(i, 3) do
          0 ->
            "# Site photos\n\n![Front entrance](photos/entrance-#{i}.jpg)\n![Lobby](photos/lobby-#{i}.jpg)\n![Meeting room](photos/room-#{i}.jpg)"

          1 ->
            """
            <svg xmlns="http://www.w3.org/2000/svg" width="160" height="40">
              <rect width="160" height="40" rx="6" fill="#2d6cdf"/>
              <text x="12" y="25" fill="#ffffff">#{cap(t.thing)}</text>
            </svg>
            """

          2 ->
            """
            ```mermaid
            flowchart LR
              A[Request] --> B{Valid?}
              B -->|yes| C[#{cap(t.thing)}]
              B -->|no| D[Reject]
            ```
            """
        end

      sample("visual", i, text, :visual, nil)
    end
  end
end
