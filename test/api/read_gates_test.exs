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
  alias OptimalEngine.Workspace

  @opts Router.init([])

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
      confidential: confidential.memory,
      custom: custom.memory,
      team: team.memory,
      plain: plain.memory,
      secret_doc: secret_doc.context,
      plain_doc: plain_doc.context
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
    test "a memory list shows what the grants cover and says what it left out", ctx do
      bare = get_json("/api/memory?" <> ws(ctx) <> "&limit=100", mint(ctx, %{}))

      assert ids(bare["memories"]) == [ctx.plain.id]
      assert bare["withheld"] == 4
      assert bare["complete"] == false

      restricted =
        get_json(
          "/api/memory?" <> ws(ctx) <> "&limit=100",
          mint(ctx, %{"allowed_security_labels" => ["restricted"]})
        )

      assert ctx.secret.id in ids(restricted["memories"])
      refute ctx.team.id in ids(restricted["memories"])

      operator = get_json("/api/memory?" <> ws(ctx) <> "&limit=100", nil)
      assert length(operator["memories"]) == 5
      assert operator["withheld"] == 0 and operator["complete"] == true
    end

    test "a key granted *, and one granted exactly the recommended default", ctx do
      root =
        get_json(
          "/api/memory?" <> ws(ctx) <> "&limit=100",
          mint(ctx, %{"allowed_security_labels" => ["*"], "allowed_partitions" => ["*"]})
        )

      assert length(root["memories"]) == 5 and root["complete"] == true

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
      assert bare["withheld"] >= 1 and bare["complete"] == false
    end

    test "grep leaves out the chunks of what the key may not see", ctx do
      query = "/api/grep?" <> URI.encode_query(%{"q" => "Zephyrcorp", "workspace" => ctx.ws})

      restricted = get_json(query, mint(ctx, %{"allowed_security_labels" => ["restricted"]}))
      assert Jason.encode!(restricted["results"]) =~ "Zephyrcorp"

      bare = get_json(query, mint(ctx, %{}))
      assert bare["results"] == []
      assert bare["withheld"] >= 1 and bare["complete"] == false
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
