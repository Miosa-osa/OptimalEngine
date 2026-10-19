defmodule OptimalEngine.API.ChatSessionsTest do
  @moduledoc """
  Committing a chat over HTTP: `POST /api/sessions/commit` stores the
  transcript as an Engine episode in the chat's workspace, proposes what the
  chat learned as claims in the review queue, and is safe to retry. The read
  routes stay inside the caller's tenant and workspace.
  """

  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias OptimalEngine.API.Router
  alias OptimalEngine.Auth.ApiKey
  alias OptimalEngine.Identity.Principal
  alias OptimalEngine.{ChatSession, MemoryCore, Organization, Store, Workspace}
  alias OptimalEngine.Tenancy.Tenant

  @opts Router.init([])

  setup do
    n = System.unique_integer([:positive])
    tenant = "chat-#{n}"
    other_tenant = "chat-other-#{n}"
    {:ok, _} = Tenant.create(%{id: tenant, name: "Chat #{n}"})
    {:ok, _} = Tenant.create(%{id: other_tenant, name: "Other #{n}"})

    {:ok, alpha} = workspace(tenant, "alpha")
    {:ok, beta} = workspace(tenant, "beta")
    {:ok, foreign} = workspace(other_tenant, "alpha")

    %{
      n: n,
      tenant: tenant,
      other_tenant: other_tenant,
      alpha: alpha.id,
      beta: beta.id,
      foreign: foreign.id,
      writer: key(tenant, [alpha.id], ["read", "write"], "agent:chat-#{n}"),
      beta_writer: key(tenant, [beta.id], ["read", "write"], "agent:chat-beta-#{n}"),
      reader: key(tenant, [alpha.id], ["read"], "agent:reader-#{n}"),
      reviewer: key(tenant, [alpha.id], ["read", "claims:review"], "user:reviewer-#{n}"),
      foreign_writer: key(other_tenant, [foreign.id], ["read", "write"], "agent:other-#{n}")
    }
  end

  defp workspace(tenant, slug) do
    Workspace.create(%{
      tenant_id: tenant,
      organization_id: Organization.default_for(tenant),
      slug: slug,
      name: String.capitalize(slug)
    })
  end

  defp key(tenant, workspaces, scopes, principal, metadata \\ %{}) do
    kind = if String.starts_with?(principal, "user:"), do: :user, else: :agent

    {:ok, _} =
      Principal.upsert(%{id: principal, tenant_id: tenant, kind: kind, display_name: principal})

    {:ok, %{key: token}} =
      ApiKey.mint(%{
        tenant_id: tenant,
        name: "chat-test",
        scopes: scopes,
        workspace_scope: workspaces,
        principal_id: principal,
        metadata: metadata
      })

    token
  end

  defp request(method, path, token, body \\ nil) do
    conn =
      case body do
        nil ->
          conn(method, path)

        body ->
          conn(method, path, Jason.encode!(body))
          |> put_req_header("content-type", "application/json")
      end

    conn = if token, do: put_req_header(conn, "authorization", "Bearer " <> token), else: conn
    Router.call(conn, @opts)
  end

  defp json(conn), do: Jason.decode!(conn.resp_body)

  defp transcript(ctx, overrides \\ %{}) do
    Map.merge(
      %{
        "workspace" => ctx.alpha,
        "correlation_id" => "chat-#{ctx.n}",
        "title" => "Launch planning",
        "source" => "chat-client",
        "messages" => [
          %{
            "role" => "user",
            "content" => "We decided to move the launch review to Thursday.",
            "at" => "2026-10-18T09:00:00Z"
          },
          %{
            "role" => "assistant",
            "content" => "Noted. The vendor asked for the signed order form by Friday.",
            "at" => "2026-10-18T09:00:05Z"
          },
          %{
            "role" => "user",
            "content" => "Keep the zephyrwatch budget note with this chat.",
            "at" => "2026-10-18T09:01:00Z"
          }
        ],
        "learned" => [
          %{
            "category" => "task",
            "content" => "Send the vendor the signed order form",
            "owner" => "user:jane",
            "due" => "2026-10-23"
          }
        ]
      },
      overrides
    )
  end

  defp commit(ctx, body, token \\ nil),
    do: request(:post, "/api/sessions/commit", token || ctx.writer, body)

  describe "POST /api/sessions/commit" do
    test "stores the chat as an episode, a searchable context and proposed claims", ctx do
      conn = commit(ctx, transcript(ctx))
      assert conn.status == 201
      body = json(conn)

      session_id = body["session_id"]
      assert "ses_" <> _ = session_id
      assert body["workspace_id"] == ctx.alpha
      assert body["tenant_id"] == ctx.tenant
      assert body["correlation_id"] == "chat-#{ctx.n}"
      assert body["uri"] == "optimal://#{ctx.alpha}/sessions/#{session_id}"
      assert body["message_count"] == 3
      assert body["started_at"] == "2026-10-18T09:00:00Z"
      assert body["ended_at"] == "2026-10-18T09:01:00Z"
      assert body["actor_id"] == "agent:chat-#{ctx.n}"
      assert body["replayed"] == false
      assert body["summary_source"] == "generated"
      assert body["summary"] =~ "launch review"

      # The episode is the Engine's episodic memory record, in this workspace.
      assert %{"id" => "epi_" <> _ = episode_id, "kind" => "session"} = body["episode"]
      assert body["episode"]["uri"] == "optimal://#{ctx.alpha}/episodes/#{episode_id}"

      assert body["stored"] == %{
               "episodes" => episode_id,
               "sessions" => session_id,
               "contexts" => session_id,
               "source_packages" => body["source_package_id"]
             }

      {:ok, [[kind, ws, tenant, provenance]]} =
        Store.raw_query(
          "SELECT kind, workspace_id, tenant_id, provenance FROM episodes WHERE id = ?1",
          [episode_id]
        )

      assert {kind, ws, tenant} == {"session", ctx.alpha, ctx.tenant}
      assert Jason.decode!(provenance)["session_id"] == session_id
      assert Jason.decode!(provenance)["source_package_id"] == body["source_package_id"]

      # What the chat learned is proposed, never accepted truth.
      learned = body["learned"]
      assert Enum.all?(learned, &(&1["status"] == "pending"))

      assert %{"origin" => "client", "category" => "task", "claim_id" => client_claim} =
               Enum.find(learned, &(&1["content"] == "Send the vendor the signed order form"))

      assert %{"origin" => "engine", "category" => "decision"} =
               Enum.find(learned, &(&1["content"] =~ "decided to move the launch review"))

      assert Enum.all?(
               learned,
               &(&1["uri"] == "optimal://#{ctx.alpha}/memory-core/claims/#{&1["claim_id"]}")
             )

      {:ok, claims} = MemoryCore.pending_claims(workspace_id: ctx.alpha, tenant_id: ctx.tenant)
      claim = Enum.find(claims, &(&1.id == client_claim))
      assert claim.claim_type == "task"
      assert claim.metadata["session_id"] == session_id
      assert claim.metadata["owner"] == "user:jane"
      assert claim.metadata["due"] == "2026-10-23"
      assert claim.source_package_id == body["source_package_id"]

      # Later chats and CLI agents find it through search and read.
      search = request(:get, "/api/search?q=zephyrwatch&workspace=#{ctx.alpha}", ctx.reader)
      assert search.status == 200
      assert Enum.any?(json(search)["results"], &(&1["id"] == session_id))

      read =
        request(
          :get,
          "/api/read?uri=#{URI.encode_www_form(body["uri"])}&workspace=#{ctx.alpha}&tier=full",
          ctx.reader
        )

      assert read.status == 200
      assert json(read)["text"] =~ "zephyrwatch"
    end

    test "a retry with the same transcript returns the stored result and writes nothing new",
         ctx do
      first = commit(ctx, transcript(ctx))
      assert first.status == 201
      second = commit(ctx, transcript(ctx))
      assert second.status == 200

      a = json(first)
      b = json(second)
      assert b["replayed"] == true
      assert Map.delete(b, "replayed") == Map.delete(a, "replayed")

      assert {:ok, [[1]]} =
               Store.raw_query("SELECT COUNT(*) FROM sessions WHERE id = ?1", [a["session_id"]])

      assert {:ok, [[1]]} =
               Store.raw_query(
                 "SELECT COUNT(*) FROM episodes WHERE workspace_id = ?1 AND kind = 'session'",
                 [ctx.alpha]
               )
    end

    test "concurrent commits of one chat store it once", ctx do
      results =
        1..4
        |> Enum.map(fn _ -> Task.async(fn -> commit(ctx, transcript(ctx)).status end) end)
        |> Enum.map(&Task.await(&1, 30_000))

      assert Enum.sort(results) == [200, 200, 200, 201]

      assert {:ok, [[1]]} =
               Store.raw_query(
                 "SELECT COUNT(*) FROM episodes WHERE workspace_id = ?1 AND kind = 'session'",
                 [ctx.alpha]
               )
    end

    test "the same chat id with a different transcript is a conflict", ctx do
      assert commit(ctx, transcript(ctx)).status == 201

      changed =
        transcript(ctx, %{"messages" => [%{"role" => "user", "content" => "Something else."}]})

      conn = commit(ctx, changed)
      assert conn.status == 409
      assert %{"error" => "idempotency_key_conflict", "session_id" => "ses_" <> _} = json(conn)
    end

    test "the same chat id in another workspace is another session", ctx do
      a = commit(ctx, transcript(ctx)) |> json()

      conn =
        request(
          :post,
          "/api/sessions/commit",
          ctx.beta_writer,
          transcript(ctx, %{"workspace" => ctx.beta})
        )

      assert conn.status == 201
      refute json(conn)["session_id"] == a["session_id"]
    end

    test "a client summary is kept as given", ctx do
      conn = commit(ctx, transcript(ctx, %{"summary" => "Review moved; order form due Friday."}))
      assert conn.status == 201
      assert json(conn)["summary"] == "Review moved; order form due Friday."
      assert json(conn)["summary_source"] == "client"
    end

    test "the actor is the key's principal, never the body's", ctx do
      conn = commit(ctx, transcript(ctx, %{"actor_id" => "user:someone-else"}))
      assert conn.status == 403
      assert json(conn)["error"] == "actor_identity_mismatch"
    end

    test "malformed transcripts are refused with 422", ctx do
      cases = [
        Map.delete(transcript(ctx), "correlation_id"),
        transcript(ctx, %{"messages" => []}),
        transcript(ctx, %{"messages" => "not a list"}),
        transcript(ctx, %{"messages" => [%{"role" => "robot", "content" => "x"}]}),
        transcript(ctx, %{"messages" => [%{"role" => "user", "content" => ""}]}),
        transcript(ctx, %{"messages" => [%{"role" => "user", "content" => "x", "at" => "soon"}]}),
        transcript(ctx, %{"learned" => [%{"content" => "x", "category" => "gossip"}]})
      ]

      for body <- cases do
        conn = commit(ctx, body)
        assert conn.status == 422, inspect(body)
        assert json(conn)["error"] == "invalid_session"
        assert is_binary(json(conn)["detail"])
      end
    end

    test "too many messages or bytes is 413 and stores nothing", ctx do
      original = Application.get_env(:optimal_engine, :chat_sessions)
      Application.put_env(:optimal_engine, :chat_sessions, max_messages: 2, max_bytes: 120)

      try do
        conn = commit(ctx, transcript(ctx))
        assert conn.status == 413

        assert %{"error" => "session_too_large", "limit" => "messages", "max" => 2, "got" => 3} =
                 json(conn)

        long = String.duplicate("a", 121)

        conn =
          commit(ctx, transcript(ctx, %{"messages" => [%{"role" => "user", "content" => long}]}))

        assert conn.status == 413
        assert %{"limit" => "bytes", "max" => 120} = json(conn)
      after
        if original,
          do: Application.put_env(:optimal_engine, :chat_sessions, original),
          else: Application.delete_env(:optimal_engine, :chat_sessions)
      end

      assert {:ok, [[0]]} =
               Store.raw_query("SELECT COUNT(*) FROM sessions WHERE workspace_id = ?1", [ctx.alpha])
    end
  end

  describe "isolation" do
    test "a key for one workspace cannot commit to another", ctx do
      conn = commit(ctx, transcript(ctx, %{"workspace" => ctx.beta}))
      assert conn.status == 403
      assert json(conn)["error"] == "workspace_scope_denied"
    end

    test "another tenant's workspace is not found", ctx do
      conn = commit(ctx, transcript(ctx, %{"workspace" => ctx.foreign}))
      assert conn.status == 404
    end

    test "a read-only key cannot commit", ctx do
      conn = commit(ctx, transcript(ctx), ctx.reader)
      assert conn.status == 403
      assert json(conn)["error"] == "permission_scope_denied"
    end

    test "a data key is confined to /api/data", ctx do
      data_key =
        key(ctx.tenant, [ctx.alpha], ["read", "write"], "app:data-#{ctx.n}", %{
          "data_access" => %{"owner" => "app"}
        })

      assert commit(ctx, transcript(ctx), data_key).status == 403
      assert request(:get, "/api/sessions?workspace=#{ctx.alpha}", data_key).status == 403
    end

    test "sessions are listed and read only inside their workspace and tenant", ctx do
      a = commit(ctx, transcript(ctx)) |> json()

      b =
        request(
          :post,
          "/api/sessions/commit",
          ctx.beta_writer,
          transcript(ctx, %{"workspace" => ctx.beta, "correlation_id" => "beta-#{ctx.n}"})
        )
        |> json()

      list = request(:get, "/api/sessions?workspace=#{ctx.alpha}", ctx.reader)
      assert list.status == 200
      ids = Enum.map(json(list)["sessions"], & &1["session_id"])
      assert ids == [a["session_id"]]

      # Another workspace's session, asked for from this workspace, is not here.
      conn =
        request(:get, "/api/sessions/#{b["session_id"]}?workspace=#{ctx.alpha}", ctx.reader)

      assert conn.status == 404

      # Asking for the other workspace with this key is refused outright.
      conn = request(:get, "/api/sessions/#{b["session_id"]}?workspace=#{ctx.beta}", ctx.reader)
      assert conn.status == 403

      # A key of another tenant sees nothing of this one.
      conn =
        request(
          :get,
          "/api/sessions/#{a["session_id"]}?workspace=#{ctx.foreign}",
          ctx.foreign_writer
        )

      assert conn.status == 404
      conn = request(:get, "/api/sessions?workspace=#{ctx.foreign}", ctx.foreign_writer)
      assert json(conn)["sessions"] == []
    end
  end

  describe "GET /api/sessions/:id" do
    test "returns the session, its learned items with their live status, and the transcript",
         ctx do
      body = commit(ctx, transcript(ctx)) |> json()
      claim = Enum.find(body["learned"], &(&1["origin"] == "engine"))

      promote =
        request(
          :post,
          "/api/memory-core/claims/#{claim["claim_id"]}/promote",
          ctx.reviewer,
          %{"workspace" => ctx.alpha}
        )

      assert promote.status == 200

      conn =
        request(
          :get,
          "/api/sessions/#{body["session_id"]}?workspace=#{ctx.alpha}&include=transcript",
          ctx.reader
        )

      assert conn.status == 200
      got = json(conn)
      assert got["session_id"] == body["session_id"]
      assert got["episode"] == body["episode"]

      assert Enum.find(got["learned"], &(&1["claim_id"] == claim["claim_id"]))["status"] ==
               "promoted"

      assert got["transcript"] =~ "**USER:** We decided to move the launch review to Thursday."

      refute Map.has_key?(
               json(
                 request(
                   :get,
                   "/api/sessions/#{body["session_id"]}?workspace=#{ctx.alpha}",
                   ctx.reader
                 )
               ),
               "transcript"
             )
    end

    test "filters the list by chat id", ctx do
      body = commit(ctx, transcript(ctx)) |> json()

      conn =
        request(
          :get,
          "/api/sessions?workspace=#{ctx.alpha}&correlation_id=chat-#{ctx.n}",
          ctx.reader
        )

      assert [%{"session_id" => id, "learned_count" => count}] = json(conn)["sessions"]
      assert id == body["session_id"]
      assert count == length(body["learned"])

      conn = request(:get, "/api/sessions?workspace=#{ctx.alpha}&correlation_id=nope", ctx.reader)
      assert json(conn)["sessions"] == []
    end
  end

  describe "ChatSession.commit/4" do
    test "is the same operation the route runs", ctx do
      {:ok, normalized} = ChatSession.normalize(transcript(ctx))

      assert {:ok, result, :created} =
               ChatSession.commit(ctx.tenant, ctx.alpha, "agent:x", normalized)

      assert {:ok, ^result, :replayed} =
               ChatSession.commit(ctx.tenant, ctx.alpha, "agent:x", normalized)

      assert {:ok, ^result} = ChatSession.get(ctx.tenant, ctx.alpha, result.session_id)
      assert {:error, :not_found} = ChatSession.get(ctx.tenant, ctx.beta, result.session_id)
      assert {:error, :not_found} = ChatSession.get(ctx.other_tenant, ctx.alpha, result.session_id)
    end
  end
end
