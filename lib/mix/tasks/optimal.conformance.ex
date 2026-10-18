defmodule Mix.Tasks.Optimal.Conformance do
  use Mix.Task

  @shortdoc "Run the conformance suite against an Engine and report pass or fail"

  @moduledoc """
  Runs the conformance suite against a live Optimal Engine.

      mix optimal.conformance --url http://127.0.0.1:4200 --key <key>
      mix optimal.conformance --url https://engine.example.com --key-file ~/.config/optimal/key --json report.json

  The suite checks the release contract, that authentication is enforced, that
  a workspace-scoped key cannot read another workspace, a decision and the
  evidence chain, every store family, replication status, the viability report,
  and the operating routes (boot, brief, loops). Each check reports pass, fail,
  or skip with the evidence that decided it.

  The run creates its own workspaces and key, revokes and archives them, and
  reports leftovers as a failure. It does not start or stop an Engine and never
  touches a store directly. `mix optimal.conformance --help` prints this text.

  ## Options

    * `--url <url>` - Engine base URL (env `OPTIMAL_ENGINE_URL`)
    * `--key <key>` - API key; never printed (env `OPTIMAL_ENGINE_API_KEY`)
    * `--key-file <path>` - read the key from a file
    * `--workspace <id>` - workspace for the read checks; without it the run creates one
    * `--other-workspace <id>` - a second workspace the key must not be able to read
    * `--prefix <slug>` - slug prefix for workspaces the run creates (default `conformance`)
    * `--timeout <seconds>` - per-request timeout (default 30)
    * `--json <path>` - write the JSON report to a file instead of standard output
    * `--extra-checks <path>` - an Elixir file returning additional check maps
    * `--quiet` - print only the summary and the failing checks

  Exit status is 0 when every check passes and 1 when any check fails or the
  Engine could not be reached, so a release gate can rely on it.
  """

  alias OptimalEngine.Conformance

  @switches [
    url: :string,
    key: :string,
    key_file: :string,
    workspace: :string,
    other_workspace: :string,
    prefix: :string,
    timeout: :integer,
    json: :string,
    extra_checks: :string,
    quiet: :boolean,
    help: :boolean
  ]

  @aliases [w: :workspace, h: :help]

  @impl Mix.Task
  def run(args) do
    {opts, _rest, _invalid} = OptionParser.parse(args, strict: @switches, aliases: @aliases)

    if opts[:help] do
      Mix.shell().info(@moduledoc)
    else
      run_suite(opts)
    end
  end

  defp run_suite(opts) do
    url = opts[:url] || System.get_env("OPTIMAL_ENGINE_URL") || "http://127.0.0.1:4200"

    case key(opts) do
      {:error, reason} -> Mix.raise(reason)
      {_source, api_key} -> execute(url, api_key, opts)
    end
  end

  defp execute(url, api_key, opts) do
    unless quiet?(opts) do
      Mix.shell().info("conformance: checking #{url}")
    end

    report =
      Conformance.run(
        url: url,
        key: api_key,
        primary: opts[:workspace],
        other: opts[:other_workspace],
        prefix: opts[:prefix],
        timeout: (opts[:timeout] || 30) * 1000,
        extra_checks: opts[:extra_checks]
      )

    write_report(report, opts)
    print_summary(report, opts)

    if get_in(report, ["summary", "ok"]) do
      :ok
    else
      Mix.raise(
        "conformance failed: #{get_in(report, ["summary", "failed"])} of #{get_in(report, ["summary", "checks"])} checks failed"
      )
    end
  end

  defp write_report(report, opts) do
    json = Jason.encode!(report, pretty: true)

    case opts[:json] do
      nil -> Mix.shell().info(json)
      path -> File.write!(path, json <> "\n")
    end
  end

  # Every check is listed by default; --quiet and --json keep the list to what
  # did not pass, since the report itself carries the detail.
  defp print_summary(report, opts) do
    summary = report["summary"]
    brief? = quiet?(opts) or opts[:json] != nil

    for check <- report["checks"], not brief? or check["status"] != "pass" do
      Mix.shell().info("#{String.upcase(check["status"])} #{check["id"]}: #{first_line(check)}")
    end

    Mix.shell().info(
      "conformance: #{summary["passed"]} passed, #{summary["failed"]} failed, #{summary["skipped"]} skipped" <>
        if(opts[:json], do: " (report: #{opts[:json]})", else: "")
    )
  end

  defp quiet?(opts), do: opts[:quiet] == true

  defp first_line(%{"status" => "fail", "evidence" => evidence}) when is_map(evidence) do
    case evidence["expectation"] do
      expectation when is_binary(expectation) ->
        "#{expectation} (observed: #{inspect(observed(evidence), limit: 4, printable_limit: 200)})"

      _ ->
        inspect(evidence, limit: 5, printable_limit: 300)
    end
  end

  defp first_line(check), do: check["description"]

  defp observed(evidence) do
    Map.take(evidence, ["status", "error", "body", "missing_fields", "unreachable", "leftovers"])
  end

  defp key(opts) do
    cond do
      opts[:key] ->
        {"--key", opts[:key]}

      opts[:key_file] ->
        read_key_file(opts[:key_file])

      System.get_env("OPTIMAL_ENGINE_API_KEY") ->
        {"OPTIMAL_ENGINE_API_KEY", System.get_env("OPTIMAL_ENGINE_API_KEY")}

      System.get_env("OPTIMAL_ENGINE_API_KEY_FILE") ->
        read_key_file(System.get_env("OPTIMAL_ENGINE_API_KEY_FILE"))

      true ->
        {nil, nil}
    end
  end

  defp read_key_file(path) do
    case File.read(path) do
      {:ok, contents} ->
        {path, String.trim(contents)}

      {:error, reason} ->
        {:error, "cannot read the key file #{path}: #{:file.format_error(reason)}"}
    end
  end
end
