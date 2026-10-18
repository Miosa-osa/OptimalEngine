defmodule OptimalEngine.Conformance do
  @moduledoc """
  The conformance suite: one run that checks a live Engine against its release
  contract and its operating surface, and reports pass or fail with evidence
  per check.

      mix optimal.conformance --url http://127.0.0.1:4200 --key <key>

  A run creates its own workspaces (unless the operator names them), mints and
  revokes its own key, cleans up after itself, and reports anything it left
  behind as a failure. The report is JSON: every check carries its id, group,
  status, and the evidence that decided the status.

  This module runs against any Engine over HTTP. It does not start, stop, or
  reconfigure one, and it never reads or writes the store directly.
  """

  alias OptimalEngine.Conformance.{Checks, Client}

  @report_version 1

  @typedoc "A run configuration. `:url` is required; everything else has a default."
  @type options :: keyword()

  @doc """
  Runs the suite and returns the report as a map with string keys.

  Options:

    * `:url` (required) - Engine base URL
    * `:key` - API key; absent means anonymous requests
    * `:transport` - a module implementing `OptimalEngine.Conformance.Transport`
    * `:timeout` - per-request timeout in milliseconds (default 30_000)
    * `:primary` - workspace for the read checks; when absent the run creates one
    * `:other` - a second workspace the key must not be able to read
    * `:prefix` - slug prefix for workspaces the run creates (default "conformance")
    * `:extra_checks` - path to a file returning additional checks
    * `:now` - a `DateTime` for the report timestamps, for tests
  """
  @spec run(options()) :: map()
  def run(opts) do
    started = DateTime.utc_now()

    client =
      Client.new(
        url: Keyword.fetch!(opts, :url),
        key: Keyword.get(opts, :key),
        transport: transport(opts),
        timeout: Keyword.get(opts, :timeout, 30_000)
      )

    context = setup(client, opts)

    checks = setup_checks(context) ++ Checks.all() ++ maybe_external_checks(opts)

    results = Enum.map(checks, &run_check(&1, client, context))

    {archived, context} = teardown(client, context)
    cleanup = run_check(Checks.cleanup(), client, %{context | archived: archived})

    build_report(
      client,
      opts,
      context,
      results ++ [cleanup],
      started,
      Keyword.get(opts, :now, DateTime.utc_now())
    )
    |> json_report()
  end

  # The report is JSON: encoding it here means every consumer, and every test,
  # reads the same shape the mix task prints.
  defp json_report(report) do
    report |> Jason.encode!() |> Jason.decode!()
  rescue
    _ ->
      Map.put(
        report,
        "report_encoding",
        "the report contained a value that is not JSON-encodable; see the check evidence"
      )
  end

  @doc "The built-in checks, without running them."
  @spec checks() :: [Checks.check()]
  def checks, do: Checks.all()

  # ---------------------------------------------------------------------------
  # setup and teardown
  # ---------------------------------------------------------------------------

  defp setup(client, opts) do
    run_id = run_id()

    {primary, primary_created} =
      resolve_workspace(client, Keyword.get(opts, :primary), opts, run_id, "a")

    {other, other_created} = resolve_workspace(client, Keyword.get(opts, :other), opts, run_id, "b")
    created = Enum.reject([primary_created, other_created], &is_nil/1)

    errors =
      for workspace <- created,
          error = Map.get(workspace, :create_error),
          do: "#{workspace.slug}: #{error}"

    %{
      url: client.url,
      key: client.key,
      transport: client.transport,
      run_id: run_id,
      primary: primary,
      other: other,
      created: Enum.filter(created, & &1.created),
      setup_error: Enum.join(errors, "; ") |> then(&if(&1 == "", do: nil, else: &1)),
      # A probe that writes only runs in a workspace this run created and
      # archives, never in a workspace the operator named.
      write_target:
        created
        |> Enum.filter(& &1.created)
        |> List.first()
        |> then(&if(&1, do: &1.slug, else: nil)),
      anonymous: Client.new(url: client.url, transport: client.transport, timeout: client.timeout),
      expected_stores: expected_stores(),
      archived: []
    }
  end

  # A run that cannot create the workspaces it needs still reports: the failure
  # becomes the first check, and the remaining checks report what they saw.
  defp setup_checks(%{setup_error: nil}), do: []

  defp setup_checks(%{setup_error: error}) do
    [
      %{
        id: "setup.workspaces",
        group: "setup",
        description: "the run creates the workspaces it needs",
        run: fn _client, _context -> {:fail, %{error: error}} end
      }
    ]
  end

  defp resolve_workspace(_client, id, _opts, _run_id, _suffix) when is_binary(id), do: {id, nil}

  defp resolve_workspace(client, nil, opts, run_id, suffix) do
    slug = "#{Keyword.get(opts, :prefix) || "conformance"}-#{run_id}-#{suffix}"

    case Client.post(client, "/api/workspaces", %{slug: slug, name: slug}) do
      {:ok, %{status: 201, body: body}} when is_map(body) ->
        {slug, %{slug: slug, id: workspace_id(body) || slug, created: true}}

      {:ok, %{status: status, body: body}} ->
        {slug,
         %{slug: slug, id: slug, created: false, create_error: "HTTP #{status} #{inspect(body)}"}}

      {:error, reason} ->
        {slug, %{slug: slug, id: slug, created: false, create_error: inspect(reason)}}
    end
  end

  # The run works in workspaces it created, so it archives those and reports
  # what happened. A workspace the operator named is left untouched.
  defp teardown(client, context) do
    archived =
      Enum.map(context.created, fn workspace ->
        %{
          workspace: workspace.slug,
          status:
            describe(
              Client.post(client, "/api/workspaces/#{URI.encode_www_form(workspace.id)}/archive")
            )
        }
      end)

    {archived, context}
  end

  defp describe({:ok, %{status: status}}), do: status
  defp describe({:error, reason}), do: "error: #{inspect(reason)}"

  defp workspace_id(body) do
    body["workspace_id"] || body["id"] || get_in(body, ["workspace", "id"])
  end

  # The declared families are read from this build's catalog, which lists them
  # without touching a store. If even that is unavailable the check compares
  # shape only rather than guessing at an expectation.
  defp expected_stores do
    OptimalEngine.StorageCatalog.family_ids()
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp maybe_external_checks(opts) do
    case Keyword.get(opts, :extra_checks) do
      nil -> []
      path -> Checks.external(path)
    end
  end

  # ---------------------------------------------------------------------------
  # the run
  # ---------------------------------------------------------------------------

  defp run_check(check, client, context) do
    result =
      try do
        check.run.(client, context)
      rescue
        error -> {:fail, %{error: Exception.message(error)}}
      catch
        :exit, reason -> {:fail, %{error: "exited: #{inspect(reason)}"}}
      end

    %{
      "id" => check.id,
      "group" => check.group,
      "description" => check.description,
      "status" => status_of(result),
      "evidence" => evidence_of(result)
    }
  end

  defp status_of({:ok, _evidence}), do: "pass"
  defp status_of({:fail, _evidence}), do: "fail"
  defp status_of({:skip, _reason}), do: "skip"
  defp status_of(_other), do: "fail"

  defp evidence_of({:ok, evidence}), do: evidence
  defp evidence_of({:fail, evidence}), do: evidence
  defp evidence_of({:skip, reason}), do: %{skipped: reason}
  defp evidence_of(other), do: %{unexpected_result: inspect(other)}

  # ---------------------------------------------------------------------------
  # the report
  # ---------------------------------------------------------------------------

  defp build_report(client, opts, context, checks, started, finished) do
    summary = summary(checks)

    %{
      "report_version" => @report_version,
      "suite" => "optimal-engine-conformance",
      "engine_url" => client.url,
      "workspaces" => %{
        "primary" => context.primary,
        "other" => context.other,
        "created_by_this_run" => Enum.map(context.created, & &1.slug)
      },
      "started_at" => DateTime.to_iso8601(started),
      "finished_at" => DateTime.to_iso8601(finished),
      "duration_ms" => DateTime.diff(finished, started, :millisecond),
      "engine" => engine_identity(client),
      "setup_error" => context.setup_error,
      "checks" => checks,
      "summary" => summary,
      "key_supplied" => is_binary(Keyword.get(opts, :key))
    }
  end

  defp summary(checks) do
    groups =
      checks
      |> Enum.group_by(& &1["group"])
      |> Map.new(fn {group, group_checks} ->
        {group, counts(group_checks)}
      end)

    Map.merge(counts(checks), %{
      "ok" => Enum.all?(checks, &(&1["status"] != "fail")),
      "groups" => groups
    })
  end

  defp counts(checks) do
    %{
      "checks" => length(checks),
      "passed" => Enum.count(checks, &(&1["status"] == "pass")),
      "failed" => Enum.count(checks, &(&1["status"] == "fail")),
      "skipped" => Enum.count(checks, &(&1["status"] == "skip"))
    }
  end

  # The engine identity in the report is the running Engine's own answer, not
  # this checkout's, so a report names what it actually measured.
  defp engine_identity(client) do
    case Client.get(client, "/api/version") do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        Map.take(
          body,
          ~w(application version release_channel git_sha build_timestamp api_version contract_version expected_migration)
        )

      {:ok, %{status: status}} ->
        %{"unavailable" => "GET /api/version answered #{status}"}

      {:error, reason} ->
        %{"unreachable" => inspect(reason)}
    end
  end

  defp transport(opts), do: Keyword.get(opts, :transport, OptimalEngine.Conformance.Transport.HTTP)

  @doc "A run identifier used in the names of everything a run creates."
  @spec run_id() :: String.t()
  def run_id do
    :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
  end
end
