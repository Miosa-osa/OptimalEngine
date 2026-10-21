defmodule OptimalEngine.Knowledge.Backend.Mnesia do
  @moduledoc """
  Mnesia backend for distributed knowledge storage.

  BEAM-native distribution — replicates across Erlang nodes with no external
  dependencies. Uses disc_copies for persistence, ram_copies for speed.

  Creates three Mnesia tables mirroring the triple index strategy:
  - `{store_id}_spo` — ordered_set, primary index
  - `{store_id}_pos` — ordered_set, predicate-first lookups
  - `{store_id}_osp` — ordered_set, object-first lookups

  ## Options

  - `:copies` — `:ram_copies` (default) or `:disc_copies`
  - `:nodes` — List of nodes to replicate to (default: [node()])

  ## Store ids

  Mnesia names its tables with atoms, and an atom is never garbage collected.
  A store id therefore has to be short and plain: a lowercase letter followed
  by up to 31 lowercase letters, digits and underscores. `init/2` answers
  `{:error, :invalid_store_id}` for any other id, and
  `{:error, :too_many_stores}` once this node has opened as many distinct ids
  as the cap allows (256 by default; `config :optimal_engine,
  :mnesia_max_stores`). An id already opened can be opened again. At most
  three atoms are created per id, so the table atoms are bounded.

  ## Setup

  For disc_copies, initialize Mnesia schema first:

      :mnesia.create_schema([node()])
      :mnesia.start()
  """

  @behaviour OptimalEngine.Knowledge.Backend

  defstruct [:store_id, :spo_table, :pos_table, :osp_table]

  @default_max_stores 256

  @impl true
  def init(store_id, opts) do
    with {:ok, id} <- check_store_id(store_id),
         :ok <- admit_store(id) do
      copies = Keyword.get(opts, :copies, :ram_copies)
      nodes = Keyword.get(opts, :nodes, [node()])

      ensure_mnesia_started()

      spo_table = table_name(id, "spo")
      pos_table = table_name(id, "pos")
      osp_table = table_name(id, "osp")

      create_table(spo_table, copies, nodes)
      create_table(pos_table, copies, nodes)
      create_table(osp_table, copies, nodes)

      {:ok,
       %__MODULE__{
         store_id: store_id,
         spo_table: spo_table,
         pos_table: pos_table,
         osp_table: osp_table
       }}
    end
  end

  @impl true
  def assert(state, s, p, o) do
    :mnesia.transaction(fn ->
      :mnesia.write({state.spo_table, {s, p, o}, true})
      :mnesia.write({state.pos_table, {p, o, s}, true})
      :mnesia.write({state.osp_table, {o, s, p}, true})
    end)

    {:ok, state}
  end

  @impl true
  def assert_many(state, triples) do
    :mnesia.transaction(fn ->
      Enum.each(triples, fn {s, p, o} ->
        :mnesia.write({state.spo_table, {s, p, o}, true})
        :mnesia.write({state.pos_table, {p, o, s}, true})
        :mnesia.write({state.osp_table, {o, s, p}, true})
      end)
    end)

    {:ok, state}
  end

  @impl true
  def retract(state, s, p, o) do
    :mnesia.transaction(fn ->
      :mnesia.delete({state.spo_table, {s, p, o}})
      :mnesia.delete({state.pos_table, {p, o, s}})
      :mnesia.delete({state.osp_table, {o, s, p}})
    end)

    {:ok, state}
  end

  @impl true
  def query(state, pattern) do
    s = Keyword.get(pattern, :subject)
    p = Keyword.get(pattern, :predicate)
    o = Keyword.get(pattern, :object)

    {:atomic, results} =
      :mnesia.transaction(fn ->
        do_query(state, s, p, o)
      end)

    {:ok, results}
  end

  @impl true
  def count(state) do
    {:ok, :mnesia.table_info(state.spo_table, :size)}
  end

  @impl true
  def sparql(_state, _query) do
    {:error, :sparql_not_supported}
  end

  @impl true
  def terminate(state) do
    :mnesia.delete_table(state.spo_table)
    :mnesia.delete_table(state.pos_table)
    :mnesia.delete_table(state.osp_table)
    :ok
  end

  # --- Query implementations ---

  defp do_query(state, s, p, o) when not is_nil(s) and not is_nil(p) and not is_nil(o) do
    case :mnesia.read({state.spo_table, {s, p, o}}) do
      [_] -> [{s, p, o}]
      [] -> []
    end
  end

  defp do_query(state, s, p, nil) when not is_nil(s) and not is_nil(p) do
    :mnesia.match_object({state.spo_table, {s, p, :_}, :_})
    |> Enum.map(fn {_, {a, b, c}, _} -> {a, b, c} end)
  end

  defp do_query(state, s, nil, nil) when not is_nil(s) do
    :mnesia.match_object({state.spo_table, {s, :_, :_}, :_})
    |> Enum.map(fn {_, {a, b, c}, _} -> {a, b, c} end)
  end

  defp do_query(state, nil, p, o) when not is_nil(p) and not is_nil(o) do
    :mnesia.match_object({state.pos_table, {p, o, :_}, :_})
    |> Enum.map(fn {_, {pred, obj, subj}, _} -> {subj, pred, obj} end)
  end

  defp do_query(state, nil, p, nil) when not is_nil(p) do
    :mnesia.match_object({state.pos_table, {p, :_, :_}, :_})
    |> Enum.map(fn {_, {pred, obj, subj}, _} -> {subj, pred, obj} end)
  end

  defp do_query(state, nil, nil, o) when not is_nil(o) do
    :mnesia.match_object({state.osp_table, {o, :_, :_}, :_})
    |> Enum.map(fn {_, {obj, subj, pred}, _} -> {subj, pred, obj} end)
  end

  defp do_query(state, s, nil, o) when not is_nil(s) and not is_nil(o) do
    :mnesia.match_object({state.osp_table, {o, s, :_}, :_})
    |> Enum.map(fn {_, {obj, subj, pred}, _} -> {subj, pred, obj} end)
  end

  defp do_query(state, nil, nil, nil) do
    :mnesia.match_object({state.spo_table, :_, :_})
    |> Enum.map(fn {_, {s, p, o}, _} -> {s, p, o} end)
  end

  # --- Helpers ---

  defp table_name(store_id, suffix) do
    :"mk_#{store_id}_#{suffix}"
  end

  defp check_store_id(store_id) when is_atom(store_id) and not is_nil(store_id),
    do: check_store_id(Atom.to_string(store_id))

  defp check_store_id(store_id) when is_binary(store_id) do
    if Regex.match?(~r/\A[a-z][a-z0-9_]{0,31}\z/, store_id),
      do: {:ok, store_id},
      else: {:error, :invalid_store_id}
  end

  defp check_store_id(_store_id), do: {:error, :invalid_store_id}

  # The ids this node has opened, kept for the life of the VM because the table
  # atoms of a closed store stay in the atom table. The check and the update run
  # under one lock, so concurrent `init/2` calls cannot pass the cap together or
  # lose an id.
  defp admit_store(id) do
    :global.trans({{__MODULE__, :admit_store}, self()}, fn -> admit_locked(id) end, [node()])
  end

  defp admit_locked(id) do
    known = :persistent_term.get({__MODULE__, :stores}, MapSet.new())
    max = Application.get_env(:optimal_engine, :mnesia_max_stores, @default_max_stores)

    cond do
      MapSet.member?(known, id) ->
        :ok

      MapSet.size(known) >= max ->
        {:error, :too_many_stores}

      true ->
        :persistent_term.put({__MODULE__, :stores}, MapSet.put(known, id))
        :ok
    end
  end

  defp ensure_mnesia_started do
    case :mnesia.system_info(:is_running) do
      :yes ->
        :ok

      :no ->
        :mnesia.start()

      :starting ->
        Process.sleep(100)
        ensure_mnesia_started()

      :stopping ->
        Process.sleep(100)
        ensure_mnesia_started()
    end
  end

  defp create_table(name, copies, nodes) do
    case :mnesia.create_table(name, [
           {copies, nodes},
           {:attributes, [:key, :value]},
           {:type, :set}
         ]) do
      {:atomic, :ok} -> :ok
      {:aborted, {:already_exists, ^name}} -> :ok
      {:aborted, reason} -> {:error, reason}
    end
  end
end
