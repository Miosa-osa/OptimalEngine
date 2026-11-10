defmodule OptimalEngine.Analytics.Slots do
  @moduledoc """
  The cap on `duckdb` processes the Engine runs at once for analytics.

  Every analytics statement (`OptimalEngine.Analytics.run_locked/4`) holds a
  slot while its process runs. Each process may use up to the lockdown's
  `memory_limit` (512 MB), so the cap is what bounds the memory analytics can
  take: `OPTIMAL_ANALYTICS_MAX_PROCESSES` (default 1, which keeps a 1 GiB
  guest out of the OOM killer; raise it on a larger machine).

  Two classes of slot. Queries share the cap: a query asks with no wait and
  is refused with `{:error, :busy}` when every query slot is taken (the API
  answers 503 with `Retry-After`). An export holds the one export slot,
  separate from the cap, so the daily export never turns queries away; it
  runs with a lower memory limit (256 MB) and spills the rest to disk, and a
  second export queues behind it instead of failing. A slot is released when
  its holder says so or exits, so a killed caller never strands one.
  """

  use GenServer

  @env "OPTIMAL_ANALYTICS_MAX_PROCESSES"
  @default 1

  @doc "The environment variable the cap is read from."
  @spec env_name() :: String.t()
  def env_name, do: @env

  @doc "The cap now: a whole number above 0 from `OPTIMAL_ANALYTICS_MAX_PROCESSES`, else #{@default}."
  @spec limit() :: pos_integer()
  def limit, do: limit(:query)

  defp limit(:export), do: 1

  defp limit(:query) do
    case Integer.parse(String.trim(System.get_env(@env) || "")) do
      {n, ""} when n > 0 -> n
      _ -> @default
    end
  end

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc """
  Takes a slot for the calling process, waiting up to `wait_ms` for one.
  `:ok` or `{:error, :busy}`. Without the server running (a task that did not
  start the application) the statement runs unbounded, as before the cap.
  """
  @spec acquire(:query | :export, non_neg_integer()) :: :ok | {:error, :busy}
  def acquire(class \\ :query, wait_ms)
      when class in [:query, :export] and is_integer(wait_ms) and wait_ms >= 0 do
    GenServer.call(__MODULE__, {:acquire, self(), class, wait_ms}, wait_ms + 5_000)
  catch
    :exit, {:noproc, _} -> :ok
    :exit, {:timeout, _} -> {:error, :busy}
  end

  @doc "Gives back the calling process's slot. Nothing held is `:ok`."
  @spec release() :: :ok
  def release do
    GenServer.call(__MODULE__, {:release, self()})
  catch
    :exit, _ -> :ok
  end

  @doc "Runs `fun` holding a slot, or returns `{:error, :busy}`."
  @spec run(:query | :export, non_neg_integer(), (-> result)) :: result | {:error, :busy}
        when result: term()
  def run(class \\ :query, wait_ms, fun) do
    case acquire(class, wait_ms) do
      :ok ->
        try do
          fun.()
        after
          release()
        end

      busy ->
        busy
    end
  end

  # holders: monitor ref => {pid, class}; waiters: queue of {from, pid, class, timer ref}

  @impl true
  def init(:ok), do: {:ok, %{holders: %{}, waiters: :queue.new()}}

  @impl true
  def handle_call({:acquire, pid, class, wait_ms}, from, state) do
    cond do
      free?(state, class, limit(class)) ->
        {:reply, :ok, hold(state, pid, class)}

      wait_ms == 0 ->
        {:reply, {:error, :busy}, state}

      true ->
        timer = Process.send_after(self(), {:give_up, from}, wait_ms)
        {:noreply, %{state | waiters: :queue.in({from, pid, class, timer}, state.waiters)}}
    end
  end

  def handle_call({:release, pid}, _from, state) do
    case Enum.find(state.holders, fn {_ref, {holder, _class}} -> holder == pid end) do
      {ref, _pid} ->
        Process.demonitor(ref, [:flush])
        {:reply, :ok, state |> drop(ref) |> grant()}

      nil ->
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    {:noreply, state |> drop(ref) |> grant()}
  end

  def handle_info({:give_up, from}, state) do
    {gone, waiting} =
      state.waiters |> :queue.to_list() |> Enum.split_with(fn {f, _, _, _} -> f == from end)

    if gone != [], do: GenServer.reply(from, {:error, :busy})
    {:noreply, %{state | waiters: :queue.from_list(waiting)}}
  end

  defp free?(state, class, cap),
    do: Enum.count(state.holders, fn {_ref, {_pid, held}} -> held == class end) < cap

  defp hold(state, pid, class), do: put_in(state.holders[Process.monitor(pid)], {pid, class})

  defp drop(state, ref), do: %{state | holders: Map.delete(state.holders, ref)}

  # Hands free slots to the oldest waiters of each class that are still alive.
  defp grant(state) do
    # The environment is read once per grant, not once per waiter.
    caps = %{query: limit(:query), export: limit(:export)}

    {granted, waiting} =
      state.waiters
      |> :queue.to_list()
      |> Enum.reduce({state, []}, fn {from, pid, class, timer} = waiter, {state, keep} ->
        cond do
          not Process.alive?(pid) ->
            Process.cancel_timer(timer)
            {state, keep}

          free?(state, class, Map.fetch!(caps, class)) ->
            Process.cancel_timer(timer)
            GenServer.reply(from, :ok)
            {hold(state, pid, class), keep}

          true ->
            {state, [waiter | keep]}
        end
      end)

    %{granted | waiters: waiting |> Enum.reverse() |> :queue.from_list()}
  end
end
