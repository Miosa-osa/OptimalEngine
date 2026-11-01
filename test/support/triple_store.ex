defmodule OptimalEngine.TestSupport.TripleStore do
  @moduledoc """
  The default knowledge triple store, for tests that look at what it holds.

  It loads every edge 10 s after boot. A change applied while it loads is
  applied again once it is done (`Knowledge.Mirror`), so a test waits for the
  load before it looks.
  """

  import ExUnit.Assertions, only: [flunk: 1]

  alias OptimalEngine.Knowledge.DefaultStore
  alias OptimalEngine.Knowledge.Store, as: KnowledgeStore

  @default_store {:via, Registry, {OptimalEngine.Knowledge.Registry, "default"}}

  @doc "The default store's name."
  def default_store, do: @default_store

  @doc "Waits until the default store has loaded the edges, up to 30 s."
  def wait_until_hydrated(tries \\ 300) do
    cond do
      :sys.get_state(DefaultStore).hydrated ->
        :ok

      tries == 0 ->
        flunk("the default store never finished loading")

      true ->
        Process.sleep(100)
        wait_until_hydrated(tries - 1)
    end
  end

  @doc "Whether the default store holds the quad."
  def held?(graph, subject, predicate, object) do
    {:ok, found} =
      KnowledgeStore.query(@default_store,
        graph: graph,
        subject: subject,
        predicate: predicate,
        object: object
      )

    found != []
  end
end
