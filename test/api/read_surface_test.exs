defmodule OptimalEngine.API.ReadSurfaceTest do
  @moduledoc """
  The routes that dump rows (`GET /api/batch/export/*`, `GET /api/sync/conflicts`)
  filter by the caller's grants the way governed retrieval does: a key sees a
  thing only when every label and partition the thing carries, itself or
  through the rows it was derived from, is among the grants of the key, and
  its principal may read it by the access lists. A key with no grants reads
  only what carries no label.
  """

  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias OptimalEngine.API.Router
  alias OptimalEngine.Auth.ApiKey
  alias OptimalEngine.Identity.{ACL, Principal}
  alias OptimalEngine.Memory
  alias OptimalEngine.Memory.Versioned
  alias OptimalEngine.Pipeline.Intake
  alias OptimalEngine.MemoryCore.SecurityLabels
  alias OptimalEngine.Store
  alias OptimalEngine.Sync.Gate
  alias OptimalEngine.Workspace

  @opts Router.init([])

  setup do
    n = System.unique_integer([:positive])
    {:ok, workspace} = Workspace.create(%{slug: "reads-#{n}", name: "Reads #{n}"})
    ws = workspace.id

    secret = remember(ws, "Wire 4471 to Harborview, routing 4407", ["restricted"])
    internal = remember(ws, "The Northwind offsite is Thursday", ["internal"])
    team = remember(ws, "Team Atlas roadmap draft", [], ["team-a"])
    {:ok, plain} = Versioned.create(%{content: "Lunch is at one", workspace_id: ws})

    {:ok, secret_doc} =
      Intake.process("Zephyrcorp acquisition: the board approved an offer of 41 million",
        workspace_id: ws,
        node: "operator",
        security_labels: ["restricted"],
        write_files: false
      )

    {:ok, plain_doc} =
      Intake.process("Docs ship Friday and the changelog goes out Monday",
        workspace_id: ws,
        node: "operator",
        write_files: false
      )

    secret_chunk =
      chunk(ws, "chk-secret-#{n}", secret_doc.context.id, "Zephyrcorp offer of 41 million")

    plain_chunk = chunk(ws, "chk-plain-#{n}", plain_doc.context.id, "the changelog goes out Monday")

    wiki(ws, "deal-room-#{n}", "Offer notes {{cite: optimal://chunk/#{secret_chunk}}}", [
      secret_chunk
    ])

    wiki(ws, "docs-calendar-#{n}", "Release notes", [plain_chunk])

    %{
      n: n,
      ws: ws,
      secret: secret.memory,
      internal: internal.memory,
      team: team.memory,
      plain: plain,
      secret_doc: secret_doc.context,
      plain_doc: plain_doc.context
    }
  end

  describe "batch exports" do
    test "a key with no grants reads only what carries no label or partition", ctx do
      token = mint(ctx, %{})

      memories = export(ctx, token, "memories")["memories"]
      assert ids(memories) == [ctx.plain.id]

      signals = export(ctx, token, "signals")["signals"]
      assert ids(signals) == [ctx.plain_doc.id]

      snapshot = export(ctx, token, "workspace")
      assert ids(snapshot["memories"]) == [ctx.plain.id]
      assert ids(snapshot["signals"]) == [ctx.plain_doc.id]
      assert Enum.map(snapshot["wiki"], & &1["slug"]) == ["docs-calendar-#{ctx.n}"]

      refute body_of(ctx, token) =~ "Harborview"
      refute body_of(ctx, token) =~ "Zephyrcorp"
    end

    test "a key granted a label reads what carries it, never what carries another", ctx do
      token = mint(ctx, %{"allowed_security_labels" => ["internal"]})

      assert ids(export(ctx, token, "memories")["memories"]) |> Enum.sort() ==
               Enum.sort([ctx.plain.id, ctx.internal.id])

      refute body_of(ctx, token) =~ "Harborview"
    end

    test "a key granted a partition reads what is partitioned to it", ctx do
      without = mint(ctx, %{"allowed_security_labels" => ["internal"]})
      with_partition = mint(ctx, %{"allowed_partitions" => ["team-a"]})

      refute ctx.team.id in ids(export(ctx, without, "memories")["memories"])
      assert ctx.team.id in ids(export(ctx, with_partition, "memories")["memories"])
    end

    test "a key granted every label reads everything, and so does the trusted local operator",
         ctx do
      keyed = mint(ctx, %{"allowed_security_labels" => ["restricted", "internal"]})
      grants_all = ids(export(ctx, keyed, "memories")["memories"])
      assert ctx.secret.id in grants_all and ctx.internal.id in grants_all

      anonymous = export(ctx, nil, "memories")["memories"]
      assert ctx.secret.id in ids(anonymous)
      assert ctx.team.id in ids(anonymous)
      assert ctx.secret_doc.id in ids(export(ctx, nil, "signals")["signals"])
    end

    test "the access lists apply on top of the grants", ctx do
      principal = "user:denied-#{ctx.n}"
      token = mint(ctx, %{"allowed_security_labels" => ["restricted", "internal"]}, principal)

      assert ctx.internal.id in ids(export(ctx, token, "memories")["memories"])

      :ok =
        ACL.deny(%{
          resource_uri: "optimal://memory/#{ctx.ws}/#{ctx.internal.id}",
          principal_id: principal,
          tenant_id: "default"
        })

      read = ids(export(ctx, token, "memories")["memories"])
      refute ctx.internal.id in read
      assert ctx.secret.id in read
    end
  end

  describe "the reader's gate" do
    test "an aggregate carries every label in its workspace", ctx do
      report = %{"id" => "report-#{ctx.n}", "kind" => "promises"}

      readable? = fn labels, partitions ->
        Gate.with_reader("default", ctx.ws, SecurityLabels.grants(labels, partitions), fn gate ->
          Gate.readable_row?(gate, "analysis_reports", report)
        end)
      end

      refute readable?.([], [])
      refute readable?.(["restricted", "internal"], [])
      assert readable?.(["restricted", "internal"], ["team-a"])
    end

    test "a row whose source cannot be found is read by no one", ctx do
      {:ok, orphan} =
        Versioned.create(%{
          content: "Staged from a source that is gone",
          workspace_id: ctx.ws,
          metadata: %{"memory_core_source_package_id" => "sp_gone_#{ctx.n}"}
        })

      everything = SecurityLabels.grants(["restricted", "internal", "confidential"], ["team-a"])

      Gate.with_reader("default", ctx.ws, everything, fn gate ->
        refute Gate.readable_id?(gate, "memories", orphan.id)
        refute Gate.readable_row?(gate, "table_nobody_classified", %{})
      end)
    end

    test "grants are labels and partitions, and nothing is read from an empty set", ctx do
      assert SecurityLabels.grants(["a"], ["p"]) == MapSet.new(["a", "partition:p"])
      assert SecurityLabels.grants(nil, nil) == MapSet.new()

      Gate.with_reader("default", ctx.ws, MapSet.new(), fn gate ->
        assert Gate.readable_id?(gate, "memories", ctx.plain.id)
        refute Gate.readable_id?(gate, "memories", ctx.secret.id)
        refute Gate.readable_id?(gate, "memories", ctx.team.id)
      end)
    end
  end

  describe "conflicts" do
    test "a version a key may not see is redacted, the rest of the conflict is kept", ctx do
      # A fact written restricted on both sides, the staged memory as it was
      # written before labels travelled with it, and an ordinary note.
      conflict(ctx, "fact", "facts", %{
        "id" => "fact-#{ctx.n}",
        "fact_text" => "Bank detail 4471",
        "security_labels" => ~s(["restricted"])
      })

      conflict(ctx, "memory", "memories", %{
        "id" => "mem-legacy-#{ctx.n}",
        "content" => "Harborview wire",
        "metadata" =>
          Jason.encode!(%{
            "memory_core_source_package_id" => ctx.secret.metadata["memory_core_source_package_id"]
          })
      })

      conflict(ctx, "plain", "memories", %{"id" => ctx.plain.id, "content" => "Lunch is at one"})

      bare = mint(ctx, %{})
      shown = conflicts(ctx, bare)

      assert shown[cid(ctx, "fact")]["redacted"]
      assert shown[cid(ctx, "fact")]["local"] == %{"redacted" => "security_labels"}
      assert shown[cid(ctx, "fact")]["remote"] == %{"redacted" => "security_labels"}
      assert shown[cid(ctx, "fact")]["table"] == "facts"
      assert shown[cid(ctx, "fact")]["kind"] == "concurrent_change"

      assert shown[cid(ctx, "memory")]["redacted"]
      refute shown[cid(ctx, "plain")]["redacted"]
      assert shown[cid(ctx, "plain")]["local"]["row"]["content"] == "Lunch is at one"

      refute body_of_conflicts(ctx, bare) =~ "Bank detail"
      refute body_of_conflicts(ctx, bare) =~ "Harborview"

      granted = conflicts(ctx, mint(ctx, %{"allowed_security_labels" => ["restricted"]}))
      refute granted[cid(ctx, "fact")]["redacted"]
      assert granted[cid(ctx, "fact")]["local"]["row"]["fact_text"] == "Bank detail 4471"

      operator = conflicts(ctx, nil)
      assert operator[cid(ctx, "fact")]["local"]["row"]["fact_text"] == "Bank detail 4471"
    end
  end

  describe "claims raised from a fact conflict" do
    test "carry the partitions of the fact, so a key without them does not read them", ctx do
      {:ok, _} = OptimalEngine.Sync.enable("default", ctx.ws, "user:owner")
      id = "fact-part-#{ctx.n}"

      {:ok, _} =
        Store.raw_query(
          "INSERT INTO facts (id, tenant_id, workspace_id, fact_text, partition_ids) VALUES (?1, 'default', ?2, 'Payroll run 5521', '[\"team-a\"]')",
          [id, ctx.ws]
        )

      {:ok, _} =
        Store.raw_query("UPDATE facts SET fact_text = 'Payroll run 5522' WHERE id = ?1", [id])

      {:ok, _} = OptimalEngine.Sync.Capture.seal()

      older = %{
        "id" => "mut_part_#{ctx.n}",
        "device_id" => "rep_remote",
        "entity_type" => "facts",
        "entity_id" => id,
        "operation" => "update",
        "occurred_at" => "2000-01-01T00:00:00.000",
        "payload" => %{
          "row" => %{
            "id" => id,
            "tenant_id" => "default",
            "workspace_id" => ctx.ws,
            "fact_text" => "Payroll run 5520"
          },
          "blobs" => %{}
        }
      }

      assert {:ok, %{conflicts: 1}} = OptimalEngine.Sync.apply_changes("default", ctx.ws, [older])

      {:ok, rows} =
        Store.raw_query(
          "SELECT id, partition_ids FROM claims WHERE workspace_id = ?1 AND json_extract(metadata, '$.sync_conflict') = 1",
          [ctx.ws]
        )

      assert length(rows) == 2
      assert Enum.all?(rows, fn [_id, partitions] -> Jason.decode!(partitions) == ["team-a"] end)
      claim_ids = Enum.map(rows, &hd/1)

      for {grants, readable?} <- [
            {SecurityLabels.grants([], []), false},
            {SecurityLabels.grants([], ["team-a"]), true}
          ] do
        Gate.with_reader("default", ctx.ws, grants, fn gate ->
          for claim_id <- claim_ids,
              do: assert(Gate.readable_id?(gate, "claims", claim_id) == readable?)
        end)
      end
    end
  end

  # -- helpers ----------------------------------------------------------------------

  defp remember(ws, content, labels, partitions \\ []) do
    {:ok, result} =
      Memory.remember(
        %{
          content: content,
          workspace_id: ws,
          security_labels: labels,
          partition_ids: partitions,
          actor_id: "user:tester"
        },
        force: true,
        versioned_projection: true
      )

    result
  end

  defp chunk(ws, id, context_id, text) do
    {:ok, _} =
      Store.raw_query(
        "INSERT INTO chunks (id, tenant_id, signal_id, scale, text, workspace_id) VALUES (?1, 'default', ?2, 'document', ?3, ?4)",
        [id, context_id, text, ws]
      )

    id
  end

  defp wiki(ws, slug, body, chunk_ids) do
    {:ok, _} =
      Store.raw_query(
        "INSERT INTO wiki_pages (tenant_id, workspace_id, slug, audience, version, frontmatter, body) VALUES ('default', ?1, ?2, 'default', 1, '{}', ?3)",
        [ws, slug, body]
      )

    for chunk_id <- chunk_ids do
      {:ok, _} =
        Store.raw_query(
          "INSERT INTO citations (tenant_id, workspace_id, wiki_slug, wiki_audience, chunk_id, claim_hash) VALUES ('default', ?1, ?2, 'default', ?3, 'h')",
          [ws, slug, chunk_id]
        )
    end
  end

  defp mint(ctx, metadata, principal \\ nil) do
    principal = principal || "user:reader-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Principal.upsert(%{
        id: principal,
        tenant_id: "default",
        kind: :agent,
        display_name: principal
      })

    {:ok, %{key: token}} =
      ApiKey.mint(%{
        tenant_id: "default",
        name: "reader #{System.unique_integer([:positive])}",
        scopes: ["read"],
        workspace_scope: [ctx.ws],
        principal_id: principal,
        metadata: metadata
      })

    token
  end

  defp get_as(path, token) do
    conn = conn(:get, path)
    conn = if token, do: put_req_header(conn, "authorization", "Bearer " <> token), else: conn
    Router.call(conn, @opts)
  end

  defp export_path(ctx, kind),
    do: "/api/batch/export/#{kind}?" <> URI.encode_query(%{"workspace" => ctx.ws})

  defp export(ctx, token, kind) do
    conn = get_as(export_path(ctx, kind), token)
    assert conn.status == 200, "export #{kind}: #{conn.status} #{conn.resp_body}"
    Jason.decode!(conn.resp_body)
  end

  defp body_of(ctx, token) do
    Enum.map_join(["memories", "signals", "workspace"], fn kind ->
      get_as(export_path(ctx, kind), token).resp_body
    end)
  end

  defp ids(items), do: Enum.map(items, & &1["id"])

  defp cid(ctx, name), do: "c-#{name}-#{ctx.n}"

  defp conflict(ctx, name, table, row) do
    id = cid(ctx, name)
    payload = Jason.encode!(%{"row" => row, "blobs" => %{}})

    {:ok, _} =
      Store.raw_query(
        """
        INSERT INTO sync_conflicts (id, tenant_id, workspace_id, table_name, entity_key, kind, resolution,
                                    local_payload, remote_payload, remote_device)
        VALUES (?1, 'default', ?2, ?3, ?4, 'concurrent_change', 'kept_local_newer', ?5, ?5, 'rep_remote')
        """,
        [id, ctx.ws, table, row["id"], payload]
      )
  end

  defp conflicts(ctx, token) do
    path = "/api/sync/conflicts?" <> URI.encode_query(%{"workspace" => ctx.ws})
    conn = get_as(path, token)
    assert conn.status == 200, "conflicts: #{conn.status} #{conn.resp_body}"

    conn.resp_body
    |> Jason.decode!()
    |> Map.fetch!("conflicts")
    |> Map.new(&{&1["id"], &1})
  end

  defp body_of_conflicts(ctx, token) do
    get_as("/api/sync/conflicts?" <> URI.encode_query(%{"workspace" => ctx.ws}), token).resp_body
  end
end
