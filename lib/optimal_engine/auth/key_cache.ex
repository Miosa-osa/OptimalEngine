defmodule OptimalEngine.Auth.KeyCache do
  @moduledoc """
  Remembers which API key secrets were already verified, so bcrypt runs once
  per key and secret instead of on every request.

  An entry maps a key id to the SHA-256 of a secret that matched and the
  stored bcrypt hash it matched against. `ApiKey.verify/1` still reads the
  key row on every request, so revocation, expiry, and a rotated hash take
  effect at once; only the bcrypt comparison is skipped, and only when the
  presented secret hashes to the remembered value and the stored hash is
  unchanged. Entries expire after `:key_cache_ttl_seconds` (default 600).
  """

  use GenServer

  @table :optimal_engine_key_cache
  @default_ttl 600
  @max_entries 10_000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "True when `secret` was verified against `hashed_secret` for `key_id`."
  @spec verified?(String.t(), String.t(), String.t()) :: boolean()
  def verified?(key_id, secret, hashed_secret) do
    now = System.monotonic_time(:second)

    case lookup(key_id) do
      [{^key_id, digest, ^hashed_secret, expires}] when expires > now ->
        Plug.Crypto.secure_compare(digest, digest(secret))

      _ ->
        false
    end
  end

  @doc "Remembers a successful verification."
  @spec remember(String.t(), String.t(), String.t()) :: :ok
  def remember(key_id, secret, hashed_secret) do
    if :ets.whereis(@table) != :undefined do
      if :ets.info(@table, :size) >= @max_entries, do: :ets.delete_all_objects(@table)
      ttl = Application.get_env(:optimal_engine, :key_cache_ttl_seconds, @default_ttl)

      :ets.insert(
        @table,
        {key_id, digest(secret), hashed_secret, System.monotonic_time(:second) + ttl}
      )
    end

    :ok
  end

  @doc "Forgets a key (on revoke or delete)."
  @spec forget(String.t()) :: :ok
  def forget(key_id) do
    if :ets.whereis(@table) != :undefined, do: :ets.delete(@table, key_id)
    :ok
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{}}
  end

  defp lookup(key_id) do
    if :ets.whereis(@table) != :undefined, do: :ets.lookup(@table, key_id), else: []
  end

  defp digest(secret), do: :crypto.hash(:sha256, secret)
end
