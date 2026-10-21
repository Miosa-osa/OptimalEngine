defmodule OptimalEngine.Signal.ModeDetector do
  @moduledoc """
  Content-based Signal Theory Mode detection: `:linguistic`, `:code`, `:data`,
  `:visual` or `:mixed`.

  Every classifier in the engine resolves Mode here (the intake pipeline, the
  per-chunk classifier and the CloudEvents analyzer), so they agree on the same
  text. Detection reads the text itself, never the container it arrived in:

    1. Whole-text data shapes: JSON, JSON Lines, delimited tables (CSV/TSV)
       and key-value config documents.
    2. Line-by-line evidence: each line is prose, code, data (a markdown table
       row or a fenced data block), visual (an embedded image), structure (a
       lone `end` or `}`) or neutral (headings, comments, blank lines).
       Code lines need real syntax (anchored, case-sensitive keywords or at
       least two operator cues), so prose such as "we require a first class
       fix" stays prose.
    3. The dominant line kind decides; prose mixed with significant code,
       data or images is `:mixed`.

  `detect/1` returns `{mode, confidence}`. Confidence is `:weak` when the text
  is too short or too structureless to decide on its own (a heading, a
  two-word reply). `resolve/2` lets a declared mode win, keeps strong content
  evidence, and falls back to the genre registry's mode for weak evidence.
  """

  alias OptimalEngine.Signal.{GenreRegistry, TimeLimit}

  @type mode :: :linguistic | :visual | :code | :data | :mixed
  @type confidence :: :strong | :weak

  @modes [:linguistic, :visual, :code, :data, :mixed]
  @mode_strings Map.new(@modes, &{Atom.to_string(&1), &1})

  # Registry modes that name a single mode; "mixed" says the genre combines
  # modes, which cannot be inferred from a text too weak to show them.
  @registry_fallback_modes ~w[linguistic code data visual]

  # Long documents are sampled from the top; the mode is settled long before.
  @max_lines 2_000

  @data_fence_langs ~w[json jsonl ndjson csv tsv yaml yml toml xml]
  @visual_fence_langs ~w[mermaid plantuml dot graphviz svg]

  # ── Line-level code evidence ────────────────────────────────────────────
  #
  # Strong patterns are anchored at the start of the (left-trimmed) line and
  # case-sensitive: one hit marks the line as code. Each pattern encodes the
  # syntax that follows the keyword, so the bare English word does not match.
  #
  # Every pattern here and below is linear in the length of the line: a
  # pattern that needs the line to end a certain way checks that first (a
  # lookahead), so a long line that does not end that way fails in one pass
  # instead of retrying each split of its middle. Caller text reaches these
  # patterns through POST /api/ingest.
  @strong_patterns [
    ~r/^(def|defp|defmodule|defmacro|defmacrop|defstruct|defimpl|defprotocol|defdelegate|defguard)\b/,
    ~r/^(fn|func)(\s+[\w(]|\()/,
    ~r/^(async\s+)?function\b\*?\s*[\w$]*\s*\(/,
    ~r/^(pub(\([\w ]+\))?\s+)?fn\s+[A-Za-z_]\w*\s*[<(]/,
    ~r/^(pub(\([\w ]+\))?\s+)?(struct|enum|trait|union)\s+[A-Z]\w*/,
    ~r/^impl(<[^>]*>)?\s+[A-Z]\w*/,
    ~r/^(pub\s+)?mod\s+[a-z_]\w*\s*[;{]/,
    ~r/^(class|interface|module|namespace|record|object)\s+[A-Z][\w.:<>]*/,
    ~r/^package\s+[a-z][\w.]*\s*;?\s*$/,
    ~r/^(public|private|protected|internal|static|final|abstract|export|override)\s+(static\s+|final\s+|async\s+|default\s+|abstract\s+)*(class|interface|enum|void|int|long|double|float|boolean|bool|char|byte|fn|function|def|const|let|var|struct|record|[A-Z]\w*(<[^>]*>)?(\[\])?\s+\w+\s*[(=;])/,
    ~r/^import\s+(\{|\*|['"]|[A-Z][\w.]*\s*(,.*)?$|[\w.{}, ]+\s+from\s+['"]|[\w.]+\s*;?\s*$|[\w.]+\s+as\s+\w+\s*$|static\s)/,
    ~r/^from\s+[\w.]+\s+import\s+[\w*(]/,
    ~r/^(require|require_relative)\s*(\(|['"]|[A-Z][\w.]*\s*$)/,
    ~r/^(use|alias)\s+[A-Z]\w*(\.[A-Z]\w*)*\s*(,.*)?$/,
    ~r/^use\s+[a-z_]\w*(::[\w{}*, ]+)+\s*;$/,
    ~r/^#include\s*[<"]/,
    ~r/^#!\//,
    ~r/^using\s+[A-Z][\w.]*\s*;$/,
    ~r/^(const|let|var|val|auto)\s+(mut\s+)?[A-Za-z_$][\w$]*\s*(=|;|:\s*[\w<>\[\]|, ]+\s*(=|;|$))/,
    ~r/^(int|long|float|double|char|bool|boolean|void|size_t|u?int\d+_t)\s+\**[A-Za-z_]\w*\s*(=|;|\[|\([^)]*\)\s*[{;]?\s*$)/,
    ~r/^(if|for|while|switch|foreach)\s*\(.*\)\s*(\{|:)?\s*$/,
    ~r/^(?=.*:\s*$)for\s+[\w, ()]+\s+in\s+.+:\s*$/,
    ~r/^(?=.*:\s*$)(if|elif|while)\s+.*(==|!=|<=|>=|<|>|\bis\b|\bnot\b|\bin\b|[().\[\]]).*:\s*$/,
    ~r/^with\s+.+\bas\s+\w+\s*:\s*$/,
    ~r/^except(\s+[A-Z][\w.]*(\s+as\s+\w+)?)?\s*:\s*$/,
    ~r/^\}?\s*catch\s*\(.*\)\s*\{?\s*$/,
    ~r/^return\b(\s*;?\s*$|\s+\S+\s*;?\s*$|.*[(){}\[\];=+*\/<>])/,
    ~r/^(raise|throw)\s+(new\s+)?[A-Z][\w.]*(Error|Exception)\b|^(raise|throw)\s+(new\s+)?[A-Z][\w.]*\s*[(,]/,
    ~r/^[A-Za-z_]\w*(\.[A-Za-z_]\w*)*!?\((?!s\)|es\))/,
    ~r/^(print|puts|println|printf|console\.\w+|IO\.(puts|inspect)|fmt\.\w+|System\.out\.\w+)\s*[("']/,
    ~r/^\|>\s*\S/,
    ~r/^\.[A-Za-z_]\w*\(/,
    # The first `,`, `:` or `=` after the brace, then the last `}`: one pass.
    ~r/^%?\{[^,:=]*+[,:=].*\}[,;)]*$/,
    ~r/^\$\s+[a-z]/,
    ~r/^(SELECT|INSERT\s+INTO|UPDATE|DELETE\s+FROM|CREATE\s+(TABLE|INDEX|UNIQUE|VIEW|SCHEMA|EXTENSION)|ALTER\s+TABLE|DROP\s+(TABLE|INDEX|VIEW)|WITH\s+\w+\s+AS|FROM|WHERE|INNER\s+JOIN|LEFT\s+JOIN|JOIN|GROUP\s+BY|ORDER\s+BY|VALUES|LIMIT|RETURNING|ON\s+CONFLICT)\b/,
    ~r/^\w+\s+(INTEGER|TEXT|VARCHAR(\(\d+\))?|BIGINT|BOOLEAN|SERIAL|BIGSERIAL|UUID|TIMESTAMP(TZ)?|INT|REAL|NUMERIC(\([\d, ]+\))?|DATE|JSONB?)\b/,
    ~r/^(FROM|RUN|COPY|ADD|WORKDIR|ENV|EXPOSE|CMD|ENTRYPOINT|ARG|USER|VOLUME|LABEL|HEALTHCHECK)\s+\S/,
    ~r/^<\/?[a-zA-Z][\w-]*(\s+[\w:@-]+(=("[^"]*"|'[^']*'|[^\s>]+))?)*\s*\/?>/,
    ~r/^[a-z-]+\s*:\s*[^;]+;\s*$/,
    ~r/^[.#]?[a-zA-Z][\w\-.#:>, \[\]="]*\s*\{\s*$/
  ]

  # One alternation, so a line costs a single regex pass.
  @strong_code @strong_patterns |> Enum.map_join("|", &"(?:#{&1.source})") |> Regex.compile!()

  # Weak cues count once each per line; a line needs two of them (or one
  # with almost no words around it) to read as code.
  @weak_patterns [
    ~r/\|>/,
    ~r/->|=>|<-/,
    ~r/::/,
    ~r/:=/,
    ~r/===|!==|==|!=/,
    ~r/&&|\|\|/,
    ~r/[+\-*\/]=/,
    ~r/#\{|%\{|\$\{|&\(|&\d/,
    # A call: a word with a letter or `_` in it, right before `(`. Read from the
    # start of the word only, so a long word is scanned once rather than once
    # per letter. (A dotted name such as `foo.bar(` matches at its last word.)
    ~r/(?<!\w)[0-9]*+[A-Za-z_]\w*+\((?!s\)|es\))/,
    ~r/;\s*$/,
    ~r/[{(\[]\s*$/,
    ~r/^[A-Za-z_][\w.\[\]'"]*\s*(=|\+=|-=)\s*[^=\s>]/,
    ~r/(^|[\s(\[{,]):[a-z_]\w*\b/,
    ~r/\w\[["'\w]/,
    ~r/\s--?[a-zA-Z][\w-]*/,
    ~r/^(sudo|npm|npx|yarn|pnpm|mix|git|cd|ls|echo|export|curl|wget|docker|kubectl|pip3?|python3?|node|make|cargo|go|chmod|chown|mkdir|rm|cp|mv|cat|grep|sed|awk|find|xargs|tail|head|sort|uniq|wc|kill|ps|source|brew|apt-get|apt|systemctl|journalctl|ssh|scp|rsync|tar)\s/,
    ~r/\s\|\s+[a-z][\w-]*(\s|$)/,
    ~r/^@[a-z_]\w*(\(|\s|$)/,
    ~r/^(case|cond|with|if|unless|receive|for|quote)\b.*\bdo\s*$/
  ]

  # Most prose lines carry no cue at all; one pass rules them out.
  @any_weak_cue @weak_patterns |> Enum.map_join("|", &"(?:#{&1.source})") |> Regex.compile!()

  # Lines that carry block structure only. They count toward code when the
  # text already has code, otherwise they are neutral ("done" as a chat reply).
  @structure_line ~r/^(end|else|elif|fi|done|esac|then|do|begin|pass|break|continue|try|finally|ensure|rescue)\s*[:;{]?\s*$|^[{}\[\]()<>;,.:\s]+$/

  @heading ~r/^[#]{1,6}\s/
  @subtitle_timing ~r/^\d{1,2}:\d{2}:\d{2}[,.]\d{3}\s*-->\s*\d{1,2}:\d{2}:\d{2}[,.]\d{3}/
  @rule ~r/^(-{3,}|\*{3,}|_{3,}|={3,})$/
  @comment ~r/^(\/\/|\/\*|\*\/|--\s|;;|<!--|#(?!!|include))/
  @fence ~r/^(```|~~~)\s*([\w+#.-]*)/
  @list_marker ~r/^([-*+]|\d+[.)])\s+(\[[ xX]\]\s+)?/
  # A markdown image `![alt](target)`. After an alt text, the next try starts
  # at its `]` (*SKIP), since an opener inside it would reach the same `]`;
  # with no `)` left in the line, no later image can close (*COMMIT).
  @markdown_image ~r/!\[[^\]]*+(*SKIP)\]\((?:[^)]*+\)|(*COMMIT)(*FAIL))/
  @image_tag ~r/<img\b|<svg\b|<figure\b/i
  @table_row ~r/^\|.*\|$/
  @table_rule ~r/^\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)*\|?$/
  # A word of letters, optionally wrapped in sentence punctuation: "Alice:",
  # "(target", "done." but not "{draft}", "row[1]" or "@moduledoc".
  @letters_word ~r/(?<!\S)[.,;:!?"'()\[\]*_~`“”‘’]*\p{L}[\p{L}'’-]*[.,;:!?"'()\[\]*_~`“”‘’]*(?!\S)/u
  @symbol_chars ~c"{}[]()<>=;|&$%^\\/~`"

  # ── Public API ──────────────────────────────────────────────────────────

  @doc "Every valid Signal Theory mode."
  @spec modes() :: [mode()]
  def modes, do: @modes

  @doc """
  Detects the mode of `text` from its content alone.

  Returns `{mode, :strong}` when the text carries enough evidence by itself
  and `{mode, :weak}` when it is too short or structureless to decide.
  """
  @spec detect(String.t() | nil) :: {mode(), confidence()}
  def detect(nil), do: {:linguistic, :weak}

  def detect(text) when is_binary(text) do
    # Bounded: a crafted text must not hold the caller (intake, for one) for
    # longer than the classification limit; past it the text counts as weak.
    TimeLimit.run(fn -> detect_text(text) end, {:linguistic, :weak}, label: "mode detection")
  end

  defp detect_text(text) do
    trimmed = String.trim(text)

    cond do
      trimmed == "" -> {:linguistic, :weak}
      json?(trimmed) -> {:data, :strong}
      json?(strip_json_comments(trimmed)) -> {:data, :strong}
      json_lines?(trimmed) -> {:data, :strong}
      log_lines?(trimmed) -> {:data, :strong}
      delimited_table?(trimmed) -> {:data, :strong}
      key_value_document?(trimmed) -> {:data, :strong}
      xml_document?(trimmed) -> {:data, :strong}
      diagram?(trimmed) -> {:visual, :strong}
      true -> trimmed |> tally_lines() |> decide()
    end
  end

  @doc """
  Resolves the final mode for `text`.

  Options:

    * `:declared` - a mode stated by the author (frontmatter); wins when valid
    * `:genre` - the signal's genre; its registry mode is used when the
      content evidence is weak
  """
  @spec resolve(String.t() | nil, keyword()) :: mode()
  def resolve(text, opts \\ []) do
    case parse(Keyword.get(opts, :declared)) do
      nil ->
        case detect(text) do
          {mode, :strong} -> mode
          {mode, :weak} -> genre_mode(Keyword.get(opts, :genre)) || mode
        end

      declared ->
        declared
    end
  end

  @doc "True when `text` is predominantly source code."
  @spec code?(String.t()) :: boolean()
  def code?(text) when is_binary(text), do: match?({:code, _}, detect(text))
  def code?(_), do: false

  @doc "Parses a declared mode (string or atom). Returns nil when invalid."
  @spec parse(term()) :: mode() | nil
  def parse(mode) when mode in @modes, do: mode

  def parse(mode) when is_binary(mode),
    do: Map.get(@mode_strings, mode |> String.trim() |> String.downcase())

  def parse(_), do: nil

  @doc """
  The genre registry's mode for `genre`, when the registry names a single
  mode for it. Returns nil for unknown genres and for "mixed" genres.
  """
  @spec genre_mode(String.t() | atom() | nil) :: mode() | nil
  def genre_mode(nil), do: nil

  def genre_mode(genre) do
    case GenreRegistry.fetch(genre) do
      {:ok, %{mode: mode}} when mode in @registry_fallback_modes -> Map.fetch!(@mode_strings, mode)
      _ -> nil
    end
  end

  # ── Whole-text data shapes ──────────────────────────────────────────────

  defp json?(text) do
    String.starts_with?(text, ["{", "["]) and
      match?({:ok, value} when is_map(value) or is_list(value), Jason.decode(text))
  end

  # JSON with comments (editor and tool settings): drop whole-line `//`
  # comments and `/* */` blocks, never `//` inside a string such as a URL.
  defp strip_json_comments(text) do
    if String.starts_with?(text, ["{", "["]) do
      text
      |> String.replace(~r{/\*.*?\*/}s, "")
      |> String.replace(~r{^\s*//[^\n]*$}m, "")
    else
      text
    end
  end

  # Machine log output: every line is a record from a known log shape. An
  # ISO timestamp needs a level or an HTTP request after it (a chat export
  # also starts with a timestamp); syslog and access-log prefixes and logfmt
  # lines (starting with key=value, three pairs or more) stand on their own.
  @iso_timestamp ~r/^\[?\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}/
  @log_marker ~r/\b(TRACE|DEBUG|INFO|WARN|WARNING|ERROR|FATAL|CRITICAL)\b|"(GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS) \S+/
  @syslog_prefix ~r/^[A-Z][a-z]{2}\s+\d{1,2}\s\d{2}:\d{2}:\d{2}\s\S+\s[\w.\/-]+(\[\d+\])?:/
  @access_log_prefix ~r/^\S+ \S+ \S+ \[\d{2}\/[A-Z][a-z]{2}\/\d{4}:[\d:]+ [+-]\d{4}\] "/
  @logfmt_pair ~r/(^|\s)[a-z_][\w.]*=("[^"]*"|\S+)/

  defp log_lines?(text) do
    lines = non_blank_lines(text)

    length(lines) >= 2 and log_line?(hd(lines)) and
      Enum.count(lines, &log_line?/1) / length(lines) >= 0.8
  end

  defp log_line?(line) do
    (Regex.match?(@iso_timestamp, line) and Regex.match?(@log_marker, line)) or
      Regex.match?(@syslog_prefix, line) or Regex.match?(@access_log_prefix, line) or
      (Regex.match?(~r/^[a-z_][\w.]*=/, line) and length(Regex.scan(@logfmt_pair, line)) >= 3)
  end

  defp json_lines?(text) do
    lines = non_blank_lines(text)

    length(lines) >= 2 and
      Enum.all?(lines, fn line ->
        String.starts_with?(line, "{") and match?({:ok, %{}}, Jason.decode(line))
      end)
  end

  defp delimited_table?(text) do
    lines = text |> unquote_cells() |> non_blank_lines()

    length(lines) >= 2 and
      not Enum.any?(lines, &Regex.match?(@list_marker, &1)) and
      Enum.any?([",", "\t", ";", "|"], &delimited_with?(lines, &1))
  end

  # Column counts must agree before any cell is read.
  defp delimited_with?([first | _] = lines, delimiter) do
    String.contains?(first, delimiter) and consistent_columns?(lines, delimiter) and
      short_cells?(lines, delimiter)
  end

  defp consistent_columns?(lines, delimiter) do
    n = length(lines)

    {columns, frequency} =
      lines
      |> Enum.frequencies_by(&length(:binary.matches(&1, delimiter)))
      |> Enum.max_by(&elem(&1, 1))

    columns >= 1 and (n > 2 or columns >= 2) and frequency / n >= 0.9
  end

  defp short_cells?(lines, delimiter) do
    words = lines |> Enum.flat_map(&String.split(&1, delimiter)) |> Enum.map(&word_count/1)

    Enum.sum(words) / max(length(words), 1) <= 4 and Enum.max(words, fn -> 0 end) <= 12 and
      Enum.count(lines, &sentence?/1) / length(lines) <= 0.1
  end

  # Quoted CSV cells may contain delimiters and line breaks; collapse them to
  # a token before splitting rows.
  defp unquote_cells(text), do: String.replace(text, ~r/"(?:[^"]|"")*"/, "q")

  # Indentation is kept: nested YAML list items are structure.
  defp key_value_document?(text) do
    lines =
      text
      |> String.split(~r/\r?\n/)
      |> Enum.map(&String.trim_trailing/1)
      |> Enum.reject(&(&1 == "" or Regex.match?(~r/^\s*[#;!]/, &1)))

    n = length(lines)
    keyed = Enum.count(lines, &key_value_line?/1)
    structural = Enum.count(lines, &(key_value_line?(&1) or kv_structure_line?(&1)))

    n >= 3 and keyed / n >= 0.5 and structural / n >= 0.9
  end

  # Config keys: lower_snake, kebab, camelCase or ALL_CAPS, never a
  # capitalized word (a speaker such as "Alice:" in a transcript).
  @config_key "(?:[a-z_][A-Za-z0-9_.-]*|[A-Z][A-Z0-9_]*)"
  @yaml_pair ~r/^\s*#{@config_key}:(\s+(.*))?$/
  @assign_pair ~r/^\s*#{@config_key}\s*=\s*("[^"]*"|'[^']*'|-?\d[\d._]*|true|false|\[.*\]|\{.*\}|[^\s=]+)\s*$/
  # .properties and .env lines: `key=value` with no space before `=`.
  @property_pair ~r/^#{@config_key}=\S/

  defp key_value_line?(line) do
    case Regex.run(@yaml_pair, line) do
      [_] -> true
      [_, _, value] -> word_count(value) <= 6
      _ -> Regex.match?(@assign_pair, line) or Regex.match?(@property_pair, line)
    end
  end

  # List items belong to the document when nested (YAML) or short.
  defp kv_structure_line?(line) do
    Regex.match?(~r/^\s+-\s+\S/, line) or
      (Regex.match?(~r/^-\s+\S/, line) and word_count(line) <= 5) or
      Regex.match?(~r/^\s*(---|\.\.\.|\[\[?[\w.-]+\]\]?)\s*$/, line)
  end

  # XML carrying records rather than an HTML page: a prolog, or markup whose
  # tags are not HTML.
  @html_tags ~w(html head body div span p a ul ol li table thead tbody tr td th script style link meta
                img button form input label select option textarea br hr h1 h2 h3 h4 h5 h6 section
                header footer nav main article aside strong em b i u code pre small template slot)

  defp xml_document?(text) do
    cond do
      String.starts_with?(text, "<?xml") ->
        true

      String.starts_with?(text, "<") ->
        lines = non_blank_lines(text)

        tags =
          ~r/<\/?([A-Za-z][\w:.-]*)/
          |> Regex.scan(text)
          |> Enum.map(&(&1 |> List.last() |> String.downcase()))

        Enum.all?(lines, &String.starts_with?(&1, "<")) and tags != [] and
          not Enum.any?(tags, &(&1 in @html_tags or &1 == "svg"))

      true ->
        false
    end
  end

  # Diagram definitions (mermaid, graphviz, PlantUML) outside a fence.
  @diagram_start ~r/^(graph|flowchart)\s+(TD|TB|BT|RL|LR)\b|^(sequenceDiagram|classDiagram|stateDiagram(-v2)?|erDiagram|gantt|pie|journey|gitGraph|mindmap|timeline|quadrantChart)\b|^(strict\s+)?(di)?graph\s+[\w"]*\s*\{|^@startuml\b/

  defp diagram?(text), do: Regex.match?(@diagram_start, text)

  # ── Line tally ──────────────────────────────────────────────────────────

  defp tally_lines(text) do
    initial = %{
      counts: %{prose: 0, code: 0, raw_code: 0, data: 0, visual: 0, structure: 0, embedded: 0},
      words: 0,
      fence: nil,
      svg: false,
      docstring: false,
      block_comment: false
    }

    text
    |> String.split(~r/\r?\n/)
    |> Enum.take(@max_lines)
    |> Enum.reduce(initial, &tally_line/2)
  end

  defp tally_line(raw, acc) do
    line = String.trim(raw)

    cond do
      acc.fence != nil ->
        if Regex.match?(@fence, line), do: %{acc | fence: nil}, else: embed(acc, acc.fence)

      Regex.match?(@fence, line) ->
        [_, _, lang] = Regex.run(@fence, line)
        %{acc | fence: fence_kind(String.downcase(lang))}

      line == "" ->
        acc

      acc.svg ->
        %{embed(acc, :visual) | svg: not String.contains?(line, "</svg>")}

      Regex.match?(~r/<svg\b/i, line) ->
        %{embed(acc, :visual) | svg: not String.contains?(line, "</svg>")}

      acc.block_comment ->
        if String.contains?(line, "*/"), do: %{acc | block_comment: false}, else: acc

      acc.docstring ->
        if docstring_toggle?(line), do: %{acc | docstring: false}, else: acc

      String.starts_with?(line, "/*") ->
        %{acc | block_comment: not String.contains?(line, "*/")}

      true ->
        acc = if docstring_toggle?(line), do: %{acc | docstring: true}, else: acc
        {kind, words} = classify_line(line)
        acc |> bump(kind) |> Map.update!(:words, &(&1 + words))
    end
  end

  @docstring_quotes [~s("""), "'''"]

  defp docstring_toggle?(line) do
    String.contains?(line, @docstring_quotes) and
      rem(Enum.sum(Enum.map(@docstring_quotes, &(length(String.split(line, &1)) - 1))), 2) == 1
  end

  defp fence_kind(lang) when lang in @data_fence_langs, do: :data
  defp fence_kind(lang) when lang in @visual_fence_langs, do: :visual
  defp fence_kind(_), do: :code

  defp bump(acc, :neutral), do: acc
  defp bump(acc, :code), do: acc |> count(:code) |> count(:raw_code)
  defp bump(acc, kind) when kind in [:data, :visual], do: embed(acc, kind)
  defp bump(acc, kind), do: count(acc, kind)

  # Content embedded in a document: fenced blocks, table rows and images.
  defp embed(acc, kind), do: acc |> count(kind) |> count(:embedded)

  defp count(acc, key), do: %{acc | counts: Map.update!(acc.counts, key, &(&1 + 1))}

  # Returns {kind, prose_words}.
  defp classify_line(line) do
    cond do
      image?(line) -> {:visual, 0}
      Regex.match?(@table_row, line) or Regex.match?(@table_rule, line) -> {:data, 0}
      Regex.match?(@heading, line) or Regex.match?(@rule, line) -> {:neutral, 0}
      Regex.match?(@subtitle_timing, line) -> {:neutral, 0}
      Regex.match?(@comment, line) -> {:neutral, 0}
      Regex.match?(@structure_line, line) -> {:structure, 0}
      Regex.match?(@list_marker, line) -> line |> String.replace(@list_marker, "") |> prose_kind()
      true -> code_or_prose(line)
    end
  end

  # Markdown list items are written for people; they never decide code.
  defp prose_kind(text) do
    {alpha, total} = word_stats(text)
    if prose?(alpha, total), do: {:prose, alpha}, else: {:neutral, 0}
  end

  defp code_or_prose(line) do
    {alpha, total} = word_stats(line)
    prose? = prose?(alpha, total)
    cues = if strong_code?(line), do: 2, else: code_cues(line)

    cond do
      cues >= 2 -> {:code, 0}
      cues == 1 and not prose? and lone_cue_code?(line, alpha) -> {:code, 0}
      prose? -> {:prose, alpha}
      true -> {:neutral, 0}
    end
  end

  defp strong_code?(line), do: Regex.match?(@strong_code, line)

  defp image?(line), do: Regex.match?(@markdown_image, line) or Regex.match?(@image_tag, line)

  # A single cue decides only when almost nothing around it reads as words.
  defp lone_cue_code?(_line, 0), do: true
  defp lone_cue_code?(line, 1), do: symbol_density(line) >= 0.08
  defp lone_cue_code?(_line, _alpha), do: false

  # Counts distinct cues, stopping at two (enough to decide).
  defp code_cues(line) do
    if Regex.match?(@any_weak_cue, line), do: count_cues(line), else: 0
  end

  defp count_cues(line) do
    Enum.reduce_while(@weak_patterns, 0, fn pattern, n ->
      cond do
        not Regex.match?(pattern, line) -> {:cont, n}
        n + 1 >= 2 -> {:halt, 2}
        true -> {:cont, n + 1}
      end
    end)
  end

  defp prose?(alpha, total), do: alpha >= 3 and alpha / max(total, 1) >= 0.6

  defp word_stats(text) do
    {length(Regex.scan(@letters_word, text)), length(String.split(text))}
  end

  defp symbol_density(line) do
    chars = line |> String.replace(~r/\s/, "") |> String.to_charlist()
    Enum.count(chars, &(&1 in @symbol_chars)) / max(length(chars), 1)
  end

  # ── Decision ────────────────────────────────────────────────────────────
  #
  # Raw (unfenced) source code decides code on its own. Prose that embeds a
  # substantive block (fenced code or data, a table, an image) is mixed: the
  # fence or the table is the author saying "this is a document with an
  # example in it". Otherwise the dominant non-prose kind wins, then prose.

  defp decide(%{counts: c, words: words}) do
    structure = if c.raw_code > 0, do: c.structure, else: 0
    raw_code = c.raw_code + structure
    code = c.code + structure
    counted = code + c.prose + c.data + c.visual

    cond do
      counted == 0 ->
        {:linguistic, :weak}

      raw_code_dominant?(raw_code, c.prose, counted) ->
        {:code, :strong}

      mixed?(c, raw_code, counted) ->
        {:mixed, :strong}

      kind = dominant_kind(%{code: code, data: c.data, visual: c.visual}, counted) ->
        {kind, :strong}

      c.prose > 0 and words >= 4 ->
        {:linguistic, :strong}

      true ->
        {:linguistic, :weak}
    end
  end

  defp raw_code_dominant?(raw_code, prose, counted) do
    share = raw_code / counted
    share >= 0.8 or (share >= 0.6 and prose / counted <= 0.25)
  end

  defp mixed?(c, raw_code, counted) do
    prose_present = c.prose >= 2 or (c.prose >= 1 and c.visual >= 1)

    substantive =
      c.visual >= 1 or (c.embedded >= 2 and c.embedded / counted >= 0.1) or
        (raw_code >= 2 and raw_code / counted >= 0.1)

    prose_present and substantive
  end

  defp dominant_kind(kinds, counted) do
    {kind, n} = Enum.max_by(kinds, &elem(&1, 1))
    if n > 0 and n / counted >= 0.5, do: kind
  end

  # ── Text helpers ────────────────────────────────────────────────────────

  defp non_blank_lines(text) do
    text
    |> String.split(~r/\r?\n/)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp word_count(text), do: text |> String.split() |> length()

  defp sentence?(line), do: word_count(line) >= 5 and Regex.match?(~r/[.!?]["')]?$/, line)
end
