defmodule OptimalEngine.API.ReadGatesTest do
  @moduledoc """
  The routes that return one record or a page of them (`GET /api/memory`,
  `GET /api/memory/:id`, `GET /api/signals/:id`, `GET /api/wiki/:slug`,
  `GET /api/search`, `GET /api/grep`) show a keyed caller only what its label
  and partition grants cover and its principal may read, as governed retrieval
  does, with the labels of the rows each was derived from. A record the key may
  not see is a 404, as if it were not there. A list says how many it left out.
  """

  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias OptimalEngine.API.Router
  alias OptimalEngine.Auth.ApiKey
  alias OptimalEngine.Identity.{ACL, Principal}
  alias OptimalEngine.Memory
  alias OptimalEngine.Pipeline.Intake
  alias OptimalEngine.Store
  alias OptimalEngine.TestSupport.KeyGrantsBackfill
  alias OptimalEngine.Workspace

  @opts Router.init([])

  # What a machine key should hold, and what migration 85 gives a key without grants.
  @machine %{
    "allowed_security_labels" => ["public", "internal", "confidential"],
    "allowed_partitions" => []
  }

  # What such a key reads, route by route: the confidential row, not the restricted one.
  @reads_default %{
    memory: {200, 404},
    memory_list: {true, false},
    signal: {200, 404},
    wiki: {200, 404},
    search_memory: {true, false},
    search_document: {true, false},
    grep: {true, false}
  }

  setup do
    n = System.unique_integer([:positive])
    {:ok, workspace} = Workspace.create(%{slug: "gates-#{n}", name: "Gates #{n}"})
    ws = workspace.id

    secret = remember(ws, "Wire 4471 to Harborview, routing 4407", ["restricted"])
    confidential = remember(ws, "Q3 pricing sheet for Northwind", ["confidential"])
    custom = remember(ws, "Vendor shortlist for Fabrikam", ["private"])
    team = remember(ws, "Team Atlas roadmap draft", [], ["team-a"])
    plain = remember(ws, "Lunch is at one on Friday", [])

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

    {:ok, confidential_doc} =
      Intake.process("Brightwater renewal: the contract renews at two million for three years",
        workspace_id: ws,
        node: "operator",
        security_labels: ["confidential"],
        write_files: false
      )

    secret_chunk =
      chunk(ws, "chk-secret-#{n}", secret_doc.context.id, "Zephyrcorp offer of 41 million")

    plain_chunk = chunk(ws, "chk-plain-#{n}", plain_doc.context.id, "the changelog goes out Monday")

    wiki(ws, "deal-room-#{n}", "Offer notes {{cite: optimal://chunk/#{secret_chunk}}}", [
      secret_chunk
    ])

    confidential_chunk =
      chunk(
        ws,
        "chk-confidential-#{n}",
        confidential_doc.context.id,
        "Brightwater renewal at two million"
      )

    wiki(ws, "docs-calendar-#{n}", "Release notes", [plain_chunk])

    wiki(
      ws,
      "renewals-#{n}",
      "Renewal notes {{cite: optimal://chunk/#{confidential_chunk}}}",
      [confidential_chunk]
    )

    %{
      n: n,
      ws: ws,
      secret: secret.memory,
      confidential: confidential.memory,
      custom: custom.memory,
      team: team.memory,
      plain: plain.memory,
      secret_doc: secret_doc.context,
      plain_doc: plain_doc.context,
      confidential_doc: confidential_doc.context
    }
  end

  describe "a record by id" do
    test "a memory the key may not see is not found", ctx do
      bare = mint(ctx, %{})
      restricted = mint(ctx, %{"allowed_security_labels" => ["restricted"]})

      assert get_as("/api/memory/#{ctx.plain.id}?" <> ws(ctx), bare).status == 200
      assert get_as("/api/memory/#{ctx.secret.id}?" <> ws(ctx), bare).status == 404
      assert get_as("/api/memory/#{ctx.team.id}?" <> ws(ctx), bare).status == 404

      assert get_as("/api/memory/#{ctx.secret.id}?" <> ws(ctx), restricted).status == 200

      assert get_as(
               "/api/memory/#{ctx.team.id}?" <> ws(ctx),
               mint(ctx, %{"allowed_partitions" => ["team-a"]})
             ).status == 200

      assert get_as("/api/memory/#{ctx.secret.id}?" <> ws(ctx), nil).status == 200
    end

    test "a not-found memory and a hidden one answer the same", ctx do
      hidden = get_as("/api/memory/#{ctx.secret.id}?" <> ws(ctx), mint(ctx, %{}))
      missing = get_as("/api/memory/mem-nobody-#{ctx.n}?" <> ws(ctx), mint(ctx, %{}))

      assert hidden.status == missing.status
      assert hidden.resp_body == missing.resp_body
    end

    test "a signal the key may not see is not found", ctx do
      bare = mint(ctx, %{})
      restricted = mint(ctx, %{"allowed_security_labels" => ["restricted"]})

      assert get_as("/api/signals/#{ctx.plain_doc.id}?" <> ws(ctx), bare).status == 200
      assert get_as("/api/signals/#{ctx.secret_doc.id}?" <> ws(ctx), bare).status == 404
      assert get_as("/api/signals/#{ctx.secret_doc.id}?" <> ws(ctx), restricted).status == 200
      assert get_as("/api/signals/#{ctx.secret_doc.id}?" <> ws(ctx), nil).status == 200
    end

    test "a wiki page that cites a restricted document is not found without the label", ctx do
      page = "/api/wiki/deal-room-#{ctx.n}?" <> ws(ctx) <> "&tenant=default"
      open = "/api/wiki/docs-calendar-#{ctx.n}?" <> ws(ctx) <> "&tenant=default"

      assert get_as(page, mint(ctx, %{})).status == 404
      assert get_as(open, mint(ctx, %{})).status == 200
      assert get_as(page, mint(ctx, %{"allowed_security_labels" => ["restricted"]})).status == 200
      assert get_as(page, nil).status == 200
    end

    test "the access lists apply to a record as well", ctx do
      principal = "user:denied-record-#{ctx.n}"
      token = mint(ctx, %{"allowed_security_labels" => ["restricted"]}, principal)

      assert get_as("/api/memory/#{ctx.secret.id}?" <> ws(ctx), token).status == 200

      :ok =
        ACL.deny(%{
          resource_uri: "optimal://memory/#{ctx.ws}/#{ctx.secret.id}",
          principal_id: principal,
          tenant_id: "default"
        })

      assert get_as("/api/memory/#{ctx.secret.id}?" <> ws(ctx), token).status == 404
      assert get_as("/api/memory/#{ctx.secret.id}?" <> ws(ctx), nil).status == 200
    end
  end

  describe "a list" do
    test "a memory list shows what the grants cover and says nothing of the rest", ctx do
      bare = get_json("/api/memory?" <> ws(ctx) <> "&limit=100", mint(ctx, %{}))

      assert ids(bare["memories"]) == [ctx.plain.id]
      refute Map.has_key?(bare, "withheld")
      refute Map.has_key?(bare, "complete")

      restricted =
        get_json(
          "/api/memory?" <> ws(ctx) <> "&limit=100",
          mint(ctx, %{"allowed_security_labels" => ["restricted"]})
        )

      assert ctx.secret.id in ids(restricted["memories"])
      refute ctx.team.id in ids(restricted["memories"])

      operator = get_json("/api/memory?" <> ws(ctx) <> "&limit=100", nil)
      assert length(operator["memories"]) == 5
      refute Map.has_key?(operator, "withheld")
    end

    test "a key granted *, and one granted exactly the recommended default", ctx do
      root =
        get_json(
          "/api/memory?" <> ws(ctx) <> "&limit=100",
          mint(ctx, %{"allowed_security_labels" => ["*"], "allowed_partitions" => ["*"]})
        )

      assert length(root["memories"]) == 5

      machine =
        mint(ctx, %{
          "allowed_security_labels" => ["public", "internal", "confidential"],
          "allowed_partitions" => []
        })

      read = ids(get_json("/api/memory?" <> ws(ctx) <> "&limit=100", machine)["memories"])

      assert ctx.confidential.id in read and ctx.plain.id in read
      refute ctx.secret.id in read
      refute ctx.custom.id in read
      refute ctx.team.id in read
    end
  end

  describe "a key with the default grants (public, internal, confidential)" do
    test "all six routes show the confidential rows and withhold the restricted ones", ctx do
      assert reads(ctx, mint(ctx, @machine)) == @reads_default
    end

    test "a custom label and a partition are withheld as well", ctx do
      machine = mint(ctx, @machine)

      assert get_as("/api/memory/#{ctx.custom.id}?" <> ws(ctx), machine).status == 404
      assert get_as("/api/memory/#{ctx.team.id}?" <> ws(ctx), machine).status == 404
      assert get_as("/api/memory/#{ctx.plain.id}?" <> ws(ctx), machine).status == 200

      list = get_json("/api/memory?" <> ws(ctx) <> "&limit=100", machine)
      assert Enum.sort(ids(list["memories"])) == Enum.sort([ctx.confidential.id, ctx.plain.id])
      refute Map.has_key?(list, "withheld")
    end
  end

  describe "a key minted before grants existed" do
    test "reads what carries no label until migration 85 gives it the default grants", ctx do
      legacy = mint(ctx, %{})
      id = key_id(legacy)

      # The routes alone: no grants, so only unlabelled rows.
      assert get_as("/api/memory/#{ctx.confidential.id}?" <> ws(ctx), legacy).status == 404
      assert get_as("/api/memory/#{ctx.plain.id}?" <> ws(ctx), legacy).status == 200

      :ok = KeyGrantsBackfill.apply_to_stored_key(id)

      assert {:ok, key} = ApiKey.verify(legacy)
      assert key.metadata == Map.put(@machine, "grants_backfilled", true)

      assert reads(ctx, legacy) == @reads_default
      assert get_as("/api/memory/#{ctx.plain.id}?" <> ws(ctx), legacy).status == 200
    end

    test "a key with explicit grants reads as it did", ctx do
      restricted = mint(ctx, %{"allowed_security_labels" => ["restricted"]})
      none = mint(ctx, %{"allowed_security_labels" => [], "allowed_partitions" => []})

      for token <- [restricted, none] do
        before = reads(ctx, token)
        :ok = KeyGrantsBackfill.apply_to_stored_key(key_id(token))
        assert reads(ctx, token) == before
      end

      assert {:ok, key} = ApiKey.verify(restricted)
      assert key.metadata == %{"allowed_security_labels" => ["restricted"]}

      assert {:ok, key} = ApiKey.verify(none)
      assert key.metadata == %{"allowed_security_labels" => [], "allowed_partitions" => []}
    end

    test "a key granted * reads everything, before and after", ctx do
      root = mint(ctx, %{"allowed_security_labels" => ["*"], "allowed_partitions" => ["*"]})
      before = reads(ctx, root)
      assert before.memory == {200, 200}

      :ok = KeyGrantsBackfill.apply_to_stored_key(key_id(root))
      assert reads(ctx, root) == before
    end
  end

  describe "search" do
    test "memory search leaves out what the key may not see", ctx do
      query =
        "/api/search?" <>
          URI.encode_query(%{"q" => "Harborview", "type" => "memory", "workspace" => ctx.ws})

      bare = get_json(query, mint(ctx, %{}))
      assert ctx.secret.id not in ids(bare["results"])

      restricted = get_json(query, mint(ctx, %{"allowed_security_labels" => ["restricted"]}))
      assert ctx.secret.id in ids(restricted["results"])

      assert ctx.secret.id in ids(get_json(query, nil)["results"])
    end

    test "document search leaves out what the key may not see", ctx do
      query = "/api/search?" <> URI.encode_query(%{"q" => "Zephyrcorp", "workspace" => ctx.ws})

      restricted = get_json(query, mint(ctx, %{"allowed_security_labels" => ["restricted"]}))
      assert ctx.secret_doc.id in ids(restricted["results"])

      bare = get_json(query, mint(ctx, %{}))
      refute ctx.secret_doc.id in ids(bare["results"])
      assert bare["results"] == []
      refute Map.has_key?(bare, "withheld")
      refute Map.has_key?(bare, "complete")
    end

    test "grep leaves out the chunks of what the key may not see", ctx do
      query = "/api/grep?" <> URI.encode_query(%{"q" => "Zephyrcorp", "workspace" => ctx.ws})

      restricted = get_json(query, mint(ctx, %{"allowed_security_labels" => ["restricted"]}))
      assert Jason.encode!(restricted["results"]) =~ "Zephyrcorp"

      bare = get_json(query, mint(ctx, %{}))
      assert bare["results"] == []
      refute Map.has_key?(bare, "withheld")
      refute Map.has_key?(bare, "complete")
    end
  end

  # A page of a list that is cut down by the key's grants is filled from what
  # the key may see. Cutting a page that was read first leaves a short page,
  # and one that is empty while more is there to read, whenever restricted rows
  # come ahead of the visible ones.
  describe "a page is filled from what the key may see" do
    @hidden_notes [
      "Board minute on the Zephyrcorp offer, first reading",
      "Board minute on the Zephyrcorp offer, second reading",
      "Counsel memo about the escrow terms",
      "Diligence list for the target's customers",
      "Financing term sheet from the lead bank",
      "Retention plan for the target's founders",
      "Integration budget for the first year",
      "Fairness opinion draft from the advisers"
    ]

    test "a memory list does not stop at the restricted memories ahead of the visible ones",
         ctx do
      for note <- @hidden_notes, do: remember(ctx.ws, note, ["restricted"])
      bare = mint(ctx, %{})

      page = get_json("/api/memory?" <> ws(ctx) <> "&limit=1", bare)

      assert ids(page["memories"]) == [ctx.plain.id]
      assert page["pagination"]["has_more"] == false
      # The total counts what the key may see, not the workspace.
      assert page["pagination"]["total"] == 1
    end

    test "an offset counts the memories the key may see", ctx do
      extra = remember(ctx.ws, "Standup is at nine on Monday", []).memory
      for note <- @hidden_notes, do: remember(ctx.ws, note, ["restricted"])
      bare = mint(ctx, %{})

      first = get_json("/api/memory?" <> ws(ctx) <> "&limit=1&offset=0", bare)
      second = get_json("/api/memory?" <> ws(ctx) <> "&limit=1&offset=1", bare)
      beyond = get_json("/api/memory?" <> ws(ctx) <> "&limit=1&offset=2", bare)

      assert length(first["memories"]) == 1 and first["pagination"]["has_more"] == true
      assert length(second["memories"]) == 1 and second["pagination"]["has_more"] == false
      assert beyond["memories"] == [] and beyond["pagination"]["has_more"] == false

      assert Enum.sort(ids(first["memories"]) ++ ids(second["memories"])) ==
               Enum.sort([ctx.plain.id, extra.id])
    end

    test "a key that reads everything is paged by the list, as before", ctx do
      root = mint(ctx, %{"allowed_security_labels" => ["*"], "allowed_partitions" => ["*"]})

      page = get_json("/api/memory?" <> ws(ctx) <> "&limit=2", root)

      assert length(page["memories"]) == 2
      assert page["pagination"]["total"] == 5
      assert page["pagination"]["has_more"] == true
    end

    test "memory search does not stop at the restricted memories that rank first", ctx do
      visible =
        remember(
          ctx.ws,
          "Harborview parking is closed on Friday for repaving, and the shuttle runs from the " <>
            "north entrance instead of the south entrance every thirty minutes until noon",
          []
        ).memory

      hidden =
        for text <- [
              "Harborview Harborview Harborview escrow account, Harborview wire",
              "Harborview Harborview Harborview closing statement, Harborview funds"
            ],
            do: remember(ctx.ws, text, ["restricted"]).memory

      query =
        "/api/search?" <>
          URI.encode_query(%{
            "q" => "Harborview",
            "type" => "memory",
            "workspace" => ctx.ws,
            "limit" => "1"
          })

      page = get_json(query, mint(ctx, %{}))

      assert [result] = page["results"]
      assert result["id"] in [visible.id, ctx.plain.id]
      refute result["id"] in [ctx.secret.id | Enum.map(hidden, & &1.id)]
    end

    test "grep does not stop at the restricted chunks that rank first", ctx do
      for text <- [
            "Zephyrcorp Zephyrcorp Zephyrcorp escrow terms, signed by the Zephyrcorp board",
            "Zephyrcorp Zephyrcorp Zephyrcorp closing checklist, owned by the Zephyrcorp counsel"
          ] do
        {:ok, _} =
          Intake.process(text,
            workspace_id: ctx.ws,
            node: "operator",
            security_labels: ["restricted"],
            write_files: false
          )
      end

      {:ok, _} =
        Intake.process(
          "A neighbor, Zephyrcorp, rents the second floor; kitchen cleanup rotates weekly " <>
            "between all tenants including engineering and facilities",
          workspace_id: ctx.ws,
          node: "operator",
          write_files: false
        )

      query =
        "/api/grep?" <>
          URI.encode_query(%{"q" => "Zephyrcorp", "workspace" => ctx.ws, "limit" => "1"})

      page = get_json(query, mint(ctx, %{}))
      shown = Jason.encode!(page["results"])

      assert length(page["results"]) == 1
      assert shown =~ "neighbor"
      refute shown =~ "escrow"
      refute shown =~ "41 million"
    end
  end

  # A signal the key may read still embeds the clusters it belongs to and the
  # wiki pages that cite it, and those are rows of their own: a cluster is named
  # for its members and a page is written from everything it cites, so either
  # can carry a restricted document's theme or slug.
  describe "what a signal embeds" do
    test "a wiki page that cites it is listed only when the key may read the page", ctx do
      doc_chunk = chunk(ctx.ws, "#{ctx.plain_doc.id}:doc", ctx.plain_doc.id, "Docs ship Friday")

      wiki(ctx.ws, "pitch-#{ctx.n}", "Notes on the docs release", [doc_chunk])
      # Cites the signal and a restricted chunk: the page is restricted.
      wiki(ctx.ws, "offer-#{ctx.n}", "Offer notes", [doc_chunk, "chk-secret-#{ctx.n}"])

      slugs = fn token ->
        "/api/signals/#{ctx.plain_doc.id}?"
        |> Kernel.<>(ws(ctx))
        |> get_json(token)
        |> Map.fetch!("citations")
        |> Enum.map(& &1["wiki_slug"])
        |> Enum.sort()
      end

      both = Enum.sort(["pitch-#{ctx.n}", "offer-#{ctx.n}"])

      assert slugs.(mint(ctx, %{})) == ["pitch-#{ctx.n}"]
      assert slugs.(mint(ctx, @machine)) == ["pitch-#{ctx.n}"]
      assert slugs.(mint(ctx, %{"allowed_security_labels" => ["restricted"]})) == both
      assert slugs.(nil) == both
    end

    test "a cluster is listed only when the key may read all of its members", ctx do
      plain_chunk = chunk(ctx.ws, "#{ctx.plain_doc.id}:doc", ctx.plain_doc.id, "Docs ship Friday")

      secret_chunk =
        chunk(ctx.ws, "#{ctx.secret_doc.id}:doc", ctx.secret_doc.id, "Zephyrcorp offer")

      open = cluster("cluster-open-#{ctx.n}", "Docs and changelog", [plain_chunk])

      mixed =
        cluster("cluster-mixed-#{ctx.n}", "Zephyrcorp offer timing", [plain_chunk, secret_chunk])

      clusters = fn token ->
        "/api/signals/#{ctx.plain_doc.id}?"
        |> Kernel.<>(ws(ctx))
        |> get_json(token)
        |> Map.fetch!("clusters")
        |> Enum.map(& &1["id"])
        |> Enum.sort()
      end

      assert clusters.(mint(ctx, %{})) == [open]

      assert clusters.(mint(ctx, %{"allowed_security_labels" => ["restricted"]})) ==
               Enum.sort([open, mixed])

      assert clusters.(nil) == Enum.sort([open, mixed])
    end

    test "the theme of a hidden cluster is not in the answer", ctx do
      plain_chunk = chunk(ctx.ws, "#{ctx.plain_doc.id}:doc", ctx.plain_doc.id, "Docs ship Friday")

      secret_chunk =
        chunk(ctx.ws, "#{ctx.secret_doc.id}:doc", ctx.secret_doc.id, "Zephyrcorp offer")

      cluster("cluster-mixed-#{ctx.n}", "Zephyrcorp offer timing", [plain_chunk, secret_chunk])

      conn = get_as("/api/signals/#{ctx.plain_doc.id}?" <> ws(ctx), mint(ctx, %{}))

      assert conn.status == 200
      refute conn.resp_body =~ "Zephyrcorp"
    end
  end

  # The node routes list the contexts of a node by title and path, and the
  # graph edges that touch them: a restricted document's title is its content.
  describe "the node routes" do
    defp node_contexts(ctx), do: [ctx.plain_doc, ctx.confidential_doc, ctx.secret_doc]

    defp in_node(ctx, listed),
      do: Enum.filter(listed, &(&1 in Enum.map(node_contexts(ctx), fn c -> c.id end)))

    test "a node lists only the contexts the key may read", ctx do
      path = "/api/node/operator?" <> ws(ctx)

      read = fn token ->
        path
        |> get_json(token)
        |> Map.fetch!("contexts")
        |> ids()
        |> then(&in_node(ctx, &1))
        |> Enum.sort()
      end

      assert read.(mint(ctx, %{})) == [ctx.plain_doc.id]
      assert read.(mint(ctx, @machine)) == Enum.sort([ctx.plain_doc.id, ctx.confidential_doc.id])

      assert read.(mint(ctx, %{"allowed_security_labels" => ["restricted", "confidential"]})) ==
               Enum.sort(Enum.map(node_contexts(ctx), & &1.id))

      assert read.(nil) == Enum.sort(Enum.map(node_contexts(ctx), & &1.id))
    end

    test "a node lists only the edges between contexts the key may read", ctx do
      open = edge(ctx, ctx.plain_doc, ctx.confidential_doc)
      to_secret = edge(ctx, ctx.plain_doc, ctx.secret_doc)
      inner = edge(ctx, ctx.confidential_doc, ctx.secret_doc)
      path = "/api/node/operator?" <> ws(ctx)

      read = fn token ->
        path
        |> get_json(token)
        |> Map.fetch!("edges")
        |> Enum.map(&{&1["source"], &1["target"]})
        |> Enum.filter(&(&1 in [open, to_secret, inner]))
        |> Enum.sort()
      end

      assert read.(mint(ctx, %{})) == []
      assert read.(mint(ctx, @machine)) == [open]

      assert read.(mint(ctx, %{"allowed_security_labels" => ["restricted", "confidential"]})) ==
               Enum.sort([open, to_secret, inner])

      assert read.(nil) == Enum.sort([open, to_secret, inner])
    end

    test "the file tree of a node lists only the contexts the key may read", ctx do
      path = "/api/optimal/nodes/operator/files?" <> ws(ctx)
      address = fn context -> context.uri || context.id end

      read = fn token ->
        path
        |> get_json(token)
        |> Map.fetch!("files")
        |> Enum.map(& &1["path"])
        |> Enum.filter(&(&1 in Enum.map(node_contexts(ctx), address)))
        |> Enum.sort()
      end

      assert read.(mint(ctx, %{})) == [address.(ctx.plain_doc)]

      assert read.(mint(ctx, @machine)) ==
               Enum.sort([address.(ctx.plain_doc), address.(ctx.confidential_doc)])

      assert read.(nil) == Enum.sort(Enum.map(node_contexts(ctx), address))
    end

    test "the title of a hidden context is not in the answer", ctx do
      for path <- ["/api/node/operator?", "/api/optimal/nodes/operator/files?"] do
        conn = get_as(path <> ws(ctx), mint(ctx, %{}))

        assert conn.status == 200
        refute conn.resp_body =~ "Zephyrcorp", path
        refute conn.resp_body =~ "Brightwater", path
      end
    end
  end

  # A list that said how many rows it left out would tell a key without the
  # label that a restricted row matches its query: a probe for a name, an
  # amount or a project. These routes answer a probe for what the key may not
  # see exactly as they answer one for nothing. (The exports, the conflict list
  # and the ledger dump rows rather than answer a query, and keep their counts.)
  describe "what a list says of what it leaves out" do
    test "search answers a probe for a hidden document as it answers one for nothing", ctx do
      bare = mint(ctx, %{})

      for params <- [%{}, %{"type" => "memory"}] do
        probe = fn q ->
          get_json(
            "/api/search?" <>
              URI.encode_query(Map.merge(params, %{"q" => q, "workspace" => ctx.ws})),
            bare
          )
        end

        hidden = Map.delete(probe.(if params == %{}, do: "Zephyrcorp", else: "Harborview"), "query")
        nothing = Map.delete(probe.("Quuxlesswordthatmatchesnothing"), "query")

        assert hidden == nothing, inspect(params)
      end
    end

    test "grep answers a probe for a hidden chunk as it answers one for nothing", ctx do
      bare = mint(ctx, %{})

      probe = fn q ->
        get_json("/api/grep?" <> URI.encode_query(%{"q" => q, "workspace" => ctx.ws}), bare)
      end

      hidden = Map.delete(probe.("Zephyrcorp"), "query")
      nothing = Map.delete(probe.("Quuxlesswordthatmatchesnothing"), "query")

      assert hidden == nothing
    end

    test "a memory list with a query answers a probe for a hidden memory as one for nothing",
         ctx do
      bare = mint(ctx, %{})

      probe = fn q ->
        get_json("/api/memory?" <> URI.encode_query(%{"q" => q, "workspace" => ctx.ws}), bare)
      end

      hidden = Map.delete(probe.("Harborview"), "query")
      nothing = Map.delete(probe.("Quuxlesswordthatmatchesnothing"), "query")

      assert hidden == nothing
      assert hidden["memories"] == []
    end

    test "the operator and a key granted * get the same shape, with nothing to say", ctx do
      root = mint(ctx, %{"allowed_security_labels" => ["*"], "allowed_partitions" => ["*"]})

      for token <- [nil, root],
          path <- [
            "/api/memory?" <> ws(ctx),
            "/api/search?" <> URI.encode_query(%{"q" => "Zephyrcorp", "workspace" => ctx.ws}),
            "/api/grep?" <> URI.encode_query(%{"q" => "Zephyrcorp", "workspace" => ctx.ws})
          ] do
        body = get_json(path, token)
        refute Map.has_key?(body, "withheld"), path
        refute Map.has_key?(body, "complete"), path
      end
    end
  end

  # -- helpers ----------------------------------------------------------------------

  # What a key reads of one confidential and one restricted row, route by route:
  # {confidential, restricted}.
  defp reads(ctx, token) do
    search = fn params ->
      get_json("/api/search?" <> URI.encode_query(Map.put(params, "workspace", ctx.ws)), token)
    end

    grep = fn q ->
      Jason.encode!(
        get_json("/api/grep?" <> URI.encode_query(%{"q" => q, "workspace" => ctx.ws}), token)[
          "results"
        ]
      )
    end

    status = fn path -> get_as(path <> ws(ctx), token).status end
    page = fn slug -> status.("/api/wiki/#{slug}-#{ctx.n}?tenant=default&") end

    %{
      memory:
        {status.("/api/memory/#{ctx.confidential.id}?"), status.("/api/memory/#{ctx.secret.id}?")},
      memory_list: {listed?(ctx, token, ctx.confidential), listed?(ctx, token, ctx.secret)},
      signal:
        {status.("/api/signals/#{ctx.confidential_doc.id}?"),
         status.("/api/signals/#{ctx.secret_doc.id}?")},
      wiki: {page.("renewals"), page.("deal-room")},
      search_memory:
        {ctx.confidential.id in ids(search.(%{"q" => "Northwind", "type" => "memory"})["results"]),
         ctx.secret.id in ids(search.(%{"q" => "Harborview", "type" => "memory"})["results"])},
      search_document:
        {ctx.confidential_doc.id in ids(search.(%{"q" => "Brightwater"})["results"]),
         ctx.secret_doc.id in ids(search.(%{"q" => "Zephyrcorp"})["results"])},
      grep: {grep.("Brightwater") =~ "Brightwater", grep.("Zephyrcorp") =~ "Zephyrcorp"}
    }
  end

  defp listed?(ctx, token, memory) do
    memory.id in ids(get_json("/api/memory?" <> ws(ctx) <> "&limit=100", token)["memories"])
  end

  defp key_id("oe_" <> <<id::binary-size(24), "_", _secret::binary>>), do: id

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

  defp edge(ctx, from, to) do
    {:ok, _} =
      Store.raw_query(
        "INSERT INTO graph_edges (tenant_id, workspace_id, source_id, target_id, relation, weight) VALUES ('default', ?1, ?2, ?3, 'links_to', 1.0)",
        [ctx.ws, from.id, to.id]
      )

    {from.id, to.id}
  end

  defp cluster(id, theme, chunk_ids) do
    {:ok, _} =
      Store.raw_query(
        "INSERT INTO clusters (id, tenant_id, theme, intent_dominant, member_count) VALUES (?1, 'default', ?2, 'inform', ?3)",
        [id, theme, length(chunk_ids)]
      )

    for chunk_id <- chunk_ids do
      {:ok, _} =
        Store.raw_query(
          "INSERT INTO cluster_members (tenant_id, cluster_id, chunk_id, weight) VALUES ('default', ?1, ?2, 0.9)",
          [id, chunk_id]
        )
    end

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

  defp ws(ctx), do: URI.encode_query(%{"workspace" => ctx.ws})

  defp get_as(path, token) do
    conn = conn(:get, path)
    conn = if token, do: put_req_header(conn, "authorization", "Bearer " <> token), else: conn
    Router.call(conn, @opts)
  end

  defp get_json(path, token) do
    conn = get_as(path, token)
    assert conn.status == 200, "#{path}: #{conn.status} #{conn.resp_body}"
    Jason.decode!(conn.resp_body)
  end

  defp ids(items), do: Enum.map(items, & &1["id"])
end
