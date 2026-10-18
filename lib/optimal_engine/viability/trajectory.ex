defmodule OptimalEngine.Viability.Trajectory do
  @moduledoc """
  Trajectory detection: an alert when a metric or a Signal flow gets worse
  for three periods in a row, before it fails.

  The last four 7-day periods ending today are compared (three steps). An
  alert fires when every step moved the wrong way: a falling rate, a rising
  re-encoding frequency, time to decode or bounce rate, a falling inbound or
  outward flow, or rising noise (falling average S/N) overall or in a unit.
  Units with fewer than 5 Signals in a period are not judged.
  """

  alias OptimalEngine.Store
  alias OptimalEngine.Viability.Metrics

  @periods 4
  @days 7
  @min_unit_signals 5

  @doc "The analysis windows, oldest first: `[%{from, to}]` with `to` exclusive."
  @spec windows(Date.t()) :: [%{from: Date.t(), to: Date.t()}]
  def windows(today) do
    end_date = Date.add(today, 1)

    for i <- (@periods - 1)..0//-1 do
      to = Date.add(end_date, -i * @days)
      %{from: Date.add(to, -@days), to: to}
    end
  end

  @doc "Computes the series and alerts for `workspace_ids` as of `today`."
  @spec analyze(String.t(), [String.t()], Date.t()) :: map()
  def analyze(_tenant_id, [], today),
    do: %{periods: Enum.map(windows(today), &label/1), series: %{}, alerts: []}

  def analyze(tenant_id, workspace_ids, today) do
    windows = windows(today)
    results = Enum.map(windows, &Metrics.compute(tenant_id, workspace_ids, &1))

    metric_series =
      for definition <- Metrics.definitions(), into: %{} do
        {definition.name, Enum.map(results, &Metrics.value(&1, definition.name))}
      end

    flows = flows(tenant_id, workspace_ids, windows)

    series =
      metric_series
      |> Map.put("inbound_signals", Enum.map(results, & &1.signals_received))
      |> Map.put("outward_signals", flows.outward)
      |> Map.put("average_sn_ratio", flows.sn)

    alerts =
      metric_alerts(metric_series) ++
        flow_alert("inbound_signals", "Inbound Signal flow", series["inbound_signals"], :higher) ++
        flow_alert("outward_signals", "Outward Signal flow (System 4)", flows.outward, :higher) ++
        flow_alert("average_sn_ratio", "Signal to noise ratio", flows.sn, :higher) ++
        unit_alerts(flows.units)

    %{periods: Enum.map(windows, &label/1), series: series, alerts: alerts}
  end

  @doc "True when the four values got worse at every step for `better`."
  @spec degrading?([number() | nil], :higher | :lower) :: boolean()
  def degrading?(values, better) do
    if Enum.any?(values, &is_nil/1) or length(values) < 4 do
      false
    else
      values
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.all?(fn [a, b] -> if better == :higher, do: b < a, else: b > a end)
    end
  end

  # ---------------------------------------------------------------------------

  defp metric_alerts(series) do
    Enum.flat_map(Metrics.definitions(), fn definition ->
      better = String.to_existing_atom(definition.better)
      values = series[definition.name]

      if degrading?(values, better) do
        [
          %{
            subject: "metric:" <> definition.name,
            kind: "metric",
            values: values,
            message:
              "#{humanize(definition.name)} got worse for 3 periods in a row (#{Enum.join(values, ", ")})."
          }
        ]
      else
        []
      end
    end)
  end

  defp flow_alert(subject, title, values, better) do
    if degrading?(values, better) do
      verb = if subject == "average_sn_ratio", do: "fell (noise rose)", else: "fell"

      [
        %{
          subject: "flow:" <> subject,
          kind: "flow",
          values: values,
          message: "#{title} #{verb} for 3 periods in a row (#{Enum.join(values, ", ")})."
        }
      ]
    else
      []
    end
  end

  defp unit_alerts(units) do
    Enum.flat_map(units, fn {unit, %{counts: counts, sn: sn}} ->
      judged? = Enum.all?(counts, &(&1 >= @min_unit_signals))

      volume =
        if Enum.at(counts, 0) >= @min_unit_signals and degrading?(counts, :higher) do
          [
            %{
              subject: "unit:" <> unit,
              kind: "unit_flow",
              values: counts,
              message:
                "Inbound Signals to #{unit} fell for 3 periods in a row (#{Enum.join(counts, ", ")})."
            }
          ]
        else
          []
        end

      noise =
        if judged? and degrading?(sn, :higher) do
          [
            %{
              subject: "unit_noise:" <> unit,
              kind: "unit_noise",
              values: sn,
              message: "Noise in #{unit} rose for 3 periods in a row (S/N #{Enum.join(sn, ", ")})."
            }
          ]
        else
          []
        end

      volume ++ noise
    end)
  end

  # Per period: outward Signals, average S/N, and per unit (node) counts and S/N.
  defp flows(tenant_id, workspace_ids, windows) do
    count = length(workspace_ids)
    ws = Enum.map_join(2..(count + 1), ", ", &"?#{&1}")
    starts = Enum.map(windows, &Date.to_iso8601(&1.from))
    final = windows |> List.last() |> Map.fetch!(:to) |> Date.to_iso8601()
    first_i = count + 2
    bucket = bucket_sql("substr(COALESCE(c.created_at, c.indexed_at), 1, 10)", first_i)
    day = "substr(COALESCE(c.created_at, c.indexed_at), 1, 10)"
    params = [tenant_id | workspace_ids] ++ starts ++ [final]
    final_i = first_i + @periods

    {:ok, rows} =
      Store.raw_query(
        """
        SELECT #{bucket} AS period, c.node, COUNT(*), AVG(c.sn_ratio),
          SUM(CASE WHEN (CASE WHEN json_valid(c.metadata) THEN json_extract(c.metadata, '$.outward') END) IS NOT NULL THEN 1 ELSE 0 END)
        FROM contexts c
        WHERE c.workspace_id IN (#{ws}) AND c.type = 'signal' AND c.archived_at IS NULL
          AND #{day} >= ?#{first_i} AND #{day} < ?#{final_i}
        GROUP BY 1, 2
        """,
        params
      )

    {:ok, event_rows} =
      Store.raw_query(
        """
        SELECT #{bucket_sql("substr(occurred_at, 1, 10)", first_i)}, COUNT(*) FROM signal_events
        WHERE tenant_id = ?1 AND workspace_id IN (#{ws}) AND kind = 'outward'
          AND substr(occurred_at, 1, 10) >= ?#{first_i} AND substr(occurred_at, 1, 10) < ?#{final_i}
        GROUP BY 1
        """,
        params
      )

    indexes = 0..(@periods - 1)
    events = Map.new(event_rows, fn [period, n] -> {period, n} end)

    outward =
      Enum.map(indexes, fn i ->
        Enum.reduce(rows, Map.get(events, i, 0), fn [period, _node, _n, _sn, out], acc ->
          if period == i, do: acc + out, else: acc
        end)
      end)

    sn =
      Enum.map(indexes, fn i ->
        {total, weighted} =
          Enum.reduce(rows, {0, 0.0}, fn [period, _node, n, avg, _out], {t, w} ->
            if period == i, do: {t + n, w + n * (avg || 0.0)}, else: {t, w}
          end)

        if total > 0, do: Float.round(weighted / total, 3)
      end)

    units =
      rows
      |> Enum.group_by(fn [_period, node, _n, _sn, _out] -> node end)
      |> Map.new(fn {node, node_rows} ->
        by_period = Map.new(node_rows, fn [period, _node, n, avg, _out] -> {period, {n, avg}} end)

        {node,
         %{
           counts: Enum.map(indexes, fn i -> by_period |> Map.get(i, {0, nil}) |> elem(0) end),
           sn:
             Enum.map(indexes, fn i ->
               case Map.get(by_period, i) do
                 {_n, avg} when is_number(avg) -> Float.round(avg, 3)
                 _ -> nil
               end
             end)
         }}
      end)

    %{outward: outward, sn: sn, units: units}
  end

  # Index of the period a day falls in, from the period start parameters.
  defp bucket_sql(day, first_i) do
    cases =
      (@periods - 1)..1//-1
      |> Enum.map_join(" ", fn i -> "WHEN #{day} >= ?#{first_i + i} THEN #{i}" end)

    "CASE #{cases} ELSE 0 END"
  end

  defp label(%{from: from, to: to}),
    do: %{from: Date.to_iso8601(from), to: Date.to_iso8601(Date.add(to, -1))}

  defp humanize(name), do: name |> String.replace("_", " ") |> String.capitalize()
end
