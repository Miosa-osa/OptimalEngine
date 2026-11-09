defmodule OptimalEngine.Analytics.Slots do
  @moduledoc """
  The cap on `duckdb` processes the Engine runs at once for analytics.

  Every analytics statement (`OptimalEngine.Analytics.run_locked/4`) holds a
  slot while its process runs. Each process may use up to the lockdown's
  `memory_limit` (512 MB), so the cap is what bounds the memory analytics can
  take: `OPTIMAL_ANALYTICS_MAX_PROCESSES` (default 1, which keeps a 1 GiB
  guest out of the OOM killer; raise it on a larger machine).

  A query asks with no wait and is refused with `{:error, :busy}` when every
  slot is taken (the API answers 503 with `Retry-After`). An export asks with
  a wait, so a scheduled export queues behind a running one instead of
  failing. A slot is released when its holder says so or exits, so a killed
  caller never strands one.
  """

  use GenServer

  @env "OPTIMAL_ANALYTICS_MAX_PROCESSES"
  @default 1

  @doc "The environment variable the cap is read from."
  @spec env_name() :: String.t()
  def env_name, do: @env

  @doc "The cap now: a whole number above 0 from `OPTIMAL_ANALYTICS_MAX_PROCESSES`, else #{@default}."
  @spec limit() :: pos_integer()
  def limit do
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
  @spec acquire(non_neg_integer()) :: :ok | {:error, :busy}
  def acquire(wait_ms) when is_integer(wait_ms) and wait_ms >= 0 do
    GenServer.call(__MODULE__, {:acquire, self(), wait_ms}, wait_ms + 5_000)
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
  @spec run(non_neg_integer(), (-> result)) :: result | {:error, :busy} when result: term()
  def run(wait_ms, fun) do
    case acquire(wait_ms) do
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

  # holders: monitor ref => pid; waiters: queue of {from, pid, timer ref}

  @impl true
  def init(:ok), do: {:ok, %{holders: %{}, waiters: :queue.new()}}

  @impl true
  def handle_call({:acquire, pid, wait_ms}, from, state) do
    cond do
      map_size(state.holders) < limit() ->
        {:reply, :ok, hold(state, pid)}

      wait_ms == 0 ->
        {:reply, {:error, :busy}, state}

      true ->
        timer = Process.send_after(self(), {:give_up, from}, wait_ms)
        {:noreply, %{state | waiters: :queue.in({from, pid, timer}, state.waiters)}}
    end
  end

  def handle_call({:release, pid}, _from, state) do
    case Enum.find(state.holders, fn {_ref, holder} -> holder == pid end) do
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
      state.waiters |> :queue.to_list() |> Enum.split_with(fn {f, _, _} -> f == from end)

    if gone != [], do: GenServer.reply(from, {:error, :busy})
    {:noreply, %{state | waiters: :queue.from_list(waiting)}}
  end

  defp hold(state, pid), do: put_in(state.holders[Process.monitor(pid)], pid)

  defp drop(state, ref), do: %{state | holders: Map.delete(state.holders, ref)}

  # Hands free slots to the oldest waiters that are still alive.
  defp grant(state) do
    if map_size(state.holders) < limit() do
      case :queue.out(state.waiters) do
        {{:value, {from, pid, timer}}, rest} ->
          Process.cancel_timer(timer)
          state = %{state | waiters: rest}

          if Process.alive?(pid) do
            GenServer.reply(from, :ok)
            state |> hold(pid) |> grant()
          else
            grant(state)
          end

        {:empty, _} ->
          state
      end
    else
      state
    end
  end
end
