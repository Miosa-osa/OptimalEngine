defmodule OptimalEngine.Authority.EvidencePagingTest do
  @moduledoc """
  The evidence chain read past any page: `Evidence.stream/3` at exact page
  multiples and with a remainder, streamed verification, export pages that say
  how complete they are and share a head pinned by `until`, the CLI export and
  the integrity scan past 10,000 entries, and an agent action trace whose native
  steps are capped.
  """

  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias OptimalEngine.API.Router
  alias OptimalEngine.Auth.ApiKey
  alias OptimalEngine.Authority
  alias OptimalEngine.Authority.{ActionChain, Evidence, Integrity, Keys}
  alias OptimalEngine.Store
  alias OptimalEngine.Tenancy.Tenant

  @opts Router.init([])

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

      # Every page names the same head and counts the whole chain through it.
      for page <- pages do
        assert %{"total" => ^total, "head" => %{"seq" => ^total, "hash" => ^head_hash}} = page
      end

      {partial, [last]} = Enum.split(pages, -1)

      for page <- partial do
        assert %{"complete" => false} = page
        assert page["next_after"] == List.last(page["entries"])["seq"]
        assert {:error, %{reason: :partial}} = Evidence.verify_export(page)
      end

      assert %{"complete" => true, "next_after" => nil} = last
      assert List.last(last["entries"])["hash"] == head_hash
      assert {:ok, %{entries: ^total, head: ^head_hash}} = Evidence.verify_export(join(pages))

      # The last page alone is not the whole chain.
      if partial != [] do
        assert {:error, %{reason: :partial, verified_from: 1_001}} = Evidence.verify_export(last)
      end
    end

    {:ok, whole} = Evidence.export(ctx.tenant)
    assert whole["complete"] and length(whole["entries"]) == whole["total"]
    assert {:ok, _} = Evidence.verify_export(whole)
  end

  test "pages read with one until share its head while the chain grows", ctx do
    chain_of(ctx.tenant, 2_500)
    {:ok, first} = Evidence.export(ctx.tenant, limit: 1_000)
    head = first["head"]
    assert head["seq"] == 2_500

    # Entries are appended between pages; pages pinned at the head never reach them.
    append_many(ctx.tenant, 300)

    {:ok, second} =
      Evidence.export(ctx.tenant, after: first["next_after"], limit: 1_000, until: 2_500)

    append_many(ctx.tenant, 300)

    {:ok, third} =
      Evidence.export(ctx.tenant, after: second["next_after"], limit: 1_000, until: 2_500)

    pages = [first, second, third]

    assert Enum.map(pages, &length(&1["entries"])) == [1_000, 1_000, 500]
    assert Enum.map(pages, & &1["head"]) == [head, head, head]
    assert Enum.map(pages, & &1["head_signature"]) |> Enum.uniq() |> length() == 1
    assert Enum.map(pages, & &1["total"]) == [2_500, 2_500, 2_500]
    assert Enum.map(pages, & &1["complete"]) == [false, false, true]
    assert third["next_after"] == nil

    entries = Enum.flat_map(pages, & &1["entries"])
    assert length(entries) == third["total"]
    assert Map.take(List.last(entries), ["seq", "hash"]) == head
    assert {:ok, %{entries: 2_500}} = Evidence.verify_export(join(pages))

    # Read without until, the head has moved on.
    {:ok, now} = Evidence.export(ctx.tenant, after: 2_500, limit: 1_000)
    assert %{"head" => %{"seq" => 3_100}, "total" => 3_100, "complete" => true} = now
  end

  test "an until beyond the head, below after, or not a seq answers 400", ctx do
    chain_of(ctx.tenant, 120)

    beyond = fn -> "until=#{chain_length(ctx.tenant) + 1}" end

    for query <- [beyond, "after=60&until=59", "until=0", "until=-3", "until=abc"] do
      query = if is_function(query), do: query.(), else: query
      conn = get_export(ctx.tenant, query)
      assert conn.status == 400, query
      assert Jason.decode!(conn.resp_body) == %{"error" => "until_out_of_range"}
    end

    assert {:error, :until_out_of_range} =
             Evidence.export(ctx.tenant, until: chain_length(ctx.tenant) + 1)

    assert {:error, :until_out_of_range} = Evidence.export(ctx.tenant, after: 60, until: 59)

    conn = get_export(ctx.tenant, "limit=40&until=100")
    assert conn.status == 200
    page = Jason.decode!(conn.resp_body)
    assert %{"total" => 100, "complete" => false, "next_after" => 40} = page
    assert page["head"]["seq"] == 100 and length(page["entries"]) == 40

    conn = get_export(ctx.tenant, "after=40&until=100")
    last = Jason.decode!(conn.resp_body)
    assert %{"complete" => true, "next_after" => nil, "total" => 100} = last

    # NDJSON: the same entries, one a line, then an export_end line with the same fields.
    conn = get_export(ctx.tenant, "after=40&until=100&format=ndjson")
    assert conn.status == 200
    assert ["application/x-ndjson" <> _] = get_resp_header(conn, "content-type")
    assert from_ndjson(conn.resp_body) == last

    assert get_export(ctx.tenant, "format=xml").status == 400
  end

  test "an empty chain exports no head, a total of 0, and is complete", ctx do
    empty = "#{ctx.tenant}-empty"

    assert {:ok,
            %{
              "entries" => [],
              "head" => nil,
              "head_signature" => nil,
              "total" => 0,
              "complete" => true,
              "next_after" => nil
            } = bundle} = Evidence.export(empty)

    assert {:ok, %{entries: 0}} =
             bundle |> Jason.encode!() |> Jason.decode!() |> Evidence.verify_export()

    assert {:error, :until_out_of_range} = Evidence.export(empty, until: 1)
  end

  test "a bundle that is cut short, or whose head is tampered with, does not verify", ctx do
    chain_of(ctx.tenant, 1_200)
    {:ok, exported} = Evidence.export(ctx.tenant)
    whole = exported |> Jason.encode!() |> Jason.decode!()
    assert {:ok, %{entries: 1_200}} = Evidence.verify_export(whole)

    # Entries dropped from the end, the bundle still saying it is complete.
    cut = update_in(whole, ["entries"], &Enum.take(&1, 1_100))
    assert {:error, %{reason: :count_mismatch}} = Evidence.verify_export(cut)
    cut = Map.put(cut, "total", 1_100)
    assert {:error, %{reason: :head_mismatch}} = Evidence.verify_export(cut)

    # A head moved to match the cut: its signature no longer holds.
    last = List.last(cut["entries"])
    moved = Map.put(cut, "head", Map.take(last, ["seq", "hash"]))
    assert {:error, %{reason: :bad_head_signature}} = Evidence.verify_export(moved)

    tampered = put_in(whole, ["head", "hash"], String.duplicate("e", 64))
    assert {:error, %{reason: :bad_head_signature}} = Evidence.verify_export(tampered)
    unsigned = Map.put(whole, "head_signature", nil)
    assert {:error, %{reason: :bad_head_signature}} = Evidence.verify_export(unsigned)

    # Only an empty chain has no head.
    assert {:error, %{reason: :missing_head}} = Evidence.verify_export(Map.put(whole, "head", nil))

    assert {:error, %{reason: :missing_completeness}} =
             Evidence.verify_export(Map.delete(whole, "complete"))

    # A page that is not the end is partial, never valid, even when its entries are.
    {:ok, page} = Evidence.export(ctx.tenant, limit: 500)
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
    {:ok, first} = Evidence.export(ctx.tenant)
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
    assert bundle["head"] == %{"seq" => total, "hash" => head}
    assert {:ok, %{entries: ^total, head: ^head}} = Evidence.verify_export(bundle)

    # Pinned with --until, the file ends complete at that entry.
    Mix.Tasks.Optimal.Authority.run([
      "export",
      "--tenant",
      ctx.tenant,
      "--until",
      "10001",
      "--out",
      out
    ])

    pinned = out |> File.read!() |> Jason.decode!()
    assert %{"complete" => true, "total" => 10_001, "head" => %{"seq" => 10_001}} = pinned
    assert {:ok, %{entries: 10_001}} = Evidence.verify_export(pinned)

    Mix.Tasks.Optimal.Authority.run([
      "export",
      "--tenant",
      ctx.tenant,
      "--until",
      "10001",
      "--format",
      "ndjson",
      "--out",
      out
    ])

    assert out |> File.read!() |> from_ndjson() == pinned
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
    {:ok, page} = Evidence.export(tenant, after: after_seq, limit: limit)

    case page["next_after"] do
      nil -> [page]
      next -> [page | export_pages(tenant, limit, next)]
    end
  end

  # An NDJSON export read back: the entries, and the fields of its export_end line.
  defp from_ndjson(text) do
    lines = text |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    {entries, [ending]} = Enum.split(lines, -1)
    assert ending["type"] == "export_end"
    ending |> Map.delete("type") |> Map.put("entries", entries)
  end

  # Pages joined into one bundle, as a verifier would: every entry, the last page's rest.
  defp join(pages), do: Map.put(List.last(pages), "entries", Enum.flat_map(pages, & &1["entries"]))

  defp get_export(tenant, query) do
    original = Application.get_env(:optimal_engine, :auth, [])

    Application.put_env(
      :optimal_engine,
      :auth,
      Keyword.merge(original, auth_required: true, bcrypt_cost: 4)
    )

    try do
      {:ok, %{key: key}} =
        ApiKey.mint(%{
          tenant_id: tenant,
          name: "evidence-paging-#{System.unique_integer([:positive])}",
          scopes: ["*"],
          workspace_scope: ["*"]
        })

      conn(:get, "/api/authority/evidence/export?" <> query)
      |> put_req_header("authorization", "Bearer " <> key)
      |> Router.call(@opts)
    after
      Application.put_env(:optimal_engine, :auth, original)
    end
  end
end
