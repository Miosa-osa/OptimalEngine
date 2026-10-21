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

    # The grants are what most of these tests are about, so the ceiling for
    # what the dump routes hand out is raised to the top; the tests of the
    # ceiling itself put the default back.
    previous = Application.get_env(:optimal_engine, :sync_serve_max_class)
    Application.put_env(:optimal_engine, :sync_serve_max_class, "restricted")

    on_exit(fn ->
      if previous,
        do: Application.put_env(:optimal_engine, :sync_serve_max_class, previous),
        else: Application.delete_env(:optimal_engine, :sync_serve_max_class)
    end)

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

    test "a grant that is not a string grants nothing and does not fail the read", ctx do
      token =
        mint(ctx, %{"allowed_security_labels" => ["internal", %{"x" => 1}, 7, ["restricted"]]})

      memories = ids(export(ctx, token, "memories")["memories"])
      assert ctx.internal.id in memories
      refute ctx.secret.id in memories
    end

    test "a key granted a partition reads what is partitioned to it", ctx do
      without = mint(ctx, %{"allowed_security_labels" => ["internal"]})
      with_partition = mint(ctx, %{"allowed_partitions" => ["team-a"]})

      refute ctx.team.id in ids(export(ctx, without, "memories")["memories"])
      assert ctx.team.id in ids(export(ctx, with_partition, "memories")["memories"])
    end

    test "a key with partitions granted does not read what has none, as in retrieval", ctx do
      only_a = mint(ctx, %{"allowed_partitions" => ["team-a"]})

      assert ids(export(ctx, only_a, "memories")["memories"]) == [ctx.team.id]
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

  describe "a key minted from the bootstrap key" do
    setup do
      token = bootstrap_token()
      %{boot: token}
    end

    test "the root bootstrap key reads in full", ctx do
      memories = ids(export(ctx, ctx.boot, "memories")["memories"])

      for memory <- [ctx.secret, ctx.internal, ctx.team, ctx.plain],
          do: assert(memory.id in memories)
    end

    test "minted without grants it reads no labelled row, whatever the minter holds", ctx do
      child = mint_from(ctx, ctx.boot, %{})

      assert ids(export(ctx, child, "memories")["memories"]) == [ctx.plain.id]
      assert ids(export(ctx, child, "signals")["signals"]) == [ctx.plain_doc.id]
      refute body_of(ctx, child) =~ "Harborview"
      refute body_of(ctx, child) =~ "Zephyrcorp"
    end

    test "minted with the recommended default grants it reads internal, never restricted", ctx do
      child =
        mint_from(ctx, ctx.boot, %{
          "allowed_security_labels" => ["public", "internal", "confidential"],
          "allowed_partitions" => []
        })

      assert Enum.sort(ids(export(ctx, child, "memories")["memories"])) ==
               Enum.sort([ctx.plain.id, ctx.internal.id])

      refute body_of(ctx, child) =~ "Harborview"
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

    test "metadata that spells a label key with an escape is read as that key by the aggregate rule",
         ctx do
      # `security\u005flabels` is the key `security_labels` once decoded, and spelled
      # so it does not contain the text the scan looks for.
      for {name, metadata} <- [
            labels: ~S({"security\u005flabels":["restricted"]}),
            partitions: ~S({"partition\u005fids":["team-a"]}),
            both_escaped: ~S({"\u0073ecurity_labels":["restricted"],"note":"a \"quoted\" word"})
          ] do
        {:ok, workspace} =
          Workspace.create(%{slug: "esc-#{slug(name)}-#{ctx.n}", name: "Esc #{name}"})

        {:ok, _} =
          Store.raw_query(
            "INSERT INTO memories (id, tenant_id, workspace_id, content, metadata) VALUES (?1, 'default', ?2, 'Escaped key', ?3)",
            ["mem-esc-#{name}-#{ctx.n}", workspace.id, metadata]
          )

        report = %{"id" => "report-esc-#{name}-#{ctx.n}", "kind" => "promises"}

        readable? = fn labels, partitions ->
          Gate.with_reader(
            "default",
            workspace.id,
            SecurityLabels.grants(labels, partitions),
            &Gate.readable_row?(&1, "analysis_reports", report)
          )
        end

        refute readable?.(["internal"], []), "#{name}: read past an escaped key"
        assert readable?.(["*"], ["*"]), "#{name}: a key of everything is not turned away"
      end

      # Metadata with escapes and neither key is no reason to hold an aggregate.
      {:ok, plain} = Workspace.create(%{slug: "esc-plain-#{ctx.n}", name: "Esc plain"})

      {:ok, _} =
        Store.raw_query(
          "INSERT INTO memories (id, tenant_id, workspace_id, content, metadata) VALUES (?1, 'default', ?2, 'Plain', ?3)",
          ["mem-esc-plain-#{ctx.n}", plain.id, ~S({"note":"line\nbreak and \"quotes\""})]
        )

      assert Gate.with_reader(
               "default",
               plain.id,
               SecurityLabels.grants(["internal"], []),
               &Gate.readable_row?(&1, "analysis_reports", %{
                 "id" => "report-esc-plain-#{ctx.n}",
                 "kind" => "promises"
               })
             )
    end

    test "metadata that repeats a key is unresolved for the aggregate rule, as it is for a row",
         ctx do
      for {name, metadata} <- [
            labels: ~s({"security_labels":[],"security_labels":["restricted"]}),
            partitions: ~s({"partition_ids":[],"partition_ids":["team-a"]})
          ] do
        {:ok, workspace} = Workspace.create(%{slug: "dup-#{name}-#{ctx.n}", name: "Dup #{name}"})

        {:ok, _} =
          Store.raw_query(
            "INSERT INTO memories (id, tenant_id, workspace_id, content, metadata) VALUES (?1, 'default', ?2, 'Repeated key', ?3)",
            ["mem-dup-#{name}-#{ctx.n}", workspace.id, metadata]
          )

        report = %{"id" => "report-dup-#{name}-#{ctx.n}", "kind" => "promises"}

        readable? = fn labels, partitions ->
          Gate.with_reader(
            "default",
            workspace.id,
            SecurityLabels.grants(labels, partitions),
            &Gate.readable_row?(&1, "analysis_reports", report)
          )
        end

        # An empty workspace would let this aggregate through.
        refute readable?.(["internal"], []), "#{name}: read past a repeated key"
        assert readable?.(["*"], ["*"]), "#{name}: a key of everything is not turned away"
      end
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
      assert SecurityLabels.grants(["a", " Restricted "], ["p"]) == %{
               labels: MapSet.new(["a", "restricted"]),
               partitions: MapSet.new(["p"]),
               all_labels?: false,
               all_partitions?: false
             }

      assert SecurityLabels.grants(["*"], nil) == %{
               labels: MapSet.new(),
               partitions: MapSet.new(),
               all_labels?: true,
               all_partitions?: false
             }

      # A label named like the old internal tokens is just a label.
      assert SecurityLabels.grants(["@unresolved", "partition:p"], []).labels ==
               MapSet.new(["@unresolved", "partition:p"])

      Gate.with_reader("default", ctx.ws, SecurityLabels.grants(nil, nil), fn gate ->
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

  describe "a link to a row that was deleted" do
    setup ctx do
      {:ok, _} = OptimalEngine.Sync.enable("default", ctx.ws, "user:owner")
      fact_id = "fact-gone-#{ctx.n}"

      {:ok, _} =
        Store.raw_query(
          "INSERT INTO facts (id, tenant_id, workspace_id, fact_text, security_labels) VALUES (?1, 'default', ?2, 'Wire 5521', '[\"restricted\"]')",
          [fact_id, ctx.ws]
        )

      {:ok, _} = OptimalEngine.Sync.Capture.seal()
      {:ok, _} = Store.raw_query("DELETE FROM facts WHERE id = ?1", [fact_id])
      %{fact_id: fact_id}
    end

    test "is judged by what the ledger recorded for it, when the link names no type", ctx do
      cite = fn name, uri ->
        id = "mem-#{name}-#{ctx.n}"

        {:ok, _} =
          Store.raw_query(
            "INSERT INTO memories (id, tenant_id, workspace_id, content, citation_uri) VALUES (?1, 'default', ?2, ?3, ?4)",
            [id, ctx.ws, "Summary #{name}", uri]
          )

        id
      end

      deleted = cite.("deleted", "optimal://fact/#{ctx.fact_id}")
      never = cite.("never", "optimal://fact/fact-never-seen-#{ctx.n}")

      bare = ids(export(ctx, mint(ctx, %{}), "memories")["memories"])
      refute deleted in bare
      # An id the ledger never saw is text that looks like an id, and names nothing.
      assert never in bare

      granted = mint(ctx, %{"allowed_security_labels" => ["restricted"]})
      assert deleted in ids(export(ctx, granted, "memories")["memories"])
      assert deleted in ids(export(ctx, nil, "memories")["memories"])
    end
  end

  describe "what a payload carries besides its row" do
    test "a conflict shows a reader the row and blobs it was judged by, nothing else", ctx do
      conflict(
        ctx,
        "extra",
        "memories",
        %{"id" => ctx.plain.id, "content" => "Lunch is at one"},
        %{"note" => "SIDE CHANNEL 6612: wire to Harborview"}
      )

      token = mint(ctx, %{})
      shown = conflicts(ctx, token)

      assert shown[cid(ctx, "extra")]["local"]["row"]["content"] == "Lunch is at one"
      assert shown[cid(ctx, "extra")]["local"] |> Map.keys() |> Enum.sort() == ["blobs", "row"]
      refute body_of_conflicts(ctx, token) =~ "SIDE CHANNEL"

      # The trusted operator is shown the record as it was written.
      assert conflicts(ctx, nil)[cid(ctx, "extra")]["local"]["note"] =~ "SIDE CHANNEL"
    end

    test "a key granted everything is shown the row and blobs of a conflict version too", ctx do
      conflict(
        ctx,
        "extra-all",
        "memories",
        %{"id" => ctx.plain.id, "content" => "Lunch is at one"},
        %{"note" => "SIDE CHANNEL 6614"}
      )

      everything = mint(ctx, %{"allowed_security_labels" => ["*"], "allowed_partitions" => ["*"]})
      shown = conflicts(ctx, everything)

      assert shown[cid(ctx, "extra-all")]["local"]["row"]["content"] == "Lunch is at one"
      assert shown[cid(ctx, "extra-all")]["local"] |> Map.keys() |> Enum.sort() == ["blobs", "row"]
      assert shown[cid(ctx, "extra-all")]["remote"] |> Map.keys() |> Enum.sort() == ["blobs", "row"]
      refute body_of_conflicts(ctx, everything) =~ "SIDE CHANNEL"
    end

    test "a ledger entry shows a reader the row and blobs, nothing else", ctx do
      {:ok, _} = OptimalEngine.Sync.enable("default", ctx.ws, "user:owner")

      captured(ctx, "memories", "mem-extra-#{ctx.n}", %{
        "row" => %{"id" => "mem-extra-#{ctx.n}", "content" => "Appended note 7741"},
        "blobs" => %{},
        "note" => "SIDE CHANNEL 6613"
      })

      answer = ledger(ctx, mint(ctx, %{}))
      body = Jason.encode!(answer["mutations"])

      assert body =~ "Appended note 7741"
      refute body =~ "SIDE CHANNEL"
    end

    test "an entry of an unknown entity type is judged by the labels of the row it carries", ctx do
      {:ok, _} = OptimalEngine.Sync.enable("default", ctx.ws, "user:owner")

      append(ctx, "app_note", "note-conf-#{ctx.n}", %{
        "row" => %{"id" => "n1", "text" => "Board note 5521", "security_labels" => ["confidential"]}
      })

      append(ctx, "app_note", "note-part-#{ctx.n}", %{
        "row" => %{"id" => "n2", "text" => "Atlas note 5522", "partition_ids" => ["team-a"]}
      })

      append(ctx, "app_note", "note-bad-#{ctx.n}", %{
        "row" => %{"id" => "n3", "text" => "Garbled note 5523", "security_labels" => "{not json"}
      })

      append(ctx, "app_note", "note-open-#{ctx.n}", %{
        "row" => %{"id" => "n4", "text" => "Open note 5524"}
      })

      append(ctx, "app_note", "note-bare-#{ctx.n}", %{"title" => "No row 5525"})

      seen = fn metadata -> Jason.encode!(ledger(ctx, mint(ctx, metadata))["mutations"]) end

      bare = seen.(%{})
      refute bare =~ "Board note 5521"
      refute bare =~ "Atlas note 5522"
      refute bare =~ "Garbled note 5523"
      assert bare =~ "Open note 5524"
      assert bare =~ "No row 5525"

      assert seen.(%{"allowed_security_labels" => ["confidential"]}) =~ "Board note 5521"
      assert seen.(%{"allowed_partitions" => ["team-a"]}) =~ "Atlas note 5522"
      refute seen.(%{"allowed_security_labels" => ["confidential"]}) =~ "Garbled note 5523"
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

  describe "the ceiling for what the dump routes hand out" do
    setup do
      Application.delete_env(:optimal_engine, :sync_serve_max_class)
      :ok
    end

    test "a key granted restricted is not exported restricted rows", ctx do
      granted =
        mint(ctx, %{"allowed_security_labels" => ["restricted", "internal", "confidential"]})

      memories = export(ctx, granted, "memories")
      refute ctx.secret.id in ids(memories["memories"])
      assert ctx.internal.id in ids(memories["memories"])
      assert memories["withheld"] >= 1 and memories["complete"] == false

      refute ctx.secret_doc.id in ids(export(ctx, granted, "signals")["signals"])
      refute "deal-room-#{ctx.n}" in slugs(export(ctx, granted, "workspace"))
    end

    test "a key granted * for labels, and the operator, are not held to it", ctx do
      root = mint(ctx, %{"allowed_security_labels" => ["*"], "allowed_partitions" => ["*"]})
      labels_only = mint(ctx, %{"allowed_security_labels" => ["*"]})

      for token <- [root, labels_only, nil] do
        assert ctx.secret.id in ids(export(ctx, token, "memories")["memories"])
      end
    end

    test "the ceiling can be raised", ctx do
      Application.put_env(:optimal_engine, :sync_serve_max_class, "restricted")
      granted = mint(ctx, %{"allowed_security_labels" => ["restricted"]})

      assert ctx.secret.id in ids(export(ctx, granted, "memories")["memories"])
    end

    test "a conflict about a restricted row is redacted for a key held to it", ctx do
      conflict(ctx, "fact", "facts", %{
        "id" => "fact-#{ctx.n}",
        "fact_text" => "Bank detail 4471",
        "security_labels" => ~s(["restricted"])
      })

      granted = mint(ctx, %{"allowed_security_labels" => ["restricted"]})
      assert conflicts(ctx, granted)[cid(ctx, "fact")]["redacted"]
      refute body_of_conflicts(ctx, granted) =~ "Bank detail"

      root = mint(ctx, %{"allowed_security_labels" => ["*"], "allowed_partitions" => ["*"]})
      refute conflicts(ctx, root)[cid(ctx, "fact")]["redacted"]
    end
  end

  describe "partitions follow retrieval" do
    test "a row in two partitions is read by a key that holds either", ctx do
      both = remember(ctx.ws, "Joint roadmap draft", [], ["team-a", "team-b"]).memory
      read = fn partitions -> ids(export(ctx, mint(ctx, partitions), "memories")["memories"]) end

      assert both.id in read.(%{"allowed_partitions" => ["team-b"]})
      assert both.id in read.(%{"allowed_partitions" => ["team-a", "team-c"]})
      refute both.id in read.(%{"allowed_partitions" => ["team-c"]})
      refute both.id in read.(%{})
    end

    test "a row drawn from a row in another partition needs a partition of each", ctx do
      # In team-a, staged from a source package that is in team-b.
      source = remember(ctx.ws, "Atlas vendor quotes", [], ["team-b"]).memory
      package = source.metadata["memory_core_source_package_id"]

      {:ok, [[stored]]} =
        Store.raw_query("SELECT partition_ids FROM source_packages WHERE id = ?1", [package])

      assert stored =~ "team-b"

      {:ok, staged} =
        Versioned.create(%{
          content: "Joint vendor summary",
          workspace_id: ctx.ws,
          metadata: %{
            "memory_core_source_package_id" => package,
            "partition_ids" => ["team-a"]
          }
        })

      read = fn partitions ->
        ids(export(ctx, mint(ctx, %{"allowed_partitions" => partitions}), "memories")["memories"])
      end

      # Sharing one partition of the union is not enough: the memory's own
      # (team-a) and its source's (team-b) are each judged.
      refute staged.id in read.(["team-a"])
      refute staged.id in read.(["team-b"])
      assert staged.id in read.(["team-a", "team-b"])
      assert staged.id in read.(["team-a", "team-b", "team-c"])
      assert source.id in read.(["team-b"])
    end

    test "a partition does not stand in for a label", ctx do
      held = remember(ctx.ws, "Atlas escrow terms", ["restricted"], ["team-a"]).memory

      refute held.id in ids(
               export(ctx, mint(ctx, %{"allowed_partitions" => ["team-a"]}), "memories")["memories"]
             )

      both =
        mint(ctx, %{"allowed_partitions" => ["team-a"], "allowed_security_labels" => ["restricted"]})

      assert held.id in ids(export(ctx, both, "memories")["memories"])
    end

    test "signals and wiki pages follow the partitions of their sources", ctx do
      {:ok, atlas} =
        Intake.process("Atlas staffing plan: two engineers join in March",
          workspace_id: ctx.ws,
          node: "operator",
          write_files: false
        )

      {:ok, _} =
        Store.raw_query(
          "UPDATE contexts SET metadata = json_set(COALESCE(metadata, '{}'), '$.partition_ids', json('[\"team-a\"]')) WHERE id = ?1",
          [atlas.context.id]
        )

      atlas_chunk = chunk(ctx.ws, "chk-atlas-#{ctx.n}", atlas.context.id, "Atlas staffing plan")
      wiki(ctx.ws, "atlas-#{ctx.n}", "Staffing", [atlas_chunk])

      only_a = mint(ctx, %{"allowed_partitions" => ["team-a"]})
      bare = mint(ctx, %{})

      assert ids(export(ctx, only_a, "signals")["signals"]) == [atlas.context.id]
      assert atlas.context.id not in ids(export(ctx, bare, "signals")["signals"])

      assert slugs(export(ctx, only_a, "workspace")) == ["atlas-#{ctx.n}"]
      refute "atlas-#{ctx.n}" in slugs(export(ctx, bare, "workspace"))
    end
  end

  describe "what a row derives from" do
    test "a memory staged from a restricted source is not exported without the label", ctx do
      {:ok, staged} =
        Versioned.create(%{
          content: "Escrow summary",
          workspace_id: ctx.ws,
          metadata: %{
            "memory_core_source_package_id" => ctx.secret.metadata["memory_core_source_package_id"]
          }
        })

      refute staged.id in ids(
               export(ctx, mint(ctx, %{"allowed_security_labels" => ["internal"]}), "memories")[
                 "memories"
               ]
             )

      assert staged.id in ids(
               export(ctx, mint(ctx, %{"allowed_security_labels" => ["restricted"]}), "memories")[
                 "memories"
               ]
             )
    end

    test "a key granted restricted sees the page citing a restricted document", ctx do
      token = mint(ctx, %{"allowed_security_labels" => ["restricted", "internal"]})

      assert "deal-room-#{ctx.n}" in slugs(export(ctx, token, "workspace"))
      assert "docs-calendar-#{ctx.n}" in slugs(export(ctx, token, "workspace"))

      refute "deal-room-#{ctx.n}" in slugs(export(ctx, mint(ctx, %{}), "workspace"))
    end

    test "metadata that repeats a label key is unresolved for a row, whichever copy is empty",
         ctx do
      insert = fn name, metadata ->
        id = "mem-repeat-#{name}-#{ctx.n}"

        {:ok, _} =
          Store.raw_query(
            "INSERT INTO memories (id, tenant_id, workspace_id, content, metadata) VALUES (?1, 'default', ?2, ?3, ?4)",
            [id, ctx.ws, "Repeated key #{name}", metadata]
          )

        id
      end

      seen = fn id, grants -> id in ids(export(ctx, mint(ctx, grants), "memories")["memories"]) end

      # SQLite keeps the first of two keys and Jason the last, so neither may
      # decide what the row is labelled. The label axis is unresolved: a reader of
      # some labels is turned away, one of every label is not.
      for {name, metadata} <- [
            labels_last_empty: ~s({"security_labels":["restricted"],"security_labels":[]}),
            labels_first_empty: ~s({"security_labels":[],"security_labels":["restricted"]})
          ] do
        id = insert.(name, metadata)

        refute seen.(id, %{"allowed_security_labels" => ["restricted", "internal"]}),
               "#{name} was shown to a reader of some labels"

        assert seen.(id, %{"allowed_security_labels" => ["*"]}),
               "#{name} was hidden from a reader of every label"
      end

      # The partition axis is unresolved on its own: every label does not read past it.
      for {name, metadata} <- [
            partitions_last_empty: ~s({"partition_ids":["team-a"],"partition_ids":[]}),
            partitions_first_empty: ~s({"partition_ids":[],"partition_ids":["team-a"]})
          ] do
        id = insert.(name, metadata)

        refute seen.(id, %{"allowed_security_labels" => ["*"]}),
               "#{name} was shown to a reader of no partition"

        refute seen.(id, %{"allowed_security_labels" => ["*"], "allowed_partitions" => ["team-a"]}),
               "#{name} was shown to a reader of one partition"

        assert seen.(id, %{"allowed_security_labels" => ["*"], "allowed_partitions" => ["*"]}),
               "#{name} was hidden from a reader of every partition"
      end
    end

    test "a label that is not a string hides the row", ctx do
      for {name, labels} <- [
            number: "[1]",
            null: "[null]",
            object: ~s([{"a":1}]),
            blank: ~s(["  "])
          ] do
        memory = remember(ctx.ws, "Odd labels #{name}", []).memory
        set_labels(memory.id, labels)

        everything =
          mint(ctx, %{
            "allowed_security_labels" => ["restricted", "internal", "confidential", "1", "a"]
          })

        refute memory.id in ids(export(ctx, everything, "memories")["memories"]),
               "#{name} was shown"

        assert memory.id in ids(
                 export(
                   ctx,
                   mint(ctx, %{"allowed_security_labels" => ["*"], "allowed_partitions" => ["*"]}),
                   "memories"
                 )["memories"]
               )
      end
    end

    test "partitions that cannot be read hide the row from a reader of every label", ctx do
      for {name, partitions} <- [
            text: ~s("not a list"),
            number: "[1]",
            null: "[null]",
            object: ~s([{"a":1}])
          ] do
        memory = remember(ctx.ws, "Odd partitions #{name}", []).memory

        {:ok, _} =
          Store.raw_query(
            "UPDATE memories SET metadata = json_set(COALESCE(metadata, '{}'), '$.partition_ids', json(?2)) WHERE id = ?1",
            [memory.id, partitions]
          )

        every_label = mint(ctx, %{"allowed_security_labels" => ["*"]})

        with_partitions =
          mint(ctx, %{"allowed_security_labels" => ["*"], "allowed_partitions" => ["team-a"]})

        every_partition = mint(ctx, %{"allowed_partitions" => ["*"]})
        everything = mint(ctx, %{"allowed_security_labels" => ["*"], "allowed_partitions" => ["*"]})

        for token <- [every_label, with_partitions] do
          refute memory.id in ids(export(ctx, token, "memories")["memories"]),
                 "#{name} was shown to a reader of every label"
        end

        for token <- [every_partition, everything] do
          assert memory.id in ids(export(ctx, token, "memories")["memories"]),
                 "#{name} was hidden from a reader of every partition"
        end
      end
    end

    test "class names are not case sensitive and labels are trimmed", ctx do
      memory = remember(ctx.ws, "Casing check", []).memory
      restricted = mint(ctx, %{"allowed_security_labels" => ["restricted"]})
      internal = mint(ctx, %{"allowed_security_labels" => ["internal"]})

      for variant <- [~s([" Restricted "]), ~s(["RESTRICTED"]), ~s(["restricted"])] do
        set_labels(memory.id, variant)

        refute memory.id in ids(export(ctx, internal, "memories")["memories"]),
               "#{variant} was shown"

        assert memory.id in ids(export(ctx, restricted, "memories")["memories"]),
               "#{variant} was hidden"
      end
    end

    test "a link to a chunk nobody wrote hides the row", ctx do
      {:ok, ghost} =
        Versioned.create(%{
          content: "Cites a chunk that is gone",
          workspace_id: ctx.ws,
          source_chunk_id: "chk-ghost-#{ctx.n}"
        })

      refute ghost.id in ids(export(ctx, mint(ctx, %{}), "memories")["memories"])
      assert ghost.id in ids(export(ctx, nil, "memories")["memories"])
    end

    test "a row with a missing source is not read by a key of every label and some partitions",
         ctx do
      {:ok, ghost} =
        Versioned.create(%{
          content: "Partitioned, and cites a chunk that is gone",
          workspace_id: ctx.ws,
          source_chunk_id: "chk-ghost-part-#{ctx.n}",
          metadata: %{"partition_ids" => ["team-a"]}
        })

      every_label = mint(ctx, %{"allowed_security_labels" => ["*"]})

      every_label_some_partitions =
        mint(ctx, %{"allowed_security_labels" => ["*"], "allowed_partitions" => ["team-a"]})

      everything = mint(ctx, %{"allowed_security_labels" => ["*"], "allowed_partitions" => ["*"]})

      for token <- [every_label, every_label_some_partitions] do
        refute ghost.id in ids(export(ctx, token, "memories")["memories"])
      end

      assert ghost.id in ids(export(ctx, everything, "memories")["memories"])
    end

    test "an unknown classification level is read by no one", ctx do
      Gate.with_reader(
        "default",
        ctx.ws,
        SecurityLabels.grants(["restricted", "internal", "confidential"], []),
        fn gate ->
          for {level, readable?} <- [
                {"internal", true},
                {"public", true},
                {"restricted", true},
                {"mystery", false},
                {"RESTRICTED", true}
              ] do
            id = "chk-level-#{level}-#{ctx.n}"
            chunk(ctx.ws, id, ctx.plain_doc.id, "Level #{level}")

            {:ok, _} =
              Store.raw_query("UPDATE chunks SET classification_level = ?2 WHERE id = ?1", [
                id,
                level
              ])

            assert Gate.readable_id?(gate, "chunks", id) == readable?, "level #{level}"
          end
        end
      )
    end

    test "a memory with fifty versions is read when its root may be", ctx do
      [root | _] = chain = version_chain(ctx.ws, 50)
      newest = List.last(chain)
      bare = SecurityLabels.grants([], [])

      # A gate that starts at the newest version has read none of the others.
      Gate.with_reader("default", ctx.ws, bare, fn gate ->
        assert Gate.readable_id?(gate, "memories", newest)
      end)

      set_labels(root, ~s(["restricted"]))

      Gate.with_reader("default", ctx.ws, bare, fn gate ->
        refute Gate.readable_id?(gate, "memories", newest)
      end)

      Gate.with_reader("default", ctx.ws, SecurityLabels.grants(["restricted"], []), fn gate ->
        assert Gate.readable_id?(gate, "memories", newest)
      end)
    end

    test "rows that link each other in a loop are read together", ctx do
      source = ctx.secret.metadata["memory_core_source_package_id"]
      pool = "pool-#{ctx.n}"
      first = "cp-first-#{ctx.n}"
      second = "cp-second-#{ctx.n}"

      {:ok, _} =
        Store.raw_query(
          "INSERT INTO active_memory_pools (id, tenant_id, workspace_id, context_package_links) VALUES (?1, 'default', ?2, ?3)",
          [pool, ctx.ws, Jason.encode!([first])]
        )

      for {id, sources} <- [{first, [source]}, {second, []}] do
        {:ok, _} =
          Store.raw_query(
            "INSERT INTO context_packages (id, tenant_id, workspace_id, active_memory_pool_id, source_package_links) VALUES (?1, 'default', ?2, ?3, ?4)",
            [id, ctx.ws, pool, Jason.encode!(sources)]
          )
      end

      Gate.with_reader("default", ctx.ws, SecurityLabels.grants([], []), fn gate ->
        allowed = Gate.readable_ids(gate, "context_packages", [first, second])

        refute first in allowed
        refute second in allowed
        refute Gate.readable_id?(gate, "active_memory_pools", pool)
      end)
    end
  end

  describe "an answer says what it leaves out" do
    test "withheld and complete", ctx do
      bare = export(ctx, mint(ctx, %{}), "memories")

      assert bare["withheld"] >= 3
      assert bare["complete"] == false

      everything = mint(ctx, %{"allowed_security_labels" => ["*"], "allowed_partitions" => ["*"]})

      for kind <- ["memories", "signals", "workspace"] do
        operator = export(ctx, nil, kind)
        assert operator["withheld"] == 0 and operator["complete"] == true

        root = export(ctx, everything, kind)
        assert root["withheld"] == 0 and root["complete"] == true
      end

      assert export(ctx, mint(ctx, %{}), "signals")["complete"] == false
      assert export(ctx, mint(ctx, %{}), "workspace")["withheld"] >= 5
    end

    test "a key granted * reads everything", ctx do
      root = mint(ctx, %{"allowed_security_labels" => ["*"], "allowed_partitions" => ["*"]})

      read = ids(export(ctx, root, "memories")["memories"])
      for memory <- [ctx.secret, ctx.internal, ctx.team, ctx.plain], do: assert(memory.id in read)

      assert "deal-room-#{ctx.n}" in slugs(export(ctx, root, "workspace"))
      assert ctx.secret_doc.id in ids(export(ctx, root, "signals")["signals"])
    end

    test "a key granted * for labels only still needs the partitions", ctx do
      labels_only = mint(ctx, %{"allowed_security_labels" => ["*"]})

      read = ids(export(ctx, labels_only, "memories")["memories"])
      assert ctx.secret.id in read
      refute ctx.team.id in read
    end

    test "the recommended machine default reads up to confidential, not restricted or custom labels",
         ctx do
      confidential = remember(ctx.ws, "Q3 pricing sheet", ["confidential"]).memory
      custom = remember(ctx.ws, "Vendor shortlist", ["private"]).memory

      key =
        mint(ctx, %{
          "allowed_security_labels" => ["public", "internal", "confidential"],
          "allowed_partitions" => []
        })

      read = ids(export(ctx, key, "memories")["memories"])

      for memory <- [ctx.plain, ctx.internal, confidential], do: assert(memory.id in read)
      for memory <- [ctx.secret, custom, ctx.team], do: refute(memory.id in read)
    end

    test "a keyed export is of the reader's tenant, whatever tenant is asked for", ctx do
      reader = %OptimalEngine.ReadScope{
        tenant_id: "default",
        principal: "user:reader",
        labels: ["*"],
        partitions: ["*"]
      }

      assert {:ok, snapshot, 0} =
               OptimalEngine.Batch.read_workspace(ctx.ws, tenant_id: "other", reader: reader)

      assert snapshot.tenant_id == "default"

      assert {:ok, %{tenant_id: "other"}, 0} =
               OptimalEngine.Batch.read_workspace(ctx.ws, tenant_id: "other")
    end
  end

  describe "wiki pages of a large workspace" do
    setup ctx do
      # 300 pages; every third cites the restricted chunk, the rest the plain one.
      {:ok, _} =
        Store.raw_query(
          """
          WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 300)
          INSERT INTO wiki_pages (tenant_id, workspace_id, slug, audience, version, frontmatter, body)
          SELECT 'default', ?1, 'bulk-' || ?2 || '-' || i, 'default', 1, '{}', 'Page ' || i FROM n
          """,
          [ctx.ws, ctx.n]
        )

      {:ok, _} =
        Store.raw_query(
          """
          WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 300)
          INSERT INTO citations (tenant_id, workspace_id, wiki_slug, wiki_audience, chunk_id, claim_hash)
          SELECT 'default', ?1, 'bulk-' || ?2 || '-' || i, 'default',
                 CASE WHEN i % 3 = 0 THEN 'chk-secret-' || ?2 ELSE 'chk-plain-' || ?2 END, 'h'
          FROM n
          """,
          [ctx.ws, ctx.n]
        )

      :ok
    end

    test "the export holds every page, not the first fifty", ctx do
      slugs = slugs(export(ctx, nil, "workspace"))
      assert length(slugs) == 302
      assert "bulk-#{ctx.n}-300" in slugs and "bulk-#{ctx.n}-1" in slugs
    end

    test "a keyed export holds the pages it may see among all of them", ctx do
      token = mint(ctx, %{"allowed_security_labels" => ["internal"]})
      snapshot = export(ctx, token, "workspace")

      shown = slugs(snapshot)
      assert length(shown) == 201
      assert "bulk-#{ctx.n}-299" in shown
      refute "bulk-#{ctx.n}-3" in shown
      refute "bulk-#{ctx.n}-300" in shown
      refute "deal-room-#{ctx.n}" in shown
    end

    test "the gate reads a number of times that follows the chunks, not the pages", ctx do
      token = mint(ctx, %{"allowed_security_labels" => ["internal"]})

      {snapshot, reads} = counting_reads(fn -> export(ctx, token, "workspace") end)

      assert length(slugs(snapshot)) == 201
      # One query per page would be more than 300 for the citations alone.
      assert reads < 60, "the gate made #{reads} reads"
    end

    test "a wiki list that cannot be read is an export_failed, never a shorter export", ctx do
      for token <- [mint(ctx, %{}), nil] do
        conn =
          with_renamed_column("wiki_pages", "curated_by", "curated_by_x", fn ->
            get_as(export_path(ctx, "workspace"), token)
          end)

        assert conn.status == 500
        assert Jason.decode!(conn.resp_body) == %{"error" => "export_failed"}
      end
    end
  end

  describe "when the Store cannot be read" do
    test "the gate's failure is a 503 with no partial body", ctx do
      token = mint(ctx, %{})

      conn =
        with_renamed_column("contexts", "metadata", "metadata_x", fn ->
          get_as(export_path(ctx, "signals"), token)
        end)

      assert conn.status == 503
      assert Jason.decode!(conn.resp_body) |> Map.keys() |> Enum.sort() == ["detail", "error"]
      refute conn.resp_body =~ "signals"
    end

    test "a failing export read is a 500, never an empty export", ctx do
      for token <- [mint(ctx, %{}), nil] do
        conn =
          with_renamed_column("contexts", "l1_overview", "l1_overview_x", fn ->
            get_as(export_path(ctx, "signals"), token)
          end)

        assert conn.status == 500
        assert Jason.decode!(conn.resp_body) == %{"error" => "export_failed"}
      end
    end
  end

  describe "the storage ledger" do
    test "a keyed reader is shown the changes its grants cover", ctx do
      Application.delete_env(:optimal_engine, :sync_serve_max_class)
      {:ok, _} = OptimalEngine.Sync.enable("default", ctx.ws, "user:owner")
      path = "/api/storage/workspaces/#{ctx.ws}/mutations?limit=500"

      remember(ctx.ws, "Ledger secret 7731", ["confidential"])
      remember(ctx.ws, "Ledger open 7732", [])
      remember(ctx.ws, "Ledger restricted 7733", ["restricted"])
      {:ok, _} = OptimalEngine.Sync.Capture.seal()

      bare = Jason.decode!(get_as(path, mint(ctx, %{})).resp_body)

      confidential =
        Jason.decode!(
          get_as(path, mint(ctx, %{"allowed_security_labels" => ["confidential"]})).resp_body
        )

      operator = Jason.decode!(get_as(path, nil).resp_body)

      refute Jason.encode!(bare["mutations"]) =~ "Ledger secret 7731"
      assert Jason.encode!(bare["mutations"]) =~ "Ledger open 7732"
      assert bare["withheld"] >= 2 and bare["complete"] == false

      assert Jason.encode!(confidential["mutations"]) =~ "Ledger secret 7731"

      # The data-class ceiling applies to everyone, the operator included.
      for answer <- [bare, confidential, operator],
          do: refute(Jason.encode!(answer["mutations"]) =~ "Ledger restricted 7733")

      assert Jason.encode!(operator["mutations"]) =~ "Ledger secret 7731"
      assert operator["withheld"] >= 1
    end
  end

  describe "conflicts of a reader" do
    test "a conflict about a resource the principal may not read is left out and counted", ctx do
      principal = "user:denied-conflict-#{ctx.n}"
      token = mint(ctx, %{"allowed_security_labels" => ["restricted", "internal"]}, principal)

      conflict(ctx, "acl", "memories", %{
        "id" => ctx.internal.id,
        "content" => "The Northwind offsite is Thursday"
      })

      conflict(ctx, "open", "memories", %{"id" => ctx.plain.id, "content" => "Lunch is at one"})

      :ok =
        ACL.deny(%{
          resource_uri: "optimal://memory/#{ctx.ws}/#{ctx.internal.id}",
          principal_id: principal,
          tenant_id: "default"
        })

      answer = conflicts_answer(ctx, token)

      assert Enum.map(answer["conflicts"], & &1["id"]) == [cid(ctx, "open")]
      assert answer["withheld"] == 1
      assert answer["complete"] == false

      assert length(conflicts_answer(ctx, nil)["conflicts"]) == 2
    end

    test "a payload that holds no row is redacted for every key but *", ctx do
      {:ok, _} =
        Store.raw_query(
          """
          INSERT INTO sync_conflicts (id, tenant_id, workspace_id, table_name, entity_key, kind, resolution, local_payload, remote_payload, remote_device)
          VALUES (?1, 'default', ?2, 'memories', ?3, 'concurrent_change', 'kept_local_newer', ?4, ?4, 'rep_remote')
          """,
          [cid(ctx, "rowless"), ctx.ws, ctx.plain.id, Jason.encode!(%{"note" => "no row here"})]
        )

      everything =
        mint(ctx, %{"allowed_security_labels" => ["restricted", "internal", "confidential"]})

      root = mint(ctx, %{"allowed_security_labels" => ["*"], "allowed_partitions" => ["*"]})

      assert conflicts(ctx, everything)[cid(ctx, "rowless")]["redacted"]
      refute conflicts(ctx, root)[cid(ctx, "rowless")]["redacted"]
      refute conflicts(ctx, nil)[cid(ctx, "rowless")]["redacted"]
    end

    test "a version is redacted when the row has been labelled since", ctx do
      conflict(ctx, "late", "memories", %{"id" => ctx.plain.id, "content" => "Lunch is at one"})
      refute conflicts(ctx, mint(ctx, %{}))[cid(ctx, "late")]["redacted"]

      set_labels(ctx.plain.id, ~s(["restricted"]))

      shown = conflicts(ctx, mint(ctx, %{}))[cid(ctx, "late")]
      assert shown["redacted"]
      refute Jason.encode!(shown) =~ "Lunch is at one"
    end

    test "the key of a conflict that names a page is hashed when it is redacted", ctx do
      key = Jason.encode!(["default", "deal-room-#{ctx.n}", "default", 1])

      row = %{
        "tenant_id" => "default",
        "slug" => "deal-room-#{ctx.n}",
        "audience" => "default",
        "version" => 1,
        "body" => "Offer notes {{cite: optimal://chunk/chk-secret-#{ctx.n}}}"
      }

      {:ok, _} =
        Store.raw_query(
          """
          INSERT INTO sync_conflicts (id, tenant_id, workspace_id, table_name, entity_key, kind, resolution, local_payload, remote_payload, remote_device)
          VALUES (?1, 'default', ?2, 'wiki_pages', ?3, 'concurrent_change', 'kept_local_newer', ?4, ?4, 'rep_remote')
          """,
          [cid(ctx, "page"), ctx.ws, key, Jason.encode!(%{"row" => row, "blobs" => %{}})]
        )

      bare = body_of_conflicts(ctx, mint(ctx, %{}))
      refute bare =~ "deal-room"
      refute bare =~ "Offer notes"

      shown = conflicts(ctx, mint(ctx, %{}))[cid(ctx, "page")]
      assert shown["redacted"] and shown["key_hidden"]
      assert String.starts_with?(shown["entity_key"], "sha256:")

      operator = conflicts(ctx, nil)[cid(ctx, "page")]
      assert operator["entity_key"] == key
      refute operator["redacted"]
    end

    test "a conflict carries the redacted flag for the operator too", ctx do
      conflict(ctx, "plain", "memories", %{"id" => ctx.plain.id, "content" => "Lunch is at one"})

      assert conflicts(ctx, nil)[cid(ctx, "plain")]["redacted"] == false
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

  defp slugs(snapshot), do: Enum.map(snapshot["wiki"], & &1["slug"])

  defp set_labels(memory_id, json) do
    {:ok, _} =
      Store.raw_query(
        "UPDATE memories SET metadata = json_set(COALESCE(metadata, '{}'), '$.security_labels', json(?2)) WHERE id = ?1",
        [memory_id, json]
      )
  end

  # A memory and `count - 1` newer versions of it, oldest first.
  defp version_chain(ws, count) do
    {:ok, first} = Versioned.create(%{content: "Version 1", workspace_id: ws})

    2..count
    |> Enum.reduce([first.id], fn number, [latest | _] = acc ->
      {:ok, next} = Versioned.update(latest, %{content: "Version #{number}"})
      [next.id | acc]
    end)
    |> Enum.reverse()
  end

  # Runs `fun` while `column` of `table` has another name: every read of it
  # fails, as a read of the Store does when it errors.
  defp counting_reads(fun) do
    id = {:gate_reads, System.unique_integer([:positive])}
    parent = self()

    :ok =
      :telemetry.attach(
        id,
        [:optimal_engine, :sync, :gate_query],
        fn _event, _measurements, _meta, _config -> send(parent, :gate_read) end,
        nil
      )

    result =
      try do
        fun.()
      after
        :telemetry.detach(id)
      end

    {result, drain_reads(0)}
  end

  defp drain_reads(count) do
    receive do
      :gate_read -> drain_reads(count + 1)
    after
      0 -> count
    end
  end

  defp with_renamed_column(table, column, renamed, fun) do
    {:ok, _} = Store.raw_query("ALTER TABLE #{table} RENAME COLUMN #{column} TO #{renamed}", [])

    try do
      fun.()
    after
      {:ok, _} = Store.raw_query("ALTER TABLE #{table} RENAME COLUMN #{renamed} TO #{column}", [])
    end
  end

  defp conflicts_answer(ctx, token) do
    path = "/api/sync/conflicts?" <> URI.encode_query(%{"workspace" => ctx.ws})
    conn = get_as(path, token)
    assert conn.status == 200, "conflicts: #{conn.status} #{conn.resp_body}"
    Jason.decode!(conn.resp_body)
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

  defp bootstrap_token do
    id = :crypto.strong_rand_bytes(12) |> Base.encode16(case: :lower)
    token = "oe_#{id}_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    :ok =
      OptimalEngine.Auth.Bootstrap.run(%{
        "OPTIMAL_BOOTSTRAP_KEY" => token,
        "OPTIMAL_BOOTSTRAP_SCOPES" => "*"
      })

    token
  end

  # POST /api/auth/keys as `parent`, the way an operator or a control plane mints.
  defp mint_from(ctx, parent, grants) do
    principal = "user:minted-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Principal.upsert(%{
        id: principal,
        tenant_id: "default",
        kind: :agent,
        display_name: principal
      })

    body =
      Map.merge(
        %{
          "name" => "minted #{System.unique_integer([:positive])}",
          "scopes" => ["read"],
          "workspace_scope" => [ctx.ws],
          "principal_id" => principal
        },
        grants
      )

    conn =
      conn(:post, "/api/auth/keys", Jason.encode!(body))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer " <> parent)
      |> Router.call(@opts)

    assert conn.status == 201, "mint: #{conn.status} #{conn.resp_body}"
    Jason.decode!(conn.resp_body)["key"]
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

  defp slug(name), do: name |> to_string() |> String.replace("_", "-")

  defp cid(ctx, name), do: "c-#{name}-#{ctx.n}"

  defp conflict(ctx, name, table, row, extra \\ %{}) do
    id = cid(ctx, name)
    payload = Jason.encode!(Map.merge(%{"row" => row, "blobs" => %{}}, extra))

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

  defp append(ctx, entity_type, entity_id, payload) do
    {:ok, _} =
      OptimalEngine.Storage.PolicyStore.append_mutation(%{
        workspace_id: ctx.ws,
        device_id: "dev-#{ctx.n}",
        entity_type: entity_type,
        entity_id: entity_id,
        operation: "create",
        payload: payload
      })
  end

  # A ledger row as change capture writes it (a storage entry may not name a table).
  defp captured(ctx, entity_type, entity_id, payload) do
    replica = OptimalEngine.Sync.replica_id()
    sequence = 900_000_000 + ctx.n

    {:ok, _} =
      Store.raw_query(
        """
        INSERT INTO sync_mutations
          (id, tenant_id, workspace_id, device_id, entity_type, entity_id, operation, payload,
           payload_hash, idempotency_key, occurred_at)
        VALUES (?1, 'default', ?2, ?3, ?4, ?5, 'create', ?6, 'h', ?7, '2026-10-14T12:00:00.000')
        """,
        [
          "mut_#{replica}_#{sequence}",
          ctx.ws,
          replica,
          entity_type,
          entity_id,
          Jason.encode!(payload),
          "#{replica}:#{sequence}"
        ]
      )
  end

  defp ledger(ctx, token) do
    conn = get_as("/api/storage/workspaces/#{ctx.ws}/mutations?limit=500", token)
    assert conn.status == 200, "ledger: #{conn.status} #{conn.resp_body}"
    Jason.decode!(conn.resp_body)
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
