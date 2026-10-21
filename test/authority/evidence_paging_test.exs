defmodule OptimalEngine.Authority.EvidencePagingTest do
  @moduledoc """
  The evidence chain read past any page: `Evidence.stream/3` at exact page
  multiples and with a remainder, streamed verification, export pages that say
  how complete they are, the CLI export and the integrity scan past 10,000
  entries, and an agent action trace whose native steps are capped.
  """

  use ExUnit.Case, async: false

  alias OptimalEngine.Authority
  alias OptimalEngine.Authority.{ActionChain, Evidence, Integrity, Keys}
  alias OptimalEngine.Store
  alias OptimalEngine.Tenancy.Tenant

  setup do
    n = System.unique_integer([:positive])
    tenant = "evidence-paging-#{n}"
    {:ok, _} = Tenant.create(%{id: tenant, name: "Evidence paging #{n}"})
    %{tenant: tenant, workspace: "#{tenant}:ops"}
  end

  # Appends `count` entries in one transaction, so thousands take a moment.
  defp append_many(tenant, count, kind \\ "decision.allowed", attrs \\ %{}) do
    {:ok, key} = Keys.active(tenant, "evidence")

    {:ok, ^count} =
      Store.transaction(
        fn txn ->
          for i <- 1..count//1 do
            {:ok, _} =
              Evidence.append_in(txn, key, tenant, kind, Map.put_new(attrs, :subject, "agent:#{i}"))
          end

          {:ok, count}
        end,
        120_000
      )
  end

  # Grows the chain to exactly `total` entries.
  defp chain_of(tenant, total) do
    append_many(tenant, total - chain_length(tenant))
    total
  end

  defp chain_length(tenant) do
    {:ok, [[n]]} =
      Store.raw_query("SELECT COUNT(*) FROM authority_evidence WHERE tenant_id = ?1", [tenant])

    n
  end

  test "stream/3 reads every entry at exact page multiples and with a remainder", ctx do
    for total <- [1_000, 1_501, 2_000] do
      chain_of(ctx.tenant, total)
      seqs = ctx.tenant |> Evidence.stream() |> Enum.map(& &1["seq"])
      assert seqs == Enum.to_list(1..total), "a chain of #{total}"
      assert Evidence.count(ctx.tenant, "1 = 1", []) == total
    end

    assert [%{"seq" => 1}, %{"seq" => 2}] = ctx.tenant |> Evidence.stream() |> Enum.take(2)
  end

  test "verify walks a long chain and finds a change or a bad checkpoint far into it", ctx do
    append_many(ctx.tenant, 700)
    {:ok, early} = Evidence.checkpoint(ctx.tenant)
    append_many(ctx.tenant, 800)
    {:ok, _late} = Evidence.checkpoint(ctx.tenant)

    total = chain_length(ctx.tenant)
    assert total >= 1_500
    assert {:ok, %{entries: ^total}} = Evidence.verify(ctx.tenant)

    {:ok, [[hash]]} =
      Store.raw_query(
        "SELECT hash FROM authority_checkpoints WHERE tenant_id = ?1 AND tenant_seq = ?2",
        [ctx.tenant, early["seq"]]
      )

    set_checkpoint_hash = fn value ->
      {:ok, _} =
        Store.raw_query(
          "UPDATE authority_checkpoints SET hash = ?3 WHERE tenant_id = ?1 AND tenant_seq = ?2",
          [ctx.tenant, early["seq"], value]
        )
    end

    set_checkpoint_hash.(String.duplicate("f", 64))
    early_seq = early["seq"]

    assert {:error, %{seq: ^early_seq, reason: :checkpoint_mismatch}} =
             Evidence.verify(ctx.tenant)

    set_checkpoint_hash.(hash)
    assert {:ok, _} = Evidence.verify(ctx.tenant)

    {:ok, _} =
      Store.raw_query(
        "UPDATE authority_evidence SET detail = '{\"by\":\"someone-else\"}' WHERE tenant_id = ?1 AND tenant_seq = 1234",
        [ctx.tenant]
      )

    assert {:error, %{seq: 1234, reason: :hash_mismatch}} = Evidence.verify(ctx.tenant)
  end

  test "export pages end complete exactly at the head, at page multiples or not", ctx do
    for total <- [1_000, 1_501, 2_000] do
      chain_of(ctx.tenant, total)
      {:ok, %{head: head_hash}} = Evidence.verify(ctx.tenant)
      pages = export_pages(ctx.tenant, 1_000)

      assert Enum.map(pages, &length(&1["entries"])) ==
               (case total do
                  1_000 -> [1_000]
                  1_501 -> [1_000, 501]
                  2_000 -> [1_000, 1_000]
                end)

      {partial, [last]} = Enum.split(pages, -1)

      for page <- partial do
        assert %{"complete" => false, "total" => ^total} = page
        assert page["next_after"] == List.last(page["entries"])["seq"]
        assert {:error, %{reason: :partial}} = Evidence.verify_export(page)
      end

      assert %{"complete" => true, "next_after" => nil, "head" => %{"seq" => ^total}} = last
      assert last["total"] == total - (length(pages) - 1) * 1_000
      assert List.last(last["entries"])["hash"] == head_hash
      assert {:ok, %{head: ^head_hash}} = Evidence.verify_export(last)
    end

    whole = Evidence.export(ctx.tenant)
    assert whole["complete"] and length(whole["entries"]) == whole["total"]
    assert {:ok, _} = Evidence.verify_export(whole)
  end

  test "a bundle that is cut short, or whose head is tampered with, does not verify", ctx do
    chain_of(ctx.tenant, 1_200)
    whole = ctx.tenant |> Evidence.export() |> Jason.encode!() |> Jason.decode!()
    assert {:ok, %{entries: 1_200}} = Evidence.verify_export(whole)

    # Entries dropped from the end, the bundle still saying it is complete.
    cut = update_in(whole, ["entries"], &Enum.take(&1, 1_100))
    assert {:error, %{reason: :count_mismatch}} = Evidence.verify_export(cut)
    cut = Map.put(cut, "total", 1_100)
    assert {:error, %{reason: :head_mismatch}} = Evidence.verify_export(cut)

    # A head moved to match the cut: its signature no longer holds.
    last = List.last(cut["entries"])

    moved =
      update_in(cut, ["head"], &Map.merge(&1, %{"seq" => last["seq"], "hash" => last["hash"]}))

    assert {:error, %{reason: :bad_head_signature}} = Evidence.verify_export(moved)

    tampered = put_in(whole, ["head", "hash"], String.duplicate("e", 64))
    assert {:error, %{reason: :bad_head_signature}} = Evidence.verify_export(tampered)
    assert {:error, %{reason: :missing_head}} = Evidence.verify_export(Map.delete(whole, "head"))

    assert {:error, %{reason: :missing_completeness}} =
             Evidence.verify_export(Map.delete(whole, "complete"))

    # A page that is not the end is partial, never valid, even when its entries are.
    page = Evidence.export(ctx.tenant, 0, 500)
    assert {:error, %{reason: :partial, entries: 500}} = Evidence.verify_export(page)
    forged = Map.put(page, "complete", true)
    assert {:error, %{reason: :count_mismatch}} = Evidence.verify_export(forged)
  end

  test "past 10,000 entries the CLI export is complete and the integrity scan sees every one",
       ctx do
    append_many(ctx.tenant, 10_050)

    pack = %{
      "name" => "ops",
      "rules" => [%{"id" => "agents-read", "effect" => "allow", "actions" => ["read"]}]
    }

    {:ok, _policy} =
      Authority.publish_policy(ctx.tenant, "workspace", ctx.workspace, pack, "user:owner")

    total = chain_length(ctx.tenant)
    assert total > 10_050

    # The publication sits past entry 10,000; a scan that stopped there reported it missing.
    scan = Integrity.scan(ctx.tenant)
    assert scan.findings == []
    assert scan.checked.evidence_entries == total

    # The API's first page stops at 10,000 and says so.
    first = Evidence.export(ctx.tenant)
    assert %{"complete" => false, "next_after" => 10_000, "total" => ^total} = first
    assert length(first["entries"]) == 10_000

    out = Path.join(System.tmp_dir!(), "evidence-export-#{System.unique_integer([:positive])}.json")
    on_exit(fn -> File.rm(out) end)
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)

    Mix.Tasks.Optimal.Authority.run(["export", "--tenant", ctx.tenant, "--out", out])

    bundle = out |> File.read!() |> Jason.decode!()
    assert %{"complete" => true, "total" => ^total, "next_after" => nil} = bundle
    assert length(bundle["entries"]) == total
    {:ok, %{head: head}} = Evidence.verify(ctx.tenant)
    assert bundle["head"]["hash"] == head
    assert {:ok, %{entries: ^total, head: ^head}} = Evidence.verify_export(bundle)
    expected = "Wrote #{total} entries to #{out}"
    assert_received {:mix_shell, :info, [^expected]}
  end

  test "a trace caps native steps, says so, and checks the workspace first", ctx do
    jti = "grt_paging_#{System.unique_integer([:positive])}"
    attrs = %{jti: jti, workspace_id: ctx.workspace, subject: "agent:batch", action: "read"}
    append_many(ctx.tenant, 1, "grant.issued", attrs)
    append_many(ctx.tenant, 2_050, "grant.admitted", attrs)

    {:ok, trace} = ActionChain.trace(ctx.tenant, jti)
    assert length(trace.steps) == 2_000
    assert trace.truncated
    assert trace.total == 2_051
    assert hd(trace.steps)["evidence_kind"] == "grant.issued"
    assert Enum.all?(trace.steps, &(&1["verified"] == true))
    assert trace.workspace_id == ctx.workspace

    # Another workspace is not found, before any step is verified.
    assert {:error, :not_found} = ActionChain.trace(ctx.tenant, jti, workspace_id: "other:ws")
    assert {:error, :not_found} = ActionChain.trace(ctx.tenant, jti, workspace_id: nil)
    assert {:ok, _} = ActionChain.trace(ctx.tenant, jti, workspace_id: ctx.workspace)

    # A short chain is whole.
    small = "grt_small_#{System.unique_integer([:positive])}"
    append_many(ctx.tenant, 3, "grant.admitted", %{attrs | jti: small})
    {:ok, whole} = ActionChain.trace(ctx.tenant, small)
    assert length(whole.steps) == 3 and whole.total == 3 and not whole.truncated
  end

  defp export_pages(tenant, limit, after_seq \\ 0) do
    page = Evidence.export(tenant, after_seq, limit)

    case page["next_after"] do
      nil -> [page]
      next -> [page | export_pages(tenant, limit, next)]
    end
  end
end
