defmodule Mix.Tasks.Optimal.ConnectorTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias OptimalEngine.Store

  @secret "example-cli-connector-secret"

  setup do
    Mix.Task.reenable("optimal.connector")

    original_key = System.get_env("CONNECTOR_KEY")
    System.put_env("CONNECTOR_KEY", Base.encode16(:crypto.strong_rand_bytes(32), case: :lower))

    on_exit(fn ->
      if original_key,
        do: System.put_env("CONNECTOR_KEY", original_key),
        else: System.delete_env("CONNECTOR_KEY")
    end)

    suffix = System.unique_integer([:positive])
    workspace = insert_workspace("default:cli-conn-#{suffix}", "active")
    archived = insert_workspace("default:cli-old-#{suffix}", "archived")

    root = Path.join(System.tmp_dir!(), "oe-cli-connector-#{suffix}")
    File.mkdir_p!(root)
    File.write!(Path.join(root, "note.md"), "# CLI note #{suffix}\n\nPulled from the command line.")

    config_path = Path.join(root, "config.json")

    File.write!(
      config_path,
      Jason.encode!(%{"root" => root, "credentials" => %{"token" => @secret}})
    )

    on_exit(fn -> File.rm_rf!(root) end)

    {:ok, suffix: suffix, workspace: workspace, archived: archived, config: config_path, root: root}
  end

  test "register puts the connector in the named workspace", ctx do
    id = "cli-folder-#{ctx.suffix}"

    output =
      connector([
        "register",
        id,
        "--kind",
        "sources_folder",
        "--config",
        ctx.config,
        "--workspace",
        ctx.workspace
      ])

    assert output =~ "Registered connector #{id}"
    assert output =~ ctx.workspace

    {:ok, [[workspace, enabled]]} =
      Store.raw_query("SELECT workspace_id, enabled FROM connectors WHERE id = ?1", [id])

    assert workspace == ctx.workspace
    assert enabled == 1
  end

  test "register --disabled stores a disabled row", ctx do
    id = "cli-disabled-#{ctx.suffix}"

    connector([
      "register",
      id,
      "--kind",
      "sources_folder",
      "--config",
      ctx.config,
      "--workspace",
      ctx.workspace,
      "--disabled"
    ])

    {:ok, [[0]]} = Store.raw_query("SELECT enabled FROM connectors WHERE id = ?1", [id])
  end

  test "register needs a workspace that exists and is active", ctx do
    args = ["register", "cli-x-#{ctx.suffix}", "--kind", "sources_folder", "--config", ctx.config]

    assert_raise Mix.Error, ~r/--workspace/, fn -> connector(args) end

    assert_raise Mix.Error, ~r/workspace_archived/, fn ->
      connector(args ++ ["--workspace", ctx.archived])
    end

    assert_raise Mix.Error, ~r/workspace_not_found/, fn ->
      connector(args ++ ["--workspace", "default:nowhere-#{ctx.suffix}"])
    end
  end

  test "list shows rows with workspace, state and last run, never credentials", ctx do
    id = "cli-listed-#{ctx.suffix}"

    connector([
      "register",
      id,
      "--kind",
      "sources_folder",
      "--config",
      ctx.config,
      "--workspace",
      ctx.workspace
    ])

    run_output = connector(["run", id])
    assert run_output =~ "success"
    assert run_output =~ "signals:      1"

    output = connector(["list", "--workspace", ctx.workspace])
    assert output =~ id
    assert output =~ ctx.workspace
    assert output =~ "enabled"
    assert output =~ "success"
    refute output =~ @secret
    refute output =~ "ciphertext"
  end

  test "run drives the signals into the connector's workspace", ctx do
    id = "cli-run-#{ctx.suffix}"

    connector([
      "register",
      id,
      "--kind",
      "sources_folder",
      "--config",
      ctx.config,
      "--workspace",
      ctx.workspace
    ])

    connector(["run", id])

    {:ok, [[n]]} =
      Store.raw_query(
        "SELECT COUNT(*) FROM contexts WHERE workspace_id = ?1 AND title = ?2",
        [ctx.workspace, "CLI note #{ctx.suffix}"]
      )

    assert n >= 1
  end

  test "adapters lists the adapter catalog" do
    output = connector(["adapters"])
    assert output =~ "gmail"
    assert output =~ "sources_folder"
  end

  defp connector(args) do
    Mix.Task.reenable("optimal.connector")
    capture_io(fn -> Mix.Tasks.Optimal.Connector.run(args) end)
  end

  defp insert_workspace(id, status) do
    {:ok, _} =
      Store.raw_query(
        """
        INSERT INTO workspaces (id, tenant_id, slug, name, status, metadata)
        VALUES (?1, 'default', ?2, ?3, ?4, '{}')
        """,
        [id, id |> String.split(":") |> List.last(), "WS #{id}", status]
      )

    id
  end
end
