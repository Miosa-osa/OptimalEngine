defmodule OptimalEngine.Compliance.RetentionRedactTest do
  @moduledoc """
  A retention `redact` rewrites a context's text, and with it everything that was made
  from the original: chunks, vectors, claims, the source package and the summaries.
  What is rebuilt is built from the redacted text.
  """

  use ExUnit.Case, async: false

  alias OptimalEngine.Compliance.Retention
  alias OptimalEngine.Pipeline.Decomposer.Chunk
  alias OptimalEngine.Store
  alias OptimalEngine.TestSupport.EmbedStub

  setup do
    n = System.unique_integer([:positive])
    saved = Application.get_env(:optimal_engine, :text_embedding)
    {url, stop} = EmbedStub.start()
    Application.put_env(:optimal_engine, :text_embedding, url: url, dimensions: 4)

    on_exit(fn ->
      stop.()

      if saved,
        do: Application.put_env(:optimal_engine, :text_embedding, saved),
        else: Application.delete_env(:optimal_engine, :text_embedding)
    end)

    tenant = "ret-red-#{n}"

    {:ok, _} =
      Retention.add_policy(
        tenant_id: tenant,
        scope_type: "tenant",
        ttl_days: 1,
        action: "redact"
      )

    %{n: n, tenant: tenant, workspace: "#{tenant}:docs", email: "jane.doe.#{n}@example.com"}
  end

  test "text that changes is replaced, with what was derived from the original", ctx do
    id = "red-#{ctx.n}"
    text = "Please write to #{ctx.email} about the renewal."
    seed!(ctx, id, text)

    assert {:ok, %{actions_taken: 1, errors: 0}} = Retention.sweep(tenant_id: ctx.tenant)

    {:ok, [[content, l0, l1, metadata]]} =
      Store.raw_query(
        "SELECT content, l0_abstract, l1_overview, metadata FROM contexts WHERE id = ?1",
        [id]
      )

    assert content =~ "<REDACTED:email>"
    for field <- [content, l0, l1, metadata], do: refute(field =~ ctx.email)
    refute metadata =~ "source_package_id"

    # What the original text made is gone.
    assert count("source_packages", "id", "pkg-#{id}") == 0
    assert count("claims", "id", "claim-#{id}") == 0
    assert count("chunks", "id", "#{id}:seeded-0") == 0
    assert count("chunk_embeddings", "chunk_id", "#{id}:seeded-0") == 0

    # What stands now is made from the redacted text.
    {:ok, chunks} = Store.raw_query("SELECT text FROM chunks WHERE signal_id = ?1", [id])
    assert chunks != []
    for [chunk] <- chunks, do: refute(chunk =~ ctx.email)
    assert count("vectors", "context_id", id) == 1

    # Redacted already: the next sweep rewrites nothing and rebuilds nothing.
    before = chunk_ids(id)
    assert {:ok, %{actions_taken: 1, errors: 0}} = Retention.sweep(tenant_id: ctx.tenant)
    assert chunk_ids(id) == before
  end

  test "text with nothing to redact keeps what was derived from it", ctx do
    id = "plain-#{ctx.n}"
    seed!(ctx, id, "Quarterly planning notes without anything personal.")

    assert {:ok, %{actions_taken: 1, errors: 0}} = Retention.sweep(tenant_id: ctx.tenant)

    assert count("source_packages", "id", "pkg-#{id}") == 1
    assert count("claims", "id", "claim-#{id}") == 1
    assert count("chunks", "id", "#{id}:seeded-0") == 1
  end

  defp seed!(ctx, id, text) do
    sql!(
      """
      INSERT INTO contexts (id, tenant_id, workspace_id, uri, title, content, l0_abstract, l1_overview, genre, node, created_at)
      VALUES (?1, ?2, ?3, ?4, 't', ?5, ?5, ?5, 'note', 'person-operator', '2020-01-01T00:00:00Z')
      """,
      [id, ctx.tenant, ctx.workspace, "optimal://redact/#{id}", text]
    )

    sql!(
      "INSERT INTO source_packages (id, tenant_id, workspace_id, content_hash, raw_text) VALUES (?1, ?2, ?3, ?4, ?5)",
      ["pkg-#{id}", ctx.tenant, ctx.workspace, "hash-#{id}", text]
    )

    sql!("UPDATE contexts SET metadata = json_object('source_package_id', ?1) WHERE id = ?2", [
      "pkg-#{id}",
      id
    ])

    sql!(
      "INSERT INTO claims (id, tenant_id, workspace_id, source_package_id, signal_id, claim_text) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
      ["claim-#{id}", ctx.tenant, ctx.workspace, "pkg-#{id}", id, text]
    )

    :ok =
      Store.insert_chunks([
        Chunk.new(
          id: "#{id}:seeded-0",
          signal_id: id,
          tenant_id: ctx.tenant,
          workspace_id: ctx.workspace,
          text: text
        )
      ])

    :ok =
      Store.insert_embeddings([
        %{
          chunk_id: "#{id}:seeded-0",
          tenant_id: ctx.tenant,
          model: "test",
          modality: :text,
          dim: 4,
          vector: [1.0, 0.0, 0.0, 0.0],
          workspace_id: ctx.workspace
        }
      ])

    :ok = Store.Vectors.store(id, [1.0, 0.0, 0.0, 0.0], workspace_id: ctx.workspace)
  end

  defp chunk_ids(id) do
    {:ok, rows} = Store.raw_query("SELECT id FROM chunks WHERE signal_id = ?1 ORDER BY id", [id])
    List.flatten(rows)
  end

  defp sql!(sql, params) do
    {:ok, _} = Store.raw_query(sql, params)
    :ok
  end

  defp count(table, column, value) do
    {:ok, [[n]]} = Store.raw_query("SELECT COUNT(*) FROM #{table} WHERE #{column} = ?1", [value])
    n
  end
end
