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

  The sweep destroys content, so it empties a package only on evidence. A
  package whose objects could not be looked up is skipped and reported, never
  taken for an offender, and a package that changed state since it was read
  (refreshed, invalidated) is skipped too. Run it again to retry the skipped.

  Run once after upgrading, with `mix optimal.context.sweep`. It is safe to
  repeat: a package that passes, or was already emptied, is left alone.
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

  @type skipped :: %{
          id: String.t(),
          tenant_id: String.t(),
          workspace_id: String.t(),
          reason: String.t()
        }

  @type summary :: %{
          scanned: non_neg_integer(),
          offenders: [offender()],
          skipped: [skipped()],
          scrubbed: non_neg_integer()
        }

  @doc """
  Sweeps the packages of `:tenant_id` and `:workspace_id` (all when omitted).
  With `dry_run: true` nothing is written. `:object_query` is the function that
  looks up the returned objects (`fn sql, params -> {:ok, rows} | {:error, _} end`,
  the Store's `raw_query/2` by default), so a test can make a lookup fail.
  """
  @spec run(keyword()) :: {:ok, summary()} | {:error, term()}
  def run(opts \\ []) do
    with {:ok, scanned, offenders, skipped} <- scan(opts, "", 0, [], []) do
      if Keyword.get(opts, :dry_run, false) do
        {:ok, %{scanned: scanned, offenders: public(offenders), skipped: skipped, scrubbed: 0}}
      else
        scrub(scanned, offenders, skipped)
      end
    end
  end

  defp scan(opts, after_id, scanned, offenders, skipped) do
    with {:ok, rows} <- suspects(opts, after_id) do
      verdicts = Enum.map(rows, &examine(&1, opts))
      scanned = scanned + length(rows)
      offenders = offenders ++ for({:offender, offender} <- verdicts, do: offender)
      skipped = skipped ++ for({:skipped, entry} <- verdicts, do: entry)

      case List.last(rows) do
        [last_id | _] when length(rows) == @page -> scan(opts, last_id, scanned, offenders, skipped)
        _ -> {:ok, scanned, offenders, skipped}
      end
    end
  end

  # A package a refresh made and that was not emptied already. `json_valid`
  # keeps one unreadable metadata value from failing the whole query.
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
      AND CASE WHEN json_valid(metadata) THEN json_extract(metadata, '$.scrubbed') IS NULL ELSE 1 END
      #{Enum.join(clauses, "\n  ")}
    ORDER BY id
    LIMIT #{@page}
    """

    BaseStore.raw_query(sql, [after_id | params])
  end

  # nil (inside its envelope), {:offender, offender} or {:skipped, entry}.
  defp examine([id, tenant_id, workspace_id, refresh_state, envelope, links], opts) do
    base = %{id: id, tenant_id: tenant_id, workspace_id: workspace_id}

    with {:ok, envelope} <- read_envelope(envelope),
         {:ok, objects} <- read_links(links),
         {:ok, outside} <- outside(objects, envelope, lookup(opts)) do
      if outside == [] do
        nil
      else
        {:offender,
         Map.merge(base, %{
           reason: "outside_envelope",
           objects_outside: length(outside),
           refresh_state: refresh_state
         })}
      end
    else
      :unreadable_envelope ->
        {:offender,
         Map.merge(base, %{
           reason: "authorization_envelope_unreadable",
           objects_outside: 0,
           refresh_state: refresh_state
         })}

      :unreadable_links ->
        {:offender,
         Map.merge(base, %{
           reason: "returned_objects_unreadable",
           objects_outside: 0,
           refresh_state: refresh_state
         })}

      {:error, reason} ->
        {:skipped, Map.put(base, :reason, "lookup_failed: " <> inspect(reason))}
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

  # The returned objects the envelope does not admit (or that cannot be read),
  # or the error of a lookup that failed: with no answer there is no evidence.
  defp outside(objects, envelope, lookup) do
    objects
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.reduce_while({:ok, []}, fn {table, ids}, {:ok, found} ->
      case outside_in(table, ids, envelope, lookup) do
        {:ok, outside} -> {:cont, {:ok, found ++ outside}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp lookup(opts), do: Keyword.get(opts, :object_query, &BaseStore.raw_query/2)

  defp outside_in(table, ids, envelope, lookup) do
    marks = Enum.map_join(1..length(ids), ", ", &"?#{&1}")

    with {:ok, rows} <-
           lookup.(
             "SELECT id, security_labels, partition_ids FROM #{table} WHERE id IN (#{marks})",
             ids
           ) do
      {:ok,
       for([id, labels, partitions] <- rows, not admitted?(envelope, labels, partitions), do: id)}
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

  defp scrub(scanned, offenders, skipped) do
    outcomes =
      Enum.map(offenders, fn offender ->
        result =
          Store.scrub_context_package_content(offender.id,
            tenant_id: offender.tenant_id,
            workspace_id: offender.workspace_id,
            reason: "swept:" <> offender.reason,
            refresh_state: next_state(offender),
            expect_state: offender.refresh_state
          )

        {offender, result}
      end)

    scrubbed = for {offender, {:ok, 1}} <- outcomes, do: offender

    not_scrubbed =
      for {offender, result} <- outcomes, result != {:ok, 1} do
        reason =
          case result do
            {:ok, 0} -> "state_changed"
            {:error, reason} -> "scrub_failed: " <> inspect(reason)
          end

        offender |> Map.take([:id, :tenant_id, :workspace_id]) |> Map.put(:reason, reason)
      end

    {:ok,
     %{
       scanned: scanned,
       offenders: public(scrubbed),
       skipped: skipped ++ not_scrubbed,
       scrubbed: length(scrubbed)
     }}
  end

  defp next_state(%{reason: "authorization_envelope_unreadable"}), do: "failed"
  defp next_state(%{refresh_state: state}) when state in ["fresh", "stale"], do: "stale"
  defp next_state(%{refresh_state: state}), do: state

  defp public(offenders), do: Enum.map(offenders, &Map.delete(&1, :refresh_state))
end
