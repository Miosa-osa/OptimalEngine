defmodule OptimalEngine.Analyses do
  @moduledoc """
  Analyses that run as scheduled Engine jobs (`OptimalEngine.Jobs`) and
  leave a report in `analysis_reports`.

  | Kind | Scope | What it does |
  | --- | --- | --- |
  | `promises` | each workspace | detects commitments, owed replies, payments and decisions in recent Signals, closes the ones answered in their thread, and reports what is open and overdue |
  | `workspace_population` | the intake workspace | with placement by meaning on, first embeds up to 200 of the tenant's documents that have no vector; then moves high-confidence intake items to their workspace and queues the rest for routing review |
  | `meeting_archive` | workspaces with meeting connectors | pulls new meetings from the workspace's meeting connectors into the workspace |
  | `file_audit` | the tenant | storage and hierarchy audits: index and graph parity, isolation, leaked fixtures, asset paths, workspace and node structure |
  | `storage_usage` | the tenant | usage against the size profile (`OptimalEngine.Sizing`) with the resize advice |
  | `retention_sweep` | the tenant | applies the tenant's retention policies; legal holds win |

  `schedule/1` enqueues each day's analyses once (an idempotency key per
  kind, workspace, and day); the worker (`Analyses.Worker`) drains them.
  `run_now/4` runs one immediately and returns its report.
  """

  require Logger

  alias OptimalEngine.{
    Compliance,
    CorpusOrganizer,
    HierarchyAudit,
    Jobs,
    Sizing,
    StorageAudit,
    Store
  }

  alias OptimalEngine.Connectors.{PullScheduler, Runner}
  alias OptimalEngine.Embed.Backfill
  alias OptimalEngine.Operating.Loops
  alias OptimalEngine.Tenancy.Tenant
  alias OptimalEngine.Workspace

  @kinds ~w(promises workspace_population meeting_archive file_audit storage_usage retention_sweep)
  @tenant_kinds ~w(file_audit storage_usage retention_sweep)
  @meeting_connectors ~w(zoom teams fathom)

  @doc "The analysis kinds."
  @spec kinds() :: [String.t()]
  def kinds, do: @kinds

  @doc "The job kind for an analysis."
  @spec job_kind(String.t()) :: String.t()
  def job_kind(kind), do: "analysis." <> kind

  @doc """
  Enqueues the day's analyses for every tenant (once per kind, workspace,
  and day). Returns how many jobs were enqueued or already queued.
  """
  @spec schedule(Date.t()) :: non_neg_integer()
  def schedule(today \\ Date.utc_today()) do
    {:ok, tenants} = Tenant.list()

    tenants
    |> Enum.flat_map(&due(&1.id))
    |> Enum.count(fn {workspace_id, kind} ->
      match?(
        {:ok, _},
        Jobs.enqueue(workspace_id, job_kind(kind), %{"kind" => kind},
          idempotency_key: "analysis:#{kind}:#{Date.to_iso8601(today)}",
          max_attempts: 3
        )
      )
    end)
  end

  @doc "Runs due analysis jobs, at most `limit`. Returns the outcomes."
  @spec drain(pos_integer()) :: [map()]
  def drain(limit \\ 20) do
    Enum.reduce_while(1..limit, [], fn _, acc ->
      case Jobs.run_next(&handle/1, kinds: Enum.map(@kinds, &job_kind/1), retry_in: 60) do
        {:ok, %{job: job, outcome: outcome}} ->
          {:cont, [%{job_id: job.id, kind: job.kind, outcome: outcome} | acc]}

        :empty ->
          {:halt, acc}

        {:error, reason} ->
          {:halt, [%{error: inspect(reason)} | acc]}
      end
    end)
    |> Enum.reverse()
  end

  @doc """
  Enqueues an analysis for `workspace_id` and runs it now. Returns the job
  outcome and the report.
  """
  @spec run_now(String.t(), String.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def run_now(tenant_id, workspace_id, kind, payload \\ %{})

  def run_now(tenant_id, workspace_id, kind, payload) when kind in @kinds do
    with {:ok, workspace} <- Workspace.get(workspace_id),
         true <- workspace.tenant_id == tenant_id || {:error, :not_found},
         {:ok, job} <-
           Jobs.enqueue(workspace_id, job_kind(kind), Map.put(payload, "kind", kind),
             priority: 100,
             max_attempts: 1
           ),
         {:ok, %{job: done, outcome: outcome}} <-
           Jobs.run_next(&handle/1, workspace_id: workspace_id, kinds: [job_kind(kind)]) do
      {:ok,
       %{
         job_id: done.id,
         requested_job_id: job.id,
         outcome: outcome,
         report: latest(tenant_id, workspace_id, kind)
       }}
    end
  end

  def run_now(_tenant_id, _workspace_id, _kind, _payload), do: {:error, :unknown_analysis}

  @doc "Reports for workspaces, newest first. Options `:kind`, `:limit`."
  @spec reports(String.t(), [String.t()], keyword()) :: [map()]
  def reports(tenant_id, workspace_ids, opts \\ []) do
    limit = opts |> Keyword.get(:limit, 20) |> max(1) |> min(200)
    placeholders = Enum.map_join(1..length(workspace_ids), ", ", &"?#{&1 + 1}")

    {kind_sql, params} =
      case opts[:kind] do
        nil -> {"", []}
        kind -> {" AND kind = ?#{length(workspace_ids) + 2}", [kind]}
      end

    {:ok, rows} =
      Store.raw_query(
        """
        SELECT id, workspace_id, kind, job_id, status, summary, report, created_at
        FROM analysis_reports
        WHERE tenant_id = ?1 AND workspace_id IN (#{placeholders})#{kind_sql}
        ORDER BY created_at DESC, rowid DESC LIMIT #{limit}
        """,
        [tenant_id | workspace_ids] ++ params
      )

    Enum.map(rows, fn [id, ws, kind, job_id, status, summary, report, at] ->
      %{
        id: id,
        workspace_id: ws,
        kind: kind,
        job_id: job_id,
        status: status,
        summary: summary,
        report: Jason.decode!(report),
        created_at: at
      }
    end)
  end

  @doc "Runs the analysis a job names and records its report."
  @spec handle(map()) :: :ok | {:error, term()}
  def handle(job) do
    kind = job.payload["kind"] || String.replace_prefix(job.kind, "analysis.", "")

    result =
      try do
        analyze(kind, job.tenant_id, job.workspace_id, job.payload)
      rescue
        error -> {:error, Exception.message(error)}
      end

    case result do
      {:ok, summary, report} ->
        record(job, kind, "ok", summary, report)
        :ok

      {:error, reason} ->
        record(job, kind, "failed", "Failed: #{inspect(reason)}", %{"error" => inspect(reason)})
        {:error, reason}
    end
  end

  # -- the analyses ------------------------------------------------------------

  defp analyze("promises", tenant_id, workspace_id, payload) do
    since = payload["since"] || Date.utc_today() |> Date.add(-7) |> Date.to_iso8601()
    {:ok, detected} = Loops.extract(tenant_id, workspace_id, since: since)
    {:ok, closed} = Loops.close_answered(tenant_id, workspace_id)
    open = Loops.list(tenant_id, workspace_ids: [workspace_id], state: "open", limit: 1_000)
    today = Date.to_iso8601(Date.utc_today())
    overdue = Enum.filter(open, &(&1.due_at && String.slice(&1.due_at, 0, 10) < today))

    {:ok,
     "#{length(detected)} detected, #{count(closed)} closed by reply, #{length(open)} open, #{length(overdue)} overdue.",
     %{
       "since" => since,
       "detected" => length(detected),
       "closed_by_reply" => count(closed),
       "open" => length(open),
       "open_by_kind" => Enum.frequencies_by(open, & &1.kind),
       "overdue" =>
         overdue
         |> Enum.sort_by(& &1.due_at)
         |> Enum.take(20)
         |> Enum.map(
           &%{"id" => &1.id, "title" => &1.title, "due_at" => &1.due_at, "owner" => &1.owner}
         )
     }}
  end

  defp analyze("workspace_population", tenant_id, workspace_id, payload) do
    if workspace_id != CorpusOrganizer.source_workspace() do
      {:ok, "Not the intake workspace; nothing to place.", %{"moved" => 0, "queued" => 0}}
    else
      embedding = embed_for_placement(tenant_id, payload)
      {:ok, preview} = CorpusOrganizer.preview()

      moved =
        case CorpusOrganizer.apply_high_confidence(preview: preview) do
          {:ok, %{moved: moved}} -> moved
          {:error, %{moved: moved}} -> moved
        end

      {:ok, queued} = CorpusOrganizer.queue_remaining(preview: preview)
      by_meaning = Map.get(preview.by_method, :semantic, 0)

      {:ok,
       "#{moved} items placed in their workspace (#{by_meaning} by meaning), #{queued} queued for routing review.",
       %{
         "moved" => moved,
         "moved_by_meaning" => by_meaning,
         "queued" => queued,
         "embedding" => embedding
       }}
    end
  end

  defp analyze("meeting_archive", tenant_id, workspace_id, _payload) do
    connectors = meeting_connectors(tenant_id, workspace_id)

    runs =
      Enum.map(connectors, fn [id, kind] ->
        case Runner.run(id, signal_sink: PullScheduler.intake_sink()) do
          {:ok, result} ->
            %{"connector" => id, "kind" => kind, "status" => inspect(result[:status] || :ok)}

          {:error, reason} ->
            %{"connector" => id, "kind" => kind, "status" => "error", "error" => inspect(reason)}
        end
      end)

    failed = Enum.count(runs, &(&1["status"] == "error"))

    {:ok, "#{length(connectors)} meeting connectors pulled, #{failed} failed.",
     %{"connectors" => runs}}
  end

  defp analyze("file_audit", tenant_id, _workspace_id, _payload) do
    storage = StorageAudit.run()
    {:ok, hierarchy} = HierarchyAudit.run(tenant_id)
    failing = for check <- storage.checks, not check.ok, do: check.name

    {:ok,
     "Storage #{if storage.ok, do: "ok", else: "failing: " <> Enum.join(failing, ", ")}; hierarchy #{hierarchy.issue_count} issues.",
     %{"storage" => json_safe(storage), "hierarchy" => json_safe(hierarchy)}}
  end

  defp analyze("storage_usage", _tenant_id, _workspace_id, _payload) do
    usage = Sizing.usage()
    worst = usage.worst || %{name: "none", percent: 0.0}

    {:ok,
     "Profile #{usage.profile.id}; highest gauge #{worst.name} at #{worst.percent} percent; #{usage.recommendation.action}.",
     json_safe(usage)}
  end

  defp analyze("retention_sweep", tenant_id, _workspace_id, payload) do
    {:ok, result} =
      Compliance.retention_sweep(tenant_id: tenant_id, dry_run: payload["dry_run"] == true)

    {:ok,
     "#{result.policies_evaluated} policies, #{result.actions_taken} actions, #{result.skipped_held} held, #{result.errors} errors.",
     json_safe(result)}
  end

  defp analyze(kind, _tenant_id, _workspace_id, _payload), do: {:error, {:unknown_analysis, kind}}

  # Placement by meaning compares document vectors, so documents still
  # without one are embedded first, a bounded number per run.
  defp embed_for_placement(tenant_id, payload) do
    if CorpusOrganizer.semantic_settings() do
      case Backfill.run(tenant_id: tenant_id, limit: payload["embed_limit"] || 200) do
        {:ok, result} -> json_safe(result)
        {:error, reason} -> %{"error" => inspect(reason)}
      end
    end
  end

  # -- scheduling --------------------------------------------------------------

  # {workspace, kind} pairs due for a tenant.
  defp due(tenant_id) do
    {:ok, workspaces} = Workspace.list(tenant_id: tenant_id, status: :active, limit: 10_000)
    ids = Enum.map(workspaces, & &1.id)

    tenant_pairs =
      case home_workspace(tenant_id, ids) do
        nil -> []
        home -> Enum.map(@tenant_kinds, &{home, &1})
      end

    population =
      if CorpusOrganizer.source_workspace() in ids,
        do: [{CorpusOrganizer.source_workspace(), "workspace_population"}],
        else: []

    meetings = for id <- ids, meeting_connectors(tenant_id, id) != [], do: {id, "meeting_archive"}

    Enum.map(ids, &{&1, "promises"}) ++ population ++ meetings ++ tenant_pairs
  end

  # Tenant-wide analyses run on the tenant's default workspace, or its first.
  defp home_workspace(_tenant_id, []), do: nil

  defp home_workspace(tenant_id, ids) do
    default =
      if tenant_id == Tenant.default_id(), do: Workspace.default_id(), else: tenant_id <> ":default"

    if default in ids, do: default, else: hd(Enum.sort(ids))
  end

  defp meeting_connectors(tenant_id, workspace_id) do
    placeholders = Enum.map_join(1..length(@meeting_connectors), ", ", &"?#{&1 + 2}")

    case Store.raw_query(
           "SELECT id, kind FROM connectors WHERE tenant_id = ?1 AND workspace_id = ?2 AND enabled = 1 AND kind IN (#{placeholders})",
           [tenant_id, workspace_id | @meeting_connectors]
         ) do
      {:ok, rows} -> rows
      _ -> []
    end
  end

  # -- reports -----------------------------------------------------------------

  defp record(job, kind, status, summary, report) do
    {:ok, _} =
      Store.raw_query(
        """
        INSERT INTO analysis_reports (id, tenant_id, workspace_id, kind, job_id, status, summary, report)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
        """,
        [
          "anr_" <> (:crypto.strong_rand_bytes(12) |> Base.encode16(case: :lower)),
          job.tenant_id,
          job.workspace_id,
          kind,
          job.id,
          status,
          summary,
          Jason.encode!(report)
        ]
      )
  rescue
    error -> Logger.warning("[Analyses] report not recorded: #{Exception.message(error)}")
  end

  defp latest(tenant_id, workspace_id, kind) do
    case reports(tenant_id, [workspace_id], kind: kind, limit: 1) do
      [report] -> report
      [] -> nil
    end
  end

  defp count(list) when is_list(list), do: length(list)
  defp count(n) when is_integer(n), do: n
  defp count(_), do: 0

  # Reports are stored as JSON: tuples and structs become strings.
  defp json_safe(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp json_safe(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp json_safe(%Date{} = value), do: Date.to_iso8601(value)
  defp json_safe(%_{} = struct), do: struct |> Map.from_struct() |> json_safe()

  defp json_safe(map) when is_map(map),
    do: Map.new(map, fn {k, v} -> {to_string(k), json_safe(v)} end)

  defp json_safe(list) when is_list(list), do: Enum.map(list, &json_safe/1)
  defp json_safe(tuple) when is_tuple(tuple), do: inspect(tuple)
  defp json_safe(value), do: value
end
