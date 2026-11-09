defmodule Mix.Tasks.Optimal.Nats do
  use Mix.Task

  @shortdoc "List and requeue the NATS dead letters"

  @moduledoc """
  The NATS dead letters (`OptimalEngine.Storage.NATS.DeadLetters`): queued
  items whose handling kept failing past their delivery cap.

      mix optimal.nats dead-letters [--flow intake] [--limit 50] [--after SEQ]
      mix optimal.nats requeue SEQ

  `dead-letters` prints them without their payload; `requeue` puts one back on
  the work queue it came from and removes it from the dead letters. Both use
  `OPTIMAL_NATS_URL` and `OPTIMAL_NATS_NAMESPACE`, as the Engine does.
  """

  alias OptimalEngine.Storage.NATS
  alias OptimalEngine.Storage.NATS.{Connection, DeadLetters}

  @impl true
  def run(args) do
    {opts, positional, _invalid} =
      OptionParser.parse(args, strict: [flow: :string, limit: :integer, after: :integer])

    Mix.Task.run("app.start")
    wait_connected()

    case positional do
      ["dead-letters"] ->
        case DeadLetters.list(Connection, namespace(), Keyword.take(opts, [:flow, :limit, :after])) do
          {:ok, letters} -> print(%{dead_letters: letters, count: length(letters)})
          {:error, reason} -> Mix.raise("dead letters not read: #{inspect(reason)}")
        end

      ["requeue", seq] ->
        with {n, ""} when n > 0 <- Integer.parse(seq),
             {:ok, result} <- DeadLetters.requeue(Connection, namespace(), n) do
          print(result)
        else
          {:error, :not_found} -> Mix.raise("no dead letter #{seq}")
          {:error, reason} -> Mix.raise("not requeued: #{inspect(reason)}")
          _ -> Mix.raise("SEQ must be a positive integer")
        end

      _ ->
        Mix.raise(
          "usage: mix optimal.nats dead-letters [--flow F] [--limit N] [--after SEQ] | requeue SEQ"
        )
    end
  end

  defp wait_connected(tries \\ 50) do
    cond do
      not NATS.configured?() -> Mix.raise("OPTIMAL_NATS_URL is not set")
      Connection.connected?() -> :ok
      tries == 0 -> Mix.raise("NATS is not reachable: #{inspect(Connection.status().last_error)}")
      true -> Process.sleep(100) && wait_connected(tries - 1)
    end
  end

  defp namespace do
    case NATS.namespace() do
      {:ok, namespace} -> namespace
      {:error, _} -> Mix.raise("OPTIMAL_NATS_NAMESPACE is not a valid namespace")
    end
  end

  defp print(value), do: IO.puts(Jason.encode!(value, pretty: true))
end
