defmodule OptimalEngine.Conformance.StoreProof do
  @moduledoc """
  Runs the store reality proof as a check of the conformance suite.

  `scripts/store_reality_proof.exs` boots an Engine against a store it is given
  and exercises every logical store in `OptimalEngine.StorageCatalog` once,
  printing a JSON report with one entry per store. It is a host-side proof, not
  an HTTP one: it writes fixture rows, so it must run against a disposable store.

  This module runs that script as a separate process with a temporary store
  under the system temp directory, never the configured one, and maps its report
  onto one conformance check. The HTTP client is untouched: the proof answers
  for the code in this checkout, and the other checks answer for the Engine the
  caller pointed the suite at.
  """

  alias OptimalEngine.Conformance

  @timeout_ms 900_000
  @max_failing_evidence 3

  @doc """
  One check that runs the store proof at `path`, or no check when `path` is nil.
  """
  @spec check(String.t() | nil) :: [OptimalEngine.Conformance.Checks.check()]
  def check(nil), do: []

  def check(path) do
    [
      %{
        id: "stores.reality_proof",
        group: "stores",
        description:
          "every logical store is proved against a disposable store with the proof script",
        run: fn _client, _context -> run(path) end
      }
    ]
  end

  defp run(path) do
    script = Path.expand(path)

    if File.exists?(script) do
      root = Path.join(System.tmp_dir!(), "conformance-store-proof-#{Conformance.run_id()}")
      execute(script, root, Path.join(root, "store-proof.json"))
    else
      {:fail,
       %{script: script, error: "no such file", expectation: "a store proof script at this path"}}
    end
  end

  defp execute(script, root, report_path) do
    File.mkdir_p!(root)

    task =
      Task.async(fn ->
        System.cmd("mix", ["run", script],
          env: environment(root, report_path),
          cd: File.cwd!(),
          stderr_to_stdout: false
        )
      end)

    case Task.yield(task, @timeout_ms) do
      {:ok, {out, exit_status}} ->
        verdict(script, report_path, out, exit_status)

      {:exit, reason} ->
        {:fail, %{script: shown(script), error: "the store proof exited: #{inspect(reason)}"}}

      nil ->
        Task.shutdown(task, :brutal_kill)

        {:fail,
         %{script: shown(script), error: "the store proof did not finish within #{@timeout_ms} ms"}}
    end
  end

  defp verdict(script, report_path, out, exit_status) do
    case report(report_path, out) do
      {:ok, report} ->
        failing =
          report |> Map.get("stores", []) |> List.wrap() |> Enum.reject(&(&1["status"] == "pass"))

        summary = report["summary"] || %{}

        evidence = %{
          script: shown(script),
          exit_status: exit_status,
          summary: summary,
          catalog_coverage: report["catalog_coverage"],
          stores: Map.new(List.wrap(report["stores"]), &{&1["store"], &1["status"]}),
          providers_adapter_missing: summary["providers_adapter_missing"],
          failing: Enum.take(failing, @max_failing_evidence)
        }

        cond do
          exit_status != 0 ->
            {:fail, Map.put(evidence, :expectation, "the proof exits 0 with every store passing")}

          get_in(report, ["catalog_coverage", "complete"]) != true ->
            {:fail,
             Map.put(evidence, :expectation, "the proof covers every store family in the catalog")}

          failing != [] ->
            {:fail, Map.put(evidence, :expectation, "every store family passes the proof")}

          true ->
            {:ok, evidence}
        end

      {:error, reason} ->
        {:fail,
         %{
           script: shown(script),
           exit_status: exit_status,
           error: reason,
           output_tail: tail(out)
         }}
    end
  end

  # The proof writes its report where STORE_PROOF_OUT points when it can, and
  # prints it either way.
  defp report(report_path, out) do
    case read_json(report_path) do
      {:ok, report} -> {:ok, report}
      {:error, _reason} -> read_json_from_output(out)
    end
  end

  defp read_json(path) do
    with {:ok, contents} <- File.read(path) do
      decode(contents)
    end
  end

  defp read_json_from_output(out) when is_binary(out) do
    out
    |> String.split("\n{", parts: 2)
    |> case do
      [_before, json] -> decode("{" <> json)
      _ -> {:error, "the store proof printed no JSON report"}
    end
  end

  defp read_json_from_output(_out), do: {:error, "the store proof printed no JSON report"}

  defp decode(contents) do
    {:ok, Jason.decode!(contents)}
  rescue
    _ -> {:error, "the store proof report is not JSON"}
  end

  defp environment(root, report_path) do
    [
      {"MIX_ENV", mix_env()},
      {"OPTIMAL_API_ENABLED", "false"},
      {"OPTIMAL_ENGINE_ROOT", Path.join(root, "root")},
      {"OPTIMAL_ENGINE_DB", Path.join(root, "engine.db")},
      {"OPTIMAL_ENGINE_CACHE", Path.join(root, "cache")},
      {"OPTIMAL_ENGINE_TOPOLOGY", Path.join(root, "config.yaml")},
      {"OPTIMAL_ENGINE_TOPOLOGY_FULL", Path.join(root, "topology.yaml")},
      {"OPTIMAL_BACKUP_DIR", Path.join(root, "backups")},
      {"OPTIMAL_KNOWLEDGE_BACKEND", "ets"},
      {"OPTIMAL_KNOWLEDGE_ROCKSDB_PATH", Path.join(root, "knowledge-rocksdb")},
      {"STORE_PROOF_OUT", report_path}
    ]
  end

  # The proof runs in the environment the suite was started in, so a checkout
  # that already compiled for tests does not compile again for the proof.
  defp mix_env do
    if Code.ensure_loaded?(Mix) and function_exported?(Mix, :env, 0),
      do: to_string(Mix.env()),
      else: "dev"
  end

  defp shown(script), do: Path.relative_to_cwd(script)

  defp tail(out) when is_binary(out), do: out |> String.split("\n") |> Enum.take(-8)
  defp tail(out), do: inspect(out)
end
