defmodule OptimalEngine.Operating.Rhythm do
  @moduledoc """
  Daily, weekly, and monthly rhythm notes per workspace, in the workspace's
  time zone.

  Each cadence has a template (the Engine default, or one the workspace sets
  with `put_template/6`). `current/4` returns the note for the current
  period, generating it from the template the first time it is asked for.
  Generated priorities always come from the workspace's open loops at that
  moment; a note never copies a previous period's priorities. Notes are
  date-named (`2026-10-18`, `2026-W42`, `2026-10`) and editable with
  `put_note/6`.

  Template placeholders: `{{date}}`, `{{weekday}}`, `{{period}}`,
  `{{workspace}}`, `{{priorities}}`, `{{due}}`, `{{waiting}}`.
  """

  alias OptimalEngine.Operating.Loops
  alias OptimalEngine.Store

  @cadences ~w(daily weekly monthly)

  @templates %{
    "daily" => """
    # {{weekday}}, {{date}} ({{workspace}})

    ## Top 3 today
    {{priorities}}

    ## Due soon
    {{due}}

    ## Waiting on others
    {{waiting}}

    ## Notes
    """,
    "weekly" => """
    # Week {{period}} ({{workspace}})

    ## Outcomes this week
    {{priorities}}

    ## Due this week
    {{due}}

    ## Waiting on others
    {{waiting}}

    ## Review
    - What moved:
    - What stalled:
    - What changes next week:
    """,
    "monthly" => """
    # {{period}} ({{workspace}})

    ## Outcomes this month
    {{priorities}}

    ## Commitments due
    {{due}}

    ## Review
    - Money in and out:
    - Relationships to tend:
    - What to stop:
    """
  }

  @doc "The cadences."
  @spec cadences() :: [String.t()]
  def cadences, do: @cadences

  @doc "The period key for `cadence` on `date`."
  @spec period(String.t(), Date.t()) :: String.t()
  def period("daily", date), do: Date.to_iso8601(date)

  def period("weekly", date) do
    {year, week} = :calendar.iso_week_number(Date.to_erl(date))
    "#{year}-W#{String.pad_leading(Integer.to_string(week), 2, "0")}"
  end

  def period("monthly", date), do: date |> Date.to_iso8601() |> String.slice(0, 7)

  @doc "The workspace's time zone (its daily template's, else Etc/UTC)."
  @spec timezone(String.t(), String.t()) :: String.t()
  def timezone(tenant_id, workspace_id) do
    case Store.raw_query(
           "SELECT timezone FROM rhythm_templates WHERE tenant_id = ?1 AND workspace_id = ?2 ORDER BY cadence LIMIT 1",
           [tenant_id, workspace_id]
         ) do
      {:ok, [[tz]]} when is_binary(tz) -> tz
      _ -> "Etc/UTC"
    end
  end

  @doc "Today's date in `timezone` (falls back to UTC for an unknown zone)."
  @spec today(String.t()) :: {Date.t(), String.t()}
  def today(timezone) do
    case DateTime.now(timezone) do
      {:ok, now} -> {DateTime.to_date(now), timezone}
      _ -> {Date.utc_today(), "Etc/UTC"}
    end
  end

  @doc """
  The note for the current period of `cadence`, generated on first request.
  Options: `:timezone` (overrides the workspace's), `:date` (for tests),
  `:generate` (`false` returns the note a first request would write, with
  `stored: false`, and writes nothing). A stored note has `stored: true`.
  """
  @spec current(String.t(), String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, atom()}
  def current(tenant_id, workspace_id, cadence \\ "daily", opts \\ [])

  def current(tenant_id, workspace_id, cadence, opts) when cadence in @cadences do
    {date, timezone} =
      case opts[:date] do
        %Date{} = date -> {date, opts[:timezone] || timezone(tenant_id, workspace_id)}
        nil -> today(opts[:timezone] || timezone(tenant_id, workspace_id))
      end

    key = period(cadence, date)
    generate? = Keyword.get(opts, :generate, true)

    case note(tenant_id, workspace_id, cadence, key) do
      {:ok, note} ->
        {:ok, Map.merge(note, %{timezone: timezone, stored: true})}

      {:error, :not_found} when not generate? ->
        {:ok,
         %{
           workspace_id: workspace_id,
           cadence: cadence,
           period: key,
           content: render(tenant_id, workspace_id, cadence, date, key),
           generated: true,
           stored: false,
           timezone: timezone
         }}

      {:error, :not_found} ->
        content = render(tenant_id, workspace_id, cadence, date, key)

        {:ok, _} =
          Store.raw_query(
            """
            INSERT OR IGNORE INTO rhythm_notes (tenant_id, workspace_id, cadence, period, content, generated, updated_by)
            VALUES (?1, ?2, ?3, ?4, ?5, 1, 'engine:rhythm')
            """,
            [tenant_id, workspace_id, cadence, key, content]
          )

        with {:ok, note} <- note(tenant_id, workspace_id, cadence, key),
             do: {:ok, Map.merge(note, %{timezone: timezone, stored: true})}
    end
  end

  def current(_tenant_id, _workspace_id, _cadence, _opts), do: {:error, :invalid_cadence}

  @doc "A stored note."
  @spec note(String.t(), String.t(), String.t(), String.t()) :: {:ok, map()} | {:error, :not_found}
  def note(tenant_id, workspace_id, cadence, period) do
    case Store.raw_query(
           """
           SELECT cadence, period, content, generated, created_at, updated_at, updated_by FROM rhythm_notes
           WHERE tenant_id = ?1 AND workspace_id = ?2 AND cadence = ?3 AND period = ?4
           """,
           [tenant_id, workspace_id, cadence, period]
         ) do
      {:ok, [[cadence, period, content, generated, created_at, updated_at, by]]} ->
        {:ok,
         %{
           workspace_id: workspace_id,
           cadence: cadence,
           period: period,
           content: content,
           generated: generated == 1,
           created_at: created_at,
           updated_at: updated_at,
           updated_by: by
         }}

      _ ->
        {:error, :not_found}
    end
  end

  @doc "Notes for a workspace and cadence, newest first."
  @spec list(String.t(), String.t(), String.t(), pos_integer()) :: [map()]
  def list(tenant_id, workspace_id, cadence \\ "daily", limit \\ 30) do
    {:ok, rows} =
      Store.raw_query(
        "SELECT period FROM rhythm_notes WHERE tenant_id = ?1 AND workspace_id = ?2 AND cadence = ?3 ORDER BY period DESC LIMIT ?4",
        [tenant_id, workspace_id, cadence, limit]
      )

    Enum.flat_map(rows, fn [period] ->
      case note(tenant_id, workspace_id, cadence, period) do
        {:ok, note} -> [note]
        _ -> []
      end
    end)
  end

  @doc "Writes a note (an edit by a person or agent)."
  @spec put_note(String.t(), String.t(), String.t(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, atom()}
  def put_note(tenant_id, workspace_id, cadence, period, content, updated_by)
      when cadence in @cadences and is_binary(content) do
    {:ok, _} =
      Store.raw_query(
        """
        INSERT INTO rhythm_notes (tenant_id, workspace_id, cadence, period, content, generated, updated_by)
        VALUES (?1, ?2, ?3, ?4, ?5, 0, ?6)
        ON CONFLICT(tenant_id, workspace_id, cadence, period) DO UPDATE SET
          content = excluded.content, generated = 0, updated_by = excluded.updated_by,
          updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
        """,
        [tenant_id, workspace_id, cadence, period, content, updated_by]
      )

    note(tenant_id, workspace_id, cadence, period)
  end

  def put_note(_tenant_id, _workspace_id, _cadence, _period, _content, _by),
    do: {:error, :invalid_cadence}

  @doc "Sets the workspace's template and time zone for a cadence."
  @spec put_template(String.t(), String.t(), String.t(), String.t(), String.t(), String.t()) ::
          :ok | {:error, atom()}
  def put_template(tenant_id, workspace_id, cadence, content, timezone, updated_by)
      when cadence in @cadences and is_binary(content) do
    if match?({:ok, _}, DateTime.now(timezone)) do
      {:ok, _} =
        Store.raw_query(
          """
          INSERT INTO rhythm_templates (tenant_id, workspace_id, cadence, content, timezone, updated_by)
          VALUES (?1, ?2, ?3, ?4, ?5, ?6)
          ON CONFLICT(tenant_id, workspace_id, cadence) DO UPDATE SET
            content = excluded.content, timezone = excluded.timezone, updated_by = excluded.updated_by,
            updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
          """,
          [tenant_id, workspace_id, cadence, content, timezone, updated_by]
        )

      :ok
    else
      {:error, :unknown_timezone}
    end
  end

  def put_template(_tenant_id, _workspace_id, _cadence, _content, _timezone, _by),
    do: {:error, :invalid_cadence}

  @doc "The template text for a cadence."
  @spec template(String.t(), String.t(), String.t()) :: String.t()
  def template(tenant_id, workspace_id, cadence) do
    case Store.raw_query(
           "SELECT content FROM rhythm_templates WHERE tenant_id = ?1 AND workspace_id = ?2 AND cadence = ?3",
           [tenant_id, workspace_id, cadence]
         ) do
      {:ok, [[content]]} -> content
      _ -> @templates[cadence]
    end
  end

  # ---------------------------------------------------------------------------

  defp render(tenant_id, workspace_id, cadence, date, key) do
    horizon =
      case cadence do
        "daily" -> 3
        "weekly" -> 7
        "monthly" -> 31
      end

    loops = Loops.list(tenant_id, workspace_ids: [workspace_id], state: "open", limit: 200)
    due_limit = Date.add(date, horizon) |> Date.to_iso8601()

    mine = Enum.reject(loops, &(&1.kind == "owed_reply" and is_nil(&1.owner)))

    priorities =
      mine
      |> Enum.sort_by(&{is_nil(&1.due_at), &1.due_at || "", -(&1.confidence || 0)})
      |> Enum.take(3)
      |> bullets("No open commitments. Pick the most important outcome for today.")

    due =
      loops
      |> Enum.filter(&(&1.due_at && String.slice(&1.due_at, 0, 10) <= due_limit))
      |> bullets("Nothing due in the next #{horizon} days.")

    waiting =
      loops
      |> Enum.filter(&(&1.kind in ["owed_reply", "decision_needed"] and &1.counterparty))
      |> bullets("Nobody is waiting on a reply.")

    template(tenant_id, workspace_id, cadence)
    |> String.replace("{{date}}", Date.to_iso8601(date))
    |> String.replace("{{weekday}}", weekday(date))
    |> String.replace("{{period}}", key)
    |> String.replace("{{workspace}}", workspace_id)
    |> String.replace("{{priorities}}", priorities)
    |> String.replace("{{due}}", due)
    |> String.replace("{{waiting}}", waiting)
  end

  defp bullets([], empty), do: "- " <> empty

  defp bullets(loops, _empty) do
    Enum.map_join(loops, "\n", fn loop ->
      due = if loop.due_at, do: " (due #{String.slice(loop.due_at, 0, 10)})", else: ""
      who = if loop.counterparty, do: " with #{loop.counterparty}", else: ""
      "- #{loop.title}#{who}#{due} [#{loop.source_uri || loop.id}]"
    end)
  end

  @weekdays ~w(Monday Tuesday Wednesday Thursday Friday Saturday Sunday)
  defp weekday(date), do: Enum.at(@weekdays, Date.day_of_week(date) - 1)
end
