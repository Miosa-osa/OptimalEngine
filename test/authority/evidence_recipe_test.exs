defmodule OptimalEngine.Authority.EvidenceRecipeTest do
  @moduledoc """
  The recipe `docs/guides/optimal-authority.md` publishes for verifying evidence
  offline: its worked example is what the Engine computes and verifies, and a live
  entry's hash and signatures are recomputed by that recipe alone.
  """

  use ExUnit.Case, async: false

  alias OptimalEngine.Authority.{CanonicalJSON, Evidence, JWS, Keys}
  alias OptimalEngine.Tenancy.Tenant

  @guide "docs/guides/optimal-authority.md"

  # The twelve hashed fields in the order the guide gives, which is the canonical order.
  @fields ~w(action detail id jti kind prev_hash recorded_at resource seq subject tenant_id workspace_id)

  # RFC 8032 test 1: a published test key, never a real one.
  @secret Base.decode16!("9D61B19DEFFD5A60BA844AF492EC2CC44449C5697B326919703BAC031CAE7F60")

  @example %{
    "tenant_id" => "acme",
    "seq" => 1,
    "id" => "ev_example0000000000",
    "kind" => "grant.issued",
    "jti" => "grt_example",
    "subject" => "agent:analyst",
    "action" => "read",
    "resource" => "optimal://acme:ops/notes",
    "workspace_id" => "acme:ops",
    "detail" => %{"by" => "user:owner"},
    "prev_hash" => String.duplicate("0", 64),
    "recorded_at" => "2026-10-21T00:00:00.000000Z"
  }
  @hash "b0b34816fa897020ff710bb47d1a235a806b69af9d155e1b273ad60ef6be327d"
  @x "11qYAYKxCrfVS_7TyWQHOg7hcvPapiMlrwIaaPcHURo"
  @kid "kPrK_qmxVWaYVA9wwBF6Iuo3vVzz7TxHCTwXBygrS4k"
  @signature "I1n5bJG6O_IsBQsvRdEGKxzu2As7Ajo9Ww8CNmoZFhMZQgFJOFmnzpXkPiKPV-sIIqAa22JoRPHVN-eH2ybQDA"
  @head_signature "7wK7vhhnJyDos-w6oJrJPXmtCqVjimy6eCIm1jxvW8mEfaBRn2qaftGvOGDA84i3wS91kNLm_BWE9HVmLs2yDA"

  test "the guide's worked example is what the Engine computes and verifies" do
    guide = File.read!(@guide)
    assert Enum.sort(@fields) == @fields

    canonical = recipe(Map.take(@example, @fields))
    assert String.contains?(guide, canonical)
    assert CanonicalJSON.encode(@example) == canonical
    assert sha256(canonical) == @hash
    assert CanonicalJSON.hash(@example) == @hash

    {public, _secret} = :crypto.generate_key(:eddsa, :ed25519, @secret)
    assert JWS.encode64(public) == @x
    assert Keys.thumbprint(public) == @kid
    assert sign(@hash) == @signature

    statement = recipe(%{"tenant_id" => "acme", "seq" => 1, "hash" => @hash})
    assert statement == ~s({"hash":"#{@hash}","seq":1,"tenant_id":"acme"})
    assert sign(statement) == @head_signature

    for value <- [@hash, @x, @kid, @signature, statement, @head_signature] do
      assert String.contains?(guide, value), "the guide shows #{value}"
    end

    jwk = public |> Keys.jwk() |> Map.merge(%{"kid" => @kid, "optimal_purpose" => "evidence"})
    entry = Map.merge(@example, %{"hash" => @hash, "kid" => @kid, "signature" => @signature})

    bundle = %{
      "tenant_id" => "acme",
      "entries" => [entry],
      "head" => %{"seq" => 1, "hash" => @hash},
      "head_signature" => %{"kid" => @kid, "signature" => @head_signature},
      "total" => 1,
      "complete" => true,
      "next_after" => nil,
      "keys" => %{"keys" => [jwk]}
    }

    assert {:ok, %{entries: 1, head: @hash}} = Evidence.verify_export(bundle)
  end

  test "a live entry's hash and signatures are recomputed by the recipe alone" do
    tenant = "evidence-recipe-#{System.unique_integer([:positive])}"
    {:ok, _} = Tenant.create(%{id: tenant, name: "Evidence recipe"})

    attrs = %{subject: "agent:recipe", detail: %{"why" => "a recipe check", "n" => 2}}
    {:ok, _} = Evidence.append(tenant, "decision.allowed", attrs)

    {:ok, page} = Evidence.export(tenant)
    [entry] = page["entries"]

    assert sha256(recipe(Map.take(entry, @fields))) == entry["hash"]

    %{"x" => x, "optimal_purpose" => "evidence"} =
      Enum.find(Keys.jwks(tenant)["keys"], &(&1["kid"] == entry["kid"]))

    {:ok, public} = JWS.decode64(x)
    assert verified?(entry["hash"], entry["signature"], public)

    statement = recipe(%{"tenant_id" => tenant, "seq" => entry["seq"], "hash" => entry["hash"]})
    assert %{"kid" => kid, "signature" => head_signature} = page["head_signature"]
    assert kid == entry["kid"]
    assert verified?(statement, head_signature, public)
  end

  # The guide's recipe, written out apart from the Engine's own CanonicalJSON: members
  # sorted by name (these names are ASCII, so bytes and UTF-16 units sort alike), no
  # whitespace, and JSON's own string, integer and null forms.
  defp recipe(map) when is_map(map) do
    members =
      map
      |> Enum.sort_by(fn {name, _value} -> name end)
      |> Enum.map_join(",", fn {name, value} -> Jason.encode!(name) <> ":" <> recipe(value) end)

    "{" <> members <> "}"
  end

  defp recipe(value), do: Jason.encode!(value)

  defp sha256(text), do: :sha256 |> :crypto.hash(text) |> Base.encode16(case: :lower)

  defp sign(text), do: :eddsa |> :crypto.sign(:none, text, [@secret, :ed25519]) |> JWS.encode64()

  defp verified?(text, signature, public) do
    {:ok, raw} = JWS.decode64(signature)
    :crypto.verify(:eddsa, :none, text, raw, [public, :ed25519])
  end
end
