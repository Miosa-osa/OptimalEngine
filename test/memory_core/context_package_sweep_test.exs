defmodule OptimalEngine.MemoryCore.ContextPackageSweepTest do
  @moduledoc """
  A refresh used to store packages that hold objects their recorded envelope
  does not admit. The sweep finds those among the packages a refresh made and
  empties them, leaving everything else alone.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias OptimalEngine.MemoryCore.ContextPackageSweep
  alias OptimalEngine.MemoryCore.ID
  alias OptimalEngine.MemoryCore.RetrievalCoordinator
  alias OptimalEngine.MemoryCore.Store, as: MemoryCoreStore
  alias OptimalEngine.Store

  @narrow ~s({"allowed_partitions":[],"allowed_security_labels":["public"]})

  setup do
    workspace_id = "sweep-#{System.unique_integer([:positive])}"

    for {tag, labels} <- [{"open", []}, {"public", ["public"]}, {"restricted", ["restricted"]}] do
      shared = %{
        tenant_id: "default",
        workspace_id: workspace_id,
        subject_anchor: "launch",
        action_class: "noted",
        security_labels: labels,
        partition_ids: []
      }

      :ok =
        MemoryCoreStore.insert_fact(
          Map.merge(shared, %{
            id: ID.random_id("fact"),
            fact_text: "Launch note #{tag}-marker.",
            lifecycle_state: "accepted",
            contradiction_status: "none"
          })
        )
    end

    packages = %{
      # What an old refresh stored: read with the filter off, recorded narrow.
      over_wide: refresh_product!(workspace_id, ["public", "restricted"], @narrow),
      # A refresh product that stayed inside its envelope.
      clean: refresh_product!(workspace_id, ["public"], @narrow),
      # An over-wide product a later refresh already replaced.
      replaced: refresh_product!(workspace_id, ["public", "restricted"], @narrow, "refreshed"),
      # A refresh product whose envelope cannot be read.
      unreadable: refresh_product!(workspace_id, ["public"], "{}"),
      # Wide, but not made by a refresh: not the sweep's concern.
      not_a_refresh: build!(workspace_id, ["public", "restricted"])
    }

    {:ok, workspace_id: workspace_id, packages: packages}
  end

  test "a dry run reports the offenders and changes nothing", ctx do
    before = snapshot(ctx.packages)

    assert {:ok, summary} = ContextPackageSweep.run(workspace_id: ctx.workspace_id, dry_run: true)

    assert summary.scanned == 4
    assert summary.scrubbed == 0
    assert offender_ids(summary) == ids(ctx.packages, [:over_wide, :replaced, :unreadable])
    assert snapshot(ctx.packages) == before
  end

  test "empties the offenders and leaves the rest alone", ctx do
    before = snapshot(ctx.packages)

    assert {:ok, summary} = ContextPackageSweep.run(workspace_id: ctx.workspace_id)

    assert summary.scrubbed == 3
    assert offender_ids(summary) == ids(ctx.packages, [:over_wide, :replaced, :unreadable])

    reasons = Map.new(summary.offenders, &{&1.id, &1.reason})
    assert reasons[ctx.packages.over_wide.id] == "outside_envelope"
    assert reasons[ctx.packages.unreadable.id] == "authorization_envelope_unreadable"

    after_sweep = snapshot(ctx.packages)

    for key <- [:clean, :not_a_refresh] do
      assert after_sweep[key] == before[key]
    end

    for key <- [:over_wide, :replaced, :unreadable] do
      assert %{fact_links: "[]", returned_object_links: "[]", sections: nil} = after_sweep[key]
    end

    # In use: rebuilt by the next refresh. Replaced: stays replaced. Unreadable: out of the list.
    assert after_sweep.over_wide.state == "stale"
    assert after_sweep.replaced.state == "refreshed"
    assert after_sweep.unreadable.state == "failed"
  end

  test "an emptied package is rebuilt inside its envelope, and a second sweep finds nothing",
       ctx do
    assert {:ok, _summary} = ContextPackageSweep.run(workspace_id: ctx.workspace_id)

    assert {:ok, refreshed} =
             RetrievalCoordinator.refresh_context_package(ctx.packages.over_wide.id,
               workspace_id: ctx.workspace_id
             )

    texts = Enum.map(refreshed.facts, & &1.text)
    assert Enum.any?(texts, &(&1 =~ "public-marker"))
    refute Enum.any?(texts, &(&1 =~ "restricted-marker"))

    assert {:ok, again} = ContextPackageSweep.run(workspace_id: ctx.workspace_id)
    assert again.offenders == []
    assert again.scrubbed == 0
  end

  test "a package whose objects cannot be looked up is skipped and reported, never emptied",
       ctx do
    before = snapshot(ctx.packages)

    failing = fn _sql, _params -> {:error, :database_busy} end

    assert {:ok, summary} =
             ContextPackageSweep.run(workspace_id: ctx.workspace_id, object_query: failing)

    # Only the packages that need no object lookup are judged: the one whose
    # envelope cannot be read.
    assert offender_ids(summary) == ids(ctx.packages, [:unreadable])
    assert summary.scrubbed == 1

    assert Enum.sort(Enum.map(summary.skipped, & &1.id)) ==
             ids(ctx.packages, [:over_wide, :clean, :replaced])

    assert Enum.all?(summary.skipped, &(&1.reason =~ "lookup_failed"))

    after_sweep = snapshot(ctx.packages)

    for key <- [:over_wide, :clean, :replaced, :not_a_refresh] do
      assert after_sweep[key] == before[key]
    end
  end

  test "a package that changed state since it was read is skipped, not emptied", ctx do
    over_wide_id = ctx.packages.over_wide.id

    refreshed_meanwhile = fn sql, params ->
      :ok =
        Store.raw_execute("UPDATE context_packages SET refresh_state = 'refreshed' WHERE id = ?1", [
          over_wide_id
        ])

      Store.raw_query(sql, params)
    end

    assert {:ok, summary} =
             ContextPackageSweep.run(
               workspace_id: ctx.workspace_id,
               object_query: refreshed_meanwhile
             )

    assert %{reason: "state_changed"} = Enum.find(summary.skipped, &(&1.id == over_wide_id))
    refute over_wide_id in offender_ids(summary)
    assert snapshot(ctx.packages).over_wide.fact_links != "[]"
  end

  test "the store empties a package only in the state the caller saw", ctx do
    id = ctx.packages.over_wide.id

    assert {:ok, 0} =
             MemoryCoreStore.scrub_context_package_content(id,
               workspace_id: ctx.workspace_id,
               expect_state: "stale"
             )

    assert snapshot(ctx.packages).over_wide.fact_links != "[]"

    assert {:ok, 1} =
             MemoryCoreStore.scrub_context_package_content(id,
               workspace_id: ctx.workspace_id,
               expect_state: "fresh"
             )

    assert snapshot(ctx.packages).over_wide.fact_links == "[]"
  end

  test "a package with unreadable metadata does not stop the sweep", ctx do
    broken = build!(ctx.workspace_id, ["public", "restricted"])

    assert :ok =
             Store.raw_execute(
               "UPDATE context_packages SET authorization_envelope = ?2, metadata = 'refreshed_from_context_package_id (not json' WHERE id = ?1",
               [broken.id, @narrow]
             )

    assert {:ok, summary} = ContextPackageSweep.run(workspace_id: ctx.workspace_id)

    assert broken.id in offender_ids(summary)
    assert summary.skipped == []

    assert {:ok, [["[]"]]} =
             Store.raw_query("SELECT fact_links FROM context_packages WHERE id = ?1", [broken.id])
  end

  test "the Mix task prints the summary and honours --dry-run", ctx do
    output =
      capture_io(fn ->
        Mix.Tasks.Optimal.Context.Sweep.run([
          "--workspace",
          ctx.workspace_id,
          "--dry-run",
          "--json"
        ])
      end)

    assert %{"scanned" => 4, "scrubbed" => 0, "offenders" => offenders} = Jason.decode!(output)
    assert length(offenders) == 3
    assert snapshot(ctx.packages).over_wide.fact_links != "[]"
  end

  # -- fixtures ---------------------------------------------------------------

  defp build!(workspace_id, labels) do
    {:ok, package} =
      RetrievalCoordinator.retrieve("launch",
        workspace_id: workspace_id,
        actor_id: "agent:builder",
        allowed_partitions: [],
        allowed_security_labels: labels
      )

    package
  end

  # A package built under `labels`, recorded under `envelope` and marked as the
  # product of a refresh.
  defp refresh_product!(workspace_id, labels, envelope, state \\ "fresh") do
    package = build!(workspace_id, labels)

    assert :ok =
             Store.raw_execute(
               """
               UPDATE context_packages
               SET authorization_envelope = ?2,
                   refresh_state = ?3,
                   metadata = json_set(metadata, '$.refreshed_from_context_package_id', 'ctxpkg_replaced')
               WHERE id = ?1
               """,
               [package.id, envelope, state]
             )

    package
  end

  defp ids(packages, keys), do: keys |> Enum.map(&packages[&1].id) |> Enum.sort()

  defp offender_ids(summary), do: summary.offenders |> Enum.map(& &1.id) |> Enum.sort()

  defp snapshot(packages) do
    Map.new(packages, fn {key, package} ->
      assert {:ok, [[fact_links, returned, state, metadata]]} =
               Store.raw_query(
                 "SELECT fact_links, returned_object_links, refresh_state, metadata FROM context_packages WHERE id = ?1",
                 [package.id]
               )

      {key,
       %{
         fact_links: fact_links,
         returned_object_links: returned,
         state: state,
         sections: Jason.decode!(metadata)["sections"],
         metadata: metadata
       }}
    end)
  end
end
