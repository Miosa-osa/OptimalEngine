defmodule OptimalEngine.Signal.PreSendTest do
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias OptimalEngine.API.Router
  alias OptimalEngine.Auth.ApiKey
  alias OptimalEngine.Signal.PreSend
  alias OptimalEngine.Tenancy.Tenant
  alias OptimalEngine.Viability.SignalEvents

  defp long_reply(words) do
    sentence = "The delivery moves to Friday because the vendor confirmed the parts late this week."
    count = length(String.split(sentence))

    body =
      1..div(words, count)
      |> Enum.map_join(" ", fn _ -> sentence end)

    "Hi Sam, thanks for the update. Can you confirm the new address by Thursday? " <> body
  end

  test "a 2,000-word reply for a WhatsApp receiver is a bandwidth overload with a shorter version" do
    draft = long_reply(2_000)
    result = PreSend.check(draft, %{"channel" => "whatsapp"})

    refute result.ok
    assert result.words > 1_900
    overload = Enum.find(result.flags, &(&1.code == "bandwidth_overload"))
    assert overload.constraint == "shannon"

    shorter_words = overload.shorter |> String.split() |> length()
    assert shorter_words <= 150
    assert overload.shorter =~ "Can you confirm the new address by Thursday?"
    assert overload.shorter =~ "available on request"
  end

  test "a short message on the same channel passes" do
    result =
      PreSend.check("Hi Sam, can you confirm the new address by Thursday? Thanks!", %{
        "channel" => "whatsapp"
      })

    assert result.ok
    assert result.detected.type == "direct"
  end

  test "genre, type and routing failures carry suggestions" do
    spec =
      "# Requirements\nThe export runs nightly.\n# Constraints\nNo data leaves the region.\n# Acceptance\nA report lands by 6 am."

    mismatch = PreSend.check(spec, %{"channel" => "sms"})
    assert Enum.any?(mismatch.flags, &(&1.code == "genre_mismatch"))

    declared =
      PreSend.check("We shipped the export and it ran clean last night.", %{"channel" => "email"},
        genre: "invoice"
      )

    assert %{suggestion: suggestion} = Enum.find(declared.flags, &(&1.code == "genre_mismatch"))
    assert suggestion =~ "invoice"

    no_ask =
      PreSend.check("The export ran clean last night.", %{"channel" => "email"}, type: "direct")

    assert Enum.any?(no_ask.flags, &(&1.code == "missing_type"))

    nowhere = PreSend.check("The export ran clean last night.", %{})
    assert [%{code: "routing_failure"}] = nowhere.flags

    by_bandwidth = PreSend.check(long_reply(600), %{"bandwidth" => "medium"})
    assert Enum.any?(by_bandwidth.flags, &(&1.code == "bandwidth_overload"))
  end

  test "the API checks a draft and records the check for the genre recognition rate" do
    n = System.unique_integer([:positive])
    tenant = "presend-#{n}"
    {:ok, _} = Tenant.create(%{id: tenant, name: "Presend #{n}"})
    workspace = "#{tenant}:ops"

    {:ok, _} =
      OptimalEngine.Store.raw_query(
        "INSERT INTO workspaces (id, tenant_id, slug, name, status, metadata) VALUES (?1, ?2, 'ops', 'ops', 'active', '{}')",
        [workspace, tenant]
      )

    {:ok, %{key: key}} =
      ApiKey.mint(%{
        tenant_id: tenant,
        name: "k",
        scopes: ["read", "write"],
        workspace_scope: [workspace]
      })

    conn =
      conn(
        :post,
        "/api/signals/check",
        Jason.encode!(%{
          "workspace" => workspace,
          "draft" => long_reply(800),
          "receiver" => %{"channel" => "slack"}
        })
      )
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer " <> key)
      |> Router.call(Router.init([]))

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["ok"] == false
    assert Enum.any?(body["flags"], &(&1["code"] == "bandwidth_overload"))

    assert [%{kind: "genre_checked", metadata: %{"source" => "pre_send"}}] =
             SignalEvents.list(tenant, [workspace], kind: "genre_checked")
  end
end
