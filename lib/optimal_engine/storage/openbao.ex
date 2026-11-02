defmodule OptimalEngine.Storage.OpenBao do
  @moduledoc """
  The OpenBao service provider: secrets, keys and PKI for the Engine and its
  workspaces. It is the one provider that holds truth of its own (managed
  secrets); recovery follows the secret manager's policy.

  Reached over its HTTP API through `OptimalEngine.Connectors.HTTP`, from
  `OPTIMAL_OPENBAO_ADDR` and `OPTIMAL_OPENBAO_TOKEN` (sent as `X-Vault-Token`,
  never logged, described or returned). `OPTIMAL_OPENBAO_KV_MOUNT` names the
  KV version 2 mount the proof writes under (`secret` by default).

  Health is `GET /v1/sys/health` saying initialized and unsealed, then
  `GET /v1/auth/token/lookup-self` answering 200: a sealed server or a bad
  token is `unreachable`, not healthy. The proof writes one secret under
  `<mount>/data/optimal/proof/<random>`, reads the same value back and deletes
  its metadata, so a healthy provider has stored and returned a secret.
  """

  alias OptimalEngine.Connectors.HTTP

  @addr_env "OPTIMAL_OPENBAO_ADDR"
  @token_env "OPTIMAL_OPENBAO_TOKEN"
  @mount_env "OPTIMAL_OPENBAO_KV_MOUNT"
  @default_mount "secret"
  @default_timeout 3_000

  @type health :: :healthy | :unreachable | :not_configured | :invalid_config

  @doc "The environment variables the provider is configured by."
  @spec env_names() :: [String.t()]
  def env_names, do: [@addr_env, @token_env]

  @doc "Whether the address and the token are set and the address is an http(s) URL."
  @spec configured?() :: boolean()
  def configured?, do: match?({:ok, _}, config())

  @doc """
  The address, the KV mount and whether a token is set. The token itself is
  not in the result; `headers/0` carries it to the request and nowhere else.
  """
  @spec config(keyword()) :: {:ok, map()} | {:error, atom()}
  def config(opts \\ []) do
    addr = Keyword.get(opts, :addr) || System.get_env(@addr_env)
    token = System.get_env(@token_env)

    cond do
      not present?(addr) or not present?(token) ->
        {:error, :not_configured}

      not match?(
        %URI{scheme: s, host: h} when s in ["http", "https"] and is_binary(h),
        URI.parse(addr)
      ) ->
        {:error, :invalid_url}

      true ->
        mount = System.get_env(@mount_env) |> then(&if(present?(&1), do: &1, else: @default_mount))

        {:ok,
         %{
           base_url: String.trim_trailing(addr, "/"),
           tls: String.starts_with?(addr, "https"),
           mount: mount,
           token: true
         }}
    end
  end

  @doc "Initialized, unsealed, and the token looks itself up."
  @spec health(keyword()) :: health()
  def health(opts \\ []) do
    case config(opts) do
      {:ok, config} ->
        with {:ok, 200, %{"initialized" => true, "sealed" => false}} <-
               call(config, :get, "/v1/sys/health", nil, opts),
             {:ok, 200, _} <- call(config, :get, "/v1/auth/token/lookup-self", nil, opts) do
          :healthy
        else
          _ -> :unreachable
        end

      {:error, :not_configured} ->
        :not_configured

      {:error, _reason} ->
        :invalid_config
    end
  end

  @doc "Writes a secret, reads the same value back and deletes it. Nothing is left behind."
  @spec round_trip(keyword()) :: {:ok, map()} | {:error, term()}
  def round_trip(opts \\ []) do
    with {:ok, config} <- config(opts) do
      name = Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
      value = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
      data_path = "/v1/#{config.mount}/data/optimal/proof/#{name}"
      metadata_path = "/v1/#{config.mount}/metadata/optimal/proof/#{name}"

      try do
        with {:ok, status, _} when status in [200, 204] <-
               call(config, :post, data_path, %{data: %{value: value}}, opts),
             {:ok, 200, %{"data" => %{"data" => %{"value" => ^value}}}} <-
               call(config, :get, data_path, nil, opts) do
          {:ok, %{wrote: 1, read_back: true, mount: config.mount}}
        else
          {:ok, status, body} -> {:error, {:round_trip_mismatch, status, summary(body)}}
          {:error, reason} -> {:error, reason}
        end
      after
        call(config, :delete, metadata_path, nil, opts)
      end
    end
  end

  defp call(config, method, path, body, opts) do
    request_opts =
      [method: method, headers: headers(), timeout: Keyword.get(opts, :timeout, @default_timeout)]
      |> then(fn o -> if body, do: Keyword.put(o, :body, body), else: o end)

    case HTTP.request(config.base_url <> path, request_opts) do
      {:ok, %{status: status, body: body}} -> {:ok, status, body}
      {:error, reason} -> {:error, {:unreachable, class(reason)}}
    end
  catch
    _kind, _reason -> {:error, :unreachable}
  end

  defp headers do
    [{"X-Vault-Token", System.get_env(@token_env) || ""}, {"content-type", "application/json"}]
  end

  defp class(reason) when is_atom(reason), do: reason
  defp class({class, _detail}) when is_atom(class), do: class
  defp class(_other), do: :request_failed

  defp summary(%{"errors" => errors}) when is_list(errors), do: Enum.join(errors, "; ")
  defp summary(body) when is_binary(body), do: String.slice(body, 0, 80)
  defp summary(_body), do: :unexpected_body

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false
end
