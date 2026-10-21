defmodule OptimalEngine.Connectors.AccessToken do
  @moduledoc """
  The bearer token an OAuth connector calls its API with, and the one helper
  every such adapter makes its calls through, so a token issued by the
  credential broker is handled the same way in every adapter.

  ## Where the token comes from

  `session/3` opens the token for one sync from the adapter state's
  `access_token` credential:

    * an issued token (`%AccessToken{}`), which `CredentialSource` puts there
      for a connector on the broker: the broker's short-lived token, its
      `expires_at`, and the means to ask the broker again
    * a string: a token given directly (tests, simple setups), used as it is
    * neither: the adapter's own grant, run once per sync exactly as before
      (a refresh token, client credentials, or an app token)

  ## Calls

  `get_json/3`, `post_json/4` and `request/3` send `authorization: Bearer
  <token>` and otherwise behave as `OptimalEngine.Connectors.HTTP`. For an
  issued token they also:

    * ask the broker for a new token before a call when the current one
      expires within 60 seconds
    * when the API rejects the token (a `401`, or the adapter's own
      `:rejected?` test), ask the broker for a new token once and retry that
      call. A second rejection anywhere in the same sync fails the sync with
      `:broker_token_rejected`; a broker that cannot answer fails it with its
      own reason (`:broker_unreachable`, `:broker_unauthorized`,
      `:broker_refused`)

  One re-fetch per sync is the whole budget, so a broker that keeps issuing
  tokens the API refuses can never make a sync loop. Once a session has
  failed, every later call answers the same error without touching the
  network, and `session/3` returns that error whatever the adapter made of
  it: a failure an adapter would skip past still fails the run, and the
  cursor stays where it was.

  A token given directly or obtained by the adapter's own grant is never
  replaced: a rejection comes back as the response it was, and the adapter
  maps it as it always has (usually `:auth_expired`).

  ## Secrecy

  The token value is held in a closure, so `inspect/1` of a token, a session,
  an adapter state or an error shows the source and the expiry and never the
  value. A token lives in memory for one sync. It is never written to the
  store, a log, an error, a connector run record or evidence.

  A session belongs to the process that opened it: every call of one sync is
  made from that process.
  """

  alias OptimalEngine.Connectors.HTTP

  @enforce_keys [:source, :value]
  defstruct [:source, :value, :expires_at, :renew]

  @type source :: :broker | :direct | :grant
  @type t :: %__MODULE__{
          source: source(),
          value: (-> String.t()),
          expires_at: DateTime.t() | nil,
          renew: (-> {:ok, t()} | {:error, atom()}) | nil
        }

  @type grant :: (map() -> {:ok, String.t()} | {:error, term()})

  @early_refresh_seconds 60

  defmodule Session do
    @moduledoc "The handle of one sync's token, bound to the process that opened it."
    @enforce_keys [:ref, :owner]
    defstruct [:ref, :owner]

    @type t :: %__MODULE__{ref: reference(), owner: pid()}
  end

  @doc """
  A token issued by the broker. `renew` asks the broker again and answers
  `{:ok, token}` or `{:error, reason}`.
  """
  @spec issued(String.t(), DateTime.t() | nil, (-> {:ok, t()} | {:error, atom()})) :: t()
  def issued(value, expires_at, renew)
      when is_binary(value) and value != "" and is_function(renew, 0) do
    %__MODULE__{source: :broker, value: fn -> value end, expires_at: expires_at, renew: renew}
  end

  @doc "Whether the state carries an access token: an issued one or a string."
  @spec present?(map()) :: boolean()
  def present?(state) when is_map(state) do
    case credential(state) do
      %__MODULE__{} -> true
      value when is_binary(value) and value != "" -> true
      _absent -> false
    end
  end

  @doc """
  Opens the token for one sync, runs `fun` with the session, and closes it.

  `grant` is the adapter's own way to a token, called with the state when the
  state carries none: `{:ok, token}` or `{:error, reason}`. Its error is
  returned before `fun` runs, as an adapter's sync always did.
  """
  @spec session(map(), grant(), (Session.t() -> result)) :: result | {:error, term()}
        when result: term()
  def session(state, grant, fun)
      when is_map(state) and is_function(grant, 1) and is_function(fun, 1) do
    with {:ok, token} <- initial(state, grant) do
      ref = make_ref()
      key = {__MODULE__, ref}
      Process.put(key, %{token: token, early: true, recovered: false, failure: nil})

      try do
        result = fun.(%Session{ref: ref, owner: self()})

        case Process.get(key) do
          %{failure: nil} -> result
          %{failure: reason} -> {:error, reason}
        end
      after
        Process.delete(key)
      end
    end
  end

  @doc "`HTTP.get_json/2` with the session's bearer token."
  @spec get_json(Session.t(), String.t(), keyword()) :: {:ok, HTTP.response()} | {:error, term()}
  def get_json(session, url, opts \\ []),
    do: request(session, url, Keyword.put(opts, :method, :get))

  @doc "`HTTP.post_json/3` with the session's bearer token."
  @spec post_json(Session.t(), String.t(), map(), keyword()) ::
          {:ok, HTTP.response()} | {:error, term()}
  def post_json(session, url, body, opts \\ []) when is_map(body) do
    request(session, url, opts |> Keyword.put(:method, :post) |> Keyword.put(:body, body))
  end

  @doc """
  `HTTP.request/2` with the session's bearer token. Takes the `HTTP` options
  plus `:rejected?`, a function of the response that says the API refused the
  token (default: a `401`), for an API that refuses it another way.
  """
  @spec request(Session.t(), String.t(), keyword()) :: {:ok, HTTP.response()} | {:error, term()}
  def request(%Session{} = session, url, opts \\ []) when is_binary(url) do
    {rejected?, opts} = Keyword.pop(opts, :rejected?, &unauthorized?/1)

    with {:ok, token} <- current(session) do
      response = HTTP.request(url, authorize(opts, token))

      if rejected?.(response),
        do: recover(session, url, opts, rejected?, response),
        else: response
    end
  end

  # ─── session state ───────────────────────────────────────────────────────

  defp initial(state, grant) do
    case credential(state) do
      %__MODULE__{} = issued ->
        {:ok, issued}

      value when is_binary(value) and value != "" ->
        {:ok, held(:direct, value)}

      _absent ->
        case grant.(state) do
          {:ok, value} when is_binary(value) and value != "" -> {:ok, held(:grant, value)}
          {:ok, _blank} -> {:error, {:missing_credentials, [:access_token]}}
          {:error, _reason} = error -> error
        end
    end
  end

  defp held(source, value), do: %__MODULE__{source: source, value: fn -> value end}

  defp credential(state), do: Map.get(state, "access_token") || Map.get(state, :access_token)

  # A token about to expire is replaced before it is used. A replacement that
  # is itself about to expire turns early replacement off for the rest of the
  # sync, so a broker answering with short expiries cannot cost a fetch a call.
  defp current(session) do
    state = fetch!(session)

    cond do
      state.failure != nil ->
        {:error, state.failure}

      state.early and renewable?(state.token) and expiring?(state.token) ->
        renew(session, state, &%{state | token: &1, early: not expiring?(&1)})

      true ->
        {:ok, state.token}
    end
  end

  # One rejection is answered with one new token; the next one fails the sync.
  defp recover(session, url, opts, rejected?, response) do
    state = fetch!(session)

    cond do
      not renewable?(state.token) ->
        response

      state.recovered ->
        fail(session, :broker_token_rejected)

      true ->
        state = %{state | recovered: true}

        with {:ok, fresh} <- renew(session, state, &%{state | token: &1}) do
          retried = HTTP.request(url, authorize(opts, fresh))
          if rejected?.(retried), do: fail(session, :broker_token_rejected), else: retried
        end
    end
  end

  defp renew(session, state, update) do
    case state.token.renew.() do
      {:ok, %__MODULE__{} = fresh} ->
        put(session, update.(fresh))
        {:ok, fresh}

      {:error, reason} when is_atom(reason) ->
        put(session, state)
        fail(session, reason)

      _other ->
        put(session, state)
        fail(session, :broker_refused)
    end
  end

  defp fail(session, reason) do
    put(session, %{fetch!(session) | failure: reason})
    {:error, reason}
  end

  defp fetch!(%Session{ref: ref, owner: owner}) do
    unless owner == self() do
      raise ArgumentError, "an access token session is used from the process that opened it"
    end

    Process.get({__MODULE__, ref}) ||
      raise ArgumentError, "the access token session has already closed"
  end

  defp put(%Session{ref: ref}, state), do: Process.put({__MODULE__, ref}, state)

  defp renewable?(%__MODULE__{source: :broker, renew: renew}), do: is_function(renew, 0)
  defp renewable?(_token), do: false

  defp expiring?(%__MODULE__{expires_at: %DateTime{} = expires_at}),
    do: DateTime.diff(expires_at, DateTime.utc_now()) <= @early_refresh_seconds

  defp expiring?(_token), do: false

  defp authorize(opts, %__MODULE__{value: value}) do
    bearer = {"authorization", "Bearer " <> value.()}
    Keyword.update(opts, :headers, [bearer], &[bearer | &1])
  end

  defp unauthorized?({:ok, %{status: 401}}), do: true
  defp unauthorized?(_response), do: false
end

defimpl Inspect, for: OptimalEngine.Connectors.AccessToken do
  def inspect(%{source: source, expires_at: expires_at}, _opts) do
    expiry =
      case expires_at do
        %DateTime{} -> " expires_at: " <> DateTime.to_iso8601(expires_at)
        _none -> ""
      end

    "#OptimalEngine.Connectors.AccessToken<#{source}#{expiry}>"
  end
end
