defmodule OptimalEngine.MemoryCore.ContextPackageSweep do
  @moduledoc """
  Finds the Context Packages a refresh stored beyond their own authorization
  envelope, and empties them.

  A refresh used to read with the authorization filter off, so the package it
  stored held objects its recorded envelope does not admit. Those packages are
  the ones a refresh made (their metadata names the package they replaced), and
  each is checked here the way governed recall checks an object: every object
  it returned must be admitted by the envelope recorded on it.

  A package that fails the check, or whose envelope or object list cannot be
  read, is emptied (`Store.scrub_context_package_content/2`): its links,
  summaries and assembled sections go; its query, plan and envelope stay. A
  package still in use becomes stale, so the next refresh rebuilds it inside
  its envelope; one that was already replaced stays replaced; one whose
  envelope cannot be read leaves the stale list as failed.

  Run once after upgrading, with `mix optimal.context.sweep`. It is safe to
  repeat: a package that passes is left alone.
  """

  alias OptimalEngine.MemoryCore.{RetrievalCoordinator, SecurityLabels, Store}
  alias OptimalEngine.Store, as: BaseStore

  @page 200

  # The tables the links of a package point at, by link type.
  @object_tables %{
    "fact" => "facts",
    "memory_object" => "memory_objects",
    "asset_extraction" => "asset_extractions",
    "generalized_workflow" => "generalized_workflows",
    "skill_package" => "skill_packages"
  }

  @type offender :: %{
          id: String.t(),
          tenant_id: String.t(),
          workspace_id: String.t(),
          reason: String.t(),
          objects_outside: non_neg_integer()
        }

  @type summary :: %{
          scanned: non_neg_integer(),
          offenders: [offender()],
          scrubbed: non_neg_integer()
        }

  @doc """
  Sweeps the packages of `:tenant_id` and `:workspace_id` (all when omitted).
  With `dry_run: true` nothing is written.
  """
  @spec run(keyword()) :: {:ok, summary()} | {:error, term()}
  def run(opts \\ []) do
    with {:ok, scanned, offenders} <- scan(opts, "", 0, []) do
      if Keyword.get(opts, :dry_run, false) do
        {:ok, %{scanned: scanned, offenders: public(offenders), scrubbed: 0}}
      else
        scrub(scanned, offenders)
      end
    end
  end

  defp scan(opts, after_id, scanned, offenders) do
    with {:ok, rows} <- suspects(opts, after_id) do
      found = rows |> Enum.map(&examine/1) |> Enum.reject(&is_nil/1)
      scanned = scanned + length(rows)
      offenders = offenders ++ found

      case List.last(rows) do
        nil -> {:ok, scanned, offenders}
        [last_id | _] when length(rows) == @page -> scan(opts, last_id, scanned, offenders)
        _ -> {:ok, scanned, offenders}
      end
    end
  end

  defp suspects(opts, after_id) do
    {clauses, params} =
      [tenant_id: Keyword.get(opts, :tenant_id), workspace_id: Keyword.get(opts, :workspace_id)]
      |> Enum.reject(fn {_column, value} -> is_nil(value) end)
      |> Enum.with_index(2)
      |> Enum.map(fn {{column, value}, index} -> {"AND #{column} = ?#{index}", value} end)
      |> Enum.unzip()

    sql = """
    SELECT id, tenant_id, workspace_id, refresh_state, authorization_envelope,
           returned_object_links
    FROM context_packages
    WHERE id > ?1
      AND metadata LIKE '%refreshed_from_context_package_id%'
      AND metadata NOT LIKE '%"scrubbed"%'
      #{Enum.join(clauses, "\n  ")}
    ORDER BY id
    LIMIT #{@page}
    """

    BaseStore.raw_query(sql, [after_id | params])
  end

  defp examine([id, tenant_id, workspace_id, refresh_state, envelope, links]) do
    base = %{id: id, tenant_id: tenant_id, workspace_id: workspace_id, refresh_state: refresh_state}

    with {:ok, envelope} <- read_envelope(envelope),
         {:ok, objects} <- read_links(links) do
      case outside(objects, envelope) do
        [] -> nil
        outside -> Map.merge(base, %{reason: "outside_envelope", objects_outside: length(outside)})
      end
    else
      :unreadable_envelope ->
        Map.merge(base, %{reason: "authorization_envelope_unreadable", objects_outside: 0})

      :unreadable_links ->
        Map.merge(base, %{reason: "returned_objects_unreadable", objects_outside: 0})
    end
  end

  defp read_envelope(json) do
    with {:ok, %{} = envelope} <- Jason.decode(json || ""),
         partitions when is_list(partitions) <- Map.get(envelope, "allowed_partitions"),
         labels when is_list(labels) <- Map.get(envelope, "allowed_security_labels") do
      {:ok, %{allowed_partitions: partitions, allowed_security_labels: labels}}
    else
      _ -> :unreadable_envelope
    end
  end

  defp read_links(json) do
    case Jason.decode(json || "") do
      {:ok, links} when is_list(links) ->
        {:ok,
         for(
           %{"type" => type, "id" => id} <- links,
           table = Map.get(@object_tables, type),
           do: {table, id}
         )}

      _ ->
        :unreadable_links
    end
  end

  # The returned objects the envelope does not admit (or that cannot be read).
  defp outside(objects, envelope) do
    objects
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.flat_map(fn {table, ids} -> outside_in(table, ids, envelope) end)
  end

  defp outside_in(table, ids, envelope) do
    marks = Enum.map_join(1..length(ids), ", ", &"?#{&1}")

    case BaseStore.raw_query(
           "SELECT id, security_labels, partition_ids FROM #{table} WHERE id IN (#{marks})",
           ids
         ) do
      {:ok, rows} ->
        for [id, labels, partitions] <- rows, not admitted?(envelope, labels, partitions), do: id

      # An object that cannot be looked up cannot be shown to be admitted.
      _error ->
        ids
    end
  end

  defp admitted?(envelope, labels, partitions) do
    with {:ok, labels} <- SecurityLabels.decode(labels),
         {:ok, partitions} <- SecurityLabels.decode(partitions) do
      RetrievalCoordinator.admits?(envelope, %{security_labels: labels, partition_ids: partitions})
    else
      :invalid -> false
    end
  end

  defp scrub(scanned, offenders) do
    results =
      Enum.map(offenders, fn offender ->
        Store.scrub_context_package_content(offender.id,
          tenant_id: offender.tenant_id,
          workspace_id: offender.workspace_id,
          reason: "swept:" <> offender.reason,
          refresh_state: next_state(offender)
        )
      end)

    case Enum.find(results, &match?({:error, _}, &1)) do
      nil -> {:ok, %{scanned: scanned, offenders: public(offenders), scrubbed: length(results)}}
      error -> error
    end
  end

  defp next_state(%{reason: "authorization_envelope_unreadable"}), do: "failed"
  defp next_state(%{refresh_state: state}) when state in ["fresh", "stale"], do: "stale"
  defp next_state(%{refresh_state: state}), do: state

  defp public(offenders), do: Enum.map(offenders, &Map.delete(&1, :refresh_state))
end
