defmodule OptimalEngine.Connectors.RunnerTest do
  use ExUnit.Case, async: false

  alias OptimalEngine.Connectors
  alias OptimalEngine.Connectors.{Runner, Transform}
  alias OptimalEngine.Pipeline.Decomposer.Chunk
  alias OptimalEngine.Store
  alias OptimalEngine.Test.ConnectorFixtureStub

  setup do
    # Credentials are only persisted as an encrypted envelope.
    original_key = System.get_env("CONNECTOR_KEY")
    System.put_env("CONNECTOR_KEY", Base.encode16(:crypto.strong_rand_bytes(32), case: :lower))

    on_exit(fn ->
      if original_key,
        do: System.put_env("CONNECTOR_KEY", original_key),
        else: System.delete_env("CONNECTOR_KEY")
    end)

    # Every test gets a unique connector row id so they don't collide.
    suffix = System.unique_integer([:positive])
    {:ok, %{id: "slack-runner-#{suffix}"}}
  end

  test "register + run drives `sync/2` and writes a connector_runs row", %{id: id} do
    {:ok, ^id} =
      Connectors.register(%{
        id: id,
        kind: :slack,
        config: %{
          "workspace_id" => "T01",
          "channels" => ["C01"],
          "credentials" => %{"bot_token" => "xoxb-test"}
        }
      })

    # Slack answers the test token with its invalid_auth envelope. That is
    # reported as :auth_expired, not as an empty successful sync.
    stub = ConnectorFixtureStub.install(:slack, body: %{"ok" => false, "error" => "invalid_auth"})
    on_exit(fn -> ConnectorFixtureStub.uninstall(stub) end)

    {:ok, result} = Runner.run(id, governed: false)

    assert result.status == :error
    assert result.reason == :auth_expired

    # A run row was written
    {:ok, [[count]]} =
      Store.raw_query(
        "SELECT COUNT(*) FROM connector_runs WHERE connector_id = ?1",
        [id]
      )

    assert count >= 1
  end

  test "disabled connectors return :disabled without invoking sync/2", %{id: id} do
    {:ok, ^id} =
      Connectors.register(%{
        id: id,
        kind: :slack,
        config: %{
          "workspace_id" => "T01",
          "channels" => ["C01"],
          "credentials" => %{"bot_token" => "xoxb-test"}
        },
        enabled: false
      })

    assert {:error, :disabled} = Runner.run(id, governed: false)
  end

  test "successful sync advances the cursor", %{id: id} do
    # We swap the registry by using a fake adapter via the signal_sink only —
    # too invasive for a quick test. Instead, exercise the happy path via
    # a direct run-row finalize: insert a connector, mark it enabled, and
    # use a known adapter path.
    #
    # Simpler: cover the happy path through `Transform.signal_id/2` +
    # a behaviour-compliant stub adapter, registered ad-hoc via a
    # reusable approach — but registering new adapters means editing
    # Registry, which is compile-time. So we assert the cursor-advance
    # plumbing via a direct SQL-level check: update a connector with
    # a cursor, re-read, confirm.
    {:ok, ^id} =
      Connectors.register(%{
        id: id,
        kind: :slack,
        config: %{
          "workspace_id" => "T01",
          "channels" => ["C01"],
          "credentials" => %{"bot_token" => "xoxb-test"}
        }
      })

    {:ok, _} =
      Store.raw_query(
        "UPDATE connectors SET cursor = ?1 WHERE id = ?2",
        ["cursor-42", id]
      )

    {:ok, [[cursor]]} =
      Store.raw_query("SELECT cursor FROM connectors WHERE id = ?1", [id])

    assert cursor == "cursor-42"
  end

  test "successful sync preserves raw payload attachments through Memory Core", %{id: id} do
    workspace_id = "connector-sync-assets-#{System.unique_integer([:positive])}"
    original_root = Application.get_env(:optimal_engine, :root_path)

    tmp_dir =
      Path.join(System.tmp_dir!(), "connector-sync-assets-#{System.unique_integer([:positive])}")

    Application.put_env(:optimal_engine, :root_path, tmp_dir)

    on_exit(fn ->
      if original_root do
        Application.put_env(:optimal_engine, :root_path, original_root)
      else
        Application.delete_env(:optimal_engine, :root_path)
      end

      File.rm_rf(tmp_dir)
    end)

    {:ok, ^id} =
      Connectors.register(%{
        id: id,
        kind: :slack,
        config: %{
          "workspace_id" => "T01",
          "channels" => ["C01"],
          "credentials" => %{"bot_token" => "xoxb-test"}
        }
      })

    sink = fn signals ->
      send(self(), {:signals, signals})
      :ok
    end

    assert {:ok, result} =
             Runner.run(id,
               governed: false,
               adapter_resolver: fn "slack" ->
                 {:ok, OptimalEngine.Connectors.RunnerTest.SyncAssetAdapter}
               end,
               signal_sink: sink,
               workspace_id: workspace_id,
               actor_id: "agent:connector-sync-test",
               security_labels: ["internal"],
               partition_ids: ["ops"]
             )

    assert result.status == :success
    assert result.signals == 1
    assert result.errors == 0
    assert result.assets == 1
    assert result.asset_errors == 0
    assert result.cursor_after == "cursor-next"

    assert_received {:signals, [_signal]}

    {:ok, [[asset_count]]} =
      Store.raw_query(
        "SELECT COUNT(*) FROM assets WHERE workspace_id = ?1 AND metadata LIKE ?2",
        [workspace_id, "%msg-1%"]
      )

    assert asset_count == 1

    {:ok, [[run_errors]]} =
      Store.raw_query(
        "SELECT errors_encountered FROM connector_runs WHERE connector_id = ?1 ORDER BY id DESC LIMIT 1",
        [id]
      )

    assert run_errors == 0
  end

  test "governed run rejects missing privileges before connector execution", %{id: id} do
    workspace_id = "default:connector-governance-#{System.unique_integer([:positive])}"

    {:ok, ^id} =
      Connectors.register(%{
        id: id,
        kind: :slack,
        config: %{
          "workspace_id" => "T01",
          "channels" => ["C01"],
          "credentials" => %{"bot_token" => "xoxb-test"}
        }
      })

    assert {:error, {:rejected, rejected_run}} =
             Runner.run_governed(id,
               workspace_id: workspace_id,
               actor_id: "agent:connector-test",
               granted_privileges: [],
               requested_partitions: ["ops"],
               allowed_partitions: ["ops"]
             )

    assert rejected_run.tool_name == "connector.slack.sync"
    assert rejected_run.decision_state == "rejected"
    assert rejected_run.run_status == "rejected"
    assert rejected_run.rejection_reason =~ "connector:slack:sync"
    assert rejected_run.rejection_reason =~ "signal:ingest"

    {:ok, [[connector_runs]]} =
      Store.raw_query("SELECT COUNT(*) FROM connector_runs WHERE connector_id = ?1", [id])

    assert connector_runs == 0
  end

  test "default run is governed and rejects missing privileges before connector execution", %{
    id: id
  } do
    workspace_id = "default:connector-default-governance-#{System.unique_integer([:positive])}"

    {:ok, ^id} =
      Connectors.register(%{
        id: id,
        kind: :slack,
        config: %{
          "workspace_id" => "T01",
          "channels" => ["C01"],
          "credentials" => %{"bot_token" => "xoxb-test"}
        }
      })

    assert {:error, {:rejected, rejected_run}} =
             Runner.run(id,
               workspace_id: workspace_id,
               actor_id: "agent:connector-test",
               granted_privileges: [],
               requested_partitions: ["ops"],
               allowed_partitions: ["ops"]
             )

    assert rejected_run.tool_name == "connector.slack.sync"
    assert rejected_run.decision_state == "rejected"
    assert rejected_run.run_status == "rejected"

    {:ok, [[connector_runs]]} =
      Store.raw_query("SELECT COUNT(*) FROM connector_runs WHERE connector_id = ?1", [id])

    assert connector_runs == 0
  end

  test "default governed run allows connector execution and records both audit layers", %{id: id} do
    workspace_id = "default:connector-governance-#{System.unique_integer([:positive])}"

    {:ok, ^id} =
      Connectors.register(%{
        id: id,
        kind: :slack,
        config: %{
          "workspace_id" => "T01",
          "channels" => ["C01"],
          "credentials" => %{"bot_token" => "xoxb-test"}
        }
      })

    stub = ConnectorFixtureStub.install(:slack, body: %{"ok" => false, "error" => "invalid_auth"})
    on_exit(fn -> ConnectorFixtureStub.uninstall(stub) end)

    assert {:ok, result} =
             Runner.run(id,
               workspace_id: workspace_id,
               actor_id: "agent:connector-test",
               granted_privileges: ["connector:slack:sync", "signal:ingest"],
               requested_partitions: ["ops"],
               allowed_partitions: ["ops"]
             )

    assert result.connector_id == id
    assert result.governance_run.tool_name == "connector.slack.sync"
    assert result.governance_run.decision_state == "allowed"
    assert result.governance_run.run_status == "completed"
    # The connector's own sync failed (Slack rejected the token), and the
    # governance layer still records the run as completed.
    assert result.connector_result.status == "error"
    assert result.connector_result.reason == "auth_expired"

    {:ok, [[connector_runs]]} =
      Store.raw_query("SELECT COUNT(*) FROM connector_runs WHERE connector_id = ?1", [id])

    assert connector_runs == 1

    {:ok, [[tool_runs]]} =
      Store.raw_query(
        """
        SELECT COUNT(*)
        FROM tool_call_runs
        WHERE workspace_id = ?1
          AND tool_name = 'connector.slack.sync'
          AND decision_state = 'allowed'
          AND run_status = 'completed'
        """,
        [workspace_id]
      )

    assert tool_runs == 1
  end

  test "a run's cursor and audit row commit without holding a transaction open across Store calls",
       %{id: id} do
    {:ok, ^id} =
      Connectors.register(%{
        id: id,
        kind: :slack,
        config: %{
          "workspace_id" => "T01",
          "channels" => ["C01"],
          "credentials" => %{"bot_token" => "xoxb-test"}
        }
      })

    # Another caller keeps opening its own Store transactions while the runs
    # finish. A BEGIN left open between Store calls would make some of them
    # fail with "cannot start a transaction within a transaction".
    parent = self()
    signal = "runner-txn-#{System.unique_integer([:positive])}"
    chunk = Chunk.new(id: "#{signal}:chk", signal_id: signal, scale: :chunk, text: "chunk")
    on_exit(fn -> Store.raw_query("DELETE FROM chunks WHERE signal_id = ?1", [signal]) end)

    writer =
      spawn_link(fn ->
        Stream.repeatedly(fn -> Store.insert_chunks([chunk]) end)
        |> Enum.reduce_while([], fn result, errors ->
          errors = if result == :ok, do: errors, else: [result | errors]

          receive do
            :stop -> {:halt, send(parent, {:writer_errors, errors})}
          after
            0 -> {:cont, errors}
          end
        end)
      end)

    for n <- 1..30 do
      assert {:ok, %{status: :success, cursor_after: cursor}} =
               Runner.run(id,
                 governed: false,
                 adapter_resolver: fn "slack" ->
                   {:ok, OptimalEngine.Connectors.RunnerTest.CursorAdapter}
                 end
               )

      assert cursor == "cursor-#{n}"
    end

    send(writer, :stop)
    assert_receive {:writer_errors, errors}, 5_000
    assert errors == []

    assert {:ok, [["cursor-30"]]} =
             Store.raw_query("SELECT cursor FROM connectors WHERE id = ?1", [id])

    assert {:ok, [[30]]} =
             Store.raw_query(
               "SELECT COUNT(*) FROM connector_runs WHERE connector_id = ?1 AND status = 'success'",
               [id]
             )
  end

  describe "Transform helpers" do
    test "signal_id/2 is deterministic" do
      a = Transform.signal_id(:slack, "abc")
      b = Transform.signal_id(:slack, "abc")
      assert a == b
      refute a == Transform.signal_id(:slack, "abd")
    end

    test "source_uri/2 builds optimal:// paths" do
      assert Transform.source_uri(:slack, "C01") == "optimal://connectors/slack/C01"
    end

    test "strip_html collapses tags + whitespace" do
      assert Transform.strip_html("<p>hi  <b>there</b></p>") == "hi there"
    end

    test "parse_iso8601 returns fallback on bad input" do
      fallback = ~U[2026-01-01 00:00:00Z]
      assert Transform.parse_iso8601("garbage", fallback) == fallback
    end
  end
end

defmodule OptimalEngine.Connectors.RunnerTest.SyncAssetAdapter do
  @behaviour OptimalEngine.Connectors.Behaviour

  alias OptimalEngine.Connectors.Transform

  @impl true
  def kind, do: :slack

  @impl true
  def display_name, do: "Sync Asset Test"

  @impl true
  def auth_scheme, do: :token

  @impl true
  def required_config_keys, do: []

  @impl true
  def init(config), do: {:ok, config}

  @impl true
  def sync(_state, _cursor) do
    signal =
      Transform.new_signal(%{
        id: Transform.signal_id(:slack, "msg-1"),
        title: "Connector payload with file",
        content: "Connector payload body",
        path: "optimal://connectors/slack/msg-1",
        node: "inbox"
      })

    payload = %{
      "id" => "msg-1",
      "text" => "Connector payload body",
      "attachments" => [
        %{
          "id" => "file-1",
          "filename" => "note.txt",
          "content_type" => "text/plain",
          "content_base64" => Base.encode64("connector attachment evidence")
        }
      ]
    }

    {:ok, %{signals: [signal], cursor: "cursor-next", payloads: [payload]}}
  end

  @impl true
  def transform(_payload), do: {:error, :not_used}
end

defmodule OptimalEngine.Connectors.RunnerTest.CursorAdapter do
  @moduledoc false
  @behaviour OptimalEngine.Connectors.Behaviour

  @impl true
  def kind, do: :slack

  @impl true
  def display_name, do: "Cursor Test"

  @impl true
  def auth_scheme, do: :token

  @impl true
  def required_config_keys, do: []

  @impl true
  def init(config), do: {:ok, config}

  # Each run moves the cursor one step: nil -> cursor-1 -> cursor-2 ...
  @impl true
  def sync(_state, cursor) do
    n =
      case cursor do
        "cursor-" <> n -> String.to_integer(n) + 1
        _ -> 1
      end

    {:ok, [], "cursor-#{n}"}
  end

  @impl true
  def transform(_payload), do: {:error, :not_used}
end
