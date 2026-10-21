defmodule OptimalEngine.Connectors.AccessToken do
  @moduledoc """
  The bearer token an OAuth connector calls its API with, and the one helper
  every such adapter makes its calls through, so a token issued by the
  credential broker is handled the same way in every adapter.

  ## Where the token comes from

  `session/4` opens the token for one sync from the adapter state's
  `access_token` credential and the adapter's own grant. In order:

    1. a token issued by the credential broker (`%AccessToken{source: :broker}`,
       which `CredentialSource` puts in the state): the broker's short-lived
       token, its `expires_at`, and the means to ask the broker again
    2. the adapter's own grant (a refresh token, client credentials, a bot
       token), when the state carries every one of its keys (`:grant_keys`):
       run once per sync, exactly as before
    3. a token given directly, kept as an opaque token of source `:direct`:
       used as it is, never renewed
    4. nothing: the grant is run, and fails with what it is missing

  So a stored connector that carries a complete grant uses it, and an
  `access_token` left in its credentials is only a fallback: a stale one
  cannot override a grant that works.

  ## Calls

  `get_json/3`, `post_json/4` and `request/3` send `authorization: Bearer
  <token>` over https only, verify TLS, and never follow a redirect by
  themselves: the token goes to the URL the adapter named and nowhere else. A
  call may ask `follow_same_origin: n` to follow up to `n` redirects of a GET
  that stay on the same scheme, host and port (Drive media), with the token;
  any other redirect is handed back as the response it was.

  For an issued token they also:

    * ask the broker for a new token before a call when the current one
      expires within 60 seconds
    * when the API rejects the token (a `401`, or the adapter's own
      `:rejected?` test), ask the broker for a new token once and retry that
      call. A second rejection fails the sync with `:broker_token_rejected`; a
      broker that cannot answer fails it with its own reason
      (`:broker_unreachable`, `:broker_unauthorized`, `:broker_refused`)

  One re-fetch is the whole budget, so a broker that keeps issuing tokens the
  API refuses can never make a sync loop. Once a session has failed, every
  later call answers the same error without touching the network, and
  `session/4` returns that error whatever the adapter made of it: a failure an
  adapter would skip past still fails the run, and the cursor stays where it
  was.

  The budget belongs to the run, not to one attempt at the sync: `run/1` wraps
  the attempts the Runner makes, and the renewed token and the spent re-fetch
  carry over from one attempt to the next. Outside a `run/1` each session has
  its own.

  A token given directly or obtained by the adapter's own grant is never
  replaced: a rejection comes back as the response it was, and the adapter
  maps it as it always has (usually `:auth_expired`).

  ## Secrecy

  Every secret a connector holds in its adapter state that the broker issued,
  and a token given directly, is held as an `AccessToken` (`secret/1`,
  `conceal/1`): the value sits in a closure, so `inspect/1` of a token, a
  session, an adapter state or an error shows the source and the expiry and
  never the value, and a crash that prints the state prints no secret. The
  value comes out only by `reveal/1`, which is called by name where a header is
  built (a held secret does not convert to text by itself). A token lives in
  memory for one run. It is never written to the
  store, a log, an error, a connector run record or evidence.

  A session belongs to the process that opened it: every call of one sync is
  made from that process.
  """

  alias OptimalEngine.Connectors.HTTP

  @enforce_keys [:source, :value]
  defstruct [:source, :value, :expires_at, :renew, :id]

  @type source :: :broker | :direct | :grant | :secret
  @type t :: %__MODULE__{
          source: source(),
          value: (-> String.t()),
          expires_at: DateTime.t() | nil,
          renew: (-> {:ok, t()} | {:error, atom()}) | nil,
          id: reference() | nil
        }

  @type grant :: (map() -> {:ok, String.t() | t()} | {:error, term()})

  @early_refresh_seconds 60
  @redirect_statuses [301, 302, 303, 307, 308]
  @run_key {__MODULE__, :run}

  defmodule Session do
    @moduledoc "The handle of one sync's token, bound to the process that opened it."
    @enforce_keys [:ref, :owner]
    defstruct [:ref, :owner]

    @type t :: %__MODULE__{ref: reference(), owner: pid()}
  end

  # ─── tokens ──────────────────────────────────────────────────────────────

  @doc """
  A token issued by the broker. `renew` asks the broker again and answers
  `{:ok, token}` or `{:error, reason}`.
  """
  @spec issued(String.t(), DateTime.t() | nil, (-> {:ok, t()} | {:error, atom()})) :: t()
  def issued(value, expires_at, renew)
      when is_binary(value) and value != "" and is_function(renew, 0) do
    %__MODULE__{
      source: :broker,
      value: fn -> value end,
      expires_at: expires_at,
      renew: renew,
      id: make_ref()
    }
  end

  @doc "A secret the broker issued that is never renewed (an API key), held opaque."
  @spec secret(String.t()) :: t()
  def secret(value) when is_binary(value) and value != "", do: held(:secret, value)

  @doc """
  The value of a token (or of a plain string, which is its own value, and of
  nothing, which is the empty string). This is the one way out: a held secret
  has no `String.Chars`, so `"\#{secret}"` and `to_string/1` raise instead of
  leaking it, and the places that build a header call `reveal/1` by name.
  """
  @spec reveal(t() | String.t() | nil) :: String.t()
  def reveal(%__MODULE__{value: value}), do: value.()
  def reveal(value) when is_binary(value), do: value
  def reveal(nil), do: ""

  @doc """
  The state with a token given directly (`access_token` as a string, at the top
  or in the `credentials` it was lifted from) held opaque, so the state shows
  no secret.
  """
  @spec conceal(map()) :: map()
  def conceal(state) when is_map(state) do
    state = hold_direct(state)

    Enum.reduce(["credentials", :credentials], state, fn key, acc ->
      case Map.get(acc, key) do
        credentials when is_map(credentials) and not is_struct(credentials) ->
          Map.put(acc, key, hold_direct(credentials))

        _other ->
          acc
      end
    end)
  end

  defp hold_direct(map) do
    Enum.reduce(["access_token", :access_token], map, fn key, acc ->
      case Map.get(acc, key) do
        value when is_binary(value) and value != "" -> Map.put(acc, key, held(:direct, value))
        _other -> acc
      end
    end)
  end

  @doc "Whether the state carries an access token: an issued one, a held one or a string."
  @spec present?(map()) :: boolean()
  def present?(state) when is_map(state) do
    case credential(state) do
      %__MODULE__{} -> true
      value when is_binary(value) and value != "" -> true
      _absent -> false
    end
  end

  # ─── run and session ─────────────────────────────────────────────────────

  @doc """
  Runs `fun` (the attempts the Runner makes at one sync) so that the broker
  tokens its sessions renew, and the re-fetch they spend, carry over from one
  session to the next. Returns what `fun` returns.
  """
  @spec run((-> result)) :: result when result: term()
  def run(fun) when is_function(fun, 0) do
    previous = Process.get(@run_key)
    Process.put(@run_key, %{})

    try do
      fun.()
    after
      if previous, do: Process.put(@run_key, previous), else: Process.delete(@run_key)
    end
  end

  @doc """
  Opens the token for one sync, runs `fun` with the session, and closes it.

  `grant` is the adapter's own way to a token, called with the state when the
  token does not come from the broker: `{:ok, token}` or `{:error, reason}`.
  Its error is returned before `fun` runs, as an adapter's sync always did.
  Options: `:grant_keys`, the keys whose presence makes the grant complete.
  """
  @spec session(map(), grant(), (Session.t() -> result), keyword()) :: result | {:error, term()}
        when result: term()
  def session(state, grant, fun, opts \\ [])
      when is_map(state) and is_function(grant, 1) and is_function(fun, 1) do
    with {:ok, token} <- initial(state, grant, Keyword.get(opts, :grant_keys, [])) do
      ref = make_ref()
      key = {__MODULE__, ref}
      Process.put(key, resume(token, credential(state)))

      try do
        result = fun.(%Session{ref: ref, owner: self()})

        case Process.get(key) do
          %{failure: nil} -> result
          %{failure: reason} -> {:error, reason}
        end
      after
        remember(Process.get(key))
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
  token (default: a `401`), for an API that refuses it another way, and
  `:follow_same_origin`, the number of same-origin redirects of a GET to follow
  (default `0`).
  """
  @spec request(Session.t(), String.t(), keyword()) :: {:ok, HTTP.response()} | {:error, term()}
  def request(%Session{} = session, url, opts \\ []) when is_binary(url) do
    {rejected?, opts} = Keyword.pop(opts, :rejected?, &unauthorized?/1)
    {hops, opts} = Keyword.pop(opts, :follow_same_origin, 0)

    opts =
      opts |> Keyword.put(:follow_redirects, false) |> Keyword.put(:verify_tls, true)

    with :ok <- https(url),
         {:ok, token} <- current(session) do
      attempt = fn token -> send_with(url, opts, token, hops) end
      response = attempt.(token)

      if rejected?.(response),
        do: recover(session, attempt, rejected?, response),
        else: response
    end
  end

  # ─── sending ─────────────────────────────────────────────────────────────

  defp https("https://" <> _rest), do: :ok
  defp https(_url), do: {:error, :insecure_url}

  # A redirect is followed only for a GET, only to the same origin, and only as
  # many times as the caller allowed. Anything else comes back as it was.
  defp send_with(url, opts, token, hops) do
    response = HTTP.request(url, authorize(opts, token))

    with true <- hops > 0 and Keyword.get(opts, :method, :get) == :get,
         {:ok, %{status: status, headers: headers}} when status in @redirect_statuses <-
           response,
         {:ok, next} <- same_origin(url, headers) do
      send_with(next, opts, token, hops - 1)
    else
      _no_redirect -> response
    end
  end

  defp same_origin(url, headers) do
    with {_name, location} <- Enum.find(headers, fn {k, _} -> String.downcase(k) == "location" end),
         %URI{scheme: "https", host: host, port: port} = next when is_binary(host) <-
           URI.merge(URI.parse(url), location),
         %URI{scheme: "https", host: current_host, port: current_port} = URI.parse(url),
         true <- String.downcase(host, :ascii) == String.downcase(current_host, :ascii),
         true <- port == current_port do
      {:ok, URI.to_string(next)}
    else
      _other -> :error
    end
  end

  defp authorize(opts, token) do
    bearer = {"authorization", "Bearer " <> reveal(token)}
    Keyword.update(opts, :headers, [bearer], &[bearer | &1])
  end

  # ─── token choice ────────────────────────────────────────────────────────

  defp initial(state, grant, grant_keys) do
    case credential(state) do
      %__MODULE__{source: :broker} = issued ->
        {:ok, issued}

      held ->
        if complete?(state, grant_keys) or not present?(state),
          do: grant_token(state, grant),
          else: {:ok, direct(held)}
    end
  end

  defp grant_token(state, grant) do
    case grant.(state) do
      {:ok, %__MODULE__{} = token} -> {:ok, token}
      {:ok, value} when is_binary(value) and value != "" -> {:ok, held(:grant, value)}
      {:ok, _blank} -> {:error, {:missing_credentials, [:access_token]}}
      {:error, _reason} = error -> error
    end
  end

  defp direct(%__MODULE__{} = token), do: token
  defp direct(value) when is_binary(value), do: held(:direct, value)

  defp complete?(_state, []), do: false

  defp complete?(state, keys) do
    Enum.all?(keys, fn key ->
      case Map.get(state, key) || Map.get(state, to_string(key)) do
        %__MODULE__{} -> true
        value -> is_binary(value) and value != ""
      end
    end)
  end

  defp held(source, value),
    do: %__MODULE__{source: source, value: fn -> value end, id: make_ref()}

  defp credential(state), do: Map.get(state, "access_token") || Map.get(state, :access_token)

  # ─── session state ───────────────────────────────────────────────────────

  # The state of a session. A broker token that an earlier session of the same
  # run renewed, or spent the re-fetch on, is taken up where that left it; the
  # ledger is keyed by the token the state started with, not by its renewals.
  defp resume(token, state_token) do
    base = %{
      token: token,
      early: true,
      recovered: false,
      failure: nil,
      root: root(state_token)
    }

    case ledger_entry(base.root) do
      nil -> base
      entry -> Map.merge(base, entry)
    end
  end

  defp root(%__MODULE__{source: :broker, id: id}), do: id
  defp root(_token), do: nil

  defp ledger_entry(nil), do: nil

  defp ledger_entry(root) do
    case Process.get(@run_key) do
      %{^root => entry} -> entry
      _none -> nil
    end
  end

  defp remember(%{root: nil}), do: :ok

  defp remember(%{root: root} = state) do
    case Process.get(@run_key) do
      nil ->
        :ok

      ledger ->
        entry = Map.take(state, [:token, :early, :recovered])
        Process.put(@run_key, Map.put(ledger, root, entry))
        :ok
    end
  end

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
  defp recover(session, attempt, rejected?, response) do
    state = fetch!(session)

    cond do
      not renewable?(state.token) ->
        response

      state.recovered ->
        fail(session, :broker_token_rejected)

      true ->
        state = %{state | recovered: true}

        with {:ok, fresh} <- renew(session, state, &%{state | token: &1}) do
          retried = attempt.(fresh)
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
