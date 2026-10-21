defmodule OptimalEngine.SafeAtom do
  @moduledoc """
  Turns text into one of a known set of atoms without ever creating an atom.

  The BEAM atom table is finite (about a million entries by default) and is
  never garbage collected, so an atom created from data a caller, a peer or a
  file supplies is a denial of service that survives restarts when the data
  persists. Code that reads such text and needs an atom looks the text up in
  an explicit list of allowed atoms instead of calling `String.to_atom/1`.

      iex> OptimalEngine.SafeAtom.fetch("user", [:system, :user])
      {:ok, :user}

      iex> OptimalEngine.SafeAtom.cast("nonsense", [:system, :user], :user)
      :user

      iex> OptimalEngine.SafeAtom.cast_or_string("nonsense", [:system, :user])
      "nonsense"

  The allowed list is always code, never data. A value that is not in it is
  not an error here: the caller picks a documented default, keeps the text, or
  rejects the input.
  """

  @doc """
  Looks `value` up in `allowed`.

  `value` is text or an atom. Returns `{:ok, atom}` when it names an allowed
  atom, `:error` otherwise.
  """
  @spec fetch(term(), [atom()]) :: {:ok, atom()} | :error
  def fetch(value, allowed) when is_atom(value) and not is_nil(value) and is_list(allowed) do
    if value in allowed, do: {:ok, value}, else: :error
  end

  def fetch(value, allowed) when is_binary(value) and is_list(allowed) do
    case Enum.find(allowed, &(Atom.to_string(&1) == value)) do
      nil -> :error
      atom -> {:ok, atom}
    end
  end

  def fetch(_value, _allowed), do: :error

  @doc "Like `fetch/2`, with `default` when `value` is not allowed."
  @spec cast(term(), [atom()], default) :: atom() | default when default: term()
  def cast(value, allowed, default) do
    case fetch(value, allowed) do
      {:ok, atom} -> atom
      :error -> default
    end
  end

  @doc """
  Like `fetch/2`, but text that names no allowed atom is returned unchanged.

  For stored text where dropping or defaulting the value would misstate the
  data: the caller keeps what was stored and compares it as text.
  """
  @spec cast_or_string(term(), [atom()]) :: atom() | term()
  def cast_or_string(value, allowed) do
    case fetch(value, allowed) do
      {:ok, atom} -> atom
      :error -> value
    end
  end

  @doc """
  Returns the atom for `value` only when it already exists in the atom table.

  Use this when the set of valid values is open (an option key, an adapter
  that may not be loaded yet) and a value that names no existing atom cannot
  be read by any code, so ignoring it changes nothing. Prefer `fetch/2` when
  the valid values are known.
  """
  @spec existing(term()) :: {:ok, atom()} | :error
  def existing(value) when is_atom(value) and not is_nil(value), do: {:ok, value}

  def existing(value) when is_binary(value) do
    {:ok, String.to_existing_atom(value)}
  rescue
    ArgumentError -> :error
  end

  def existing(_value), do: :error
end
