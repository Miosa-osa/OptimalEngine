defmodule OptimalEngine.Store.TransactionControl do
  @moduledoc """
  Refuses transaction control sent as a statement, the same way on both stores.

  Every raw statement is a store call of its own. On SQLite one connection
  serves every caller, so a transaction opened by one raw statement would stay
  open across every other caller's statements; on PostgreSQL the next
  statement may run on another pooled connection, and the transaction would be
  left open on this one. So BEGIN, COMMIT, END, ROLLBACK, SAVEPOINT and RELEASE
  sent as a raw statement raise `ArgumentError`, and so do START and ABORT,
  PostgreSQL's own spellings of BEGIN and ROLLBACK (SQLite has neither
  statement). Inside a transaction, `SAVEPOINT`, `RELEASE` and `ROLLBACK TO`
  stay available, and the rest is refused. Transactions go through
  `OptimalEngine.Store.transaction/2`.

  The keyword is read as SQLite's tokenizer reads it: after any leading
  whitespace, comments and empty statements, the letters up to the first
  character that is not one, so `COMMIT--x` and `BEGIN/**/IMMEDIATE` are
  COMMIT and BEGIN.
  """

  @outside ~w(BEGIN COMMIT END ROLLBACK SAVEPOINT RELEASE START ABORT)
  @inside ~w(BEGIN COMMIT END START ABORT)

  @doc """
  Raises `ArgumentError` when `sql` is transaction control that may not run
  `where`: `:outside` a transaction, as a raw statement, or `:inside` one.
  """
  @spec refuse!(term(), :outside | :inside) :: :ok
  def refuse!(sql, where) when is_binary(sql) and where in [:outside, :inside] do
    text = statement(sql)

    keyword =
      case Regex.run(~r/\A[A-Za-z]+/, text) do
        [word] -> String.upcase(word)
        nil -> ""
      end

    if refused?(where, keyword, text) do
      raise ArgumentError,
            "#{keyword} is transaction control; run the statements in " <>
              "OptimalEngine.Store.transaction/2 instead of sending #{keyword} as a raw statement"
    end

    :ok
  end

  def refuse!(_sql, where) when where in [:outside, :inside], do: :ok

  @doc """
  The statement after its leading whitespace, comments and empty statements.
  A block comment ends at the first `*/` after its opening `/*`, so `/*/`
  does not close it.
  """
  @spec statement(String.t()) :: String.t()
  def statement(sql) when is_binary(sql) do
    case String.trim_leading(sql) do
      "--" <> rest ->
        rest |> String.split("\n", parts: 2) |> Enum.at(1, "") |> statement()

      "/*" <> rest ->
        rest |> String.split("*/", parts: 2) |> Enum.at(1, "") |> statement()

      ";" <> rest ->
        statement(rest)

      trimmed ->
        trimmed
    end
  end

  defp refused?(:outside, keyword, _text), do: keyword in @outside

  # ROLLBACK TO <savepoint> (or ROLLBACK TRANSACTION TO) stays in the transaction.
  defp refused?(:inside, "ROLLBACK", text),
    do: not Regex.match?(~r/\AROLLBACK(\s+TRANSACTION)?\s+TO\b/i, text)

  defp refused?(:inside, keyword, _text), do: keyword in @inside
end
