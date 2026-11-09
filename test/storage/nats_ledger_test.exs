defmodule OptimalEngine.Storage.NATSLedgerTest do
  @moduledoc """
  The change ledger (`sync_mutations`) published as a JetStream stream: one
  subject per workspace, in ledger order, each change once (its mutation id is
  the `Nats-Msg-Id`), never a change the data-class gate keeps home, and a
  publisher that picks up where the stream says it left off. NATS being down
  never fails an Engine write: the ledger is the buffer, and the backlog goes
  out when the server is back.
  """
  use ExUnit.Case, async: false

  alias OptimalEngine.{Store, Sync, Workspace}
  alias OptimalEngine.Storage.NATS
  alias OptimalEngine.Storage.NATS.{Connection, LedgerPublisher, Protocol}
  alias OptimalEngine.Tenancy.Tenant
  alias OptimalEngine.TestSupport.NATSStub

  setup do
    n = System.unique_integer([:positive])
    tenant = "natsled-#{n}"
    {:ok, _} = Tenant.create(%{id: tenant, name: "NATS ledger #{n}"})

    {:ok, _} =
      OptimalEngine.Organization.create(%{
        id: "#{tenant}:org",
        tenant_id: tenant,
        slug: "org",
        name: "Org"
      })

    {:ok, ws} =
      Workspace.create(%{
        tenant_id: tenant,
        organization_id: "#{tenant}:org",
        slug: "notes",
        name: "Notes"
      })

    {:ok, _} = Sync.enable(tenant, ws.id, "user:owner")

    {:ok, stub} = NATSStub.start()
    on_exit(fn -> NATSStub.stop(stub) end)

    conn = :"nats_ledger_conn_#{n}"
    url = "nats://127.0.0.1:#{stub.port}"
    start_supervised!({Connection, name: conn, url: url, backoff: {20, 100}}, id: conn)
    assert wait_for(fn -> Connection.connected?(conn) end)

    %{tenant: tenant, ws: ws.id, n: n, stub: stub, conn: conn, url: url}
  end

  defp publisher(ctx, extra \\ []) do
    name = :"nats_ledger_pub_#{System.unique_integer([:positive])}"

    opts =
      Keyword.merge(
        [
          name: name,
          connection: ctx.conn,
          namespace: "optimal",
          enabled: true,
          interval_ms: 0,
          workspaces: [ctx.ws]
        ],
        extra
      )

    start_supervised!({LedgerPublisher, opts}, id: name)
    name
  end

  defp insert_context(ctx, id, title) do
    {:ok, _} =
      Store.raw_query(
        "INSERT INTO contexts (id, tenant_id, workspace_id, title, content, created_at) VALUES (?1, ?2, ?3, ?4, 'body', '2026-10-14T10:00:00Z')",
        [id, ctx.tenant, ctx.ws, title]
      )
  end

  defp subject(ctx), do: "optimal.ledger.#{Protocol.token(ctx.tenant)}.#{Protocol.token(ctx.ws)}"
  defp in_workspace?(ctx, message), do: String.starts_with?(message.subject, subject(ctx) <> ".")

  defp wait_for(fun, tries \\ 100) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(20) && wait_for(fun, tries - 1)
    end
  end

  test "each change goes out once, in ledger order, on its workspace's subject", ctx do
    for i <- 1..3, do: insert_context(ctx, "c#{i}-#{ctx.n}", "T#{i}")
    pub = publisher(ctx)

    assert {:ok, %{published: published}} = LedgerPublisher.publish_now(pub)
    assert published >= 3

    messages = NATSStub.messages(ctx.stub, "OPTIMAL_LEDGER")
    assert Enum.all?(messages, &in_workspace?(ctx, &1))

    sequences = Enum.map(messages, &String.to_integer(&1.headers["Optimal-Ledger-Seq"]))
    assert sequences == Enum.sort(sequences)

    changes = Enum.map(messages, &Jason.decode!(&1.data))
    assert Enum.all?(messages, &(&1.headers["Nats-Msg-Id"] =~ ~r/^mut_/))
    assert Enum.map(changes, & &1["id"]) == Enum.map(messages, & &1.headers["Nats-Msg-Id"])

    titles =
      for %{"entity_type" => "contexts", "operation" => "create", "payload" => p} <- changes,
          do: p["row"]["title"]

    assert titles == ~w(T1 T2 T3)
    assert hd(changes)["workspace_id"] == ctx.ws
    assert hd(changes)["tenant_id"] == ctx.tenant

    # Nothing new: nothing published.
    assert {:ok, %{published: 0}} = LedgerPublisher.publish_now(pub)

    insert_context(ctx, "c4-#{ctx.n}", "T4")
    assert {:ok, %{published: 1}} = LedgerPublisher.publish_now(pub)
  end

  test "a restarted publisher picks up where the stream left off and repeats nothing", ctx do
    for i <- 1..2, do: insert_context(ctx, "r#{i}-#{ctx.n}", "R#{i}")
    first = publisher(ctx)
    assert {:ok, %{published: published}} = LedgerPublisher.publish_now(first)
    assert published >= 2
    stop_supervised!(first)

    insert_context(ctx, "r3-#{ctx.n}", "R3")
    second = publisher(ctx)
    assert {:ok, %{published: 1}} = LedgerPublisher.publish_now(second)

    ids = ctx.stub |> NATSStub.messages("OPTIMAL_LEDGER") |> Enum.map(& &1.headers["Nats-Msg-Id"])
    assert ids == Enum.uniq(ids)
  end

  test "NATS down: the write succeeds, the publisher buffers, and the backlog goes out in order",
       ctx do
    pub = publisher(ctx)
    assert {:ok, _} = LedgerPublisher.publish_now(pub)

    port = ctx.stub.port
    NATSStub.stop(ctx.stub)
    assert wait_for(fn -> not Connection.connected?(ctx.conn) end)

    for i <- 1..3, do: insert_context(ctx, "d#{i}-#{ctx.n}", "D#{i}")

    assert {:error, :not_connected} = LedgerPublisher.publish_now(pub)
    status = LedgerPublisher.status(pub)
    assert status.state == "buffering"
    assert [%{workspace_id: ws, backlog: backlog}] = status.workspaces
    assert ws == ctx.ws
    assert backlog >= 3

    {:ok, back} = NATSStub.start(port: port)
    on_exit(fn -> NATSStub.stop(back) end)
    assert wait_for(fn -> Connection.connected?(ctx.conn) end, 200)

    # The stub came back empty, as a server that lost its stream: the publisher
    # provisions the stream again and starts from the ledger's beginning.
    assert {:ok, %{published: published}} = LedgerPublisher.publish_now(pub)
    assert published >= 3

    titles =
      for m <- NATSStub.messages(back, "OPTIMAL_LEDGER"),
          %{"entity_type" => "contexts", "payload" => %{"row" => %{"title" => "D" <> _ = t}}} <- [
            Jason.decode!(m.data)
          ],
          do: t

    assert titles == ~w(D1 D2 D3)
    assert %{state: "caught_up", workspaces: [%{backlog: 0}]} = LedgerPublisher.status(pub)
  end

  test "a change the data-class gate keeps home is never published", ctx do
    {:ok, _} =
      Store.raw_query(
        "INSERT INTO source_packages (id, tenant_id, workspace_id, content_hash, raw_text, security_labels) VALUES (?1, ?2, ?3, ?4, 'secret', '[\"restricted\"]')",
        ["sp-#{ctx.n}", ctx.tenant, ctx.ws, "hash-#{ctx.n}"]
      )

    insert_context(ctx, "open-#{ctx.n}", "Open")
    pub = publisher(ctx)
    assert {:ok, _} = LedgerPublisher.publish_now(pub)

    types =
      ctx.stub
      |> NATSStub.messages("OPTIMAL_LEDGER")
      |> Enum.map(&Jason.decode!(&1.data)["entity_type"])

    assert "contexts" in types
    refute "source_packages" in types
    refute Enum.any?(NATSStub.messages(ctx.stub, "OPTIMAL_LEDGER"), &(&1.data =~ "secret"))
  end

  describe "a pass that fails" do
    defp second_workspace(ctx) do
      {:ok, ws} =
        Workspace.create(%{
          tenant_id: ctx.tenant,
          organization_id: "#{ctx.tenant}:org",
          slug: "second",
          name: "Second"
        })

      {:ok, _} = Sync.enable(ctx.tenant, ws.id, "user:owner")
      ws.id
    end

    # Reads a workspace's changes as `Sync.changes/3` does, except `failing`,
    # whose read raises or exits as a seal that fails or times out would.
    defp changes_failing(failing, how) do
      fn tenant, ws, opts ->
        if ws == failing do
          case how do
            :raise -> raise "seal failed"
            :exit -> exit({:timeout, {GenServer, :call, [:seal]}})
          end
        else
          Sync.changes(tenant, ws, opts)
        end
      end
    end

    test "keeps the cursors it moved before the failure", ctx do
      second = second_workspace(ctx)
      insert_context(ctx, "kept-#{ctx.n}", "Kept")
      pub = publisher(ctx, workspaces: [ctx.ws, second], changes: changes_failing(second, :raise))

      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, _} = LedgerPublisher.publish_now(pub)
      end)

      status = LedgerPublisher.status(pub)
      assert status.state == "error"
      first = Enum.find(status.workspaces, &(&1.workspace_id == ctx.ws))
      assert is_integer(first.published_through) and first.published_through > 0
      assert first.backlog == 0
    end

    test "an exit ends the pass, not the publisher, and failures that keep coming are reported",
         ctx do
      pub = publisher(ctx, changes: changes_failing(ctx.ws, :exit))
      pid = Process.whereis(pub)

      ExUnit.CaptureLog.capture_log(fn ->
        for _ <- 1..4, do: assert({:error, _} = LedgerPublisher.publish_now(pub))
        assert LedgerPublisher.health(pub) == :ok

        assert {:error, _} = LedgerPublisher.publish_now(pub)
      end)

      assert Process.whereis(pub) == pid
      assert %{state: "error", consecutive_failures: 5} = LedgerPublisher.status(pub)
      assert {:degraded, 5, _last_error} = LedgerPublisher.health(pub)
    end

    test "a raise on a later page keeps the cursor the earlier pages moved", ctx do
      insert_context(ctx, "paged-#{ctx.n}", "Paged")
      calls = :counters.new(1, [])

      # The first page goes out whole and says there is more; the second
      # holds a change that cannot be encoded, so publishing it raises.
      changes = fn tenant, ws, opts ->
        :counters.add(calls, 1, 1)
        page = Sync.changes(tenant, ws, opts)

        case :counters.get(calls, 1) do
          1 ->
            Map.put(page, "more", true)

          _later ->
            [last | _] = Enum.reverse(page_mutations(tenant, ws))

            bad =
              last
              |> Map.put("id", "unencodable-#{ctx.n}")
              |> Map.put("sequence", last["sequence"] + 1_000_000)
              |> Map.put("payload", {:not, :json})

            %{page | "mutations" => [bad], "more" => false}
        end
      end

      pub = publisher(ctx, changes: changes)

      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, _} = LedgerPublisher.publish_now(pub)
      end)

      status = LedgerPublisher.status(pub)
      assert status.state == "error"
      ws = Enum.find(status.workspaces, &(&1.workspace_id == ctx.ws))
      assert is_integer(ws.published_through) and ws.published_through > 0
      assert ws.backlog == 0
    end

    defp page_mutations(tenant, ws), do: Sync.changes(tenant, ws, since: 0, limit: 200)["mutations"]
  end

  test "a publisher that starts again starts healthy", ctx do
    name = :"nats_ledger_pub_restart_#{ctx.n}"
    key = {LedgerPublisher, :health, name}
    :persistent_term.put(key, {:degraded, 7, "the last run's error"})
    on_exit(fn -> :persistent_term.erase(key) end)

    publisher(ctx, name: name)
    assert LedgerPublisher.health(name) == :ok
  end

  test "off unless the ledger flow is enabled, and the inventory says which" do
    previous = {System.get_env("OPTIMAL_NATS_FLOWS"), System.get_env("OPTIMAL_NATS_URL")}

    on_exit(fn ->
      for {key, value} <- Enum.zip(~w(OPTIMAL_NATS_FLOWS OPTIMAL_NATS_URL), Tuple.to_list(previous)),
          do: if(value, do: System.put_env(key, value), else: System.delete_env(key))
    end)

    System.delete_env("OPTIMAL_NATS_FLOWS")
    System.put_env("OPTIMAL_NATS_URL", "nats://127.0.0.1:1")
    assert NATS.flows() == []
    refute NATS.flow?("ledger")

    System.put_env("OPTIMAL_NATS_FLOWS", "ledger, bogus")
    assert NATS.flows() == ["ledger"]
    assert NATS.flow?("ledger")

    System.put_env("OPTIMAL_NATS_FLOWS", "all")
    assert "ledger" in NATS.flows()

    System.delete_env("OPTIMAL_NATS_URL")
    refute NATS.flow?("ledger")

    assert {:ok, %{runtime: %{flows: %{ledger: %{state: state}}}}} =
             OptimalEngine.Storage.Providers.get("nats_jetstream")

    assert state in ~w(off not_configured)
  end

  test "the namespace names the stream and the subjects, and a bad one is refused" do
    previous = System.get_env("OPTIMAL_NATS_NAMESPACE")

    on_exit(fn ->
      if previous,
        do: System.put_env("OPTIMAL_NATS_NAMESPACE", previous),
        else: System.delete_env("OPTIMAL_NATS_NAMESPACE")
    end)

    System.delete_env("OPTIMAL_NATS_NAMESPACE")
    assert NATS.namespace() == {:ok, "optimal"}
    assert NATS.stream_name("optimal", "LEDGER") == "OPTIMAL_LEDGER"

    System.put_env("OPTIMAL_NATS_NAMESPACE", "eng-a_1")
    assert NATS.namespace() == {:ok, "eng-a_1"}
    assert NATS.stream_name("eng-a_1", "LEDGER") == "ENG-A_1_LEDGER"

    for bad <- ["a.b", "has space", "*", ">", String.duplicate("x", 40), ""] do
      System.put_env("OPTIMAL_NATS_NAMESPACE", bad)
      assert NATS.namespace() == {:error, :invalid_namespace}, bad
    end
  end
end
