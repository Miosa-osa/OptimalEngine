defmodule OptimalEngine.SafeAtomTest do
  use ExUnit.Case, async: true

  import OptimalEngine.AtomProbe

  alias OptimalEngine.SafeAtom

  doctest OptimalEngine.SafeAtom

  @allowed [:system, :user, :assistant]

  describe "fetch/2" do
    test "returns the allowed atom a text names" do
      assert {:ok, :user} = SafeAtom.fetch("user", @allowed)
    end

    test "accepts an atom that is allowed" do
      assert {:ok, :assistant} = SafeAtom.fetch(:assistant, @allowed)
    end

    test "rejects an atom that is not allowed" do
      assert :error = SafeAtom.fetch(:tool, @allowed)
    end

    test "rejects text that names no allowed atom, without creating one" do
      text = never_seen()

      assert :error = SafeAtom.fetch(text, @allowed)
      refute_atom(text)
    end

    test "rejects text naming an atom that exists but is not allowed" do
      assert :error = SafeAtom.fetch("tool", @allowed)
    end

    test "rejects values that are neither text nor an atom" do
      assert :error = SafeAtom.fetch(nil, @allowed)
      assert :error = SafeAtom.fetch(7, @allowed)
      assert :error = SafeAtom.fetch(%{}, @allowed)
      assert :error = SafeAtom.fetch(["user"], @allowed)
    end

    test "is case sensitive" do
      assert :error = SafeAtom.fetch("User", @allowed)
    end
  end

  describe "cast/3" do
    test "returns the default for text outside the allowed set" do
      text = never_seen()

      assert SafeAtom.cast(text, @allowed, :user) == :user
      assert SafeAtom.cast(nil, @allowed, :fallback) == :fallback
      refute_atom(text)
    end

    test "returns the atom for allowed text" do
      assert SafeAtom.cast("system", @allowed, :user) == :system
    end
  end

  describe "cast_or_string/2" do
    test "keeps text outside the allowed set as it is" do
      text = never_seen()

      assert SafeAtom.cast_or_string(text, @allowed) == text
      refute_atom(text)
    end

    test "returns the atom for allowed text" do
      assert SafeAtom.cast_or_string("assistant", @allowed) == :assistant
    end
  end

  describe "existing/1" do
    test "returns an atom that already exists" do
      assert {:ok, :user} = SafeAtom.existing("user")
    end

    test "does not create an atom for new text" do
      text = never_seen()

      assert :error = SafeAtom.existing(text)
      refute_atom(text)
    end

    test "passes an atom through and rejects other values" do
      assert {:ok, :user} = SafeAtom.existing(:user)
      assert :error = SafeAtom.existing(nil)
      assert :error = SafeAtom.existing(12)
    end
  end
end
