defmodule OptimalEngine.Store.AdapterContractTest do
  @moduledoc """
  The canonical store contract is explicit, and the current implementation
  implements all of it. A store function added to one implementation and not
  the other fails here (and at compile time through `@behaviour`).
  """

  use ExUnit.Case, async: true

  alias OptimalEngine.Store.Adapter

  test "the SQLite store implements every adapter callback" do
    Code.ensure_loaded!(OptimalEngine.Store)

    callbacks = Adapter.behaviour_info(:callbacks)
    assert callbacks != []

    missing =
      Enum.reject(callbacks, fn {name, arity} ->
        function_exported?(OptimalEngine.Store, name, arity)
      end)

    assert missing == [], "OptimalEngine.Store is missing callbacks: #{inspect(missing)}"
  end

  test "the contract covers transactions, raw statements and the typed operations" do
    callbacks = Adapter.behaviour_info(:callbacks)

    for callback <- [
          {:transaction, 2},
          {:txn_query, 3},
          {:txn_execute, 3},
          {:raw_query, 2},
          {:raw_execute, 2},
          {:insert_context, 1},
          {:get_context, 1},
          {:delete_context, 1}
        ] do
      assert callback in callbacks, "contract is missing #{inspect(callback)}"
    end
  end
end
