defmodule OptimalEngine.Store.KeyGrantsBackfillMigrationTest do
  @moduledoc """
  Migration 85 gives the keys minted before label and partition grants existed
  the grants a machine key should hold: `allowed_security_labels` of public,
  internal and confidential, and no partition. Such a key has none, and reads
  only rows that carry no label; the backfill lets it read confidential ones
  too (and, on the routes that read everything before they followed grants,
  takes restricted ones away). It touches nothing else: not a key that already
  has either field, not the operator's bootstrap root key (which holds `"*"`
  and is given it at boot), not a revoked key, and not a key whose metadata it
  cannot read.
  """

  use ExUnit.Case, async: false

  alias OptimalEngine.TestSupport.KeyGrantsBackfill

  @default_labels ["public", "internal", "confidential"]

  defp key(id, metadata, opts \\ []) do
    %{
      id: id,
      scopes: Jason.encode!(Keyword.get(opts, :scopes, ["read"])),
      revoked_at: Keyword.get(opts, :revoked_at),
      metadata: if(is_binary(metadata), do: metadata, else: Jason.encode!(metadata))
    }
  end

  defp stored(result, id), do: result.metadata |> Map.fetch!(id) |> Jason.decode!()

  test "a key without grant fields gets the default grants and a marker" do
    result = KeyGrantsBackfill.run([key("legacy", %{})])

    assert stored(result, "legacy") == %{
             "allowed_security_labels" => @default_labels,
             "allowed_partitions" => [],
             "grants_backfilled" => true
           }
  end

  test "what else the key's metadata holds is kept" do
    metadata = %{"rate_limit_per_minute" => 30, "permissions" => ["a"], "note" => "ci"}
    result = KeyGrantsBackfill.run([key("legacy", metadata)])

    assert stored(result, "legacy") ==
             Map.merge(metadata, %{
               "allowed_security_labels" => @default_labels,
               "allowed_partitions" => [],
               "grants_backfilled" => true
             })
  end

  test "a key of any scope is backfilled, a root-scoped one included" do
    rows = [
      key("read", %{}, scopes: ["read"]),
      key("write", %{}, scopes: ["read", "write"]),
      key("root", %{}, scopes: ["*"]),
      key("admin", %{}, scopes: ["admin"])
    ]

    result = KeyGrantsBackfill.run(rows)

    for id <- ["read", "write", "root", "admin"] do
      assert stored(result, id)["allowed_security_labels"] == @default_labels, id
      assert stored(result, id)["allowed_partitions"] == [], id
    end
  end

  describe "a key that already has a grant field is not touched" do
    test "whichever field it has, and whatever it holds" do
      held = [
        {"labels-only", %{"allowed_security_labels" => ["public"]}},
        {"partitions-only", %{"allowed_partitions" => ["team-a"]}},
        {"both", %{"allowed_security_labels" => ["restricted"], "allowed_partitions" => ["x"]}},
        {"none-on-purpose", %{"allowed_security_labels" => [], "allowed_partitions" => []}},
        {"wildcards", %{"allowed_security_labels" => ["*"], "allowed_partitions" => ["*"]}},
        {"empty-labels-only", %{"allowed_security_labels" => []}},
        {"explicit-null", %{"allowed_partitions" => nil}}
      ]

      rows = for {id, metadata} <- held, do: key(id, metadata)
      result = KeyGrantsBackfill.run(rows)

      for {id, metadata} <- held do
        assert result.metadata[id] == Jason.encode!(metadata), id
      end
    end

    test "a key marked as backfilled is not backfilled again" do
      metadata = %{"grants_backfilled" => true}
      result = KeyGrantsBackfill.run([key("marked", metadata)])

      assert result.metadata["marked"] == Jason.encode!(metadata)
    end
  end

  describe "the operator's bootstrap key" do
    test "a root bootstrap key keeps no grants, so that the boot gives it the wildcard" do
      bootstrap = %{"source" => "bootstrap"}

      rows = [
        key("boot-star", bootstrap, scopes: ["*"]),
        key("boot-admin", bootstrap, scopes: ["admin"]),
        key("boot-mixed", bootstrap, scopes: ["read", "write", "admin"])
      ]

      result = KeyGrantsBackfill.run(rows)

      for id <- ["boot-star", "boot-admin", "boot-mixed"] do
        assert result.metadata[id] == Jason.encode!(bootstrap), id
      end
    end

    test "a bootstrap key without a root scope is a key like any other" do
      result =
        KeyGrantsBackfill.run([
          key("boot-rw", %{"source" => "bootstrap"}, scopes: ["read", "write"])
        ])

      assert stored(result, "boot-rw")["allowed_security_labels"] == @default_labels
      assert stored(result, "boot-rw")["source"] == "bootstrap"
    end

    test "a key that only looks like the bootstrap key is backfilled" do
      rows = [
        key("other-source", %{"source" => "platform"}, scopes: ["*"]),
        key("no-source", %{"origin" => "bootstrap"}, scopes: ["*"])
      ]

      result = KeyGrantsBackfill.run(rows)

      assert stored(result, "other-source")["allowed_security_labels"] == @default_labels
      assert stored(result, "no-source")["allowed_security_labels"] == @default_labels
    end
  end

  test "a revoked key is not touched" do
    revoked = key("revoked", %{}, revoked_at: "2026-10-01 10:00:00")
    result = KeyGrantsBackfill.run([revoked])

    assert result.metadata["revoked"] == "{}"
  end

  test "a key whose metadata or scopes cannot be read does not stop the migration" do
    rows = [
      key("not-json", "this is not json"),
      key("array", "[1, 2]"),
      key("string", "\"text\""),
      key("empty", ""),
      %{id: "bad-scopes", scopes: "not json", revoked_at: nil, metadata: "{}"},
      key("fine", %{})
    ]

    result = KeyGrantsBackfill.run(rows)

    assert result.metadata["not-json"] == "this is not json"
    assert result.metadata["array"] == "[1, 2]"
    assert result.metadata["string"] == "\"text\""
    assert result.metadata["empty"] == ""
    assert stored(result, "fine")["allowed_security_labels"] == @default_labels
    assert stored(result, "bad-scopes")["allowed_security_labels"] == @default_labels
  end

  test "running its statements again changes nothing" do
    rows = [
      key("legacy", %{"rate_limit_per_minute" => 5}),
      key("explicit", %{"allowed_security_labels" => ["restricted"]}),
      key("boot", %{"source" => "bootstrap"}, scopes: ["*"]),
      key("revoked", %{}, revoked_at: "2026-10-01 10:00:00")
    ]

    result = KeyGrantsBackfill.run(rows, again: true)

    assert stored(result, "legacy")["allowed_security_labels"] == @default_labels
  end

  test "the boot log says how many keys were given grants, and names none" do
    rows = [
      key("secret-key-name-1", %{}),
      key("secret-key-name-2", %{}),
      key("secret-key-name-3", %{"allowed_security_labels" => []})
    ]

    %{log: log} = KeyGrantsBackfill.run(rows)

    assert log =~ ~r/data: [^\n]*, rows changed: 2(?!\d)/
    refute log =~ "secret-key-name"
  end
end
