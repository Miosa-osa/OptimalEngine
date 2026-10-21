defmodule OptimalEngine.Connectors.RegistryTest do
  use ExUnit.Case, async: true

  alias OptimalEngine.Connectors.Registry

  test "all/0 lists every adapter module" do
    mods = Registry.all()
    assert length(mods) == 20
    # Every module responds to kind/0
    assert Enum.all?(mods, fn m -> is_atom(m.kind()) end)
  end

  test "kinds/0 returns 20 unique adapter atoms" do
    kinds = Registry.kinds()
    assert length(kinds) == 20
    assert length(Enum.uniq(kinds)) == 20
    assert :slack in kinds
    assert :gmail in kinds
    assert :github in kinds
    assert :hubspot in kinds
    assert :go_high_level in kinds
    assert :stripe in kinds
    assert :beehiiv in kinds
    assert :jot_form in kinds
    assert :fathom in kinds
  end

  describe "fetch_by_name/2" do
    test "finds an adapter by the name of its kind, and makes no atom for a name that is not one" do
      for mod <- Registry.all() do
        assert {:ok, ^mod} = Registry.fetch_by_name(Atom.to_string(mod.kind()))
      end

      name = "no_such_connector_#{System.unique_integer([:positive])}"
      assert {:error, :unknown_kind} = Registry.fetch_by_name(name)
      assert {:error, :unknown_kind} = Registry.fetch_by_name(:gmail)
      assert {:error, :unknown_kind} = Registry.fetch_by_name(nil)
      assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
    end

    test "does not need the atom of a kind to exist before the adapter has been used" do
      # An adapter module that has not been loaded has not created the atom its
      # kind/0 returns, so a lookup through String.to_existing_atom/1 refuses a
      # kind the Engine does support.
      name = "lazy_kind_#{System.unique_integer([:positive])}"
      module = Module.concat(__MODULE__, "Lazy#{System.unique_integer([:positive])}")

      # The name is read when kind/0 is called: written as a literal in the
      # module, the compiler would fold the conversion and create the atom.
      :persistent_term.put({module, :kind}, name)
      on_exit(fn -> :persistent_term.erase({module, :kind}) end)

      Module.create(
        module,
        quote do
          def kind, do: String.to_atom(:persistent_term.get({__MODULE__, :kind}))
        end,
        Macro.Env.location(__ENV__)
      )

      assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
      assert {:ok, ^module} = Registry.fetch_by_name(name, [module])
    end
  end

  test "fetch/1 returns the adapter module for a known kind" do
    assert {:ok, OptimalEngine.Connectors.Adapters.Slack} = Registry.fetch(:slack)
    assert {:ok, OptimalEngine.Connectors.Adapters.Linear} = Registry.fetch(:linear)
  end

  test "fetch/1 returns :unknown_kind for an unregistered atom" do
    assert {:error, :unknown_kind} = Registry.fetch(:nonexistent)
  end

  test "summary/0 emits (kind, name, auth) triples" do
    summary = Registry.summary()
    assert length(summary) == 20
    assert Enum.all?(summary, fn {k, n, a} -> is_atom(k) and is_binary(n) and is_atom(a) end)

    {:slack, name, auth} =
      Enum.find(summary, fn {k, _, _} -> k == :slack end)

    assert name == "Slack"
    assert auth == :oauth2
  end
end
