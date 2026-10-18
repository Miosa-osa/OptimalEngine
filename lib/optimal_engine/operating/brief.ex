defmodule OptimalEngine.Operating.Brief do
  @moduledoc """
  The decision brief: what needs a decision or an action today, across one
  workspace or every workspace the caller may see, each item with its
  sources and a suggested next action.

  Items, highest priority first:

  1. `overdue` - open loops past their due date.
  2. `due_soon` - open loops due within three days.
  3. `owed_reply` - someone asked and is waiting.
  4. `money` - payments due or owed.
  5. `decision_needed` - decisions someone is waiting on.
  6. `approval` - authority requests waiting for an approver.
  7. `stalled` - open loops with no due date and no change for 14 days.
  8. `review` - claims waiting for review.

  The same brief feeds agents (Optimal chat), voice, and scheduled email.
  """

  alias OptimalEngine.Authority.Requests
  alias OptimalEngine.Operating.Loops
  alias OptimalEngine.Store

  @doc """
  Builds the brief. Options: `:workspace_ids` (nil means every workspace in
  the tenant), `:date` (default today, UTC), `:limit` (items, default 25).
  """
  @spec build(String.t(), keyword()) :: map()
  def build(tenant_id, opts \\ []) do
    date = Keyword.get(opts, :date, Date.utc_today())
    today = Date.to_iso8601(date)
    soon = date |> Date.add(3) |> Date.to_iso8601()
    stale = date |> Date.add(-14) |> Date.to_iso8601()
    workspace_ids = opts[:workspace_ids]
    loops = Loops.list(tenant_id, workspace_ids: workspace_ids, state: "open", limit: 1_000)

    loop_items =
      Enum.flat_map(loops, fn loop ->
        due = loop.due_at && String.slice(loop.due_at, 0, 10)

        category =
          cond do
            due && due < today -> "overdue"
            due && due <= soon -> "due_soon"
            loop.kind == "owed_reply" -> "owed_reply"
            loop.kind in ["payment_due", "payment_owed"] -> "money"
            loop.kind == "decision_needed" -> "decision_needed"
            is_nil(due) and String.slice(loop.updated_at || "", 0, 10) < stale -> "stalled"
            true -> nil
          end

        if category, do: [loop_item(category, loop, today)], else: []
      end)

    items =
      (loop_items ++
         approval_items(tenant_id, workspace_ids) ++
         review_items(tenant_id, workspace_ids) ++
         audit_items(tenant_id, workspace_ids))
      |> Enum.sort_by(&{rank(&1.category), &1[:due_at] || "9999"})
      |> Enum.take(Keyword.get(opts, :limit, 25))

    %{
      date: today,
      scope: if(workspace_ids, do: workspace_ids, else: "tenant"),
      items: items,
      counts: Enum.frequencies_by(items, & &1.category),
      open_loops: length(loops)
    }
  end

  defp loop_item(category, loop, today) do
    %{
      category: category,
      title: loop.title,
      kind: loop.kind,
      loop_id: loop.id,
      workspace_id: loop.workspace_id,
      owner: loop.owner,
      counterparty: loop.counterparty,
      due_at: loop.due_at,
      sources: Enum.reject([loop.source_uri], &is_nil/1),
      next_action: next_action(category, loop, today)
    }
  end

  defp next_action("overdue", loop, _today),
    do:
      "Do it now or agree a new date#{with_who(loop.counterparty)}, then close or update the loop."

  defp next_action("due_soon", loop, _today),
    do: "Block time before #{String.slice(loop.due_at, 0, 10)}#{with_who(loop.counterparty)}."

  defp next_action("owed_reply", loop, _today),
    do: "Reply#{to_who(loop.counterparty)}, then close the loop with the reply's source."

  defp next_action("money", %{kind: "payment_due"}, _today),
    do: "Pay or schedule the payment, then close the loop."

  defp next_action("money", loop, _today),
    do: "Send the invoice or a reminder#{to_who(loop.counterparty)}."

  defp next_action("decision_needed", loop, _today),
    do: "Decide and record the decision#{with_who(loop.counterparty)}."

  defp next_action("stalled", _loop, _today), do: "Give it a date, hand it off, or drop it."

  defp with_who(nil), do: ""
  defp with_who(who), do: " with #{who}"
  defp to_who(nil), do: ""
  defp to_who(who), do: " to #{who}"

  defp approval_items(tenant_id, workspace_ids) do
    tenant_id
    |> Requests.list(status: "pending")
    |> Enum.filter(&(is_nil(workspace_ids) or &1.workspace_id in workspace_ids))
    |> Enum.map(fn request ->
      %{
        category: "approval",
        title: "#{request.subject} asks to #{request.action} #{request.resource}",
        workspace_id: request.workspace_id,
        request_id: request.id,
        sources: ["optimal://authority/requests/#{request.id}"],
        next_action:
          "Approve or deny the request (POST /api/authority/requests/#{request.id}/approve)."
      }
    end)
  end

  defp review_items(tenant_id, workspace_ids) do
    {sql, params} =
      case workspace_ids do
        nil ->
          {"SELECT workspace_id, COUNT(*) FROM claims WHERE tenant_id = ?1 AND lifecycle_state = 'pending' AND review_status = 'unreviewed' GROUP BY workspace_id",
           [tenant_id]}

        ids ->
          placeholders = ids |> Enum.with_index(2) |> Enum.map_join(", ", fn {_, i} -> "?#{i}" end)

          {"SELECT workspace_id, COUNT(*) FROM claims WHERE tenant_id = ?1 AND lifecycle_state = 'pending' AND review_status = 'unreviewed' AND workspace_id IN (#{placeholders}) GROUP BY workspace_id",
           [tenant_id | ids]}
      end

    case Store.raw_query(sql, params) do
      {:ok, rows} ->
        for [workspace_id, count] <- rows, count > 0 do
          %{
            category: "review",
            title: "#{count} claims waiting for review in #{workspace_id}",
            workspace_id: workspace_id,
            sources: ["optimal://#{workspace_id}/memory-core/claim-review"],
            next_action: "Review the claims so only verified facts are used."
          }
        end

      _ ->
        []
    end
  end

  # Flagged System 3* audit samples, one item per workspace.
  defp audit_items(tenant_id, workspace_ids) do
    {filter, params} =
      case workspace_ids do
        nil ->
          {"", [tenant_id]}

        ids ->
          placeholders = ids |> Enum.with_index(2) |> Enum.map_join(", ", fn {_, i} -> "?#{i}" end)
          {" AND workspace_id IN (#{placeholders})", [tenant_id | ids]}
      end

    case Store.raw_query(
           "SELECT workspace_id, COUNT(*) FROM audit_samples WHERE tenant_id = ?1 AND state = 'flagged'#{filter} GROUP BY workspace_id",
           params
         ) do
      {:ok, rows} ->
        for [workspace_id, count] <- rows, count > 0 do
          %{
            category: "audit",
            title: "#{count} audit samples flagged in #{workspace_id}",
            workspace_id: workspace_id,
            sources: ["optimal://#{workspace_id}/viability/audit"],
            next_action:
              "Confirm or dismiss them (GET /api/viability/audit?workspace=#{workspace_id}&state=flagged)."
          }
        end

      _ ->
        []
    end
  end

  @order ~w(overdue due_soon owed_reply money decision_needed approval stalled review audit)
  defp rank(category), do: Enum.find_index(@order, &(&1 == category)) || 99
end
