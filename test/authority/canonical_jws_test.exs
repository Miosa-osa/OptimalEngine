defmodule OptimalEngine.Authority.CanonicalJWSTest do
  use ExUnit.Case, async: true

  alias OptimalEngine.Authority.{CanonicalJSON, JWS}

  describe "RFC 8785 canonical JSON" do
    test "matches the RFC's primitive data example" do
      value = %{
        "numbers" => [333_333_333.333_333_29, 1.0e30, 4.5, 2.0e-3, 1.0e-27],
        "string" => "€$" <> <<0x0F>> <> "\nA'B\"\\\\\"/",
        "literals" => [nil, true, false]
      }

      assert CanonicalJSON.encode(value) ==
               ~S({"literals":[null,true,false],"numbers":[333333333.3333333,1e+30,4.5,0.002,1e-27],"string":"€$\u000f\nA'B\"\\\\\"/"})
    end

    test "sorts members by UTF-16 code units, as the RFC's sorting example" do
      value = %{
        "€" => "Euro Sign",
        "\r" => "Carriage Return",
        "דּ" => "Hebrew Letter Dalet With Dagesh",
        "1" => "One",
        "😀" => "Emoji: Grinning Face",
        "\u0080" => "Control",
        "ö" => "Latin Small Letter O With Diaeresis"
      }

      keys =
        value
        |> CanonicalJSON.encode()
        |> Jason.decode!(objects: :ordered_objects)
        |> Map.get(:values)
        |> Enum.map(&elem(&1, 0))

      assert keys == ["\r", "1", "\u0080", "ö", "€", "😀", "דּ"]
    end

    test "integral floats print as integers and small numbers as plain decimals" do
      assert CanonicalJSON.encode([1.0, -0.0, 1.0e-6, 1.0e-7, 1.0e21, 100]) ==
               "[1,0,0.000001,1e-7,1e+21,100]"
    end

    test "atoms and string keys canonicalize identically" do
      assert CanonicalJSON.hash(%{a: 1, b: :x}) == CanonicalJSON.hash(%{"b" => "x", "a" => 1})
    end
  end

  describe "compact JWS (EdDSA only)" do
    setup do
      {public, private} = :crypto.generate_key(:eddsa, :ed25519)
      claims = %{"sub" => "agent:one", "n" => 1}
      token = JWS.sign(claims, "example+jws", "kid-1", private)
      %{public: public, private: private, claims: claims, token: token}
    end

    test "round trips", ctx do
      assert {:ok, parsed} = JWS.parse(ctx.token, "example+jws")
      assert parsed.claims == ctx.claims
      assert parsed.header["kid"] == "kid-1"
      assert :ok = JWS.verify_signature(parsed, ctx.public)
    end

    test "a changed payload fails the signature", ctx do
      [header, _payload, signature] = String.split(ctx.token, ".")
      forged = JWS.encode64(CanonicalJSON.encode(%{"sub" => "agent:two", "n" => 1}))
      assert {:ok, parsed} = JWS.parse(Enum.join([header, forged, signature], "."), "example+jws")
      assert {:error, :bad_signature} = JWS.verify_signature(parsed, ctx.public)
    end

    test "a different key fails the signature", ctx do
      {other_public, _} = :crypto.generate_key(:eddsa, :ed25519)
      {:ok, parsed} = JWS.parse(ctx.token, "example+jws")
      assert {:error, :bad_signature} = JWS.verify_signature(parsed, other_public)
    end

    test "algorithm substitution is refused before any key is used", ctx do
      [_header, payload, _signature] = String.split(ctx.token, ".")

      for header <- [
            %{"alg" => "none", "kid" => "kid-1", "typ" => "example+jws"},
            %{"alg" => "HS256", "kid" => "kid-1", "typ" => "example+jws"},
            %{"alg" => "RS256", "kid" => "kid-1", "typ" => "example+jws"},
            %{"kid" => "kid-1", "typ" => "example+jws"}
          ] do
        mac = :crypto.mac(:hmac, :sha256, ctx.public, "x")
        token = Enum.join([JWS.encode64(Jason.encode!(header)), payload, JWS.encode64(mac)], ".")
        assert {:error, :algorithm_not_allowed} = JWS.parse(token, "example+jws"), inspect(header)
      end
    end

    test "unexpected headers, types and encodings are refused", ctx do
      [_header, payload, signature] = String.split(ctx.token, ".")

      cases = [
        {%{"alg" => "EdDSA", "kid" => "kid-1", "typ" => "other+jws"}, :wrong_type},
        {%{"alg" => "EdDSA", "kid" => "kid-1", "typ" => "example+jws", "crit" => ["exp"]},
         :unsupported_critical_header},
        {%{"alg" => "EdDSA", "kid" => "kid-1", "typ" => "example+jws", "b64" => false},
         :unsupported_critical_header},
        {%{"alg" => "EdDSA", "typ" => "example+jws"}, :missing_kid},
        {%{"alg" => "EdDSA", "kid" => "kid-1", "typ" => "example+jws", "jku" => "https://x"},
         :unexpected_header}
      ]

      for {header, reason} <- cases do
        token = Enum.join([JWS.encode64(Jason.encode!(header)), payload, signature], ".")
        assert {:error, ^reason} = JWS.parse(token, "example+jws"), inspect(header)
      end

      assert {:error, :malformed} = JWS.parse("a.b", "example+jws")
      assert {:error, :malformed} = JWS.parse(ctx.token <> "=", "example+jws")
    end

    test "a payload that is not canonical JSON is refused", ctx do
      [header, _payload, signature] = String.split(ctx.token, ".")
      loose = JWS.encode64(~s({ "sub": "agent:one", "n": 1 }))

      assert {:error, :non_canonical_payload} =
               JWS.parse(Enum.join([header, loose, signature], "."), "example+jws")
    end
  end
end
