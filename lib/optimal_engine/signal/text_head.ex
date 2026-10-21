defmodule OptimalEngine.Signal.TextHead do
  @moduledoc """
  The head of a long text: at most a given number of bytes from its start.

  The mode and genre detectors and the intake classifier read a long text by
  its head, so the time they take is bounded whatever a caller sends. The
  head ends after the last line break in its window, so every line it keeps
  is whole. When that break would drop more than half the window (one very
  long line), the head is cut between two characters instead.
  """

  @doc """
  At most `bytes` bytes from the start of `text`, ending after a line break,
  or between two characters when the last line is longer than half of that.
  A text no longer than `bytes` is returned as it is.
  """
  @spec take(String.t(), pos_integer()) :: String.t()
  def take(text, bytes) when is_binary(text) and byte_size(text) <= bytes, do: text

  def take(text, bytes) when is_binary(text) and is_integer(bytes) and bytes > 0 do
    window = binary_part(text, 0, bytes)

    case last_line_break(window, bytes - 1, div(bytes, 2)) do
      nil -> whole_characters(window)
      at -> binary_part(window, 0, at + 1)
    end
  end

  # A line break is one byte that never occurs inside a UTF-8 character, so
  # cutting after it keeps every character whole.
  defp last_line_break(_window, at, floor) when at < floor, do: nil

  defp last_line_break(window, at, floor) do
    case :binary.at(window, at) do
      ?\n -> at
      _ -> last_line_break(window, at - 1, floor)
    end
  end

  # A cut inside a UTF-8 character drops the bytes it has of that character.
  defp whole_characters(window) do
    case :unicode.characters_to_binary(window) do
      {:incomplete, whole, _split_character} -> whole
      _valid_or_not -> window
    end
  end
end
