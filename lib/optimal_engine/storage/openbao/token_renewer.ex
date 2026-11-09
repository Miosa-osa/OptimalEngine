defmodule OptimalEngine.Storage.OpenBao.TokenRenewer do
  @moduledoc """
  Keeps `OPTIMAL_OPENBAO_TOKEN` alive.

  At start, and again after each renewal, the token is looked up
  (`auth/token/lookup-self`):

    * no expiry (`ttl` 0, as a root token has): nothing to do; it is looked
      up again hourly;
    * renewable: it is renewed (`auth/token/renew-self`) when half its
      remaining time has passed, and again after each renewal;
    * expiring and not renewable: a warning is logged once, saying when it
      runs out, so the operator replaces it before secrets stop resolving.

  OpenBao sealed or unreachable is tried again in 30 seconds, without a log
  line each time. The token is never logged. Not started without OpenBao
  configured (`:ignore`).
  """

  use GenServer

  require Logger

  alias OptimalEngine.Secrets
  alias OptimalEngine.Storage.OpenBao

  @idle_ms :timer.hours(1)
  @retry_ms :timer.seconds(30)
  @min_ms 500

  def start_link(opts \\ []) do
    if OpenBao.configured?() do
      case Keyword.get(opts, :name, __MODULE__) do
        nil -> GenServer.start_link(__MODULE__, opts)
        name -> GenServer.start_link(__MODULE__, opts, name: name)
      end
    else
      :ignore
    end
  end

  def child_spec(opts),
    do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, restart: :permanent}

  @doc "Looks the token up now (and renews it if it is due). Returns once done."
  @spec check(GenServer.server()) :: :ok
  def check(server \\ __MODULE__), do: GenServer.call(server, :check)

  @doc "What was last learned about the token: `ttl`, `renewable`, and the last problem."
  @spec status(GenServer.server()) :: map()
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @impl true
  def init(_opts) do
    {:ok, %{timer: nil, ttl: nil, renewable: nil, warned: false, problem: nil}, {:continue, :check}}
  end

  @impl true
  def handle_continue(:check, state), do: {:noreply, run(state)}

  @impl true
  def handle_info(:check, state), do: {:noreply, run(%{state | timer: nil})}
  def handle_info(:renew, state), do: {:noreply, renew(%{state | timer: nil})}

  @impl true
  def handle_call(:check, _from, state), do: {:reply, :ok, run(state)}

  def handle_call(:status, _from, state),
    do: {:reply, Map.take(state, [:ttl, :renewable, :problem]), state}

  defp run(state) do
    case OpenBao.token_lookup() do
      {:ok, %{ttl: 0} = token} ->
        schedule(%{state | ttl: 0, renewable: token.renewable, problem: nil}, @idle_ms)

      {:ok, %{renewable: true, ttl: ttl}} ->
        schedule(%{state | ttl: ttl, renewable: true, problem: nil}, half(ttl), :renew)

      {:ok, %{renewable: false, ttl: ttl}} ->
        state
        |> Map.merge(%{ttl: ttl, renewable: false, problem: nil})
        |> warn_once(ttl)
        |> schedule(half(ttl))

      {:error, reason} ->
        schedule(%{state | problem: reason}, @retry_ms)
    end
  end

  defp renew(state) do
    case OpenBao.token_renew() do
      {:ok, ttl} ->
        Logger.debug("OpenBao: OPTIMAL_OPENBAO_TOKEN renewed for #{ttl}s.")
        schedule(%{state | ttl: ttl, problem: nil}, half(ttl), :renew)

      {:error, :openbao_token_not_renewable} ->
        state |> Map.merge(%{renewable: false}) |> warn_once(state.ttl) |> schedule(@retry_ms)

      {:error, reason} ->
        Logger.warning(
          "OpenBao: OPTIMAL_OPENBAO_TOKEN could not be renewed: #{Secrets.describe(reason)}; trying again in 30s."
        )

        schedule(%{state | problem: reason}, @retry_ms)
    end
  end

  defp warn_once(%{warned: true} = state, _ttl), do: state

  defp warn_once(state, ttl) do
    Logger.warning(
      "OpenBao: OPTIMAL_OPENBAO_TOKEN is not renewable and expires in #{ttl}s. Replace it with a renewable or periodic token before then, or secrets stop resolving."
    )

    %{state | warned: true}
  end

  defp half(ttl), do: max(div(ttl * 1000, 2), @min_ms)

  defp schedule(%{timer: timer} = state, ms, message \\ :check) do
    if timer, do: Process.cancel_timer(timer)
    %{state | timer: Process.send_after(self(), message, ms)}
  end
end
