defmodule OptimalEngine.Storage.Valkey.Connection do
  @moduledoc """
  One supervised connection of `OptimalEngine.Storage.Valkey.Pool`.

  The process owns a socket opened by `OptimalEngine.Storage.Valkey.open/2`
  and answered by a `PING`, and reports itself `:up` or `:down` in the pool's table, so callers only
  ever pick a connection that has one. A connection that fails to open, or
  whose socket fails mid-command, is closed and opened again with an
  exponential backoff (100 ms doubling to 5 seconds, with jitter). A
  command never waits for a reconnect: on a closed connection it is answered
  `{:error, :unavailable}` at once, and the caller falls back.

  A socket the server closed while idle is noticed on the next command; that
  command is tried once more on a fresh connection before it is reported
  unavailable. Nothing here logs the URL or the credential.
  """

  use GenServer

  require Logger

  alias OptimalEngine.Storage.Valkey
  alias OptimalEngine.Storage.Valkey.Pool

  @min_backoff 100
  @max_backoff 5_000

  @doc false
  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :index)},
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent
    }
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc """
  Runs `commands` as one pipeline. `{:ok, replies}` or `{:error, :unavailable}`.
  """
  @spec run(pid(), [[String.t()]], timeout()) :: {:ok, [term()]} | {:error, :unavailable}
  def run(pid, commands, timeout) do
    GenServer.call(pid, {:run, commands}, timeout + 100)
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  @impl true
  def init(opts) do
    state = %{
      index: Keyword.fetch!(opts, :index),
      config: Keyword.fetch!(opts, :config),
      timeout: Keyword.fetch!(opts, :timeout),
      socket: nil,
      backoff: @min_backoff,
      logged_down: false
    }

    Pool.mark(state.index, self(), :down)
    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state), do: {:noreply, connect(state)}

  @impl true
  def handle_info(:connect, %{socket: nil} = state), do: {:noreply, connect(state)}
  def handle_info(:connect, state), do: {:noreply, state}
  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def handle_call({:run, _commands}, _from, %{socket: nil} = state),
    do: {:reply, {:error, :unavailable}, state}

  def handle_call({:run, commands}, _from, state) do
    case Valkey.pipeline(state.socket, commands, state.timeout) do
      {:ok, replies} ->
        {:reply, {:ok, replies}, state}

      {:error, reason} ->
        state = drop(state)

        # The server may have closed an idle connection; one fresh attempt.
        if stale?(reason) do
          state = connect(state)

          if is_nil(state.socket) do
            # The reconnect failed and scheduled the next attempt itself.
            {:reply, {:error, :unavailable}, state}
          else
            case Valkey.pipeline(state.socket, commands, state.timeout) do
              {:ok, replies} -> {:reply, {:ok, replies}, state}
              {:error, _} -> {:reply, {:error, :unavailable}, retry_soon(drop(state))}
            end
          end
        else
          {:reply, {:error, :unavailable}, retry_soon(state)}
        end
    end
  end

  @impl true
  def terminate(_reason, %{socket: socket}) when not is_nil(socket), do: Valkey.close(socket)
  def terminate(_reason, _state), do: :ok

  defp connect(state) do
    case open(state) do
      {:ok, socket} ->
        Pool.mark(state.index, self(), :up)

        if state.logged_down,
          do: Logger.info("[Valkey] connection #{state.index} restored")

        %{state | socket: socket, backoff: @min_backoff, logged_down: false}

      {:error, reason} ->
        Pool.mark(state.index, self(), :down)

        unless state.logged_down do
          Logger.warning(
            "[Valkey] connection #{state.index} unavailable (#{describe(reason)}); " <>
              "serving from local ETS until it reconnects"
          )
        end

        Process.send_after(self(), :connect, jitter(state.backoff))
        %{state | backoff: min(state.backoff * 2, @max_backoff), logged_down: true}
    end
  end

  # A connection is up only once the server has answered on it: one that
  # accepts and never replies must not be handed to callers.
  defp open(state) do
    with {:ok, socket} <- Valkey.open(state.config, state.timeout) do
      case Valkey.command(socket, ["PING"], state.timeout) do
        {:ok, "PONG"} ->
          {:ok, socket}

        other ->
          Valkey.close(socket)
          {:error, ping_failure(other)}
      end
    end
  end

  defp ping_failure({:error, {:recv, reason}}), do: {:recv, reason}
  defp ping_failure(_other), do: :no_pong

  defp drop(%{socket: nil} = state), do: state

  defp drop(state) do
    Valkey.close(state.socket)
    Pool.mark(state.index, self(), :down)
    %{state | socket: nil}
  end

  defp retry_soon(state) do
    Process.send_after(self(), :connect, jitter(state.backoff))
    %{state | backoff: min(state.backoff * 2, @max_backoff)}
  end

  defp stale?({:recv, reason}), do: reason in [:closed, :enotconn, :econnreset]
  defp stale?(reason), do: reason in [:closed, :enotconn, :econnreset, :epipe]

  defp jitter(ms), do: ms + :rand.uniform(max(div(ms, 4), 1))

  # The class of the failure only: never the URL or the credential.
  defp describe({:auth_failed, class}) when is_binary(class), do: "auth failed: #{class}"
  defp describe({:auth_failed, _}), do: "auth failed"
  defp describe({:select_failed, _}), do: "select failed"
  defp describe({:recv, reason}) when is_atom(reason), do: Atom.to_string(reason)
  defp describe(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp describe(_reason), do: "error"
end
