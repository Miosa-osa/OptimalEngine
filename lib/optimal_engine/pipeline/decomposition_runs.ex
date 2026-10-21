defmodule OptimalEngine.Pipeline.DecompositionRuns do
  @moduledoc """
  Checkpointed decomposition of preserved Source Packages, recorded in the
  `decomposition_runs` table.

  `run/3` reads the Source Package's raw text from its workspace, decomposes
  it, and records every attempt:

    * `:deterministic` (default) runs the four-scale `Pipeline.Decomposer`
    * `:recursive` runs the optional DSPy RLM sidecar
      (`Pipeline.Decomposer.RLM`). When the sidecar is unavailable or fails,
      that attempt is recorded as `failed` with `fallback_strategy:
      "deterministic"` and a second attempt runs with strategy `"fallback"`

  Each completed attempt writes its output to a JSON checkpoint under the
  cache directory and stores the path in `checkpoint_uri`, so the result can
  be inspected or reused without decomposing again. Runs never persist
  chunks or claims; callers decide what to promote.
  """

  alias OptimalEngine.Pipeline.Decomposer
  alias OptimalEngine.Pipeline.Decomposer.{ChunkTree, RLM}
  alias OptimalEngine.Pipeline.Parser.ParsedDoc
  alias OptimalEngine.Store

  @columns "id, tenant_id, organization_id, workspace_id, source_package_id, strategy, status, fallback_strategy, attempt, checkpoint_uri, input_bytes, output_units, model_calls, iterations, metrics, error, started_at, completed_at, created_at"

  @doc """
  Decompose a Source Package. Options: `:strategy` (`:deterministic` or
  `:recursive`), `:checkpoint_dir`, and RLM options (`:command`, `:script`,
  `:timeout`, ...) passed through to the sidecar.

  Returns the completed run and its output (`%ChunkTree{}` for
  deterministic and fallback runs, the RLM result map for recursive runs).
  """
  @spec run(String.t(), String.t(), keyword()) ::
          {:ok, %{run: map(), output: ChunkTree.t() | map(), attempts: [map()]}}
          | {:error, term()}
  def run(workspace_id, source_package_id, opts \\ [])
      when is_binary(workspace_id) and is_binary(source_package_id) do
    with {:ok, strategy} <- strategy(Keyword.get(opts, :strategy, :deterministic)),
         {:ok, scope} <- workspace_scope(workspace_id),
         {:ok, source} <- source_package(workspace_id, source_package_id) do
      context = Map.merge(scope, %{source: source, opts: opts})

      case strategy do
        "deterministic" ->
          with {:ok, run, output} <- attempt(context, "deterministic", 1) do
            {:ok, %{run: run, output: output, attempts: [run]}}
          end

        "recursive" ->
          case attempt(context, "recursive", 1) do
            {:ok, run, output} ->
              {:ok, %{run: run, output: output, attempts: [run]}}

            {:error, {:attempt_failed, failed}} ->
              with {:ok, run, output} <- attempt(context, "fallback", 2) do
                {:ok, %{run: run, output: output, attempts: [failed, run]}}
              end

            {:error, reason} ->
              {:error, reason}
          end
      end
    end
  end

  @spec get(String.t(), String.t()) :: {:ok, map()} | {:error, :not_found | term()}
  def get(workspace_id, run_id) do
    case Store.raw_query(
           "SELECT #{@columns} FROM decomposition_runs WHERE workspace_id = ?1 AND id = ?2",
           [workspace_id, run_id]
         ) do
      {:ok, [row]} -> {:ok, from_row(row)}
      {:ok, []} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "List runs newest first. Options: `:source_package_id`, `:status`, `:limit`."
  @spec list(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def list(workspace_id, opts \\ []) do
    limit = opts |> Keyword.get(:limit, 50) |> max(1) |> min(500)

    {clauses, params} =
      [:source_package_id, :status]
      |> Enum.map(&{&1, Keyword.get(opts, &1)})
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Enum.with_index(3)
      |> Enum.map_reduce([], fn {{key, value}, index}, acc ->
        {" AND #{key} = ?#{index}", acc ++ [to_string(value)]}
      end)

    with {:ok, rows} <-
           Store.raw_query(
             "SELECT #{@columns} FROM decomposition_runs WHERE workspace_id = ?1#{Enum.join(clauses)} ORDER BY created_at DESC, attempt DESC, id LIMIT ?2",
             [workspace_id, limit | params]
           ) do
      {:ok, Enum.map(rows, &from_row/1)}
    end
  end

  # ─── private ─────────────────────────────────────────────────────────────

  defp attempt(context, strategy, attempt_number) do
    id = "dcr_" <> (:crypto.strong_rand_bytes(12) |> Base.encode16(case: :lower))

    with :ok <- insert_run(context, id, strategy, attempt_number) do
      case execute(strategy, context) do
        {:ok, output, stats} ->
          with {:ok, checkpoint} <- write_checkpoint(context, id, strategy, output),
               :ok <- complete_run(id, checkpoint, stats),
               {:ok, run} <- get(context.workspace_id, id) do
            {:ok, run, output}
          end

        {:error, reason} ->
          fallback = if strategy == "recursive", do: "deterministic"

          with :ok <- fail_run(id, reason, fallback),
               {:ok, run} <- get(context.workspace_id, id) do
            if fallback,
              do: {:error, {:attempt_failed, run}},
              else: {:error, {:decomposition_failed, run}}
          end
      end
    end
  end

  defp execute(strategy, context) when strategy in ["deterministic", "fallback"] do
    doc = ParsedDoc.new(text: context.source.raw_text, modality: :text)

    {:ok, tree} =
      Decomposer.decompose(doc,
        tenant_id: context.tenant_id,
        workspace_id: context.workspace_id
      )

    {:ok, tree, %{output_units: length(tree.chunks), model_calls: 0, iterations: 0, metrics: %{}}}
  rescue
    error -> {:error, {:raised, Exception.message(error)}}
  end

  defp execute("recursive", context) do
    rlm_opts = Keyword.drop(context.opts, [:strategy, :checkpoint_dir])

    case RLM.decompose(context.source.raw_text, rlm_opts) do
      {:ok, result} ->
        {:ok, result,
         %{
           output_units: length(result["atoms"] || []),
           model_calls: integer(result["sub_model_calls"]),
           iterations: integer(result["iterations"]),
           metrics: Map.take(result, ["strategy"])
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp insert_run(context, id, strategy, attempt_number) do
    Store.raw_execute(
      """
      INSERT INTO decomposition_runs (
        id, tenant_id, organization_id, workspace_id, source_package_id, strategy,
        status, attempt, input_bytes, started_at
      ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, 'running', ?7, ?8, datetime('now'))
      """,
      [
        id,
        context.tenant_id,
        context.organization_id,
        context.workspace_id,
        context.source.id,
        strategy,
        attempt_number,
        byte_size(context.source.raw_text)
      ]
    )
  end

  defp complete_run(id, checkpoint, stats) do
    Store.raw_execute(
      """
      UPDATE decomposition_runs SET status = 'completed', checkpoint_uri = ?2,
        output_units = ?3, model_calls = ?4, iterations = ?5, metrics = ?6,
        completed_at = datetime('now')
      WHERE id = ?1
      """,
      [
        id,
        checkpoint,
        stats.output_units,
        stats.model_calls,
        stats.iterations,
        Jason.encode!(stats.metrics)
      ]
    )
  end

  defp fail_run(id, reason, fallback) do
    Store.raw_execute(
      """
      UPDATE decomposition_runs SET status = 'failed', error = ?2, fallback_strategy = ?3,
        completed_at = datetime('now')
      WHERE id = ?1
      """,
      [id, String.slice(inspect(reason), 0, 2_000), fallback]
    )
  end

  @doc """
  Where a checkpoint is written unless the caller names a directory:
  `<cache_path>/decomposition`. `Compliance.Artifacts` removes a checkpoint only
  from here.
  """
  @spec checkpoint_dir() :: String.t()
  def checkpoint_dir do
    :optimal_engine
    |> Application.get_env(:cache_path, ".optimal/cache")
    |> Path.join("decomposition")
    |> Path.expand()
  end

  defp write_checkpoint(context, id, strategy, output) do
    dir = Keyword.get_lazy(context.opts, :checkpoint_dir, &checkpoint_dir/0)

    path = Path.join(Path.expand(dir), "#{id}.json")

    body = %{
      run_id: id,
      workspace_id: context.workspace_id,
      source_package_id: context.source.id,
      strategy: strategy,
      output: checkpoint_output(output)
    }

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, Jason.encode!(body)) do
      {:ok, path}
    else
      {:error, reason} -> {:error, {:checkpoint_failed, reason}}
    end
  end

  defp checkpoint_output(%ChunkTree{} = tree) do
    %{
      root_chunk_id: tree.root_chunk_id,
      chunks:
        Enum.map(tree.chunks, fn chunk ->
          %{
            id: chunk.id,
            parent_id: chunk.parent_id,
            scale: chunk.scale,
            offset_bytes: chunk.offset_bytes,
            length_bytes: chunk.length_bytes,
            text: chunk.text
          }
        end)
    }
  end

  defp checkpoint_output(result) when is_map(result), do: result

  defp strategy(value) when value in [:deterministic, "deterministic"], do: {:ok, "deterministic"}
  defp strategy(value) when value in [:recursive, "recursive"], do: {:ok, "recursive"}
  defp strategy(value), do: {:error, {:unknown_strategy, value}}

  defp workspace_scope(workspace_id) do
    case Store.raw_query(
           "SELECT tenant_id, organization_id FROM workspaces WHERE id = ?1 AND status = 'active'",
           [workspace_id]
         ) do
      {:ok, [[tenant_id, organization_id]]} when is_binary(organization_id) ->
        {:ok, %{tenant_id: tenant_id, organization_id: organization_id, workspace_id: workspace_id}}

      {:ok, [[_tenant_id, nil]]} ->
        {:error, :workspace_organization_missing}

      {:ok, []} ->
        {:error, :workspace_not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp source_package(workspace_id, source_package_id) do
    case Store.raw_query(
           "SELECT id, raw_text FROM source_packages WHERE id = ?1 AND workspace_id = ?2",
           [source_package_id, workspace_id]
         ) do
      {:ok, [[id, raw_text]]} when is_binary(raw_text) and raw_text != "" ->
        {:ok, %{id: id, raw_text: raw_text}}

      {:ok, [[_id, _empty]]} ->
        {:error, :source_package_empty}

      {:ok, []} ->
        {:error, :source_package_not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp integer(value) when is_integer(value), do: value
  defp integer(_), do: 0

  defp from_row([
         id,
         tenant_id,
         organization_id,
         workspace_id,
         source_package_id,
         strategy,
         status,
         fallback_strategy,
         attempt,
         checkpoint_uri,
         input_bytes,
         output_units,
         model_calls,
         iterations,
         metrics,
         error,
         started_at,
         completed_at,
         created_at
       ]) do
    %{
      id: id,
      tenant_id: tenant_id,
      organization_id: organization_id,
      workspace_id: workspace_id,
      source_package_id: source_package_id,
      strategy: strategy,
      status: status,
      fallback_strategy: fallback_strategy,
      attempt: attempt,
      checkpoint_uri: checkpoint_uri,
      input_bytes: input_bytes,
      output_units: output_units,
      model_calls: model_calls,
      iterations: iterations,
      metrics: decode(metrics),
      error: error,
      started_at: started_at,
      completed_at: completed_at,
      created_at: created_at
    }
  end

  defp decode(nil), do: %{}

  defp decode(json) do
    case Jason.decode(json) do
      {:ok, value} when is_map(value) -> value
      _ -> %{}
    end
  end
end
