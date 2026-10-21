defmodule OptimalEngine.Connectors.Adapters.Base do
  @moduledoc """
  `use` macro that supplies the boilerplate every adapter needs:

    * declares `@behaviour OptimalEngine.Connectors.Behaviour`
    * imports `Transform` + `Signal` aliases
    * provides `require_keys/2`, `require_credentials/2`, `string_or_atom/2`

  Options: `:kind`, `:display_name`, `:auth_scheme`, `:required_keys`,
  `:credential_keys`, and `access_token: true` for an adapter that calls its
  API through `OptimalEngine.Connectors.AccessToken`: an `access_token`
  credential, given directly or issued by the credential broker, then stands
  in for its `:credential_keys`. `:token_key` names the key the adapter's
  single secret lives under (`:api_key`, `:pat`, `:integration_token`), which
  is where the credential broker puts the secret it issues for the adapter.

  An adapter then writes only the parts that distinguish it:

      defmodule ... do
        use OptimalEngine.Connectors.Adapters.Base, kind: :slack, ...

        @impl true
        def sync(state, cursor), do: ...

        @impl true
        def transform(raw), do: ...
      end
  """

  defmacro __using__(opts) do
    kind = Keyword.fetch!(opts, :kind)
    display_name = Keyword.fetch!(opts, :display_name)
    auth_scheme = Keyword.fetch!(opts, :auth_scheme)
    required_keys = Keyword.get(opts, :required_keys, [])
    credential_keys = Keyword.get(opts, :credential_keys, [])
    access_token = Keyword.get(opts, :access_token, false)
    token_key = Keyword.get(opts, :token_key)

    quote bind_quoted: [
            kind: kind,
            display_name: display_name,
            auth_scheme: auth_scheme,
            required_keys: required_keys,
            credential_keys: credential_keys,
            access_token: access_token,
            token_key: token_key
          ] do
      @behaviour OptimalEngine.Connectors.Behaviour

      alias OptimalEngine.Connectors.Transform
      alias OptimalEngine.Signal

      @impl true
      def kind, do: unquote(kind)

      @impl true
      def display_name, do: unquote(display_name)

      @impl true
      def auth_scheme, do: unquote(auth_scheme)

      @impl true
      def required_config_keys, do: unquote(required_keys)

      # What the credential broker needs to know of this adapter: the key its
      # single secret lives under (`token_key`, nil when it has none), and
      # whether it calls through `AccessToken`, which takes a brokered access
      # token under `access_token` and renews it.
      @doc false
      def broker_token_key, do: unquote(token_key)

      @doc false
      def broker_access_token?, do: unquote(access_token)

      @impl true
      def init(config) do
        flat = flatten_credentials(config)

        with :ok <- require_keys(flat, unquote(required_keys)),
             :ok <- require_credentials(flat, unquote(credential_keys)) do
          {:ok, hydrate_state(flat)}
        end
      end

      # Adapters override to shape the runtime state they want. Default is
      # to expose the full config map (with credentials lifted to top-level
      # keys).
      def hydrate_state(config) do
        flatten_credentials(config)
      end

      # Adapters with either-or credential schemes (e.g. GitHub pat vs. App,
      # HubSpot token vs. OAuth) declare `credential_keys: []` and override
      # `init/1` to enforce their own credential gate.
      defoverridable init: 1, hydrate_state: 1

      # ── shared helpers ───────────────────────────────────────────────────

      defp require_keys(config, keys) do
        missing =
          Enum.reject(keys, fn k ->
            Map.has_key?(config, k) or Map.has_key?(config, Atom.to_string(k))
          end)

        if missing == [], do: :ok, else: {:error, {:missing_config, missing}}
      end

      # An adapter that calls through AccessToken also takes an access token
      # in place of its credential keys.
      if access_token do
        defp require_credentials(config, keys) do
          if OptimalEngine.Connectors.AccessToken.present?(config),
            do: :ok,
            else: require_credential_keys(config, keys)
        end
      else
        defp require_credentials(config, keys), do: require_credential_keys(config, keys)
      end

      defp require_credential_keys(config, keys) do
        missing =
          Enum.reject(keys, fn k ->
            has_credential_key?(config, k)
          end)

        if missing == [], do: :ok, else: {:error, {:missing_credentials, missing}}
      end

      defp has_credential_key?(config, k) do
        str = if is_atom(k), do: Atom.to_string(k), else: k
        Map.has_key?(config, k) or Map.has_key?(config, str)
      end

      defp pick(config, key, default \\ nil) do
        str = if is_atom(key), do: Atom.to_string(key), else: key
        Map.get(config, key) || Map.get(config, str) || default
      end

      defp flatten_credentials(config) do
        case Map.get(config, "credentials") || Map.get(config, :credentials) do
          creds when is_map(creds) -> Map.merge(config, creds)
          _ -> config
        end
      end
    end
  end
end
