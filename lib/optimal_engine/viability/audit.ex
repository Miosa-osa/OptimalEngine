defmodule OptimalEngine.Viability.Audit do
  @moduledoc """
  System 3*: sporadic audit. Each week a random sample of the Signals a
  workspace sent is scored with the paper's triple-layer verification, and
  low scores are filed for review.

  | Layer | Weight | Scored from |
  | --- | --- | --- |
  | formal | 0.40 | a title, a body of at least 20 words, recorded dimensions, and the genre's required sections when the text has headings |
  | semantic | 0.35 | agreement between the recorded genre and the genre the text reads as, between the recorded mode and the mode the current detector reads with strong evidence, and the classifier's S/N estimate |
  | information | 0.25 | novelty against the 30 Signals before it in the workspace (1 minus the highest word-trigram overlap), scaled down under 20 words |

  Signals sent are those with `metadata.direction = "outbound"` or a
  `produced` event naming them; when a
  workspace sent none in the period, received Signals are sampled instead and
  the sample's `basis` says so. A sample scoring under 0.5, or with any one
  layer under 0.4, is `flagged` and appears in the review queue until
  confirmed or dismissed.
  """

  alias OptimalEngine.Signal.{GenreRegistry, ModeDetector}
  alias OptimalEngine.Store

  @weights %{formal: 0.40, semantic: 0.35, information: 0.25}
  @default_size 10
  @flag_below 0.5
  @layer_floor 0.4
  @prior_count 30

  @doc "The layer weights."
  @spec weights() :: map()
  def weights, do: @weights

  @doc "The ISO week label for a date, for example `2026-W42`."
  @spec period(Date.t()) :: String.t()
  def period(date) do
    {year, week} = :calendar.iso_week_number(Date.to_erl(date))
    "#{year}-W#{String.pad_leading(Integer.to_string(week), 2, "0")}"
  end

  @doc """
  Samples and scores a workspace's Signals for the week of `:today`.
  Options `:size` (default 10) and `:today`. Signals already sampled this
  week are not sampled again.
  """
  @spec run(String.t(), String.t(), keyword()) :: {:ok, map()}
  def run(tenant_id, workspace_id, opts \\ []) do
    today = Keyword.get(opts, :today, Date.utc_today())
    size = opts |> Keyword.get(:size, @default_size) |> max(1) |> min(100)
    period = period(today)
    from = today |> Date.add(-6) |> Date.to_iso8601()
    to = today |> Date.add(1) |> Date.to_iso8601()

    {basis, candidates} =
      case sample(tenant_id, workspace_id, period, from, to, size, :sent) do
        [] -> {"received", sample(tenant_id, workspace_id, period, from, to, size, :received)}
        rows -> {"sent", rows}
      end

    samples =
      Enum.map(candidates, fn [id, title, content, genre, signal_type, mode, sn, at] ->
        priors = priors(workspace_id, id, at)

        scored =
          score(
            %{
              title: title,
              content: content,
              genre: genre,
              signal_type: signal_type,
              mode: mode,
              sn_ratio: sn
            },
            priors
          )

        sample = %{
          id: "aud_" <> random_id(),
          workspace_id: workspace_id,
          period: period,
          context_id: id,
          basis: basis,
          state: if(flag?(scored), do: "flagged", else: "passed")
        }

        {:ok, _} =
          Store.raw_query(
            """
            INSERT OR IGNORE INTO audit_samples
              (id, tenant_id, workspace_id, period, context_id, basis, formal, semantic, information,
               score, findings, state)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)
            """,
            [
              sample.id,
              tenant_id,
              workspace_id,
              period,
              id,
              basis,
              scored.formal,
              scored.semantic,
              scored.information,
              scored.score,
              Jason.encode!(scored.findings),
              sample.state
            ]
          )

        Map.merge(sample, scored)
      end)

    {:ok,
     %{
       workspace_id: workspace_id,
       period: period,
       basis: basis,
       sampled: length(samples),
       flagged: Enum.count(samples, &(&1.state == "flagged")),
       samples: samples
     }}
  end

  @doc """
  Scores one Signal (`title`, `content`, `genre`, `signal_type`, `mode`,
  `sn_ratio`) against prior texts.
  """
  @spec score(map(), [String.t()]) :: map()
  def score(signal, priors) do
    content = signal.content || ""
    words = word_count(content)
    {formal, formal_findings} = formal(signal, content, words)
    {semantic, semantic_findings} = semantic(signal, content)
    {information, information_findings} = information(content, words, priors)

    total =
      @weights.formal * formal + @weights.semantic * semantic +
        @weights.information * information

    %{
      formal: Float.round(formal, 3),
      semantic: Float.round(semantic, 3),
      information: Float.round(information, 3),
      score: Float.round(total, 3),
      findings: formal_findings ++ semantic_findings ++ information_findings
    }
  end

  @doc "Audit samples for workspaces, newest first. Options `:state`, `:limit`."
  @spec list(String.t(), [String.t()], keyword()) :: [map()]
  def list(tenant_id, workspace_ids, opts \\ []) do
    limit = opts |> Keyword.get(:limit, 50) |> max(1) |> min(500)
    placeholders = Enum.map_join(1..length(workspace_ids), ", ", &"?#{&1 + 1}")

    {state_sql, params} =
      case opts[:state] do
        nil -> {"", []}
        state -> {" AND a.state = ?#{length(workspace_ids) + 2}", [state]}
      end

    {:ok, rows} =
      Store.raw_query(
        """
        SELECT a.id, a.workspace_id, a.period, a.context_id, a.basis, a.formal, a.semantic,
               a.information, a.score, a.findings, a.state, a.reviewed_by, a.reviewed_at, a.note,
               a.created_at, c.title
        FROM audit_samples a LEFT JOIN contexts c ON c.id = a.context_id
        WHERE a.tenant_id = ?1 AND a.workspace_id IN (#{placeholders})#{state_sql}
        ORDER BY a.created_at DESC, a.score ASC LIMIT #{limit}
        """,
        [tenant_id | workspace_ids] ++ params
      )

    Enum.map(rows, fn [
                        id,
                        ws,
                        period,
                        context_id,
                        basis,
                        f,
                        s,
                        i,
                        score,
                        findings,
                        state,
                        by,
                        at,
                        note,
                        created,
                        title
                      ] ->
      %{
        id: id,
        workspace_id: ws,
        period: period,
        context_id: context_id,
        title: title,
        basis: basis,
        formal: f,
        semantic: s,
        information: i,
        score: score,
        findings: Jason.decode!(findings),
        state: state,
        reviewed_by: by,
        reviewed_at: at,
        note: note,
        created_at: created
      }
    end)
  end

  @doc "Confirms (`confirm`) or dismisses (`dismiss`) a flagged sample."
  @spec review(String.t(), String.t(), String.t(), String.t(), String.t() | nil) ::
          {:ok, String.t()} | {:error, atom()}
  def review(tenant_id, id, decision, reviewer, note \\ nil)

  def review(tenant_id, id, decision, reviewer, note) when decision in ["confirm", "dismiss"] do
    state = if decision == "confirm", do: "confirmed", else: "dismissed"

    {:ok, _} =
      Store.raw_query(
        """
        UPDATE audit_samples SET state = ?3, reviewed_by = ?4, note = ?5,
          reviewed_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
        WHERE tenant_id = ?1 AND id = ?2 AND state = 'flagged'
        """,
        [tenant_id, id, state, reviewer, note]
      )

    case Store.raw_query("SELECT state FROM audit_samples WHERE tenant_id = ?1 AND id = ?2", [
           tenant_id,
           id
         ]) do
      {:ok, [[^state]]} -> {:ok, state}
      {:ok, [[_other]]} -> {:error, :not_flagged}
      {:ok, []} -> {:error, :not_found}
    end
  end

  def review(_tenant_id, _id, _decision, _reviewer, _note), do: {:error, :invalid_decision}

  # A sample is flagged when its score is low or any one layer fails.
  defp flag?(scored) do
    scored.score < @flag_below or
      Enum.min([scored.formal, scored.semantic, scored.information]) < @layer_floor
  end

  # -- layers ------------------------------------------------------------------

  defp formal(signal, content, words) do
    checks = [
      {present?(signal.title), "The Signal has no title."},
      {min(words / 20, 1.0), "The body is shorter than 20 words."},
      {Enum.all?([signal.genre, signal.signal_type, signal.mode], &present?/1),
       "Not every dimension (genre, type, mode) is recorded."}
    ]

    checks =
      case section_coverage(signal.genre, content) do
        nil ->
          checks

        {coverage, missing} ->
          checks ++
            [
              {coverage,
               "Missing required sections for #{signal.genre}: #{Enum.join(missing, ", ")}."}
            ]
      end

    values = Enum.map(checks, fn {value, _finding} -> as_number(value) end)

    findings =
      for {value, finding} <- checks, as_number(value) < 1.0, do: finding

    {Enum.sum(values) / length(values), findings}
  end

  # Required sections are judged only when the text has at least two headings.
  defp section_coverage(genre, content) do
    headings =
      ~r/^\s{0,3}#+\s*(.+)$/m
      |> Regex.scan(content)
      |> Enum.map(fn [_line, heading] -> String.downcase(heading) end)

    required =
      genre
      |> GenreRegistry.skeleton()
      |> Enum.filter(& &1.required)
      |> Enum.map(& &1.name)

    if length(headings) >= 2 and required != [] do
      missing =
        Enum.reject(required, fn name ->
          down = String.downcase(name)
          Enum.any?(headings, &String.contains?(&1, down))
        end)

      {(length(required) - length(missing)) / length(required), missing}
    end
  end

  defp semantic(signal, content) do
    detected = GenreRegistry.detect(content)
    recorded = signal.genre || GenreRegistry.default_genre()

    agreement =
      cond do
        detected == recorded ->
          1.0

        recorded == GenreRegistry.default_genre() or detected == GenreRegistry.default_genre() ->
          0.5

        true ->
          0.0
      end

    sn = signal.sn_ratio || 0.5
    mode = mode_fit(signal.mode, content)

    findings =
      [
        if(agreement == 0.0, do: "The text reads as #{detected} but is recorded as #{recorded}."),
        case mode do
          {fit, plausible} when fit < 1.0 ->
            "Recorded as mode #{signal.mode} but reads as #{plausible}."

          _ ->
            nil
        end,
        if(sn < 0.4,
          do: "The classifier estimates a low signal to noise ratio (#{Float.round(sn * 1.0, 2)})."
        )
      ]
      |> Enum.reject(&is_nil/1)

    value =
      case mode do
        {fit, _plausible} -> 0.35 * agreement + 0.35 * fit + 0.30 * sn
        nil -> 0.5 * agreement + 0.5 * sn
      end

    {value, findings}
  end

  # The audit re-reads the mode from the text with the current detector and
  # judges it only on strong evidence, so Signals stored by an older or wrong
  # classification are caught. Visual, audio, and mixed records are not judged.
  defp mode_fit(recorded, content) when recorded in ["linguistic", "code", "data"] do
    case ModeDetector.detect(content) do
      {mode, :strong} ->
        plausible = Atom.to_string(mode)
        {if(plausible == recorded, do: 1.0, else: 0.0), plausible}

      _weak ->
        nil
    end
  end

  defp mode_fit(_recorded, _content), do: nil

  defp information(content, words, priors) do
    grams = trigrams(content)

    overlap =
      priors
      |> Enum.map(&jaccard(grams, trigrams(&1)))
      |> Enum.max(fn -> 0.0 end)

    novelty = (1.0 - overlap) * min(words / 20, 1.0)

    findings =
      [
        if(overlap >= 0.6,
          do: "Mostly repeats an earlier Signal (overlap #{Float.round(overlap, 2)})."
        ),
        if(words < 20, do: "Too short to reduce much uncertainty.")
      ]
      |> Enum.reject(&is_nil/1)

    {novelty, findings}
  end

  # -- sampling ----------------------------------------------------------------

  defp sample(tenant_id, workspace_id, period, from, to, size, basis) do
    direction =
      "(CASE WHEN json_valid(c.metadata) THEN json_extract(c.metadata, '$.direction') END)"

    produced =
      "EXISTS (SELECT 1 FROM signal_events e WHERE e.context_id = c.id AND e.kind = 'produced')"

    sent =
      case basis do
        :sent -> "(#{direction} = 'outbound' OR #{produced})"
        :received -> "(#{direction} IS NOT 'outbound' AND NOT #{produced})"
      end

    {:ok, rows} =
      Store.raw_query(
        """
        SELECT c.id, c.title, substr(c.content, 1, 20000), COALESCE(c.genre, 'note'), c.signal_type,
               c.mode, c.sn_ratio, COALESCE(c.created_at, c.indexed_at)
        FROM contexts c
        WHERE c.workspace_id = ?1 AND c.type = 'signal' AND c.archived_at IS NULL
          AND (CASE WHEN json_valid(c.metadata) THEN json_extract(c.metadata, '$.agent_action') END) IS NULL
          AND (CASE WHEN json_valid(c.metadata) THEN json_extract(c.metadata, '$.cross_ref_from') END) IS NULL
          AND #{sent}
          AND substr(COALESCE(c.created_at, c.indexed_at), 1, 10) >= ?2
          AND substr(COALESCE(c.created_at, c.indexed_at), 1, 10) < ?3
          AND c.id NOT IN (SELECT context_id FROM audit_samples WHERE tenant_id = ?4 AND workspace_id = ?1 AND period = ?5)
        ORDER BY random() LIMIT ?6
        """,
        [workspace_id, from, to, tenant_id, period, size]
      )

    rows
  end

  defp priors(workspace_id, id, at) do
    {:ok, rows} =
      Store.raw_query(
        """
        SELECT substr(content, 1, 20000) FROM contexts
        WHERE workspace_id = ?1 AND type = 'signal' AND id <> ?2 AND archived_at IS NULL
          AND COALESCE(created_at, indexed_at) < ?3
        ORDER BY COALESCE(created_at, indexed_at) DESC LIMIT #{@prior_count}
        """,
        [workspace_id, id, at]
      )

    Enum.map(rows, fn [content] -> content || "" end)
  end

  # ---------------------------------------------------------------------------

  defp trigrams(text) do
    words =
      text
      |> String.downcase()
      |> String.split(~r/[^\p{L}\p{N}]+/u, trim: true)

    words
    |> Enum.chunk_every(3, 1, :discard)
    |> MapSet.new()
  end

  defp jaccard(a, b) do
    union = MapSet.size(MapSet.union(a, b))
    if union == 0, do: 0.0, else: MapSet.size(MapSet.intersection(a, b)) / union
  end

  defp word_count(text), do: text |> String.split(~r/\s+/u, trim: true) |> length()

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp as_number(true), do: 1.0
  defp as_number(false), do: 0.0
  defp as_number(value), do: value * 1.0

  defp random_id, do: :crypto.strong_rand_bytes(12) |> Base.encode16(case: :lower)
end
