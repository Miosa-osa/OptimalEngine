defmodule OptimalEngine.Operating.Loops do
  @moduledoc """
  Open loops: commitments, owed replies, follow-ups, money to collect or pay,
  and decisions someone is waiting on, each with an owner, a counterparty, a
  due date, and the source it came from.

  Loops are created explicitly (`create/3`) or detected from a workspace's
  contexts (`extract/3`). Detection is deterministic: phrases that commit to
  an action ("I'll send", "we will follow up"), ask for one ("can you
  confirm"), or name money due ("invoice is due"), with a due date resolved
  from phrases such as "by Friday", "tomorrow", "end of week", or an ISO
  date, relative to the context's own date. A detected loop records its
  confidence and is deduplicated by a fingerprint of workspace, kind, and
  normalized title, so running extraction again never duplicates it.

  A loop closes explicitly (`close/4`), or when a later context carries the
  same `thread_ref` (a reply in the thread it came from; `close_answered/2`).
  """

  alias OptimalEngine.Store

  @kinds ~w(commitment owed_reply follow_up payment_due payment_owed decision_needed)
  @states ~w(open closed dropped)

  @type t :: map()

  @doc "The loop kinds."
  @spec kinds() :: [String.t()]
  def kinds, do: @kinds

  @doc """
  Creates a loop. Required: `workspace_id`, `title`. Optional: `kind`
  (default `commitment`), `owner`, `counterparty`, `due_at` (ISO date or
  datetime), `source_uri`, `source_context_id`, `thread_ref`, `confidence`,
  `metadata`. Creating the same loop twice returns the existing one.
  """
  @spec create(String.t(), map(), String.t()) :: {:ok, t()} | {:error, term()}
  def create(tenant_id, attrs, created_by) do
    attrs = stringify(attrs)
    kind = attrs["kind"] || "commitment"

    with :ok <- require_text(attrs, "workspace_id"),
         :ok <- require_text(attrs, "title"),
         :ok <- valid_kind(kind),
         {:ok, due_at} <- normalize_due(attrs["due_at"]) do
      id = "loop_" <> (:crypto.strong_rand_bytes(10) |> Base.url_encode64(padding: false))
      fingerprint = fingerprint(attrs["workspace_id"], kind, attrs["title"])

      {:ok, _} =
        Store.raw_query(
          """
          INSERT OR IGNORE INTO open_loops
            (id, tenant_id, workspace_id, kind, title, owner, counterparty, due_at, confidence,
             detected, fingerprint, source_uri, source_context_id, thread_ref, created_by, metadata)
          VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16)
          """,
          [
            id,
            tenant_id,
            attrs["workspace_id"],
            kind,
            String.slice(String.trim(attrs["title"]), 0, 300),
            attrs["owner"],
            attrs["counterparty"],
            due_at,
            attrs["confidence"] || 1.0,
            if(attrs["detected"] == true, do: 1, else: 0),
            fingerprint,
            attrs["source_uri"],
            attrs["source_context_id"],
            attrs["thread_ref"],
            created_by,
            Jason.encode!(attrs["metadata"] || %{})
          ]
        )

      by_fingerprint(tenant_id, attrs["workspace_id"], fingerprint)
    end
  end

  @doc """
  Lists loops. Options: `:workspace_ids` (list; nil means every workspace in
  the tenant), `:state` (default open), `:owner`, `:kind`, `:due_before`
  (ISO date), `:limit` (default 200).
  """
  @spec list(String.t(), keyword()) :: [t()]
  def list(tenant_id, opts \\ []) do
    state = Keyword.get(opts, :state, "open")

    filters =
      [
        {"state = ?", if(state == "all", do: nil, else: state)},
        {"owner = ?", opts[:owner]},
        {"kind = ?", opts[:kind]},
        {"due_at IS NOT NULL AND due_at < ?", opts[:due_before]}
      ]
      |> Enum.reject(fn {_sql, value} -> is_nil(value) end)

    {workspace_sql, workspace_params} =
      case opts[:workspace_ids] do
        nil -> {[], []}
        [] -> {["0"], []}
        ids -> {["workspace_id IN (" <> Enum.map_join(ids, ", ", fn _ -> "?" end) <> ")"], ids}
      end

    clauses = ["tenant_id = ?"] ++ Enum.map(filters, &elem(&1, 0)) ++ workspace_sql
    params = [tenant_id] ++ Enum.map(filters, &elem(&1, 1)) ++ workspace_params
    limit = opts |> Keyword.get(:limit, 200) |> max(1) |> min(1_000)

    {:ok, rows} =
      Store.raw_query(
        select_sql() <>
          " WHERE " <>
          number(Enum.join(clauses, " AND ")) <>
          " ORDER BY CASE WHEN due_at IS NULL THEN 1 ELSE 0 END, due_at, created_at LIMIT #{limit}",
        params
      )

    Enum.map(rows, &to_loop/1)
  end

  @doc "One loop in the tenant."
  @spec get(String.t(), String.t()) :: {:ok, t()} | {:error, :not_found}
  def get(tenant_id, id) do
    case Store.raw_query(select_sql() <> " WHERE tenant_id = ?1 AND id = ?2", [tenant_id, id]) do
      {:ok, [row]} -> {:ok, to_loop(row)}
      _ -> {:error, :not_found}
    end
  end

  @doc "Closes an open loop, optionally pointing at the source that closed it."
  @spec close(String.t(), String.t(), String.t(), map()) :: {:ok, t()} | {:error, atom()}
  def close(tenant_id, id, closed_by, attrs \\ %{}) do
    transition(tenant_id, id, "closed", closed_by, attrs)
  end

  @doc "Drops an open loop that will not happen."
  @spec drop(String.t(), String.t(), String.t(), map()) :: {:ok, t()} | {:error, atom()}
  def drop(tenant_id, id, dropped_by, attrs \\ %{}) do
    transition(tenant_id, id, "dropped", dropped_by, attrs)
  end

  @doc "Reopens a closed or dropped loop."
  @spec reopen(String.t(), String.t(), String.t()) :: {:ok, t()} | {:error, atom()}
  def reopen(tenant_id, id, by) do
    case Store.transaction(fn txn ->
           Store.txn_execute(
             txn,
             """
             UPDATE open_loops SET state = 'open', closed_at = NULL, closed_by = NULL, close_reason = NULL,
               close_source_uri = NULL, updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now'),
               metadata = json_set(metadata, '$.reopened_by', ?3)
             WHERE tenant_id = ?1 AND id = ?2 AND state != 'open'
             """,
             [tenant_id, id, by]
           )
         end) do
      {:ok, 1} -> get(tenant_id, id)
      _ -> {:error, :not_closed}
    end
  end

  @doc """
  Detects loops in a workspace's contexts. Options: `:since` (ISO datetime,
  default 30 days ago), `:limit` (contexts scanned, default 500). Returns
  the loops created or matched.
  """
  @spec extract(String.t(), String.t(), keyword()) :: {:ok, [t()]}
  def extract(tenant_id, workspace_id, opts \\ []) do
    since =
      Keyword.get_lazy(opts, :since, fn ->
        DateTime.utc_now() |> DateTime.add(-30 * 86_400) |> DateTime.to_iso8601()
      end)

    limit = opts |> Keyword.get(:limit, 500) |> max(1) |> min(5_000)

    {:ok, rows} =
      Store.raw_query(
        """
        SELECT id, title, content, COALESCE(created_at, modified_at), uri
        FROM contexts
        WHERE tenant_id = ?1 AND workspace_id = ?2 AND COALESCE(created_at, modified_at, '') >= ?3
        ORDER BY COALESCE(created_at, modified_at) DESC
        LIMIT ?4
        """,
        [tenant_id, workspace_id, since, limit]
      )

    loops =
      Enum.flat_map(rows, fn [id, title, content, created_at, uri] ->
        reference = reference_date(created_at)

        "#{title}\n#{content}"
        |> detect(reference)
        |> Enum.flat_map(fn found ->
          attrs =
            Map.merge(found, %{
              "workspace_id" => workspace_id,
              "source_context_id" => id,
              "source_uri" => present(uri) || "optimal://#{workspace_id}/contexts/#{id}",
              "detected" => true
            })

          case create(tenant_id, attrs, "engine:loop-extractor") do
            {:ok, loop} -> [loop]
            _ -> []
          end
        end)
      end)

    {:ok, Enum.uniq_by(loops, & &1.id)}
  end

  @doc """
  Detects loop candidates in `text`, resolving due dates relative to
  `reference` (a Date). Returns maps with `kind`, `title`, `due_at`,
  `confidence`.
  """
  @spec detect(String.t(), Date.t()) :: [map()]
  def detect(text, reference \\ Date.utc_today()) when is_binary(text) do
    text
    |> sentences()
    |> Enum.flat_map(fn sentence ->
      case classify(sentence) do
        nil ->
          []

        {kind, confidence} ->
          due = due_date(sentence, reference)

          [
            %{
              "kind" => kind,
              "title" => sentence,
              "due_at" => due && Date.to_iso8601(due),
              "confidence" =>
                if(due, do: Float.round(min(confidence + 0.1, 1.0), 2), else: confidence)
            }
          ]
      end
    end)
  end

  @doc """
  Closes open loops answered by a later context in the same thread: a
  context whose `thread_ref` metadata equals the loop's and that was created
  after it. Returns the closed loops.
  """
  @spec close_answered(String.t(), String.t()) :: {:ok, [t()]}
  def close_answered(tenant_id, workspace_id) do
    {:ok, rows} =
      Store.raw_query(
        """
        SELECT l.id, c.id, c.uri FROM open_loops l
        JOIN contexts c ON c.tenant_id = l.tenant_id AND c.workspace_id = l.workspace_id
          AND json_extract(c.metadata, '$.thread_ref') = l.thread_ref
          AND COALESCE(c.created_at, c.modified_at) > l.created_at
          AND c.id != COALESCE(l.source_context_id, '')
        WHERE l.tenant_id = ?1 AND l.workspace_id = ?2 AND l.state = 'open' AND l.thread_ref IS NOT NULL
        """,
        [tenant_id, workspace_id]
      )

    closed =
      Enum.flat_map(Enum.uniq_by(rows, &hd/1), fn [loop_id, context_id, uri] ->
        case close(tenant_id, loop_id, "engine:loop-extractor", %{
               "reason" => "answered in thread",
               "source_uri" => present(uri) || "optimal://#{workspace_id}/contexts/#{context_id}"
             }) do
          {:ok, loop} -> [loop]
          _ -> []
        end
      end)

    {:ok, closed}
  end

  # ---------------------------------------------------------------------------
  # Detection

  @commit ~r/\b(i|we)\s*('ll|’ll| will| shall| am going to| are going to| plan to)\s+(send|share|deliver|follow up|get back|review|schedule|prepare|draft|call|email|finish|ship|submit|confirm|introduce|book|update)\b/iu
  @ask ~r/\b(can|could|would) you\s+(please\s+)?(send|share|confirm|review|let (me|us) know|sign|approve|check)\b|\bplease\s+(send|share|confirm|review|sign|approve|let (me|us) know)\b/iu
  @owed_money ~r/\b(we|i)\s+(owe|need to pay|must pay)\b|\b(bill|invoice|payment)\b.{0,40}\b(we owe|to pay|payable)\b/iu
  @money_due ~r/\b(invoice|payment|retainer|deposit|balance)\b.{0,50}\b(due|outstanding|overdue|unpaid|owed)\b/iu
  @decision ~r/\b(need(s)? (a|your) decision|waiting (on|for) (a|your) decision|decide (by|before))\b/iu

  defp classify(sentence) do
    cond do
      Regex.match?(@owed_money, sentence) -> {"payment_due", 0.7}
      Regex.match?(@money_due, sentence) -> {"payment_owed", 0.6}
      Regex.match?(@decision, sentence) -> {"decision_needed", 0.6}
      Regex.match?(@commit, sentence) -> {"commitment", 0.7}
      Regex.match?(@ask, sentence) -> {"owed_reply", 0.6}
      true -> nil
    end
  end

  defp sentences(text) do
    text
    |> String.split(~r/(?<=[.!?])\s+|\n+/u, trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&(String.length(&1) in 12..400))
  end

  @weekdays %{
    "monday" => 1,
    "tuesday" => 2,
    "wednesday" => 3,
    "thursday" => 4,
    "friday" => 5,
    "saturday" => 6,
    "sunday" => 7
  }

  @months %{
    "jan" => 1,
    "feb" => 2,
    "mar" => 3,
    "apr" => 4,
    "may" => 5,
    "jun" => 6,
    "jul" => 7,
    "aug" => 8,
    "sep" => 9,
    "oct" => 10,
    "nov" => 11,
    "dec" => 12
  }

  @doc false
  def due_date(sentence, reference) do
    text = String.downcase(sentence)

    cond do
      match = Regex.run(~r/\b(\d{4})-(\d{2})-(\d{2})\b/, text) ->
        [_, y, m, d] = match
        date_or_nil(String.to_integer(y), String.to_integer(m), String.to_integer(d))

      Regex.match?(~r/\b(today|tonight|eod|end of (the )?day)\b/, text) ->
        reference

      Regex.match?(~r/\btomorrow\b/, text) ->
        Date.add(reference, 1)

      Regex.match?(~r/\b(end of (the )?week|eow|this week)\b/, text) ->
        Date.add(reference, 5 - Date.day_of_week(reference)) |> not_before(reference)

      Regex.match?(~r/\bnext week\b/, text) ->
        Date.add(reference, 8 - Date.day_of_week(reference))

      match =
          Regex.run(
            ~r/\b(by|on|before|until|this|next)?\s*(monday|tuesday|wednesday|thursday|friday|saturday|sunday)\b/,
            text
          ) ->
        # "next <day>" is that day in the following calendar week; a bare or
        # "this" day is its next occurrence after the reference day.
        target = @weekdays[List.last(match)]

        if Enum.at(match, 1) == "next" do
          reference |> Date.add(8 - Date.day_of_week(reference)) |> Date.add(target - 1)
        else
          days = rem(target - Date.day_of_week(reference) + 7, 7)
          Date.add(reference, if(days == 0, do: 7, else: days))
        end

      match =
          Regex.run(
            ~r/\b(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?\s+(\d{1,2})(st|nd|rd|th)?\b/,
            text
          ) ->
        [_, month, day | _] = match
        candidate = date_or_nil(reference.year, @months[month], String.to_integer(day))

        cond do
          is_nil(candidate) ->
            nil

          Date.compare(candidate, Date.add(reference, -60)) == :lt ->
            date_or_nil(reference.year + 1, @months[month], String.to_integer(day))

          true ->
            candidate
        end

      true ->
        nil
    end
  end

  defp not_before(date, reference),
    do: if(Date.compare(date, reference) == :lt, do: reference, else: date)

  defp date_or_nil(year, month, day) do
    case Date.new(year, month, day) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp reference_date(nil), do: Date.utc_today()

  defp reference_date(value) do
    case Date.from_iso8601(String.slice(value, 0, 10)) do
      {:ok, date} -> date
      _ -> Date.utc_today()
    end
  end

  # ---------------------------------------------------------------------------

  defp transition(tenant_id, id, state, by, attrs) when state in @states do
    attrs = stringify(attrs)

    case Store.transaction(fn txn ->
           Store.txn_execute(
             txn,
             """
             UPDATE open_loops SET state = ?3, closed_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now'), closed_by = ?4,
               close_reason = ?5, close_source_uri = ?6, updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
             WHERE tenant_id = ?1 AND id = ?2 AND state = 'open'
             """,
             [tenant_id, id, state, by, attrs["reason"], attrs["source_uri"]]
           )
         end) do
      {:ok, 1} ->
        get(tenant_id, id)

      _ ->
        case get(tenant_id, id) do
          {:ok, _} -> {:error, :not_open}
          error -> error
        end
    end
  end

  defp by_fingerprint(tenant_id, workspace_id, fingerprint) do
    case Store.raw_query(
           select_sql() <> " WHERE tenant_id = ?1 AND workspace_id = ?2 AND fingerprint = ?3",
           [tenant_id, workspace_id, fingerprint]
         ) do
      {:ok, [row]} -> {:ok, to_loop(row)}
      _ -> {:error, :not_found}
    end
  end

  defp fingerprint(workspace_id, kind, title) do
    normalized =
      title
      |> String.downcase()
      |> String.replace(~r/[^[:alnum:]]+/u, " ")
      |> String.trim()

    :crypto.hash(:sha256, Enum.join([workspace_id, kind, normalized], "|"))
    |> Base.encode16(case: :lower)
  end

  defp normalize_due(nil), do: {:ok, nil}
  defp normalize_due(""), do: {:ok, nil}

  defp normalize_due(value) when is_binary(value) do
    cond do
      match?({:ok, _}, Date.from_iso8601(value)) -> {:ok, value}
      match?({:ok, _, _}, DateTime.from_iso8601(value)) -> {:ok, value}
      true -> {:error, :invalid_due_at}
    end
  end

  defp normalize_due(_value), do: {:error, :invalid_due_at}

  defp require_text(attrs, field) do
    if is_binary(attrs[field]) and String.trim(attrs[field]) != "",
      do: :ok,
      else: {:error, String.to_atom(field <> "_required")}
  end

  defp valid_kind(kind) when kind in @kinds, do: :ok
  defp valid_kind(_kind), do: {:error, :invalid_kind}

  defp present(value) when is_binary(value) and value != "", do: value
  defp present(_value), do: nil

  defp stringify(attrs), do: Map.new(attrs, fn {key, value} -> {to_string(key), value} end)

  # Positional "?" placeholders become numbered ones in order.
  defp number(sql) do
    sql
    |> String.split("?")
    |> Enum.with_index()
    |> Enum.map_join(fn
      {part, 0} -> part
      {part, index} -> "?#{index}" <> part
    end)
  end

  defp select_sql do
    """
    SELECT id, tenant_id, workspace_id, kind, title, owner, counterparty, due_at, state, confidence,
           detected, source_uri, source_context_id, thread_ref, created_by, created_at, updated_at,
           closed_at, closed_by, close_reason, close_source_uri, metadata
    FROM open_loops
    """
  end

  defp to_loop([
         id,
         tenant_id,
         workspace_id,
         kind,
         title,
         owner,
         counterparty,
         due_at,
         state,
         confidence,
         detected,
         source_uri,
         source_context_id,
         thread_ref,
         created_by,
         created_at,
         updated_at,
         closed_at,
         closed_by,
         close_reason,
         close_source_uri,
         metadata
       ]) do
    %{
      id: id,
      tenant_id: tenant_id,
      workspace_id: workspace_id,
      kind: kind,
      title: title,
      owner: owner,
      counterparty: counterparty,
      due_at: due_at,
      state: state,
      confidence: confidence,
      detected: detected == 1,
      source_uri: source_uri,
      source_context_id: source_context_id,
      thread_ref: thread_ref,
      created_by: created_by,
      created_at: created_at,
      updated_at: updated_at,
      closed_at: closed_at,
      closed_by: closed_by,
      close_reason: close_reason,
      close_source_uri: close_source_uri,
      metadata: Jason.decode!(metadata || "{}")
    }
  end
end
