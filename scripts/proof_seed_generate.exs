# Writes a synthetic workspace for scripts/proof-seed.sh: documents (contexts
# and their chunks), vectors (a 768-dimension embedding per chunk and per
# document), graph edges between documents, and files in the workspace folder.
#
# Run it on the source Engine's data directory while that Engine is stopped,
# after sync was enabled for the workspace, so every row is captured into the
# replication ledger as it is on an Engine that has been syncing:
#
#     OPTIMAL_API_ENABLED=false SEED_WORKSPACE=default:seed SEED_MB=50 \
#       mix run scripts/proof_seed_generate.exs
#
# SEED_MB is the size of the generated content (text, vectors, and file bytes)
# in MiB. The changes each batch captures are sealed into the ledger before the
# next batch, as the sync scheduler does on a running Engine every few seconds.
# Prints one SEED_* line per measurement.

defmodule ProofSeedGenerate do
  alias OptimalEngine.{Store, Workspace}
  alias OptimalEngine.Sync.Capture
  alias OptimalEngine.Workspace.Filesystem

  @dim 768
  @chunks_per_document 3
  @edges_per_document 2
  @documents_per_batch 250
  @file_bytes 1_048_576
  @relations {"related", "cites", "follows", "supports"}
  @words List.to_tuple(
           ~w(account action agenda answer archive audit backlog balance batch brief budget
            calendar campaign capacity channel checklist client cluster commit context
            contract cost customer cycle dashboard deadline decision delivery demand
            design draft estimate evidence feedback filing forecast goal handoff hiring
            incident index insight invoice issue journal kickoff ledger lesson market
            meeting memo metric milestone model network note offer onboarding outline
            owner partner pipeline plan policy priority process product project proposal
            quarter question record release report request review revenue risk roadmap
            rollout schedule scope segment service signal source sprint status strategy
            summary supplier support survey system target task team template ticket
            timeline topic trend update vendor version volume window workflow workshop)
         )

  def run do
    workspace_id = System.fetch_env!("SEED_WORKSPACE")
    target = max(mib("SEED_MB", 50), 10) * 1_048_576
    {:ok, workspace} = Workspace.get(workspace_id)
    scope = %{tenant: workspace.tenant_id, workspace: workspace.id}
    :rand.seed(:exsss, {7, 11, 13})

    file_count = max(div(target, 20 * @file_bytes), 1)
    row_target = target - file_count * @file_bytes

    started = System.monotonic_time(:millisecond)
    totals = write_documents(scope, row_target)
    files = write_files(workspace_id, file_count)
    done = System.monotonic_time(:millisecond)

    {:ok, [[ledger]]} =
      Store.raw_query(
        "SELECT COUNT(*) FROM sync_mutations WHERE tenant_id = ?1 AND workspace_id = ?2",
        [scope.tenant, scope.workspace]
      )

    IO.puts("SEED_DOCUMENTS=#{totals.documents}")
    IO.puts("SEED_CHUNKS=#{totals.chunks}")
    IO.puts("SEED_VECTORS=#{totals.vectors}")
    IO.puts("SEED_EDGES=#{totals.edges}")
    IO.puts("SEED_FILES=#{files}")
    IO.puts("SEED_GENERATED_BYTES=#{totals.bytes + files * @file_bytes}")
    IO.puts("SEED_SECONDS=#{seconds(done - started)}")
    IO.puts("SEED_SEAL_SECONDS=#{seconds(totals.seal_ms)}")
    IO.puts("SEED_LEDGER_ENTRIES=#{ledger}")
  end

  defp write_documents(scope, row_target) do
    empty = %{documents: 0, chunks: 0, vectors: 0, edges: 0, bytes: 0, seal_ms: 0}

    Stream.iterate(0, &(&1 + @documents_per_batch))
    |> Enum.reduce_while(empty, fn first, acc ->
      if acc.documents > 0 and acc.bytes >= row_target do
        {:halt, acc}
      else
        batch = Enum.map(first..(first + @documents_per_batch - 1), &document(&1))
        {:ok, counts} = Store.transaction(&insert_batch(&1, scope, batch), 120_000)
        sealing = System.monotonic_time(:millisecond)
        {:ok, _sealed} = Capture.seal()
        seal_ms = System.monotonic_time(:millisecond) - sealing
        {:cont, acc |> merge(counts) |> merge(%{seal_ms: seal_ms})}
      end
    end)
  end

  defp merge(acc, counts), do: Map.merge(acc, counts, fn _key, a, b -> a + b end)

  defp document(index) do
    id = "seed-doc-" <> String.pad_leading(Integer.to_string(index), 7, "0")
    content = sentence(300)
    chunk_size = div(byte_size(content), @chunks_per_document) + 1

    chunks =
      for {text, n} <- Enum.with_index(chunk_texts(content, chunk_size)) do
        %{id: "#{id}:p#{n}", text: text, offset: n * chunk_size, vector: vector()}
      end

    targets =
      if index == 0,
        do: [],
        else: for(_ <- 1..@edges_per_document, do: :rand.uniform(index) - 1) |> Enum.uniq()

    %{
      id: id,
      index: index,
      title: "Seed document #{index}: " <> sentence(5),
      abstract: sentence(30),
      content: content,
      vector: vector(),
      chunks: chunks,
      targets: targets
    }
  end

  defp chunk_texts(content, size) do
    case content do
      <<part::binary-size(size), rest::binary>> when rest != "" -> [part | chunk_texts(rest, size)]
      last -> [last]
    end
  end

  defp insert_batch(txn, scope, batch) do
    empty = %{documents: 0, chunks: 0, vectors: 0, edges: 0, bytes: 0}

    Enum.reduce(batch, {:ok, empty}, fn doc, {:ok, acc} ->
      now = DateTime.utc_now() |> DateTime.to_iso8601()

      {:ok, 1} =
        Store.txn_execute(
          txn,
          """
          INSERT INTO contexts (id, tenant_id, workspace_id, uri, type, title, l0_abstract, content, node,
                                created_at, modified_at)
          VALUES (?1, ?2, ?3, ?4, 'resource', ?5, ?6, ?7, 'seed', ?8, ?8)
          """,
          [
            doc.id,
            scope.tenant,
            scope.workspace,
            "optimal://seed/#{doc.id}",
            doc.title,
            doc.abstract,
            doc.content,
            now
          ]
        )

      {:ok, 1} =
        Store.txn_execute(
          txn,
          "INSERT INTO vectors (context_id, tenant_id, workspace_id, embedding, model, dimensions) VALUES (?1, ?2, ?3, ?4, 'seed-embed', ?5)",
          [doc.id, scope.tenant, scope.workspace, {:blob, doc.vector}, @dim]
        )

      Enum.each(doc.chunks, fn chunk ->
        {:ok, 1} =
          Store.txn_execute(
            txn,
            """
            INSERT INTO chunks (id, tenant_id, workspace_id, signal_id, parent_id, scale, offset_bytes,
                                length_bytes, text, modality)
            VALUES (?1, ?2, ?3, ?4, ?4, 'paragraph', ?5, ?6, ?7, 'text')
            """,
            [
              chunk.id,
              scope.tenant,
              scope.workspace,
              doc.id,
              chunk.offset,
              byte_size(chunk.text),
              chunk.text
            ]
          )

        {:ok, 1} =
          Store.txn_execute(
            txn,
            "INSERT INTO chunk_embeddings (chunk_id, tenant_id, workspace_id, model, modality, dim, vector) VALUES (?1, ?2, ?3, 'seed-embed', 'text', ?4, ?5)",
            [chunk.id, scope.tenant, scope.workspace, @dim, {:blob, chunk.vector}]
          )
      end)

      edges =
        Enum.count(doc.targets, fn target ->
          {:ok, n} =
            Store.txn_execute(
              txn,
              "INSERT OR IGNORE INTO edges (source_id, target_id, relation, weight, tenant_id, workspace_id) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
              [
                doc.id,
                "seed-doc-" <> String.pad_leading(Integer.to_string(target), 7, "0"),
                elem(@relations, rem(doc.index + target, tuple_size(@relations))),
                :rand.uniform(),
                scope.tenant,
                scope.workspace
              ]
            )

          n == 1
        end)

      bytes =
        byte_size(doc.title) + byte_size(doc.abstract) + byte_size(doc.content) +
          byte_size(doc.vector) +
          Enum.reduce(doc.chunks, 0, &(&2 + byte_size(&1.text) + byte_size(&1.vector))) +
          edges * 64

      {:ok,
       merge(acc, %{
         documents: 1,
         chunks: length(doc.chunks),
         vectors: length(doc.chunks) + 1,
         edges: edges,
         bytes: bytes
       })}
    end)
  end

  defp write_files(workspace_id, count) do
    root = Application.get_env(:optimal_engine, :root_path)
    dir = Path.join(Filesystem.path(root, workspace_id), "seed-files")
    File.mkdir_p!(dir)

    for n <- 1..count do
      body = Stream.repeatedly(fn -> sentence(200) <> "\n" end) |> Enum.take(800) |> Enum.join()
      File.write!(Path.join(dir, "file-#{n}.txt"), binary_part(body, 0, @file_bytes))
    end

    count
  end

  # Little-endian float32 values with a magnitude in [0.25, 0.5): random sign
  # and mantissa under a fixed exponent, so every vector is distinct and finite.
  defp vector do
    for <<a, b, c, d <- :crypto.strong_rand_bytes(@dim * 4)>>, into: <<>> do
      <<a, b, Bitwise.bor(Bitwise.band(c, 0x7F), 0x80), Bitwise.bor(Bitwise.band(d, 0x80), 0x3E)>>
    end
  end

  defp sentence(words) do
    Enum.map_join(1..words, " ", fn _ -> elem(@words, :rand.uniform(tuple_size(@words)) - 1) end)
  end

  defp mib(name, default) do
    case Integer.parse(System.get_env(name, "")) do
      {n, ""} when n >= 1 -> n
      _ -> default
    end
  end

  defp seconds(ms), do: Float.round(ms / 1000, 1)
end

ProofSeedGenerate.run()
