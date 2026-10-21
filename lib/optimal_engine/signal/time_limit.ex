defmodule OptimalEngine.Signal.TimeLimit do
  @moduledoc """
  Runs one detection step with a time limit.

  The mode and genre detectors run many regular expressions over text a
  caller sent. A crafted text can make one of them backtrack for seconds, and
  intake classifies in one process that every tenant's intake waits on. Each
  detection therefore runs in a process of its own, which is stopped once it
  passes the limit; the caller then gets the detector's fallback, the answer
  for a text that carries no evidence.

  The limit is `:classification_timeout_ms` (1,000 by default). An ordinary
  document is classified in a few milliseconds, so only a text built to be
  slow reaches it.

  One document can need many detections (its genre, its mode, each chunk),
  so `with_budget/2` also bounds them together: inside it, a detection gets at
  most what is left of the budget (`:classification_budget_ms`, 3,000 by
  default), and once the budget is spent the rest get their fallback without
  running.
  """

  require Logger

  @default_timeout_ms 1_000
  @default_budget_ms 3_000
  @deadline :optimal_engine_classification_deadline

  @doc """
  Runs `fun` with one classification budget for every detection inside it.
  A budget opened inside another never extends it. Options: `:budget_ms`
  (default: the configured budget).
  """
  @spec with_budget((-> result), keyword()) :: result when result: term()
  def with_budget(fun, opts \\ []) when is_function(fun, 0) do
    budget = Keyword.get_lazy(opts, :budget_ms, &budget_ms/0)
    outer = Process.get(@deadline)
    deadline = System.monotonic_time(:millisecond) + budget
    Process.put(@deadline, if(outer, do: min(outer, deadline), else: deadline))

    try do
      fun.()
    after
      if outer, do: Process.put(@deadline, outer), else: Process.delete(@deadline)
    end
  end

  @doc """
  Returns `fun.()`, or `fallback` when it does not finish within the limit or
  fails. Options: `:timeout_ms` (default: the configured limit) and `:label`,
  which names the step in the log line and the telemetry event.
  """
  @spec run((-> result), result, keyword()) :: result when result: term()
  def run(fun, fallback, opts \\ []) when is_function(fun, 0) do
    label = Keyword.get(opts, :label, "detection")

    case allowed_ms(Keyword.get_lazy(opts, :timeout_ms, &timeout_ms/0)) do
      0 ->
        :telemetry.execute(
          [:optimal_engine, :signal, :classification_budget_spent],
          %{count: 1},
          %{label: label}
        )

        fallback

      timeout ->
        run_limited(fun, fallback, timeout, label)
    end
  end

  # The limit, or what is left of the budget when that is less.
  defp allowed_ms(limit) do
    case Process.get(@deadline) do
      nil -> limit
      deadline -> deadline |> Kernel.-(System.monotonic_time(:millisecond)) |> max(0) |> min(limit)
    end
  end

  # The worker is a linked task, so it dies with its caller (a request
  # process shut down mid-check takes its detection with it), and it never
  # exits abnormally itself: a failure comes back as a value, which also keeps
  # the exception text out of the crash log. Task.shutdown/2 drops a reply
  # that races the deadline.
  defp run_limited(fun, fallback, timeout, label) do
    task =
      Task.async(fn ->
        try do
          {:ok, fun.()}
        catch
          kind, reason -> {:failed, failure(kind, reason)}
        end
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, result}} ->
        result

      {:ok, {:failed, why}} ->
        Logger.warning("[Signal] #{label} failed (#{why}); using the fallback")
        fallback

      _stopped ->
        :telemetry.execute(
          [:optimal_engine, :signal, :classification_timeout],
          %{count: 1, timeout_ms: timeout},
          %{label: label}
        )

        Logger.warning("[Signal] #{label} stopped after #{timeout} ms; using the fallback")
        fallback
    end
  end

  defp timeout_ms,
    do: Application.get_env(:optimal_engine, :classification_timeout_ms, @default_timeout_ms)

  defp budget_ms,
    do: Application.get_env(:optimal_engine, :classification_budget_ms, @default_budget_ms)

  # Names the failure without its arguments or message, which may hold the text.
  defp failure(:error, %module{}), do: inspect(module)
  defp failure(kind, reason) when is_atom(reason), do: "#{kind} #{inspect(reason)}"
  defp failure(kind, _reason), do: Atom.to_string(kind)
end
