defmodule OptimalEngine.Storage.Valkey.Pool do
  @moduledoc """
  The supervised connections the Engine's data path uses to reach Valkey.

  Started by the application only when `OPTIMAL_VALKEY_URL` is set and parses;
  otherwise `start_link/1` returns `:ignore` and every caller of
  `OptimalEngine.Storage.Shared` runs on local ETS, as an Engine without
  Valkey always has.

  The pool is a supervisor of `OPTIMAL_VALKEY_POOL_SIZE` connections (default
  4, at most 32), each an `OptimalEngine.Storage.Valkey.Connection` that
  reconnects with a backoff. A command waits at most `OPTIMAL_VALKEY_TIMEOUT_MS`
  (default 500) for its reply. The pool's table records which connections
  are up, so `serving?/0` and the choice of a connection are an ETS read: a
  caller never waits on a connection that is down.

  The table also holds the invalidations Valkey has not seen yet: a delete or
  a clear made while Valkey was unreachable is kept here and applied, in order,
  before the next command reaches it (`OptimalEngine.Storage.Shared`), so an
  entry removed during an outage, such as a revoked API key's, is never read
  back from Valkey afterwards.
  """

  use Supervisor

  require Logger

  alias OptimalEngine.Storage.Valkey
  alias OptimalEngine.Storage.Valkey.Connection

  @table :optimal_valkey_pool
  @pending :optimal_valkey_pending
  @default_size 4
  @max_size 32
  @default_timeout 500

  @spec start_link(keyword()) :: Supervisor.on_start() | :ignore
  def start_link(opts \\ []) do
    case Valkey.config(opts) do
      {:ok, config} ->
        Supervisor.start_link(__MODULE__, {config, opts}, name: __MODULE__)

      {:error, :not_configured} ->
        :ignore

      {:error, reason} ->
        Logger.warning(
          "[Valkey] #{Valkey.env_name()} is set but invalid (#{reason}); " <>
            "caches and rate limits stay on local ETS"
        )

        :ignore
    end
  end

  @impl true
  def init({config, opts}) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    :ets.new(@pending, [:named_table, :public, :ordered_set])
    :ets.insert(@table, {:rr, 0})

    size =
      Keyword.get_lazy(opts, :size, fn -> env_int("OPTIMAL_VALKEY_POOL_SIZE", @default_size) end)

    size = size |> max(1) |> min(@max_size)
    timeout = command_timeout(opts)
    :ets.insert(@table, {:timeout, timeout})

    children =
      for index <- 1..size do
        {Connection, index: index, config: config, timeout: timeout}
      end

    Supervisor.init(children, strategy: :one_for_one, max_restarts: 10, max_seconds: 5)
  end

  @doc "Whether the pool runs and at least one connection is up."
  @spec serving?() :: boolean()
  def serving? do
    :ets.select_count(@table, [{{:_, :_, :up}, [], [true]}]) > 0
  rescue
    ArgumentError -> false
  end

  @doc "Whether the pool runs at all (Valkey is configured), up or not."
  @spec running?() :: boolean()
  def running?, do: :ets.whereis(@table) != :undefined

  @doc """
  The connections and their state, for the provider status. No configuration.
  """
  @spec stats() :: %{size: non_neg_integer(), up: non_neg_integer(), pending: non_neg_integer()}
  def stats do
    rows = :ets.select(@table, [{{:"$1", :_, :"$2"}, [{:is_integer, :"$1"}], [:"$2"]}])

    %{
      size: length(rows),
      up: Enum.count(rows, &(&1 == :up)),
      pending: :ets.info(@pending, :size)
    }
  rescue
    ArgumentError -> %{size: 0, up: 0, pending: 0}
  end

  @doc "Runs one command. `{:ok, value}`, `{:error, {:server, msg}}` or `{:error, :unavailable}`."
  @spec command([String.t()]) :: {:ok, term()} | {:error, term()}
  def command(parts) do
    case pipeline([parts]) do
      {:ok, [{:error, _} = error]} -> error
      {:ok, [value]} -> {:ok, value}
      {:error, _} = error -> error
    end
  end

  @doc "Runs commands as one pipeline on one connection that is up."
  @spec pipeline([[String.t()]]) :: {:ok, [term()]} | {:error, :unavailable}
  def pipeline(commands) do
    case pick() do
      nil -> {:error, :unavailable}
      pid -> Connection.run(pid, commands, timeout())
    end
  end

  @doc false
  # Called by a connection when it opens or loses its socket.
  def mark(index, pid, status) do
    :ets.insert(@table, {index, pid, status})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc false
  # An invalidation Valkey has not applied yet: `{:delete, namespace, key}` or
  # `{:clear, namespace}`. Ignored without a pool: with no Valkey configured
  # there is nothing to invalidate.
  #
  # The queue is coalesced and bounded. A delete already queued is not queued
  # twice; a clear replaces every earlier invalidation of its namespace (it
  # covers them). Past `config :optimal_engine, :valkey_pending_max` (1000)
  # entries the queue collapses to one clear per namespace, which invalidates
  # at least as much as what it replaces.
  @spec defer(term()) :: :ok
  def defer(operation) do
    queued? =
      case operation do
        {:clear, ns} ->
          :ets.select_delete(@pending, [
            {{:_, {:delete, ns, :_}}, [], [true]},
            {{:_, {:clear, ns}}, [], [true]}
          ])

          false

        other ->
          :ets.select_count(@pending, [{{:_, :"$1"}, [{:"=:=", :"$1", {:const, other}}], [true]}]) >
            0
      end

    unless queued? do
      :ets.insert(@pending, {System.unique_integer([:monotonic, :positive]), operation})
      if :ets.info(@pending, :size) > pending_max(), do: collapse()
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  @default_pending_max 1_000

  defp pending_max do
    case Application.get_env(:optimal_engine, :valkey_pending_max) do
      max when is_integer(max) and max > 0 -> max
      _ -> @default_pending_max
    end
  end

  defp collapse do
    namespaces =
      @pending
      |> :ets.select([{{:_, :"$1"}, [], [:"$1"]}])
      |> Enum.map(fn
        {:delete, ns, _key} -> ns
        {:clear, ns} -> ns
      end)
      |> Enum.uniq()

    :ets.delete_all_objects(@pending)

    Enum.each(namespaces, fn ns ->
      :ets.insert(@pending, {System.unique_integer([:monotonic, :positive]), {:clear, ns}})
    end)

    Logger.warning(
      "[Valkey] more than #{pending_max()} invalidations waited for Valkey; " <>
        "they were folded into a clear of #{length(namespaces)} namespace(s)"
    )
  end

  @doc false
  # Applies the deferred invalidations in order with `apply_fun`, which returns
  # `:ok` or an error. Stops at the first error and keeps the rest.
  @spec flush((term() -> :ok | {:error, term()})) :: :ok | {:error, term()}
  def flush(apply_fun) do
    flush_from(:ets.first(@pending), apply_fun)
  rescue
    ArgumentError -> :ok
  end

  defp flush_from(:"$end_of_table", _apply_fun), do: :ok

  defp flush_from(id, apply_fun) do
    case :ets.lookup(@pending, id) do
      [{^id, operation}] ->
        case apply_fun.(operation) do
          :ok ->
            :ets.delete(@pending, id)
            flush_from(:ets.next(@pending, id), apply_fun)

          error ->
            error
        end

      [] ->
        flush_from(:ets.next(@pending, id), apply_fun)
    end
  end

  defp pick do
    case :ets.select(@table, [{{:_, :"$1", :up}, [], [:"$1"]}]) do
      [] ->
        nil

      up ->
        n = :ets.update_counter(@table, :rr, {2, 1, 1_000_000_000, 0})
        Enum.at(up, rem(n, length(up)))
    end
  rescue
    ArgumentError -> nil
  end

  defp timeout do
    case :ets.lookup(@table, :timeout) do
      [{:timeout, ms}] -> ms
      _ -> @default_timeout
    end
  rescue
    ArgumentError -> @default_timeout
  end

  defp command_timeout(opts) do
    Keyword.get_lazy(opts, :timeout, fn ->
      env_int("OPTIMAL_VALKEY_TIMEOUT_MS", @default_timeout)
    end)
    |> max(10)
  end

  defp env_int(name, default) do
    with value when is_binary(value) <- System.get_env(name),
         {int, ""} <- Integer.parse(String.trim(value)) do
      int
    else
      _ -> default
    end
  end
end
