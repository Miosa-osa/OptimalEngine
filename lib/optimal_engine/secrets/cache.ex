defmodule OptimalEngine.Secrets.Cache do
  @moduledoc """
  Owns the table the fields read from OpenBao are kept in
  (`OptimalEngine.Secrets`). The table is `:protected`: any process reads a
  kept field, and only this process writes one, so no other process in the VM
  can plant or overwrite a value a later fetch would serve. It is supervised;
  a restart starts an empty table, and a fetch while it is down reads OpenBao
  and keeps nothing.
  """
  use GenServer

  @table :optimal_engine_secrets_cache

  @doc false
  def table, do: @table

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Keeps `value` under `key` until `expires` (monotonic milliseconds). Never raises."
  @spec put(term(), integer(), String.t()) :: :ok
  def put(key, expires, value) do
    GenServer.call(__MODULE__, {:put, key, expires, value})
  catch
    :exit, _not_running -> :ok
  end

  @doc "Drops every kept value. Never raises."
  @spec flush() :: :ok
  def flush do
    GenServer.call(__MODULE__, :flush)
  catch
    :exit, _not_running -> :ok
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :protected, :set, read_concurrency: true])
    {:ok, %{}}
  end

  @impl true
  def handle_call({:put, key, expires, value}, _from, state) do
    :ets.insert(@table, {key, expires, value})
    {:reply, :ok, state}
  end

  def handle_call(:flush, _from, state) do
    :ets.delete_all_objects(@table)
    {:reply, :ok, state}
  end
end
