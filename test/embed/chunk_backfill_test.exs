defmodule OptimalEngine.Embed.ChunkBackfillTest do
  @moduledoc """
  The chunk embedding backfill embeds every chunk that has none, once, in the
  chunk's own tenant and workspace, through a stub embedder (never Ollama).
  """

  use ExUnit.Case, async: false

  alias OptimalEngine.Embed.ChunkBackfill
  alias OptimalEngine.Pipeline.Decomposer.ChunkTree
  alias OptimalEngine.Pipeline.Embedder.Embedding
  alias OptimalEngine.Store
  alias OptimalEngine.Tenancy.Tenant
  alias OptimalEngine.Workspace

  setup do
    n = System.unique_integer([:positive])
    tenant = "chunk-backfill-#{n}"
    {:ok, _} = Tenant.create(%{id: tenant, name: "Chunk backfill tenant"})
    org = "#{tenant}:org"

    {:ok, _} =
      OptimalEngine.Organization.create(%{id: org, tenant_id: tenant, slug: "org", name: "Org"})

    {:ok, ws} =
      Workspace.create(%{tenant_id: tenant, organization_id: org, slug: "notes", name: "Notes"})

    {:ok, other} =
      Workspace.create(%{tenant_id: tenant, organization_id: org, slug: "other", name: "Other"})

    prefix = "cbf-#{n}"
    has = chunk!(tenant, ws.id, "#{prefix}-has", "Already embedded")
    embedded!(has, tenant, ws.id)
    a = chunk!(tenant, ws.id, "#{prefix}-a", "Pricing call notes")
    b = chunk!(tenant, other.id, "#{prefix}-b", "Hiring plan")
    chunk!(tenant, ws.id, "#{prefix}-empty", "")

    %{tenant: tenant, ws: ws.id, other: other.id, prefix: prefix, has: has, a: a, b: b}
  end

  test "status counts the chunks with text and no embedding", ctx do
    assert {:ok, %{missing: 2}} = ChunkBackfill.status(tenant_id: ctx.tenant)
    assert {:ok, %{missing: 1}} = ChunkBackfill.status(workspace_id: ctx.ws)
    assert {:ok, %{missing: 1}} = ChunkBackfill.status(workspace_id: ctx.other)
  end

  test "chunks without an embedding are embedded once, in their own tenant and workspace",
       ctx do
    assert {:ok, %{embedded: 2, failed: 0, remaining: 0, next: nil}} =
             ChunkBackfill.run(tenant_id: ctx.tenant, embed: stub(self()))

    a = ctx.a
    b = ctx.b
    ws = ctx.ws
    other = ctx.other
    assert_received {:embed, [^a], ^ws, false}
    assert_received {:embed, [^b], ^other, false}

    assert {:ok, rows} =
             Store.raw_query(
               "SELECT chunk_id, tenant_id, workspace_id, model FROM chunk_embeddings WHERE tenant_id = ?1 ORDER BY chunk_id",
               [ctx.tenant]
             )

    assert rows == [
             [a, ctx.tenant, ws, "stub"],
             [b, ctx.tenant, other, "stub"],
             [ctx.has, ctx.tenant, ws, "test"]
           ]

    assert {:ok, %{embedded: 0, failed: 0, remaining: 0, next: nil}} =
             ChunkBackfill.run(tenant_id: ctx.tenant, embed: stub(self()))

    refute_received {:embed, _, _, _}
  end

  test "a limit embeds that many and says where to resume", ctx do
    assert {:ok, %{embedded: 1, remaining: 1, next: next}} =
             ChunkBackfill.run(tenant_id: ctx.tenant, limit: 1, embed: stub(self()))

    # A wider scope names the workspace it stopped in.
    assert next == {ctx.ws, ctx.a}

    assert {:ok, %{embedded: 1, remaining: 0, next: nil}} =
             ChunkBackfill.run(tenant_id: ctx.tenant, after: next, embed: stub(self()))
  end

  test "in one workspace the cursor is a chunk id, and the count can be left out", ctx do
    chunk!(ctx.tenant, ctx.ws, "#{ctx.prefix}-z", "Later note")

    assert {:ok, %{embedded: 1, remaining: nil, next: next}} =
             ChunkBackfill.run(workspace_id: ctx.ws, limit: 1, count: false, embed: stub(self()))

    assert next == ctx.a

    assert {:ok, %{embedded: 1, remaining: 0, next: nil}} =
             ChunkBackfill.run(workspace_id: ctx.ws, after: next, embed: stub(self()))
  end

  test "a window reads the workspace through its (workspace_id, id) index", ctx do
    for {sql, params} <- ChunkBackfill.window_statements(ctx.ws) do
      {:ok, plan} = Store.raw_query("EXPLAIN QUERY PLAN " <> sql, params)
      details = Enum.map_join(plan, "\n", &List.last/1)

      assert details =~ ~r/SEARCH (c|chunks) USING (COVERING )?INDEX idx_chunks_workspace_id/,
             details
    end
  end

  describe "embedder_healthy?/1" do
    test "a probe that fails once is tried again" do
      parent = self()
      {:ok, calls} = Agent.start_link(fn -> 0 end)

      probe = fn ->
        n = Agent.get_and_update(calls, &{&1, &1 + 1})
        send(parent, {:probe, n})
        if n == 0, do: {:error, :ollama_unavailable}, else: {:ok, [0.1, 0.2]}
      end

      assert ChunkBackfill.embedder_healthy?(probe: probe, retry_ms: 0)
      assert_received {:probe, 0}
      assert_received {:probe, 1}
    end

    test "a probe that never answers within its timeout is unhealthy" do
      slow = fn ->
        Process.sleep(500)
        {:ok, [0.1]}
      end

      refute ChunkBackfill.embedder_healthy?(probe: slow, timeout_ms: 20, retry_ms: 0)
      refute ChunkBackfill.embedder_healthy?(probe: fn -> {:ok, []} end, retry_ms: 0)
    end
  end

  test "one workspace can be backfilled alone", ctx do
    assert {:ok, %{embedded: 1, remaining: 0}} =
             ChunkBackfill.run(workspace_id: ctx.other, embed: stub(self()))

    assert {:ok, %{missing: 1}} = ChunkBackfill.status(workspace_id: ctx.ws)
    assert {:ok, %{missing: 0}} = ChunkBackfill.status(workspace_id: ctx.other)
  end

  test "small windows and pages still read every chunk, and every page is reported", ctx do
    for i <- 1..5, do: chunk!(ctx.tenant, ctx.ws, "#{ctx.prefix}-m#{i}", "Note #{i}")
    parent = self()
    on_page = fn page, total -> send(parent, {:page, page, total}) end

    assert {:ok, %{embedded: 7, failed: 0, remaining: 0, next: nil}} =
             ChunkBackfill.run(
               tenant_id: ctx.tenant,
               window: 2,
               page: 2,
               embed: stub(self()),
               on_page: on_page
             )

    pages = collect_pages()
    assert Enum.all?(pages, fn {page, _total} -> page.embedded in 1..2 end)
    assert pages |> List.last() |> elem(1) == %{embedded: 7, failed: 0}
  end

  test "pending_workspaces lists the workspaces with missing chunks", ctx do
    assert {:ok, workspaces} = ChunkBackfill.pending_workspaces(tenant_id: ctx.tenant, window: 2)
    assert workspaces == Enum.sort([ctx.ws, ctx.other])

    {:ok, _} = ChunkBackfill.run(workspace_id: ctx.other, embed: stub(self()))
    assert {:ok, [ws]} = ChunkBackfill.pending_workspaces(tenant_id: ctx.tenant)
    assert ws == ctx.ws
  end

  test "a chunk the embedder rejects is counted, left for later, and the run goes on", ctx do
    a = ctx.a
    embed = stub(self(), fn chunk -> if chunk.id == a, do: {:http_error, 400} end)

    assert {:ok, %{embedded: 1, failed: 1, remaining: 1}} =
             ChunkBackfill.run(tenant_id: ctx.tenant, embed: embed)

    assert {:ok, %{missing: 1}} = ChunkBackfill.status(workspace_id: ctx.ws)
  end

  test "an unavailable embedder stops the run and marks nothing failed", ctx do
    embed = stub(self(), fn _chunk -> :ollama_unavailable end)

    assert {:error, {:embedder_unavailable, :ollama_unavailable}} =
             ChunkBackfill.run(tenant_id: ctx.tenant, embed: embed)

    assert {:ok, %{missing: 2}} = ChunkBackfill.status(tenant_id: ctx.tenant)
  end

  test "what was embedded before the embedder went away is kept", ctx do
    b = ctx.b
    embed = stub(self(), fn chunk -> if chunk.id == b, do: :ollama_unavailable end)

    assert {:error, {:embedder_unavailable, :ollama_unavailable}} =
             ChunkBackfill.run(tenant_id: ctx.tenant, page: 1, embed: embed)

    assert {:ok, %{missing: 0}} = ChunkBackfill.status(workspace_id: ctx.ws)
    assert {:ok, %{missing: 1}} = ChunkBackfill.status(workspace_id: ctx.other)
  end

  test "an unavailable embedder is told apart from a rejected input" do
    assert ChunkBackfill.unavailable?(:ollama_unavailable)
    refute ChunkBackfill.unavailable?({:http_error, 400})
    refute ChunkBackfill.unavailable?(:empty_content)
  end

  # A stub for Pipeline.Embedder.embed_tree/2: every chunk gets a vector unless
  # `fail` returns a reason for it.
  defp stub(parent, fail \\ fn _chunk -> nil end) do
    fn %ChunkTree{chunks: chunks}, opts ->
      send(parent, {:embed, Enum.map(chunks, & &1.id), opts[:workspace_id], opts[:cache]})
      {ok, rejected} = Enum.split_with(chunks, &is_nil(fail.(&1)))

      embeddings =
        Enum.map(ok, fn chunk ->
          Embedding.new(
            chunk_id: chunk.id,
            tenant_id: chunk.tenant_id,
            model: "stub",
            modality: chunk.modality,
            vector: [1.0, 0.0, 0.0]
          )
        end)

      {:ok, embeddings, %{errors: Enum.map(rejected, &{&1.id, fail.(&1)})}}
    end
  end

  defp collect_pages(acc \\ []) do
    receive do
      {:page, page, total} -> collect_pages([{page, total} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp chunk!(tenant, workspace, id, text) do
    {:ok, _} =
      Store.raw_query(
        "INSERT INTO chunks (id, tenant_id, signal_id, scale, text, modality, workspace_id) VALUES (?1, ?2, ?3, 'chunk', ?4, 'text', ?5)",
        [id, tenant, "signal-" <> id, text, workspace]
      )

    id
  end

  defp embedded!(chunk_id, tenant, workspace) do
    {:ok, _} =
      Store.raw_query(
        "INSERT INTO chunk_embeddings (chunk_id, tenant_id, model, modality, dim, vector, workspace_id) VALUES (?1, ?2, 'test', 'text', 2, ?3, ?4)",
        [chunk_id, tenant, {:blob, <<1.0::float-little-32, 0.0::float-little-32>>}, workspace]
      )
  end
end
