defmodule OptimalEngine.Models.Registry do
  @moduledoc """
  Governed model-adaptation registry on the `training_examples`,
  `training_runs`, and `model_adapters` tables.

  The engine does not train models. It records what a trainer may use, what
  ran, and which resulting adapter is in service, with these invariants:

    * training examples are workspace-scoped and content-addressed; only
      `approved` examples with a recorded consent basis can feed a run
    * runs move `queued -> running -> completed | failed` and nothing else
    * an adapter can only be registered from a completed run in the same
      workspace; local artifacts must match their declared SHA-256
    * versions increase per `(workspace, base model, adapter type)` and at
      most one adapter of a kind is `active`; activating one retires the
      previous one in the same transaction

  Organization and tenant scope are read from the workspace row.
  """

  alias OptimalEngine.Store

  @example_columns "id, tenant_id, organization_id, workspace_id, source_package_id, input, expected_output, purpose, status, consent_basis, content_hash, metadata, created_at, approved_at"
  @run_columns "id, tenant_id, organization_id, workspace_id, base_model, trainer, method, status, dataset_query, hyperparameters, hardware, metrics, error, started_at, completed_at, created_at"
  @adapter_columns "id, tenant_id, organization_id, workspace_id, training_run_id, base_model, adapter_type, version, artifact_uri, checksum_sha256, status, evaluation, created_at, activated_at, retired_at"

  @run_transitions %{
    "queued" => ~w(running failed),
    "running" => ~w(completed failed)
  }

  # ─── training examples ───────────────────────────────────────────────────

  @doc """
  Add a candidate training example. Requires `:input`, `:expected_output`,
  and `:purpose`; accepts `:consent_basis`, `:source_package_id`, and
  `:metadata`. Adding identical content again returns the existing example.
  """
  @spec add_example(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def add_example(workspace_id, attrs) when is_binary(workspace_id) and is_map(attrs) do
    with {:ok, scope} <- workspace_scope(workspace_id),
         {:ok, input} <- required_text(attrs, :input),
         {:ok, expected} <- required_text(attrs, :expected_output),
         {:ok, purpose} <- required_text(attrs, :purpose) do
      hash = content_hash([purpose, input, expected])

      with :ok <-
             Store.raw_execute(
               """
               INSERT INTO training_examples (
                 id, tenant_id, organization_id, workspace_id, source_package_id, input,
                 expected_output, purpose, consent_basis, content_hash, metadata
               ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)
               ON CONFLICT(workspace_id, content_hash) DO NOTHING
               """,
               [
                 new_id("tex_"),
                 scope.tenant_id,
                 scope.organization_id,
                 workspace_id,
                 Map.get(attrs, :source_package_id),
                 input,
                 expected,
                 purpose,
                 Map.get(attrs, :consent_basis),
                 hash,
                 Jason.encode!(Map.get(attrs, :metadata, %{}))
               ]
             ) do
        fetch_one(
          "SELECT #{@example_columns} FROM training_examples WHERE workspace_id = ?1 AND content_hash = ?2",
          [workspace_id, hash],
          &example_from_row/1
        )
      end
    end
  end

  @doc """
  Approve a candidate example for training. A consent basis must already be
  recorded or be supplied as `:consent_basis`.
  """
  @spec approve_example(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def approve_example(workspace_id, example_id, opts \\ []) do
    with {:ok, example} <- get_example(workspace_id, example_id),
         :ok <- example_transition(example.status, "approved"),
         {:ok, consent} <- consent_basis(Keyword.get(opts, :consent_basis), example.consent_basis),
         :ok <-
           Store.raw_execute(
             "UPDATE training_examples SET status = 'approved', consent_basis = ?3, approved_at = datetime('now') WHERE workspace_id = ?1 AND id = ?2",
             [workspace_id, example_id, consent]
           ) do
      get_example(workspace_id, example_id)
    end
  end

  @doc "Reject a candidate example so no run can use it."
  @spec reject_example(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def reject_example(workspace_id, example_id) do
    with {:ok, example} <- get_example(workspace_id, example_id),
         :ok <- example_transition(example.status, "rejected"),
         :ok <-
           Store.raw_execute(
             "UPDATE training_examples SET status = 'rejected' WHERE workspace_id = ?1 AND id = ?2",
             [workspace_id, example_id]
           ) do
      get_example(workspace_id, example_id)
    end
  end

  @spec get_example(String.t(), String.t()) :: {:ok, map()} | {:error, :not_found | term()}
  def get_example(workspace_id, example_id) do
    fetch_one(
      "SELECT #{@example_columns} FROM training_examples WHERE workspace_id = ?1 AND id = ?2",
      [workspace_id, example_id],
      &example_from_row/1
    )
  end

  @doc "List examples, newest first. Options: `:status`, `:purpose`, `:limit`."
  @spec list_examples(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def list_examples(workspace_id, opts \\ []) do
    {where, params} = filters(opts, [:status, :purpose], 3)

    fetch_all(
      "SELECT #{@example_columns} FROM training_examples WHERE workspace_id = ?1#{where} ORDER BY created_at DESC, id LIMIT ?2",
      [workspace_id, limit(opts) | params],
      &example_from_row/1
    )
  end

  # ─── training runs ───────────────────────────────────────────────────────

  @doc """
  Queue a training run. Requires `:base_model`, `:trainer`, and `:method`;
  accepts `:dataset_query` (`%{"purpose" => ...}`), `:hyperparameters`, and
  `:hardware`. Refused unless approved examples match the dataset.
  """
  @spec create_run(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def create_run(workspace_id, attrs) when is_binary(workspace_id) and is_map(attrs) do
    dataset = Map.get(attrs, :dataset_query, %{})
    id = new_id("trun_")

    with {:ok, scope} <- workspace_scope(workspace_id),
         {:ok, base_model} <- required_text(attrs, :base_model),
         {:ok, trainer} <- required_text(attrs, :trainer),
         {:ok, method} <- required_text(attrs, :method),
         {:ok, examples} when examples > 0 <- approved_example_count(workspace_id, dataset),
         :ok <-
           Store.raw_execute(
             """
             INSERT INTO training_runs (
               id, tenant_id, organization_id, workspace_id, base_model, trainer, method,
               dataset_query, hyperparameters, hardware, metrics
             ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)
             """,
             [
               id,
               scope.tenant_id,
               scope.organization_id,
               workspace_id,
               base_model,
               trainer,
               method,
               Jason.encode!(dataset),
               Jason.encode!(Map.get(attrs, :hyperparameters, %{})),
               Jason.encode!(Map.get(attrs, :hardware, %{})),
               Jason.encode!(%{"approved_examples" => examples})
             ]
           ) do
      get_run(workspace_id, id)
    else
      {:ok, 0} -> {:error, :no_approved_examples}
      other -> other
    end
  end

  @spec start_run(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def start_run(workspace_id, run_id),
    do: transition_run(workspace_id, run_id, "running", "started_at = datetime('now')", [])

  @doc "Complete a running run, merging `metrics` into the recorded metrics."
  @spec complete_run(String.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def complete_run(workspace_id, run_id, metrics \\ %{}) when is_map(metrics) do
    with {:ok, run} <- get_run(workspace_id, run_id) do
      transition_run(
        workspace_id,
        run_id,
        "completed",
        "completed_at = datetime('now'), metrics = ?5",
        [Jason.encode!(Map.merge(run.metrics, metrics))]
      )
    end
  end

  @spec fail_run(String.t(), String.t(), term()) :: {:ok, map()} | {:error, term()}
  def fail_run(workspace_id, run_id, error) do
    message = if is_binary(error), do: error, else: inspect(error)

    transition_run(
      workspace_id,
      run_id,
      "failed",
      "completed_at = datetime('now'), error = ?5",
      [message]
    )
  end

  @spec get_run(String.t(), String.t()) :: {:ok, map()} | {:error, :not_found | term()}
  def get_run(workspace_id, run_id) do
    fetch_one(
      "SELECT #{@run_columns} FROM training_runs WHERE workspace_id = ?1 AND id = ?2",
      [workspace_id, run_id],
      &run_from_row/1
    )
  end

  @spec list_runs(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def list_runs(workspace_id, opts \\ []) do
    {where, params} = filters(opts, [:status, :base_model], 3)

    fetch_all(
      "SELECT #{@run_columns} FROM training_runs WHERE workspace_id = ?1#{where} ORDER BY created_at DESC, id LIMIT ?2",
      [workspace_id, limit(opts) | params],
      &run_from_row/1
    )
  end

  # ─── model adapters ──────────────────────────────────────────────────────

  @doc """
  Register a candidate adapter produced by a completed run. Requires
  `:training_run_id`, `:adapter_type`, `:artifact_uri`, and
  `:checksum_sha256`. A local artifact (`file://` or a plain path) must exist
  and match the checksum. Accepts `:evaluation`.
  """
  @spec register_adapter(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def register_adapter(workspace_id, attrs) when is_binary(workspace_id) and is_map(attrs) do
    id = new_id("madp_")

    with {:ok, run_id} <- required_text(attrs, :training_run_id),
         {:ok, run} <- get_run(workspace_id, run_id),
         :ok <-
           if(run.status == "completed", do: :ok, else: {:error, {:run_not_completed, run.status}}),
         {:ok, adapter_type} <- required_text(attrs, :adapter_type),
         {:ok, artifact_uri} <- required_text(attrs, :artifact_uri),
         {:ok, checksum} <- checksum_param(attrs),
         :ok <- verify_artifact(artifact_uri, checksum) do
      Store.transaction(fn txn ->
        with {:ok, [[current]]} <-
               Store.txn_query(
                 txn,
                 "SELECT COALESCE(MAX(version), 0) FROM model_adapters WHERE workspace_id = ?1 AND base_model = ?2 AND adapter_type = ?3",
                 [workspace_id, run.base_model, adapter_type]
               ),
             :ok <-
               txn
               |> Store.txn_execute(
                 """
                 INSERT INTO model_adapters (
                   id, tenant_id, organization_id, workspace_id, training_run_id, base_model,
                   adapter_type, version, artifact_uri, checksum_sha256, evaluation
                 ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)
                 """,
                 [
                   id,
                   run.tenant_id,
                   run.organization_id,
                   workspace_id,
                   run.id,
                   run.base_model,
                   adapter_type,
                   current + 1,
                   artifact_uri,
                   checksum,
                   Jason.encode!(Map.get(attrs, :evaluation, %{}))
                 ]
               )
               |> one_row() do
          txn_adapter(txn, workspace_id, id)
        end
      end)
    end
  end

  @doc """
  Put an adapter in service. Any other active adapter with the same base
  model and type in the workspace is retired in the same transaction.
  """
  @spec activate_adapter(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def activate_adapter(workspace_id, adapter_id) do
    Store.transaction(fn txn ->
      with {:ok, adapter} <- txn_adapter(txn, workspace_id, adapter_id),
           :ok <- if(adapter.status == "active", do: {:error, :already_active}, else: :ok),
           {:ok, _} <-
             Store.txn_execute(
               txn,
               """
               UPDATE model_adapters SET status = 'retired', retired_at = datetime('now')
               WHERE workspace_id = ?1 AND base_model = ?2 AND adapter_type = ?3 AND status = 'active'
               """,
               [workspace_id, adapter.base_model, adapter.adapter_type]
             ),
           :ok <-
             txn
             |> Store.txn_execute(
               "UPDATE model_adapters SET status = 'active', activated_at = datetime('now'), retired_at = NULL WHERE workspace_id = ?1 AND id = ?2",
               [workspace_id, adapter_id]
             )
             |> one_row() do
        txn_adapter(txn, workspace_id, adapter_id)
      end
    end)
  end

  @spec retire_adapter(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def retire_adapter(workspace_id, adapter_id) do
    with {:ok, adapter} <- get_adapter(workspace_id, adapter_id),
         :ok <- if(adapter.status == "retired", do: {:error, :already_retired}, else: :ok),
         :ok <-
           Store.raw_execute(
             "UPDATE model_adapters SET status = 'retired', retired_at = datetime('now') WHERE workspace_id = ?1 AND id = ?2",
             [workspace_id, adapter_id]
           ) do
      get_adapter(workspace_id, adapter_id)
    end
  end

  @spec get_adapter(String.t(), String.t()) :: {:ok, map()} | {:error, :not_found | term()}
  def get_adapter(workspace_id, adapter_id) do
    fetch_one(
      "SELECT #{@adapter_columns} FROM model_adapters WHERE workspace_id = ?1 AND id = ?2",
      [workspace_id, adapter_id],
      &adapter_from_row/1
    )
  end

  @doc "The adapter currently in service for a base model and type."
  @spec active_adapter(String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, :not_found | term()}
  def active_adapter(workspace_id, base_model, adapter_type) do
    fetch_one(
      "SELECT #{@adapter_columns} FROM model_adapters WHERE workspace_id = ?1 AND base_model = ?2 AND adapter_type = ?3 AND status = 'active'",
      [workspace_id, base_model, adapter_type],
      &adapter_from_row/1
    )
  end

  @spec list_adapters(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def list_adapters(workspace_id, opts \\ []) do
    {where, params} = filters(opts, [:status, :base_model, :adapter_type], 3)

    fetch_all(
      "SELECT #{@adapter_columns} FROM model_adapters WHERE workspace_id = ?1#{where} ORDER BY version DESC, created_at DESC LIMIT ?2",
      [workspace_id, limit(opts) | params],
      &adapter_from_row/1
    )
  end

  # ─── private ─────────────────────────────────────────────────────────────

  defp transition_run(workspace_id, run_id, to, set_sql, extra_params) do
    with {:ok, run} <- get_run(workspace_id, run_id),
         :ok <- run_transition(run.status, to),
         :ok <-
           Store.raw_execute(
             "UPDATE training_runs SET status = ?3, #{set_sql} WHERE workspace_id = ?1 AND id = ?2 AND status = ?4",
             [workspace_id, run_id, to, run.status] ++ extra_params
           ),
         {:ok, updated} <- get_run(workspace_id, run_id) do
      if updated.status == to, do: {:ok, updated}, else: {:error, :concurrent_transition}
    end
  end

  defp run_transition(from, to) do
    if to in Map.get(@run_transitions, from, []),
      do: :ok,
      else: {:error, {:invalid_transition, from, to}}
  end

  defp consent_basis(given, recorded) do
    case Enum.find([given, recorded], &(is_binary(&1) and String.trim(&1) != "")) do
      nil -> {:error, :consent_required}
      consent -> {:ok, consent}
    end
  end

  defp example_transition("candidate", to) when to in ["approved", "rejected"], do: :ok
  defp example_transition(from, to), do: {:error, {:invalid_transition, from, to}}

  defp approved_example_count(workspace_id, dataset) do
    {sql, params} =
      case Map.get(dataset, "purpose") || Map.get(dataset, :purpose) do
        nil ->
          {"SELECT COUNT(*) FROM training_examples WHERE workspace_id = ?1 AND status = 'approved'",
           [workspace_id]}

        purpose ->
          {"SELECT COUNT(*) FROM training_examples WHERE workspace_id = ?1 AND status = 'approved' AND purpose = ?2",
           [workspace_id, purpose]}
      end

    case Store.raw_query(sql, params) do
      {:ok, [[count]]} -> {:ok, count}
      {:error, reason} -> {:error, reason}
    end
  end

  defp checksum_param(attrs) do
    case Map.get(attrs, :checksum_sha256) do
      value when is_binary(value) ->
        checksum = String.downcase(value)

        if Regex.match?(~r/^[0-9a-f]{64}$/, checksum),
          do: {:ok, checksum},
          else: {:error, :invalid_checksum}

      _ ->
        {:error, {:missing_field, :checksum_sha256}}
    end
  end

  defp verify_artifact(uri, checksum) do
    case local_path(uri) do
      nil ->
        :ok

      path ->
        if File.regular?(path) do
          actual = :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)
          if actual == checksum, do: :ok, else: {:error, {:checksum_mismatch, checksum, actual}}
        else
          {:error, {:artifact_missing, path}}
        end
    end
  end

  defp local_path("file://" <> path), do: path
  defp local_path("/" <> _ = path), do: path

  defp local_path(uri) do
    if String.contains?(uri, "://"), do: nil, else: Path.expand(uri)
  end

  defp one_row({:ok, 1}), do: :ok
  defp one_row({:ok, _}), do: {:error, :not_found}
  defp one_row({:error, reason}), do: {:error, reason}

  defp txn_adapter(txn, workspace_id, adapter_id) do
    case Store.txn_query(
           txn,
           "SELECT #{@adapter_columns} FROM model_adapters WHERE workspace_id = ?1 AND id = ?2",
           [workspace_id, adapter_id]
         ) do
      {:ok, [row]} -> {:ok, adapter_from_row(row)}
      {:ok, []} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp workspace_scope(workspace_id) do
    case Store.raw_query(
           "SELECT tenant_id, organization_id FROM workspaces WHERE id = ?1 AND status = 'active'",
           [workspace_id]
         ) do
      {:ok, [[tenant_id, organization_id]]} when is_binary(organization_id) ->
        {:ok, %{tenant_id: tenant_id, organization_id: organization_id}}

      {:ok, [[_tenant_id, nil]]} ->
        {:error, :workspace_organization_missing}

      {:ok, []} ->
        {:error, :workspace_not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp required_text(attrs, key) do
    case Map.get(attrs, key) do
      value when is_binary(value) ->
        if String.trim(value) == "", do: {:error, {:missing_field, key}}, else: {:ok, value}

      _ ->
        {:error, {:missing_field, key}}
    end
  end

  defp filters(opts, keys, first_index) do
    keys
    |> Enum.map(&{&1, Keyword.get(opts, &1)})
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Enum.with_index(first_index)
    |> Enum.map_reduce([], fn {{key, value}, index}, acc ->
      {" AND #{key} = ?#{index}", acc ++ [to_string(value)]}
    end)
    |> then(fn {clauses, params} -> {Enum.join(clauses), params} end)
  end

  defp limit(opts), do: opts |> Keyword.get(:limit, 50) |> max(1) |> min(500)

  defp fetch_one(sql, params, mapper) do
    case Store.raw_query(sql, params) do
      {:ok, [row]} -> {:ok, mapper.(row)}
      {:ok, []} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_all(sql, params, mapper) do
    with {:ok, rows} <- Store.raw_query(sql, params), do: {:ok, Enum.map(rows, mapper)}
  end

  defp content_hash(parts) do
    digest = :crypto.hash(:sha256, Enum.join(parts, <<0>>)) |> Base.encode16(case: :lower)
    "sha256:" <> digest
  end

  defp new_id(prefix), do: prefix <> (:crypto.strong_rand_bytes(12) |> Base.encode16(case: :lower))

  defp decode(nil), do: %{}

  defp decode(json) do
    case Jason.decode(json) do
      {:ok, value} when is_map(value) -> value
      _ -> %{}
    end
  end

  defp example_from_row([
         id,
         tenant_id,
         organization_id,
         workspace_id,
         source_package_id,
         input,
         expected_output,
         purpose,
         status,
         consent_basis,
         content_hash,
         metadata,
         created_at,
         approved_at
       ]) do
    %{
      id: id,
      tenant_id: tenant_id,
      organization_id: organization_id,
      workspace_id: workspace_id,
      source_package_id: source_package_id,
      input: input,
      expected_output: expected_output,
      purpose: purpose,
      status: status,
      consent_basis: consent_basis,
      content_hash: content_hash,
      metadata: decode(metadata),
      created_at: created_at,
      approved_at: approved_at
    }
  end

  defp run_from_row([
         id,
         tenant_id,
         organization_id,
         workspace_id,
         base_model,
         trainer,
         method,
         status,
         dataset_query,
         hyperparameters,
         hardware,
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
      base_model: base_model,
      trainer: trainer,
      method: method,
      status: status,
      dataset_query: decode(dataset_query),
      hyperparameters: decode(hyperparameters),
      hardware: decode(hardware),
      metrics: decode(metrics),
      error: error,
      started_at: started_at,
      completed_at: completed_at,
      created_at: created_at
    }
  end

  defp adapter_from_row([
         id,
         tenant_id,
         organization_id,
         workspace_id,
         training_run_id,
         base_model,
         adapter_type,
         version,
         artifact_uri,
         checksum_sha256,
         status,
         evaluation,
         created_at,
         activated_at,
         retired_at
       ]) do
    %{
      id: id,
      tenant_id: tenant_id,
      organization_id: organization_id,
      workspace_id: workspace_id,
      training_run_id: training_run_id,
      base_model: base_model,
      adapter_type: adapter_type,
      version: version,
      artifact_uri: artifact_uri,
      checksum_sha256: checksum_sha256,
      status: status,
      evaluation: decode(evaluation),
      created_at: created_at,
      activated_at: activated_at,
      retired_at: retired_at
    }
  end
end
