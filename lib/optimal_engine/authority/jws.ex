defmodule OptimalEngine.Authority.JWS do
  @moduledoc """
  Compact JSON Web Signatures (RFC 7515) restricted to what authority needs.

  Only one algorithm is accepted: `EdDSA` with Ed25519 keys (RFC 8037).
  Every other `alg`, including `none` and HMAC algorithms, is refused before
  any key is consulted, so a token can never choose a weaker verification
  path. Headers carry `alg`, `typ`, and `kid`; a token with a `crit` header,
  an unencoded payload (`b64: false`), or an unexpected `typ` is refused.

  The payload is the RFC 8785 canonical JSON of the claims. Verification
  requires the received payload bytes to be canonical, so two parsers can
  never disagree about what was signed.
  """

  alias OptimalEngine.Authority.CanonicalJSON

  @alg "EdDSA"

  @type header :: %{required(String.t()) => term()}

  @doc """
  Signs `claims` as a compact JWS with header `alg: EdDSA`, the given `typ`,
  and `kid`, using a raw 32-byte Ed25519 private key.
  """
  @spec sign(map(), String.t(), String.t(), binary()) :: String.t()
  def sign(claims, typ, kid, private_key)
      when is_map(claims) and is_binary(typ) and is_binary(kid) and byte_size(private_key) == 32 do
    header = %{"alg" => @alg, "kid" => kid, "typ" => typ}

    signing_input =
      encode64(CanonicalJSON.encode(header)) <> "." <> encode64(CanonicalJSON.encode(claims))

    signature = :crypto.sign(:eddsa, :none, signing_input, [private_key, :ed25519])
    signing_input <> "." <> encode64(signature)
  end

  @doc """
  Splits and checks a compact JWS without verifying the signature.

  Returns `{:ok, %{header: header, claims: claims, signing_input: binary,
  signature: binary}}` or `{:error, reason}`. Callers must verify the
  signature with `verify_signature/3` before trusting any claim.
  """
  @spec parse(String.t(), String.t()) :: {:ok, map()} | {:error, atom()}
  def parse(token, expected_typ) when is_binary(token) and is_binary(expected_typ) do
    with [header64, payload64, signature64] <- String.split(token, "."),
         {:ok, header_json} <- decode64(header64),
         {:ok, payload} <- decode64(payload64),
         {:ok, signature} <- decode64(signature64),
         {:ok, %{} = header} <- decode_json(header_json),
         :ok <- check_header(header, expected_typ),
         {:ok, %{} = claims} <- decode_json(payload),
         :ok <- check_canonical(claims, payload) do
      {:ok,
       %{
         header: header,
         claims: claims,
         signing_input: header64 <> "." <> payload64,
         signature: signature
       }}
    else
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _ -> {:error, :malformed}
    end
  end

  def parse(_token, _expected_typ), do: {:error, :malformed}

  @doc "Verifies an Ed25519 signature over the JWS signing input."
  @spec verify_signature(map(), binary(), keyword()) :: :ok | {:error, :bad_signature}
  def verify_signature(%{signing_input: input, signature: signature}, public_key, _opts \\ [])
      when byte_size(public_key) == 32 do
    if byte_size(signature) == 64 and
         :crypto.verify(:eddsa, :none, input, signature, [public_key, :ed25519]),
       do: :ok,
       else: {:error, :bad_signature}
  end

  @doc "Base64url without padding (RFC 7515 section 2)."
  @spec encode64(binary()) :: String.t()
  def encode64(data), do: Base.url_encode64(data, padding: false)

  @doc "Decodes base64url without padding; padded or non-url input is refused."
  @spec decode64(String.t()) :: {:ok, binary()} | {:error, :malformed}
  def decode64(text) when is_binary(text) do
    if String.contains?(text, "="),
      do: {:error, :malformed},
      else: wrap(Base.url_decode64(text, padding: false))
  end

  defp wrap({:ok, data}), do: {:ok, data}
  defp wrap(:error), do: {:error, :malformed}

  defp decode_json(binary) do
    case Jason.decode(binary) do
      {:ok, value} -> {:ok, value}
      _ -> {:error, :malformed}
    end
  end

  defp check_header(%{"alg" => @alg} = header, expected_typ) do
    cond do
      Map.has_key?(header, "crit") -> {:error, :unsupported_critical_header}
      Map.get(header, "b64") == false -> {:error, :unsupported_critical_header}
      Map.get(header, "typ") != expected_typ -> {:error, :wrong_type}
      not (is_binary(header["kid"]) and header["kid"] != "") -> {:error, :missing_kid}
      Map.keys(header) -- ["alg", "kid", "typ"] != [] -> {:error, :unexpected_header}
      true -> :ok
    end
  end

  defp check_header(_header, _expected_typ), do: {:error, :algorithm_not_allowed}

  defp check_canonical(claims, payload) do
    if CanonicalJSON.encode(claims) == payload, do: :ok, else: {:error, :non_canonical_payload}
  end
end
