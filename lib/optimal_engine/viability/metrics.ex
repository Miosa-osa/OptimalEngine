defmodule OptimalEngine.Viability.Metrics do
  @moduledoc """
  The six proxy metrics of Signal Theory (section 11.3 of the paper) and the
  requisite variety ratio, computed for a set of workspaces over a window of
  days `[from, to)`.

  Every metric states its method, its numerator and denominator, and which
  direction is better. A metric with nothing to measure has `value: nil` and
  `status: "no_data"`, never a zero that reads as a result.

  | Metric | Maps to | Computed from |
  | --- | --- | --- |
  | action completion rate | fidelity | open loops resolved or due in the window |
  | re-encoding frequency | noise | `re_encoded` events, follow-up loops, clarification phrases |
  | time to decode | decoding efficiency | receipt to first action (`acted` event or a closed loop) |
  | signal bounce rate | routing accuracy | `rerouted` events over Signals received |
  | genre recognition rate | genre competence | recognized genres plus pre-send genre checks |
  | feedback loop closure rate | feedback completeness | reply and decision loops, confirmed direct Signals |

  Signals received are contexts of type `signal` in the workspaces, excluding
  agent action steps, cross-reference copies of a Signal routed to a second
  node (`metadata.cross_ref_from`), and Signals the workspace sent
  (`metadata.direction = "outbound"`, or a `produced` event naming the
  context); their receipt time is `created_at`, else `indexed_at`.
  """

  alias OptimalEngine.Operating.Protocol
  alias OptimalEngine.Signal.GenreRegistry
  alias OptimalEngine.Store

  @definitions [
    %{
      name: "action_completion_rate",
      maps_to: "fidelity",
      better: "higher",
      unit: "ratio",
      method:
        "Open loops closed in the window over loops closed, dropped, or missed (due in the window and not resolved by its end)."
    },
    %{
      name: "re_encoding_frequency",
      maps_to: "noise level",
      better: "lower",
      unit: "per 100 signals",
      method:
        "re_encoded events, follow-up loops opened, and Signals whose text re-explains or asks again, per 100 Signals received."
    },
    %{
      name: "time_to_decode_hours",
      maps_to: "decoding efficiency",
      better: "lower",
      unit: "hours (median)",
      method:
        "Median hours from a Signal's receipt to its first action: an acted event or the first closed loop it produced."
    },
    %{
      name: "signal_bounce_rate",
      maps_to: "routing accuracy",
      better: "lower",
      unit: "ratio",
      method: "Signals rerouted in the window (rerouted events) over Signals received."
    },
    %{
      name: "genre_recognition_rate",
      maps_to: "genre competence",
      better: "higher",
      unit: "ratio",
      method:
        "Signals classified to a registry genre other than the fallback note, plus pre-send genre checks that passed, over all of both. A real note counts as unrecognized, so this is a lower bound."
    },
    %{
      name: "feedback_loop_closure_rate",
      maps_to: "feedback completeness",
      better: "higher",
      unit: "ratio",
      method:
        "Reply, follow-up and decision loops closed over those resolved or missed in the window, plus direct Signals without a loop confirmed by a feedback_confirmed or acted event."
    }
  ]

  @default_markers [
    "to clarify",
    "what did you mean",
    "what do you mean",
    "did you mean",
    "to be clear",
    "let me rephrase",
    "in other words",
    "as i said",
    "as i mentioned",
    "as mentioned before",
    "per my last",
    "following up on",
    "circling back",
    "just checking in",
    "any update on",
    "friendly reminder",
    "resending"
  ]

  @feedback_kinds ~w(owed_reply follow_up decision_needed)
  @repertoire_days 90

  @doc "The metric definitions (name, maps_to, better, unit, method)."
  @spec definitions() :: [map()]
  def definitions, do: @definitions

  @doc "The phrases that mark a re-encoding (config `:re_encoding_markers`)."
  @spec markers() :: [String.t()]
  def markers do
    :optimal_engine
    |> Application.get_env(:re_encoding_markers, @default_markers)
    |> Enum.map(&String.downcase/1)
  end

  @doc """
  Computes the six metrics and the variety ratio for `workspace_ids` over
  `%{from: Date, to: Date}` (to exclusive).
  """
  @spec compute(String.t(), [String.t()], %{from: Date.t(), to: Date.t()}) :: map()
  def compute(_tenant_id, [], window), do: empty(window)

  def compute(tenant_id, workspace_ids, %{from: from, to: to} = window) do
    scope = scope(tenant_id, workspace_ids, from, to)
    received = count_signals(scope)

    metrics = [
      action_completion(scope),
      re_encoding(scope, received),
      time_to_decode(scope),
      bounce(scope, received),
      genre_recognition(scope, received),
      feedback_closure(scope)
    ]

    %{
      window: %{from: Date.to_iso8601(from), to: Date.to_iso8601(to)},
      signals_received: received,
      metrics: metrics,
      variety: variety(scope, window)
    }
  end

  @doc "The paper's band for a variety ratio."
  @spec band(number() | nil) :: String.t() | nil
  def band(nil), do: nil
  def band(r) when r < 1.0, do: "failing"
  def band(r) when r < 3.0, do: "marginal"
  def band(r) when r < 10.0, do: "adequate"
  def band(_r), do: "robust"

  @doc "Looks up one metric from a computed result."
  @spec value(map(), String.t()) :: number() | nil
  def value(%{metrics: metrics}, name) do
    Enum.find_value(metrics, fn metric -> if metric.name == name, do: metric.value end)
  end

  # -- the metrics -------------------------------------------------------------

  defp action_completion(scope) do
    {closed, dropped, missed} = loop_outcomes(scope, nil)
    ratio_metric("action_completion_rate", closed, closed + dropped + missed)
  end

  defp re_encoding(scope, received) do
    events = count_events(scope, "re_encoded")

    {:ok, [[follow_ups]]} =
      Store.raw_query(
        """
        SELECT COUNT(*) FROM open_loops
        WHERE tenant_id = ?1 AND workspace_id IN (#{scope.ws_sql}) AND kind = 'follow_up'
          AND substr(created_at, 1, 10) >= ?#{scope.from_i} AND substr(created_at, 1, 10) < ?#{scope.to_i}
        """,
        scope.params
      )

    phrases = count_marked_signals(scope)
    total = events + follow_ups + phrases

    value =
      if received > 0, do: Float.round(total / received * 100, 2)

    metric("re_encoding_frequency", value, %{
      count: total,
      denominator: received,
      components: %{events: events, follow_up_loops: follow_ups, phrases: phrases},
      status: if(received == 0 and total == 0, do: "no_data", else: "measured")
    })
  end

  defp time_to_decode(scope) do
    {:ok, rows} =
      Store.raw_query(
        """
        WITH sig AS (
          SELECT c.id AS id, COALESCE(c.created_at, c.indexed_at) AS at
          FROM contexts c WHERE #{signals_where("c", scope)}
        ), first_action AS (
          SELECT context_id AS id, MIN(occurred_at) AS at FROM signal_events
          WHERE tenant_id = ?1 AND kind = 'acted' AND context_id IN (SELECT id FROM sig)
          GROUP BY context_id
          UNION ALL
          SELECT source_context_id AS id, MIN(closed_at) AS at FROM open_loops
          WHERE tenant_id = ?1 AND state = 'closed' AND source_context_id IN (SELECT id FROM sig)
          GROUP BY source_context_id
        )
        SELECT (julianday(MIN(f.at)) - julianday(s.at)) * 24.0
        FROM sig s JOIN first_action f ON f.id = s.id
        GROUP BY s.id
        """,
        scope.params
      )

    hours =
      rows
      |> Enum.map(fn [h] -> h end)
      |> Enum.filter(&is_number/1)
      |> Enum.map(&max(&1, 0.0))
      |> Enum.sort()

    case hours do
      [] ->
        metric("time_to_decode_hours", nil, %{count: 0, status: "no_data"})

      _ ->
        metric("time_to_decode_hours", Float.round(percentile(hours, 0.5), 2), %{
          count: length(hours),
          p90: Float.round(percentile(hours, 0.9), 2),
          status: "measured"
        })
    end
  end

  defp bounce(scope, received) do
    {:ok, [[distinct, unattached]]} =
      Store.raw_query(
        """
        SELECT COUNT(DISTINCT context_id), COALESCE(SUM(CASE WHEN context_id IS NULL THEN 1 ELSE 0 END), 0)
        FROM signal_events
        WHERE tenant_id = ?1 AND workspace_id IN (#{scope.ws_sql}) AND kind = 'rerouted'
          AND #{date_window("occurred_at", scope)}
        """,
        scope.params
      )

    bounced = distinct + unattached

    if received == 0 do
      metric("signal_bounce_rate", nil, %{
        numerator: bounced,
        denominator: 0,
        status: "no_data"
      })
    else
      ratio_metric("signal_bounce_rate", min(bounced, received), received)
    end
  end

  defp genre_recognition(scope, received) do
    {:ok, rows} =
      Store.raw_query(
        "SELECT COALESCE(c.genre, ''), COUNT(*) FROM contexts c WHERE #{signals_where("c", scope)} GROUP BY 1",
        scope.params
      )

    default = GenreRegistry.default_genre()

    recognized =
      Enum.reduce(rows, 0, fn [genre, count], acc ->
        if genre != default and GenreRegistry.valid?(genre), do: acc + count, else: acc
      end)

    {:ok, [[checks, passed]]} =
      Store.raw_query(
        """
        SELECT COUNT(*), COALESCE(SUM(CASE WHEN value >= 0.5 THEN 1 ELSE 0 END), 0)
        FROM signal_events
        WHERE tenant_id = ?1 AND workspace_id IN (#{scope.ws_sql}) AND kind = 'genre_checked'
          AND #{date_window("occurred_at", scope)}
        """,
        scope.params
      )

    ratio_metric("genre_recognition_rate", recognized + passed, received + checks, %{
      components: %{
        recognized_signals: recognized,
        signals: received,
        checks_passed: passed,
        checks: checks
      }
    })
  end

  defp feedback_closure(scope) do
    {closed, dropped, missed} = loop_outcomes(scope, @feedback_kinds)

    {:ok, [[direct, confirmed]]} =
      Store.raw_query(
        """
        SELECT COUNT(*), COALESCE(SUM(CASE WHEN EXISTS (
            SELECT 1 FROM signal_events e
            WHERE e.tenant_id = ?1 AND e.context_id = c.id AND e.kind IN ('feedback_confirmed', 'acted')
          ) THEN 1 ELSE 0 END), 0)
        FROM contexts c
        WHERE #{signals_where("c", scope)} AND c.signal_type = 'direct'
          AND NOT EXISTS (SELECT 1 FROM open_loops l WHERE l.tenant_id = ?1 AND l.source_context_id = c.id)
        """,
        scope.params
      )

    ratio_metric(
      "feedback_loop_closure_rate",
      closed + confirmed,
      closed + dropped + missed + direct,
      %{
        components: %{
          loops_closed: closed,
          loops_dropped: dropped,
          loops_missed: missed,
          direct_signals: direct,
          direct_confirmed: confirmed
        }
      }
    )
  end

  # -- requisite variety -------------------------------------------------------

  defp variety(scope, %{to: to}) do
    {:ok, rows} =
      Store.raw_query(
        """
        SELECT COALESCE(c.genre, ?#{scope.next_i}), COALESCE(c.mode, 'linguistic'), COUNT(*)
        FROM contexts c WHERE #{signals_where("c", scope)} GROUP BY 1, 2
        """,
        scope.params ++ [GenreRegistry.default_genre()]
      )

    encountered = Map.new(rows, fn [genre, mode, count] -> {{genre, mode}, count} end)
    {repertoire, sources} = repertoire(scope, to)

    covered? = fn {genre, mode} ->
      MapSet.member?(repertoire, {genre, mode}) or MapSet.member?(repertoire, {genre, "*"})
    end

    v_system = MapSet.size(repertoire)
    v_disturbance = map_size(encountered)

    gaps =
      encountered
      |> Enum.reject(fn {class, _count} -> covered?.(class) end)
      |> Enum.sort_by(fn {_class, count} -> -count end)
      |> Enum.take(15)
      |> Enum.map(fn {{genre, mode}, count} -> %{genre: genre, mode: mode, signals: count} end)

    covered = Enum.count(encountered, fn {class, _count} -> covered?.(class) end)

    {r, status} =
      cond do
        v_disturbance == 0 -> {nil, "no_data"}
        v_system == 0 -> {nil, "no_repertoire"}
        true -> {Float.round(v_system / v_disturbance, 2), "measured"}
      end

    %{
      r: r,
      band: band(r),
      status: status,
      v_system: v_system,
      v_disturbance: v_disturbance,
      coverage: if(v_disturbance > 0, do: Float.round(covered / v_disturbance, 3)),
      gaps: gaps,
      repertoire_sources: sources,
      method:
        "V(system) counts the genre and mode classes the workspace employs: its declared repertoire (operating document kind repertoire) and the classes of Signals it sent (metadata.direction outbound, or produced events) in the last #{@repertoire_days} days. V(disturbance) counts the classes of Signals received in the window."
    }
  end

  defp repertoire(scope, to) do
    from = Date.add(to, -@repertoire_days) |> Date.to_iso8601()
    to = Date.to_iso8601(to)
    ws_count = length(scope.workspace_ids)
    params = [scope.tenant_id | scope.workspace_ids] ++ [from, to]
    from_i = ws_count + 2
    to_i = ws_count + 3

    declared =
      scope.workspace_ids
      |> Enum.flat_map(fn workspace_id ->
        case Protocol.get(scope.tenant_id, workspace_id, "repertoire") do
          {:ok, %{source: source, content: content}} when source != "default" ->
            parse_repertoire(content)

          _ ->
            []
        end
      end)

    {:ok, produced_rows} =
      Store.raw_query(
        """
        SELECT DISTINCT COALESCE(c.genre, 'note'), COALESCE(c.mode, 'linguistic') FROM contexts c
        WHERE c.workspace_id IN (#{scope.ws_sql}) AND c.type = 'signal' AND c.archived_at IS NULL
          AND #{meta("c", "$.direction")} = 'outbound'
          AND substr(COALESCE(c.created_at, c.indexed_at), 1, 10) >= ?#{from_i}
          AND substr(COALESCE(c.created_at, c.indexed_at), 1, 10) < ?#{to_i}
        UNION
        SELECT DISTINCT COALESCE(e.genre, c.genre, 'note'), COALESCE(e.mode, c.mode, '*')
        FROM signal_events e LEFT JOIN contexts c ON c.id = e.context_id
        WHERE e.tenant_id = ?1 AND e.workspace_id IN (#{scope.ws_sql}) AND e.kind = 'produced'
          AND (e.genre IS NOT NULL OR c.id IS NOT NULL)
          AND substr(e.occurred_at, 1, 10) >= ?#{from_i} AND substr(e.occurred_at, 1, 10) < ?#{to_i}
        """,
        params
      )

    produced = Enum.map(produced_rows, &List.to_tuple/1)

    {MapSet.new(declared ++ produced),
     %{declared: length(Enum.uniq(declared)), produced: length(produced)}}
  end

  @doc """
  Parses a repertoire document: one class per line, `genre` (any mode) or
  `genre/mode`, optionally as a list item. Unknown genres are ignored.
  """
  @spec parse_repertoire(String.t()) :: [{String.t(), String.t()}]
  def parse_repertoire(content) do
    content
    |> String.split("\n")
    |> Enum.map(&(&1 |> String.trim() |> String.trim_leading("-") |> String.trim()))
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
    |> Enum.flat_map(fn line ->
      case String.split(String.downcase(line), "/", parts: 2) do
        [genre] -> [{String.trim(genre), "*"}]
        [genre, mode] -> [{String.trim(genre), String.trim(mode)}]
      end
    end)
    |> Enum.filter(fn {genre, _mode} -> GenreRegistry.valid?(genre) end)
    |> Enum.uniq()
  end

  # -- shared queries ----------------------------------------------------------

  # Loops of `kinds` (nil = all) closed, dropped, or missed in the window. A
  # missed loop came due in the window (before today) and was not resolved
  # by the window's end.
  defp loop_outcomes(scope, kinds) do
    {kind_sql, kind_params} =
      case kinds do
        nil ->
          {"", []}

        kinds ->
          start = scope.next_i + 1
          placeholders = Enum.map_join(0..(length(kinds) - 1), ", ", &"?#{start + &1}")
          {" AND kind IN (#{placeholders})", kinds}
      end

    cutoff = Enum.min([scope.to, Date.to_iso8601(Date.utc_today())])

    {:ok, [[closed, dropped, missed]]} =
      Store.raw_query(
        """
        SELECT
          COALESCE(SUM(CASE WHEN state = 'closed' AND #{date_window("closed_at", scope)} THEN 1 ELSE 0 END), 0),
          COALESCE(SUM(CASE WHEN state = 'dropped' AND #{date_window("closed_at", scope)} THEN 1 ELSE 0 END), 0),
          COALESCE(SUM(CASE WHEN due_at IS NOT NULL
                    AND substr(due_at, 1, 10) >= ?#{scope.from_i} AND substr(due_at, 1, 10) < ?#{scope.next_i}
                    AND (state = 'open' OR substr(closed_at, 1, 10) >= ?#{scope.to_i})
                THEN 1 ELSE 0 END), 0)
        FROM open_loops
        WHERE tenant_id = ?1 AND workspace_id IN (#{scope.ws_sql})#{kind_sql}
        """,
        scope.params ++ [cutoff] ++ kind_params
      )

    {closed, dropped, missed}
  end

  defp count_signals(scope) do
    {:ok, [[count]]} =
      Store.raw_query(
        "SELECT COUNT(*) FROM contexts c WHERE #{signals_where("c", scope)}",
        scope.params
      )

    count
  end

  defp count_events(scope, kind) do
    {:ok, [[count]]} =
      Store.raw_query(
        """
        SELECT COUNT(*) FROM signal_events
        WHERE tenant_id = ?1 AND workspace_id IN (#{scope.ws_sql}) AND kind = ?#{scope.next_i}
          AND #{date_window("occurred_at", scope)}
        """,
        scope.params ++ [kind]
      )

    count
  end

  defp count_marked_signals(scope) do
    case markers() do
      [] ->
        0

      markers ->
        start = scope.next_i

        clauses =
          markers
          |> Enum.with_index(start)
          |> Enum.map_join(" OR ", fn {_marker, i} ->
            "lower(substr(c.content, 1, 4000)) LIKE ?#{i}"
          end)

        {:ok, [[count]]} =
          Store.raw_query(
            "SELECT COUNT(*) FROM contexts c WHERE #{signals_where("c", scope)} AND (#{clauses})",
            scope.params ++ Enum.map(markers, &("%" <> &1 <> "%"))
          )

        count
    end
  end

  # Positional parameters: ?1 tenant, ?2.. workspaces, then from and to.
  defp scope(tenant_id, workspace_ids, from, to) do
    count = length(workspace_ids)

    %{
      tenant_id: tenant_id,
      workspace_ids: workspace_ids,
      ws_sql: Enum.map_join(2..(count + 1), ", ", &"?#{&1}"),
      from: Date.to_iso8601(from),
      to: Date.to_iso8601(to),
      from_i: count + 2,
      to_i: count + 3,
      next_i: count + 4,
      params: [tenant_id | workspace_ids] ++ [Date.to_iso8601(from), Date.to_iso8601(to)]
    }
  end

  defp signals_where(a, scope) do
    """
    #{a}.workspace_id IN (#{scope.ws_sql}) AND #{a}.type = 'signal' AND #{a}.archived_at IS NULL
      AND #{meta(a, "$.agent_action")} IS NULL
      AND #{meta(a, "$.cross_ref_from")} IS NULL
      AND COALESCE(#{meta(a, "$.direction")}, 'inbound') <> 'outbound'
      AND NOT EXISTS (SELECT 1 FROM signal_events pe WHERE pe.context_id = #{a}.id AND pe.kind = 'produced')
      AND substr(COALESCE(#{a}.created_at, #{a}.indexed_at), 1, 10) >= ?#{scope.from_i}
      AND substr(COALESCE(#{a}.created_at, #{a}.indexed_at), 1, 10) < ?#{scope.to_i}
    """
  end

  defp date_window(column, scope),
    do: "substr(#{column}, 1, 10) >= ?#{scope.from_i} AND substr(#{column}, 1, 10) < ?#{scope.to_i}"

  defp meta(a, path),
    do: "(CASE WHEN json_valid(#{a}.metadata) THEN json_extract(#{a}.metadata, '#{path}') END)"

  # -- shaping -----------------------------------------------------------------

  defp ratio_metric(name, numerator, denominator, extra \\ %{}) do
    if denominator > 0 do
      metric(
        name,
        Float.round(numerator / denominator, 3),
        Map.merge(%{numerator: numerator, denominator: denominator, status: "measured"}, extra)
      )
    else
      metric(name, nil, Map.merge(%{numerator: 0, denominator: 0, status: "no_data"}, extra))
    end
  end

  defp metric(name, value, extra) do
    definition = Enum.find(@definitions, &(&1.name == name))
    definition |> Map.put(:value, value) |> Map.merge(extra)
  end

  defp percentile([single], _p), do: single * 1.0

  defp percentile(sorted, p) do
    rank = p * (length(sorted) - 1)
    low = floor(rank)
    high = ceil(rank)
    a = Enum.at(sorted, low)
    b = Enum.at(sorted, high)
    (a + (b - a) * (rank - low)) * 1.0
  end

  defp empty(%{from: from, to: to}) do
    %{
      window: %{from: Date.to_iso8601(from), to: Date.to_iso8601(to)},
      signals_received: 0,
      metrics: Enum.map(@definitions, &Map.merge(&1, %{value: nil, status: "no_data"})),
      variety: %{r: nil, band: nil, status: "no_data", v_system: 0, v_disturbance: 0, gaps: []}
    }
  end
end
