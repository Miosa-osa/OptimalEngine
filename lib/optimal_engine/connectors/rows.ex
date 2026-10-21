defmodule OptimalEngine.Connectors.Rows do
  @moduledoc """
  The connectors table as an operator sees it.

  `OptimalEngine.Connectors.Runner` owns how a row is written and run. This
  module is the one path an operator uses to register, list, change and
  delete rows, shared by `mix optimal.connector` and the `/api/connectors`
  routes, so both hold the same rules:

    * A connector is registered against one named workspace that exists,
      belongs to the tenant, and is active.
    * Credentials arrive only under `credentials`, are sealed with
      `CONNECTOR_KEY`, and are never read back. A view reports only whether
      they are `"stored"`, come from the `"broker"`, or are `"none"`.
      Secret-shaped keys anywhere else in `config` are refused.
    * A `broker_reference` is sealed with `CONNECTOR_KEY` too, and a view
      shows it only as `"[redacted]"`.
    * Every registration, change and deletion is appended to the tenant's
      authority evidence chain (`connector.registered`, `connector.changed`,
      `connector.deleted`); a run asked for by hand is `connector.run`.

  A view also carries the connector's run status, read from `connector_runs`:
  the last run, the last error, the runs and signals over its lifetime,
  whether a run is in progress, and when the scheduler pulls it next.
  """

  require Logger

  alias OptimalEngine.Authority.Evidence
  alias OptimalEngine.Connectors.{Cadence, CredentialSource, PullScheduler, Registry, Runner}
  alias OptimalEngine.{CorpusOrganizer, Scope, Store, Workspace}
  alias OptimalEngine.Tenancy.Tenant

  @id ~r/\A[A-Za-z0-9][A-Za-z0-9._:-]{0,127}\z/
  @secret_key ~r/(secret|password|passwd|token|api_?key|private_?key|bearer|\Apat\z)/i
  @sealed ~w(credentials credentials_ciphertext)
  @reference "broker_reference"
  @sealed_reference "broker_reference_ciphertext"
  @redacted "[redacted]"

  @type view :: map()

  # ─── register ────────────────────────────────────────────────────────────

  @doc """
  Registers a connector row.

  `attrs`: `:id` (generated from the kind when absent), `:kind`,
  `:tenant_id`, `:workspace_id`, `:config`, `:credentials`, `:enabled`
  (default `true`). A `"credentials"` map inside `config` is treated as
  `:credentials`.

  Options: `:mode` is `:create` (default, an existing id is
  `{:error, :connector_exists}`) or `:upsert` (replace the tenant's own row
  of that id), and `:actor` names who asked, for the evidence chain.
  """
  @spec register(map(), keyword()) :: {:ok, view()} | {:error, term()}
  def register(attrs, opts \\ []) when is_map(attrs) do
    tenant_id = attrs[:tenant_id] || Tenant.default_id()
    workspace_id = attrs[:workspace_id]

    with {:ok, kind} <- known_kind(attrs[:kind]),
         {:ok, id} <- connector_id(attrs[:id], kind),
         {:ok, config, credentials} <- split_config(attrs[:config] || %{}, attrs[:credentials]),
         {:ok, enabled} <- enabled_flag(Map.get(attrs, :enabled, true)),
         :ok <- check_workspace(tenant_id, workspace_id),
         :ok <- check_new(id, tenant_id, Keyword.get(opts, :mode, :create)),
         {:ok, ^id} <-
           Runner.upsert_row(%{
             id: id,
             kind: kind,
             tenant_id: tenant_id,
             workspace_id: workspace_id,
             config: put_credentials(config, credentials),
             enabled: enabled
           }) do
      record(tenant_id, "connector.registered", id, kind, workspace_id, opts, %{
        "enabled" => enabled,
        "credentials" => credentials_detail(credentials),
        "config_keys" => config |> Map.keys() |> Enum.sort()
      })

      get(tenant_id, id)
    end
  end

  @doc """
  Inserts a connector row for a configured spec when no row of that id
  exists. An existing row is never changed. A spec without a workspace lands
  in `default_workspace/2`. Returns `{:ok, :created}` or `{:ok, :exists}`.
  """
  @spec provision(map(), keyword()) :: {:ok, :created | :exists} | {:error, term()}
  def provision(%{id: id, kind: kind, tenant_id: tenant_id} = attrs, opts \\ []) do
    if exists?(id) do
      {:ok, :exists}
    else
      with {:ok, workspace_id} <- spec_workspace(tenant_id, attrs[:workspace_id]),
           {:ok, :created} <-
             Runner.provision_row(%{
               id: id,
               kind: kind,
               tenant_id: tenant_id,
               workspace_id: workspace_id,
               config: attrs[:config] || %{},
               enabled: true
             }) do
        opts = Keyword.put_new(opts, :actor, "system:pull-scheduler")

        record(tenant_id, "connector.registered", id, kind, workspace_id, opts, %{
          "provisioned" => true
        })

        {:ok, :created}
      end
    end
  end

  # ─── read ────────────────────────────────────────────────────────────────

  @doc """
  The tenant's connectors with their run status, ordered by workspace and id.
  `:workspace_ids` limits the list (`:all` by default).
  """
  @spec list(String.t(), keyword()) :: [view()]
  def list(tenant_id, opts \\ []) do
    case Keyword.get(opts, :workspace_ids, :all) do
      [] -> []
      workspace_ids -> tenant_id |> select_rows(workspace_ids, nil) |> views()
    end
  end

  @doc "One connector of the tenant, or `{:error, :not_found}`."
  @spec get(String.t(), String.t()) :: {:ok, view()} | {:error, :not_found}
  def get(tenant_id, id) when is_binary(id) do
    case tenant_id |> select_rows(:all, id) |> views() do
      [view] -> {:ok, view}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Connector status for `GET /api/metrics`: counts, the signals ingested, and
  the connectors whose last run failed, with the reason.
  """
  @spec summary(String.t(), keyword()) :: map()
  def summary(tenant_id, opts \\ []) do
    views = list(tenant_id, opts)
    failing = Enum.filter(views, &failing?/1)

    %{
      total: length(views),
      enabled: Enum.count(views, & &1.enabled),
      running: Enum.count(views, & &1.running),
      failing: length(failing),
      signals_total: views |> Enum.map(& &1.signals_total) |> Enum.sum(),
      failing_connectors:
        Enum.map(failing, fn view ->
          %{
            id: view.id,
            kind: view.kind,
            workspace_id: view.workspace_id,
            error: view.last_run.error,
            at: view.last_run.started_at
          }
        end)
    }
  end

  @doc """
  The tenant's enabled connectors as the scheduler plans them: id, kind,
  workspace, config, and when the last run started. `ids` limits the rows
  (`:all` by default).
  """
  @spec schedulable(String.t(), :all | [String.t()]) :: [map()]
  def schedulable(_tenant_id, []), do: []

  def schedulable(tenant_id, ids) do
    {id_sql, id_params} = in_clause("c.id", ids, 2)

    {:ok, rows} =
      Store.raw_query(
        """
        SELECT c.id, c.kind, c.workspace_id, c.config,
               (SELECT MAX(r.started_at) FROM connector_runs r WHERE r.connector_id = c.id)
        FROM connectors c
        WHERE c.tenant_id = ?1 AND c.enabled = 1#{id_sql}
        ORDER BY c.id
        """,
        [tenant_id | id_params]
      )

    Enum.map(rows, fn [id, kind, workspace_id, config, last_started_at] ->
      %{
        id: id,
        kind: kind,
        workspace_id: workspace_id,
        config: decode(config),
        last_started_at: datetime(last_started_at)
      }
    end)
  end

  @doc "Whether a connector row of this id exists, in any tenant."
  @spec exists?(String.t()) :: boolean()
  def exists?(id) do
    match?({:ok, [_ | _]}, Store.raw_query("SELECT 1 FROM connectors WHERE id = ?1", [id]))
  end

  # ─── change ──────────────────────────────────────────────────────────────

  @doc """
  Changes a connector. `changes` uses string keys:

    * `"enabled"` - `true` or `false`
    * `"cadence"`, `"interval_ms"` - see `OptimalEngine.Connectors.Cadence`;
      setting one removes the other, `nil` removes it
    * `"config"` - merged into the row's config; a `nil` value removes a key
    * `"credentials"` - replaces the sealed credentials; `nil` removes them
    * `"workspace"` - moves the connector to another active workspace

  Other keys are ignored. Credentials are never readable afterwards.
  """
  @spec update(String.t(), String.t(), map(), keyword()) :: {:ok, view()} | {:error, term()}
  def update(tenant_id, id, changes, opts \\ []) when is_map(changes) do
    with {:ok, row} <- fetch(tenant_id, id),
         {:ok, kind} <- known_kind(row.kind),
         {:ok, plan} <- plan_update(tenant_id, row, changes),
         {:ok, ^id} <-
           Runner.upsert_row(%{
             id: id,
             kind: kind,
             tenant_id: tenant_id,
             workspace_id: plan.workspace_id,
             config: plan.config,
             enabled: plan.enabled
           }) do
      record(tenant_id, "connector.changed", id, kind, plan.workspace_id, opts, %{
        "fields" => plan.fields,
        "config_keys" => plan.config_keys,
        "enabled" => plan.enabled,
        "workspace_before" => row.workspace_id
      })

      get(tenant_id, id)
    end
  end

  @doc "Deletes a connector and its run history. A running connector is not deleted."
  @spec delete(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def delete(tenant_id, id, opts \\ []) do
    with {:ok, row} <- fetch(tenant_id, id) do
      if Runner.running?(id) do
        {:error, :already_running}
      else
        {:ok, _} = Store.raw_query("DELETE FROM connector_runs WHERE connector_id = ?1", [id])

        {:ok, _} =
          Store.raw_query("DELETE FROM connectors WHERE id = ?1 AND tenant_id = ?2", [id, tenant_id])

        record(tenant_id, "connector.deleted", id, row.kind, row.workspace_id, opts, %{})
        :ok
      end
    end
  end

  @doc "Records a run asked for by hand (`POST /api/connectors/:id/run`)."
  @spec record_run(String.t(), view(), keyword(), map()) :: :ok
  def record_run(tenant_id, view, opts, detail) do
    record(tenant_id, "connector.run", view.id, view.kind, view.workspace_id, opts, detail)
  end

  # ─── workspaces ──────────────────────────────────────────────────────────

  @doc """
  Whether a connector may be registered against `workspace_id`: it must be
  named, registered to the tenant, active, and served by this Engine.
  """
  @spec check_workspace(String.t(), String.t() | nil) :: :ok | {:error, atom()}
  def check_workspace(_tenant_id, workspace_id) when workspace_id in [nil, ""],
    do: {:error, :workspace_required}

  def check_workspace(tenant_id, workspace_id) when is_binary(workspace_id) do
    case Workspace.get(workspace_id) do
      {:ok, %{tenant_id: ^tenant_id, status: :active}} ->
        if Scope.serves?(workspace_id), do: :ok, else: {:error, :workspace_not_found}

      {:ok, %{tenant_id: ^tenant_id}} ->
        {:error, :workspace_archived}

      _other ->
        {:error, :workspace_not_found}
    end
  end

  def check_workspace(_tenant_id, _workspace_id), do: {:error, :workspace_not_found}

  @doc """
  Where a connector registered without a workspace lands: the first active
  workspace the tenant owns among the candidates. The candidates are the
  Engine's own workspace when it is workspace-scoped, then the tenant's intake
  workspace (`OptimalEngine.CorpusOrganizer.source_workspace/1`), then the
  legacy `"default"` workspace. An archived candidate is skipped, so a
  connector is never parked in a workspace that was retired.
  """
  @spec default_workspace(String.t(), [String.t()] | nil) ::
          {:ok, String.t()} | {:error, :no_intake_workspace}
  def default_workspace(tenant_id, candidates \\ nil) do
    candidates = candidates || default_candidates(tenant_id)

    case Enum.find(candidates, &(check_workspace(tenant_id, &1) == :ok)) do
      nil -> {:error, :no_intake_workspace}
      workspace_id -> {:ok, workspace_id}
    end
  end

  defp default_candidates(tenant_id) do
    scoped =
      case Scope.engine_scope() do
        %{mode: "workspace", workspace_id: workspace_id} -> [workspace_id]
        _org -> []
      end

    scoped ++ [CorpusOrganizer.source_workspace(tenant_id), Workspace.default_id()]
  end

  defp spec_workspace(tenant_id, workspace_id) when workspace_id in [nil, ""],
    do: default_workspace(tenant_id)

  defp spec_workspace(_tenant_id, workspace_id), do: {:ok, workspace_id}

  # ─── validation ──────────────────────────────────────────────────────────

  defp known_kind(kind) when is_atom(kind) and not is_nil(kind) do
    case Registry.fetch(kind) do
      {:ok, _module} -> {:ok, kind}
      {:error, _} -> {:error, :unknown_kind}
    end
  end

  defp known_kind(kind) when is_binary(kind) do
    case Registry.fetch_by_name(kind) do
      {:ok, module} -> {:ok, module.kind()}
      {:error, _} -> {:error, :unknown_kind}
    end
  end

  defp known_kind(_kind), do: {:error, :unknown_kind}

  defp connector_id(nil, kind) do
    {:ok, "#{kind}-#{Base.encode16(:crypto.strong_rand_bytes(5), case: :lower)}"}
  end

  defp connector_id(id, _kind) when is_binary(id) do
    if Regex.match?(@id, id) and not String.contains?(id, ".."),
      do: {:ok, id},
      else: {:error, :invalid_id}
  end

  defp connector_id(_id, _kind), do: {:error, :invalid_id}

  defp enabled_flag(value) when is_boolean(value), do: {:ok, value}
  defp enabled_flag(_value), do: {:error, :invalid_enabled}

  defp check_new(id, tenant_id, mode) do
    case Store.raw_query("SELECT tenant_id FROM connectors WHERE id = ?1", [id]) do
      {:ok, []} -> :ok
      {:ok, [[^tenant_id]]} when mode == :upsert -> :ok
      {:ok, _rows} -> {:error, :connector_exists}
    end
  end

  # A "credentials" map inside the config is the same as the credentials
  # field; everything else in the config must be free of secrets.
  defp split_config(config, credentials) when is_map(config) do
    {nested, config} = Map.pop(stringify(config), "credentials")

    with :ok <- plain(config),
         {:ok, credentials} <- merge_credentials(nested, credentials) do
      {:ok, config, credentials}
    end
  end

  defp split_config(_config, _credentials), do: {:error, :invalid_config}

  defp merge_credentials(nil, nil), do: {:ok, nil}
  defp merge_credentials(a, nil) when is_map(a), do: {:ok, a}
  defp merge_credentials(nil, b) when is_map(b), do: {:ok, b}
  defp merge_credentials(a, b) when is_map(a) and is_map(b), do: {:ok, Map.merge(a, b)}
  defp merge_credentials(_a, _b), do: {:error, :invalid_credentials}

  defp put_credentials(config, nil), do: config
  defp put_credentials(config, credentials), do: Map.put(config, "credentials", credentials)

  defp plain(config) do
    if secret_keys(config) == [], do: :ok, else: {:error, :credentials_outside_envelope}
  end

  # The sealed reference is the Engine's own ciphertext: a caller names the
  # reference in plaintext and the Engine seals it.
  defp secret_keys(map) when is_map(map) do
    Enum.flat_map(map, fn {key, value} ->
      key = to_string(key)

      own =
        if key in [@sealed_reference | @sealed] or Regex.match?(@secret_key, key),
          do: [key],
          else: []

      own ++ secret_keys(value)
    end)
  end

  defp secret_keys(list) when is_list(list), do: Enum.flat_map(list, &secret_keys/1)
  defp secret_keys(_value), do: []

  # ─── update planning ─────────────────────────────────────────────────────

  @fields ~w(enabled cadence interval_ms config credentials workspace)

  defp plan_update(tenant_id, row, changes) do
    changes = changes |> stringify() |> normalize_workspace()
    fields = @fields |> Enum.filter(&Map.has_key?(changes, &1)) |> Enum.sort()

    with {:ok, enabled} <- planned_enabled(row, changes),
         {:ok, config_changes} <- planned_config_changes(changes),
         {:ok, workspace_id} <- planned_workspace(tenant_id, row, changes),
         config = row.config |> apply_config(config_changes) |> apply_cadence(changes),
         {:ok, config} <- apply_credentials(config, changes),
         :ok <- check_broker(config) do
      {:ok,
       %{
         fields: fields,
         config_keys: config_changes |> Map.keys() |> Enum.sort(),
         enabled: enabled,
         workspace_id: workspace_id,
         config: config
       }}
    end
  end

  defp normalize_workspace(%{"workspace_id" => workspace_id} = changes),
    do: changes |> Map.delete("workspace_id") |> Map.put_new("workspace", workspace_id)

  defp normalize_workspace(changes), do: changes

  defp planned_enabled(row, changes) do
    case Map.fetch(changes, "enabled") do
      {:ok, value} -> enabled_flag(value)
      :error -> {:ok, row.enabled}
    end
  end

  defp planned_config_changes(changes) do
    case Map.get(changes, "config") do
      nil -> {:ok, %{}}
      config when is_map(config) -> with :ok <- plain(config), do: {:ok, stringify(config)}
      _other -> {:error, :invalid_config}
    end
  end

  defp planned_workspace(tenant_id, row, changes) do
    case Map.get(changes, "workspace") do
      nil -> {:ok, row.workspace_id}
      workspace_id when workspace_id == row.workspace_id -> {:ok, workspace_id}
      workspace_id -> with :ok <- check_workspace(tenant_id, workspace_id), do: {:ok, workspace_id}
    end
  end

  # Removing the reference removes its seal with it.
  defp apply_config(config, changes) do
    Enum.reduce(changes, config, fn
      {@reference, nil}, acc -> Map.drop(acc, [@reference, @sealed_reference])
      {key, nil}, acc -> Map.delete(acc, key)
      {key, value}, acc -> Map.put(acc, key, value)
    end)
  end

  # The cadence fields are one setting: whichever one a change sets replaces
  # the other, so an older interval_ms can never silently win.
  defp apply_cadence(config, changes) do
    Enum.reduce(["interval_ms", "cadence"], config, fn key, acc ->
      case Map.fetch(changes, key) do
        {:ok, nil} -> Map.delete(acc, key)
        {:ok, value} -> acc |> Map.delete(other_cadence_key(key)) |> Map.put(key, value)
        :error -> acc
      end
    end)
  end

  defp other_cadence_key("interval_ms"), do: "cadence"
  defp other_cadence_key("cadence"), do: "interval_ms"

  defp apply_credentials(config, changes) do
    case Map.fetch(changes, "credentials") do
      :error ->
        {:ok, config}

      {:ok, nil} ->
        {:ok, Map.drop(config, @sealed)}

      {:ok, creds} when is_map(creds) ->
        {:ok, config |> Map.drop(@sealed) |> Map.put("credentials", creds)}

      {:ok, _other} ->
        {:error, :invalid_credentials}
    end
  end

  defp check_broker(config) do
    case CredentialSource.source(config) do
      {:ok, :broker} ->
        if Enum.any?(@sealed, &Map.has_key?(config, &1)),
          do: {:error, :broker_credentials_must_not_be_stored},
          else: :ok

      {:ok, :stored} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ─── rows and views ──────────────────────────────────────────────────────

  defp fetch(tenant_id, id) do
    case select_rows(tenant_id, :all, id) do
      [row] -> {:ok, row}
      [] -> {:error, :not_found}
    end
  end

  defp select_rows(tenant_id, workspace_ids, id) do
    {workspace_sql, workspace_params} = in_clause("workspace_id", workspace_ids, 2)

    {id_sql, id_params} =
      if id, do: {" AND id = ?#{2 + length(workspace_params)}", [id]}, else: {"", []}

    {:ok, rows} =
      Store.raw_query(
        """
        SELECT id, tenant_id, workspace_id, kind, config, enabled, created_at
        FROM connectors
        WHERE tenant_id = ?1#{workspace_sql}#{id_sql}
        ORDER BY workspace_id, id
        """,
        [tenant_id | workspace_params] ++ id_params
      )

    Enum.map(rows, fn [id, tenant_id, workspace_id, kind, config, enabled, created_at] ->
      %{
        id: id,
        tenant_id: tenant_id,
        workspace_id: workspace_id,
        kind: kind,
        config: decode(config),
        enabled: enabled == 1,
        created_at: created_at
      }
    end)
  end

  defp views([]), do: []

  defp views(rows) do
    status = run_status(Enum.map(rows, & &1.id))
    default_ms = PullScheduler.default_interval_ms()
    Enum.map(rows, &view(&1, Map.get(status, &1.id, %{}), default_ms))
  end

  defp view(row, status, default_ms) do
    running = Runner.running?(row.id)
    cadence = Cadence.describe(row.config, row.kind, default_ms)
    last_run = status |> Map.get(:last_run) |> run_view(running)

    %{
      id: row.id,
      kind: row.kind,
      tenant_id: row.tenant_id,
      workspace_id: row.workspace_id,
      enabled: row.enabled,
      created_at: iso(row.created_at),
      credential_source: credential_source(row.config),
      credentials: credential_state(row.config),
      cadence: cadence,
      config: view_config(row.config),
      running: running,
      last_run: last_run,
      last_error: status |> Map.get(:last_error) |> error_view(),
      runs: Map.get(status, :runs, 0),
      signals_total: Map.get(status, :signals_total, 0),
      next_run_at: next_run_at(row, cadence, Map.get(status, :last_run))
    }
  end

  # Run counts and the latest run and latest error of each connector, in
  # three queries however many connectors there are.
  defp run_status(ids) do
    {id_sql, params} = in_clause("connector_id", ids, 1)
    where = "1 = 1" <> id_sql

    {:ok, totals} =
      Store.raw_query(
        """
        SELECT connector_id, COUNT(*), COALESCE(SUM(signals_ingested), 0), MAX(id),
               MAX(CASE WHEN status = 'error' THEN id END)
        FROM connector_runs WHERE #{where} GROUP BY connector_id
        """,
        params
      )

    run_ids =
      totals
      |> Enum.flat_map(fn [_, _, _, last, error] -> [last, error] end)
      |> Enum.reject(&is_nil/1)

    runs = fetch_runs(run_ids)

    Map.new(totals, fn [connector_id, count, signals, last, error] ->
      {connector_id,
       %{
         runs: count,
         signals_total: signals,
         last_run: runs[last],
         last_error: error && runs[error]
       }}
    end)
  end

  defp fetch_runs([]), do: %{}

  defp fetch_runs(run_ids) do
    {id_sql, params} = in_clause("id", run_ids, 1)

    {:ok, rows} =
      Store.raw_query(
        """
        SELECT id, started_at, completed_at, status, signals_ingested, errors_encountered, error_detail
        FROM connector_runs WHERE 1 = 1#{id_sql}
        """,
        params
      )

    Map.new(rows, fn [id, started_at, completed_at, status, signals, errors, detail] ->
      {id,
       %{
         started_at: started_at,
         completed_at: completed_at,
         status: status,
         signals: signals,
         errors: errors,
         error: detail
       }}
    end)
  end

  defp run_view(nil, _running), do: nil

  defp run_view(run, running) do
    status = if run.status == "running" and not running, do: "interrupted", else: run.status

    %{
      started_at: iso(run.started_at),
      completed_at: iso(run.completed_at),
      status: status,
      signals: run.signals,
      errors: run.errors,
      error: if(status == "success", do: nil, else: run.error)
    }
  end

  defp error_view(nil), do: nil
  defp error_view(run), do: %{at: iso(run.started_at), error: run.error}

  defp failing?(%{last_run: %{status: status}}) when status in ["error", "interrupted"], do: true
  defp failing?(_view), do: false

  defp next_run_at(%{enabled: false}, _cadence, _last_run), do: nil
  defp next_run_at(_row, _cadence, nil), do: iso_now()

  defp next_run_at(_row, cadence, %{started_at: started_at}) do
    case datetime(started_at) do
      nil -> iso_now()
      at -> at |> DateTime.add(cadence.interval_ms, :millisecond) |> DateTime.to_iso8601()
    end
  end

  defp credential_source(config) do
    case CredentialSource.source(config) do
      {:ok, source} -> Atom.to_string(source)
      {:error, _} -> "invalid"
    end
  end

  defp credential_state(config) do
    cond do
      credential_source(config) == "broker" -> "broker"
      Enum.any?(@sealed, &Map.has_key?(config, &1)) -> "stored"
      true -> "none"
    end
  end

  # A broker reference, sealed or written before sealing, is shown only as
  # redacted, and its ciphertext not at all.
  defp view_config(config) do
    redacted = config |> Map.drop([@reference, @sealed_reference]) |> redact()

    if CredentialSource.reference?(config),
      do: Map.put(redacted, @reference, @redacted),
      else: redacted
  end

  # Sealed credentials are dropped; any other secret-shaped key (a row
  # written before secrets were refused) is shown only as redacted.
  defp redact(config) when is_map(config) do
    config
    |> Map.drop(@sealed)
    |> Map.new(fn {key, value} ->
      if Regex.match?(@secret_key, to_string(key)),
        do: {key, @redacted},
        else: {key, redact(value)}
    end)
  end

  defp redact(list) when is_list(list), do: Enum.map(list, &redact/1)
  defp redact(value), do: value

  # ─── evidence ────────────────────────────────────────────────────────────

  defp record(tenant_id, kind, id, connector_kind, workspace_id, opts, detail) do
    actor = Keyword.get(opts, :actor, "system:connectors")

    attrs = %{
      subject: actor,
      action: if(kind == "connector.run", do: "write", else: "admin"),
      resource: "optimal://#{workspace_id}/connectors/#{id}",
      workspace_id: workspace_id,
      detail: Map.merge(detail, %{"connector_id" => id, "kind" => to_string(connector_kind)})
    }

    case Evidence.append(tenant_id, kind, attrs) do
      {:ok, _entry} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[Connectors.Rows] #{kind} for #{id} not recorded as evidence: #{inspect(reason)}"
        )

        :ok
    end
  rescue
    error ->
      Logger.warning(
        "[Connectors.Rows] #{kind} for #{id} not recorded as evidence: #{Exception.message(error)}"
      )

      :ok
  end

  defp credentials_detail(nil), do: "none"
  defp credentials_detail(_credentials), do: "stored"

  # ─── helpers ─────────────────────────────────────────────────────────────

  defp in_clause(_column, :all, _first), do: {"", []}

  defp in_clause(column, values, first) when is_list(values) do
    marks = values |> Enum.with_index(first) |> Enum.map_join(", ", fn {_v, i} -> "?#{i}" end)
    {" AND #{column} IN (#{marks})", values}
  end

  defp stringify(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp decode(nil), do: %{}

  defp decode(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end

  defp datetime(nil), do: nil

  defp datetime(text) when is_binary(text) do
    case NaiveDateTime.from_iso8601(String.replace(text, " ", "T")) do
      {:ok, naive} -> DateTime.from_naive!(naive, "Etc/UTC")
      _ -> nil
    end
  end

  defp iso(nil), do: nil

  defp iso(text) do
    case datetime(text) do
      nil -> text
      at -> DateTime.to_iso8601(at)
    end
  end

  defp iso_now, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end
