defmodule OptimalEngine.Signal.GenreDetector do
  @moduledoc """
  Detects a signal's genre from its text, returning a name from
  `OptimalEngine.Signal.GenreRegistry` (default `"note"`).

  A genre is a conventionalized form, so form outranks topic. Detection runs
  in order of precision and stops at the first hit:

    1. Conversational form: standup labels, speaker turns or subtitles
       (transcript), mail headers, quoted replies or a greeting with a
       sign-off (email).
    2. The title line: "Search - Requirements", "Postmortem: ...",
       "Q4 Hiring Plan", "ADR-012: ...".
    3. Section headings, with or without `#`: a line reading exactly
       "Requirements", "Root Cause" or "## Steps". Anchored to whole lines,
       so prose that mentions "steps" or "timeline" does not match.
    4. Short text addressed to someone (message): an @mention, "you",
       "thanks", "pls", a greeting, an emoji.
    5. Topic keywords with word boundaries: "we decided", "invoice #",
       "amount due".
    6. Registry keyword scoring, accepted only with corroborating evidence
       (a single common word such as "review" or "plan" is not enough).
  """

  alias OptimalEngine.Signal.{GenreRegistry, TimeLimit}

  @default_genre "note"

  # Registry keyword scoring must reach this to count. A genre-name hit is
  # worth 3 and a section-word hit 1, so it takes both name words ("privacy
  # policy") or a name word plus three section words; one common word such
  # as "review" or "plan" never decides.
  @registry_min_score 6

  # ── Conversational form ─────────────────────────────────────────────────

  @speaker_turn ~r/^(?:>>\s*)?(?:[\[(]?\d{1,2}:\d{2}(?::\d{2})?[\])]?\s*[-–]?\s*)?(?<speaker>[A-Z][\w.'’-]*(?:\s[A-Z0-9][\w.'’-]*){0,2})(?:\s*\(\d{1,2}:\d{2}(?::\d{2})?\))?:\s+\S/u
  @speaker_header ~r/^(?<speaker>[A-Z][\w.'’-]*(?:\s[A-Z][\w.'’-]*)?)\s+(?:\d{1,2}:)?\d{1,2}:\d{2}\s*$/u
  @subtitle_timing ~r/^\d{1,2}:\d{2}:\d{2}[,.]\d{3}\s*-->\s*\d{1,2}:\d{2}:\d{2}[,.]\d{3}/
  @caption_turn ~r/^>>\s*\S/
  @disfluency ~r/\b(um+|uh+|erm|uh-huh|mm-hmm)\b/i

  # "Label:" lines that name a field, not a person. Field labels are used
  # once each; speakers recur, which `transcript?/1` also requires.
  @field_labels ~w(
    acceptance action actions agenda amount answer approach ask attendees background blocked blocker blockers
    category cause cc bcc chosen contact context consequences cost date day deadline decision decisions
    dependencies description details detection did doing done due edge error example fix format from fw fwd
    fyi goal goals idea important info input link links location month name next note notes objective
    objectives options outcome output overview owner owners participants phase price priorities priority
    problem ps purpose quarter rationale re reason reminder requirements resolution responsibilities result
    results revisit risk risks rules scope sent sequence severity solution source status step steps style
    subject success summary tag tags thought timeline tip title tldr to today todo tomorrow topic topics
    total type update updates url verification version warning week why yesterday
    monday tuesday wednesday thursday friday saturday sunday
    january february march april may june july august september october november december
  )

  @mail_header ~r/^(From|To|Cc|Bcc|Subject|Date|Sent):\s+\S/
  @quoted_reply ~r/^>\s?\S/
  @greeting ~r/^(hi|hello|hey|dear|greetings|good (morning|afternoon|evening))\b[^,\n]{0,40},\s*$/i
  @signoff ~r/^(best|best regards|kind regards|warm regards|regards|thanks|thank you|many thanks|cheers|sincerely|all the best|talk soon)\b[^\n]{0,20}[,.!]?\s*$/i

  # Standup labels fold into three slots: done, doing, blocked. They open a
  # line or follow a sentence break ("y: on-call. t: write up. b: none").
  @standup_label ~r/(?:^|[.;]\s+)\s*(?:[-*]\s+)?(?:#+\s*)?(?:\*\*)?(yesterday|today|tomorrow|blockers?|blocked|did|done yesterday|done|doing|next|issues?|Y|T|B)(?:\*\*)?\s*(?::|$)/im
  @standup_slots %{
    "yesterday" => :done,
    "did" => :done,
    "done" => :done,
    "done yesterday" => :done,
    "y" => :done,
    "today" => :doing,
    "tomorrow" => :doing,
    "doing" => :doing,
    "next" => :doing,
    "t" => :doing,
    "blocker" => :blocked,
    "blockers" => :blocked,
    "blocked" => :blocked,
    "issue" => :blocked,
    "issues" => :blocked,
    "b" => :blocked
  }

  # A letter closes with a short comma-terminated line ("Warmly,").
  @letter_close ~r/^[A-Z][^.!?\n]{0,40},$/

  # RFC 2119 requirement keywords: a spec convention.
  @rfc2119 ~r/\b(MUST NOT|MUST|SHALL NOT|SHALL|SHOULD NOT|SHOULD|REQUIRED|MAY)\b/
  @rfc2119_min 3

  # Postmortem sections, as headings or labels.
  @postmortem_section ~r/^(?:#+\s*)?(What happened|Why it happened|Why|Root cause|Impact|Detection|How we noticed|Resolution|What we changed|What we are changing|Follow-ups?|Lessons learned)\s*(?::|$)/im

  # ── Title line (first match wins) ───────────────────────────────────────

  @title_patterns [
    {"transcript", ~r/\btranscript\b/i},
    {"postmortem", ~r/\bpost-?mortem\b|\bincident (review|report)\b/i},
    {"adr", ~r/^(#+\s*)?ADR[- ]?\d+\b/},
    {"decision-log", ~r/\bdecision(s| log| record)?\b/i},
    {"runbook", ~r/\brunbook\b/i},
    {"spec", ~r/\b(spec|specification|requirements)\b/i},
    {"standup", ~r/\bstand-?up\b/i},
    {"changelog", ~r/\bchangelog\b|^v?\d+\.\d+\.\d+\b/i},
    {"release-notes", ~r/\brelease notes\b/i},
    {"brief", ~r/\bbrief\b/i},
    {"plan", ~r/\bplan\b/i},
    {"note", ~r/\bnotes\b/i}
  ]

  @title_max_words 12

  # ── Section headings (ordered by specificity) ───────────────────────────
  #
  # `(#+\s*)?` lets plain-text documents use the same headings as markdown;
  # every pattern matches a whole line, so a sentence never qualifies.

  @heading_patterns [
    {"adr",
     ~r/Architecture Decision Record|\bADR[- ]\d+|^(#+\s*)?Status\s*$.*^(#+\s*)?Context\s*$/ims},
    {"changelog", ~r/^#+\s*CHANGELOG\b|^[#]{2,4}\s*(Added|Changed|Fixed|Removed|Deprecated)\s*$/im},
    {"postmortem", ~r/^(#+\s*)?Root Cause( Analysis)?\s*$/im},
    {"runbook", ~r/^(#+\s*)?(Steps|Procedure|Rollback)\s*$/im},
    {"spec",
     ~r/^(#+\s*)?(Requirements|Acceptance Criteria|Constraints)\s*$|^(Acceptance( Criteria)?|Out of scope)\s*:/im},
    {"transcript", ~r/^(#+\s*)?(Participants|Key Points|Transcript)\s*$/im},
    {"decision-log", ~r/^#+\s*(Key\s+)?Decisions?\b|^\s*(\*\*)?Decision(\*\*)?:\s/im},
    {"plan", ~r/^#+\s*(Non-Negotiables|Time Blocks|Objectives|Milestones)\s*$/im},
    {"brief", ~r/^(#+\s*)?(Objective|Key Messages|Call to Action)\s*$/im},
    {"proposal",
     ~r/^#+\s*(Proposed\b[^\n]*|Proposal|Investment|Deliverables|Executive Summary)\s*$/im},
    {"readme", ~r/^#+\s*(Installation|Usage|Getting Started|Contributing)\s*$/im}
  ]

  # ── Message form ────────────────────────────────────────────────────────

  @message_max_lines 4
  @message_max_chars 600
  @fenced_block ~r/^\s*(```|~~~).*?^\s*(```|~~~)\s*$/ms
  @addressed ~r/(^|\s)@\w|\b(you|your|you're|youre|y'all|thanks|thank you|thx|ty|lgtm|sgtm|lol|pls|plz|please|btw|fyi|np|imo|anyone|someone|anybody|somebody|im|gonna|omw|brb)\b|^(hey|hi|hello|yo)\b|^\+1\b|:[a-z0-9_+-]+:|[\x{1F300}-\x{1FAFF}\x{2600}-\x{27BF}]/iu

  # ── Topic keywords ──────────────────────────────────────────────────────

  @keyword_patterns [
    {"invoice", ~r/\binvoice\s*(#|no\.?\s|number\b)|\bamount due\b|\bpayment due\b|\bbill to\b/i},
    {"profit-loss", ~r/\bP&L\b|\bprofit (and|&) loss\b|\bnet income\b/i},
    {"budget",
     ~r/^#+\s[^\n]*\bbudget\b|^\s*(total\s+)?budget\s*:|\bquarterly spend\b|\bannual spend\b/im},
    {"decision-log", ~r/\bdecided:|\bwe decided\b|\bkey decisions\b/i},
    {"postmortem", ~r/\bpost-?mortem\b|\bincident report\b|\broot cause analysis\b/i},
    {"runbook", ~r/\brunbook\b|\bstep-by-step\b/i},
    {"standup", ~r/\bstandup\b|\bweekly signal\b/i},
    {"pitch", ~r/\bvalue proposition\b|\bproblem.solution\b/i}
  ]

  @doc "Detects the genre of `text`. Returns a registry genre name."
  @spec detect(String.t() | nil) :: String.t()
  def detect(text) when is_binary(text) do
    # Bounded like mode detection: past the classification limit the text
    # gets the default genre.
    TimeLimit.run(fn -> detect_text(text) end, @default_genre, label: "genre detection")
  end

  def detect(_), do: @default_genre

  defp detect_text(text) do
    lines = non_blank_lines(text)

    form_genre(text, lines) ||
      title_genre(lines) ||
      first_match(@heading_patterns, text) ||
      section_genre(text) ||
      message_genre(text) ||
      first_match(@keyword_patterns, text) ||
      registry_genre(text) ||
      @default_genre
  end

  # ── Form ────────────────────────────────────────────────────────────────

  defp form_genre(text, lines) do
    cond do
      standup?(lines) -> "standup"
      transcript?(text, lines) -> "transcript"
      email?(lines) -> "email"
      true -> nil
    end
  end

  defp standup?(lines) do
    slots =
      lines
      |> Enum.flat_map(&Regex.scan(@standup_label, &1, capture: :all_but_first))
      |> Enum.map(fn [label] -> Map.fetch!(@standup_slots, String.downcase(label)) end)
      |> Enum.uniq()

    length(slots) >= 2
  end

  defp transcript?(text, lines) do
    speakers = lines |> Enum.map(&speaker/1) |> Enum.reject(&is_nil/1)
    turns = length(speakers)
    distinct = length(Enum.uniq(speakers))
    recurring? = speakers |> Enum.frequencies() |> Map.values() |> Enum.any?(&(&1 >= 2))
    n = max(length(lines), 1)

    (turns >= 3 and distinct >= 2 and recurring? and turns / n >= 0.3) or
      (turns >= 2 and turns == n and distinct >= 2) or
      Enum.count(lines, &Regex.match?(@subtitle_timing, &1)) >= 2 or
      Enum.count(lines, &Regex.match?(@caption_turn, &1)) / n >= 0.5 or
      length(Regex.scan(@disfluency, text)) >= 2
  end

  defp speaker(line) do
    with nil <- named_capture(@speaker_turn, line),
         nil <- named_capture(@speaker_header, line) do
      nil
    else
      name -> if String.downcase(name) in @field_labels, do: nil, else: name
    end
  end

  defp named_capture(regex, line) do
    case Regex.named_captures(regex, line) do
      %{"speaker" => name} -> name
      _ -> nil
    end
  end

  defp email?(lines) do
    headers = lines |> Enum.take(8) |> Enum.count(&Regex.match?(@mail_header, &1))
    quoted = Enum.count(lines, &Regex.match?(@quoted_reply, &1))
    greeting? = lines |> Enum.take(2) |> Enum.any?(&Regex.match?(@greeting, &1))

    signoff? =
      lines
      |> Enum.take(-4)
      |> Enum.any?(&(Regex.match?(@signoff, &1) or letter_close?(&1)))

    headers >= 2 or String.starts_with?(List.first(lines, ""), "Subject: ") or
      (quoted >= 2 and length(lines) - quoted >= 2) or
      (greeting? and signoff? and length(lines) >= 4)
  end

  defp letter_close?(line),
    do: Regex.match?(@letter_close, line) and length(String.split(line)) <= 7

  # ── Title ───────────────────────────────────────────────────────────────

  # The first line names the document when it is a heading, or a short line
  # without closing punctuation that is followed by more text.
  defp title_genre([first, _ | _]) do
    title = String.trim_leading(first, "#") |> String.trim()

    if String.starts_with?(first, "#") or
         (length(String.split(title)) <= @title_max_words and not Regex.match?(~r/[.?!,;]$/, title)),
       do: first_match(@title_patterns, title)
  end

  defp title_genre(_lines), do: nil

  # ── Section conventions ─────────────────────────────────────────────────

  defp section_genre(text) do
    cond do
      length(Regex.scan(@rfc2119, text)) >= @rfc2119_min -> "spec"
      distinct_matches(@postmortem_section, text) >= 2 -> "postmortem"
      true -> nil
    end
  end

  defp distinct_matches(regex, text) do
    regex
    |> Regex.scan(text, capture: :all_but_first)
    |> Enum.map(fn [label] -> String.downcase(label) end)
    |> Enum.uniq()
    |> length()
  end

  # ── Message ─────────────────────────────────────────────────────────────

  # Short text addressed to someone; a pasted code block does not count
  # toward its length.
  defp message_genre(text) do
    prose = Regex.replace(@fenced_block, text, "")
    lines = non_blank_lines(prose)

    if length(lines) <= @message_max_lines and String.length(prose) <= @message_max_chars and
         not Enum.any?(lines, &String.starts_with?(&1, "#")) and Regex.match?(@addressed, prose),
       do: "message"
  end

  # ── Fallbacks ───────────────────────────────────────────────────────────

  defp registry_genre(text) do
    case GenreRegistry.detect(text, min_score: @registry_min_score) do
      @default_genre -> nil
      genre -> genre
    end
  end

  defp first_match(patterns, text) do
    Enum.find_value(patterns, fn {genre, pattern} -> if Regex.match?(pattern, text), do: genre end)
  end

  defp non_blank_lines(text) do
    text
    |> String.split(~r/\r?\n/)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end
end
