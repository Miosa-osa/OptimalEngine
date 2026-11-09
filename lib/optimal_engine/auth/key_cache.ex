defmodule OptimalEngine.Auth.KeyCache do
  @moduledoc """
  Remembers which API key secrets were already verified, so bcrypt runs once
  per key and secret instead of on every request.

  An entry maps a key id to the SHA-256 of the stored bcrypt hash and the
  secret that matched it. `ApiKey.verify/1` still reads the key row on every
  request, so revocation, expiry, and a rotated hash take effect at once; only
  the bcrypt comparison is skipped, and only when the presented secret and the
  stored hash give the remembered digest. Entries expire after
  `:key_cache_ttl_seconds` (default 600).

  With `OPTIMAL_VALKEY_URL` set the entries live in Valkey, so a key verified
  on one node is not bcrypt-checked again on the others; otherwise, or while
  Valkey is unreachable, they live in this process's ETS table (at most
  10,000 entries). `forget/1` (revoke, delete) removes the entry from both, and
  a removal Valkey could not take is applied before Valkey is read again
  (`OptimalEngine.Storage.Shared`). Neither the secret nor the bcrypt hash is
  stored, only the digest of the two.
  """

  use GenServer

  alias OptimalEngine.Storage.Shared
  alias OptimalEngine.Storage.Shared.Local

  @table :optimal_engine_key_cache
  @default_ttl 600
  @max_entries 10_000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "True when `secret` was verified against `hashed_secret` for `key_id`."
  @spec verified?(String.t(), String.t(), String.t()) :: boolean()
  def verified?(key_id, secret, hashed_secret) do
    case Shared.get(@table, key_id) do
      {:ok, digest} when is_binary(digest) ->
        Plug.Crypto.secure_compare(digest, digest(secret, hashed_secret))

      _ ->
        false
    end
  end

  @doc "Remembers a successful verification."
  @spec remember(String.t(), String.t(), String.t()) :: :ok
  def remember(key_id, secret, hashed_secret) do
    ttl = Application.get_env(:optimal_engine, :key_cache_ttl_seconds, @default_ttl)

    if is_integer(ttl) and ttl > 0 do
      Shared.put(@table, key_id, digest(secret, hashed_secret), ttl * 1_000,
        max_entries: @max_entries
      )
    end

    :ok
  end

  @doc "Forgets a key (on revoke or delete), on every node."
  @spec forget(String.t()) :: :ok
  def forget(key_id), do: Shared.delete(@table, key_id)

  @impl true
  def init(_opts) do
    Local.new_table(@table)
    {:ok, %{}}
  end

  # Length-prefixed, so no secret and hash pair shares a digest with another.
  defp digest(secret, hashed_secret) do
    :crypto.hash(:sha256, [
      <<byte_size(hashed_secret)::32>>,
      hashed_secret,
      secret
    ])
  end
end
