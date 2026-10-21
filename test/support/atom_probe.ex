defmodule OptimalEngine.AtomProbe do
  @moduledoc """
  Test support for the atom-table checks.

  The BEAM atom table is finite and never garbage collected, so no text a
  caller, a peer or a file supplies may become an atom. `never_seen/1` returns
  text no atom exists for, a test feeds it through the code under test, and
  `refute_atom/1` then proves that nothing created the atom.

  The text is made of lowercase letters and underscores only, so it passes the
  lexers and validators that accept identifiers (wiki verbs, slugs, keys).
  """

  import ExUnit.Assertions

  @doc "Text with the given prefix that has never been an atom in this node."
  @spec never_seen(String.t()) :: String.t()
  def never_seen(prefix \\ "zz_atom_probe") do
    text = prefix <> "_" <> letters(System.unique_integer([:positive])) <> "_" <> random_letters()
    refute_atom(text)
    text
  end

  @doc "Fails when an atom exists for `text`, so something created it."
  @spec refute_atom(String.t()) :: :ok
  def refute_atom(text) when is_binary(text) do
    assert_raise ArgumentError, fn -> String.to_existing_atom(text) end
    :ok
  end

  # An integer in base 26, written with letters.
  defp letters(n) when n < 26, do: <<?a + n>>
  defp letters(n), do: letters(div(n, 26)) <> <<?a + rem(n, 26)>>

  defp random_letters do
    for <<byte <- :crypto.strong_rand_bytes(8)>>, into: "", do: <<?a + rem(byte, 26)>>
  end
end
