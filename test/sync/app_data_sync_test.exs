defmodule OptimalEngine.Sync.AppDataSyncTest do
  @moduledoc """
  App Data in replication and in workspace bundles: collections, their schema
  changes and migrations, and records move between Engines through the ledger,
  each change replayed through App Data on the receiver (its own collection
  tables, its own validation, the record's version as the base of the change).

  One test database stands in for two Engines: workspace A is one Engine's copy
  of the workspace and workspace B the other's. A change is shipped from one to
  the other as a peer would send it: the sender's own ledger rows, under the
  sender's device id.
  """

  use ExUnit.Case, async: false

  alias OptimalEngine.{AppData, Store, Sync, Workspace}
  alias OptimalEngine.AppData.Scope
  alias OptimalEngine.Portability.WorkspaceBundle
  alias OptimalEngine.Sync.Capture
  alias OptimalEngine.Tenancy.Tenant

  setup do
    n = System.unique_integer([:positive])
    tenant = "appsync-#{n}"
    {:ok, _} = Tenant.create(%{id: tenant, name: "App sync #{n}"})

    {:ok, _} =
      OptimalEngine.Organization.create(%{
        id: "#{tenant}:org",
        tenant_id: tenant,
        slug: "org",
        name: "Org"
      })

    workspace = fn slug ->
      {:ok, ws} =
        Workspace.create(%{
          tenant_id: tenant,
          organization_id: "#{tenant}:org",
          slug: slug,
          name: slug
        })

      {:ok, _} = Sync.enable(tenant, ws.id, "user:owner")
      ws.id
    end

    ctx = %{tenant: tenant, n: n, a: workspace.("laptop"), b: workspace.("cloud")}
    # How far each direction has shipped, in the sender's ledger.
    Process.put(:shipped, %{})
    ctx
  end

  defp scope(ctx, ws, actor \\ "user:ada"),
    do: Scope.new(tenant_id: ctx.tenant, workspace_id: ws, actor: actor)

  defp tasks do
    %{
      "name" => "tasks",
      "fields" => [
        %{"name" => "title", "type" => "string", "required" => true},
        %{"name" => "done", "type" => "boolean", "default" => false},
        %{"name" => "priority", "type" => "integer", "default" => 3},
        %{"name" => "project", "type" => "reference", "references" => "projects"}
      ],
      "indexes" => [%{"fields" => ["done"]}],
      "search" => %{"text" => ["title"]}
    }
  end

  defp projects do
    %{
      "name" => "projects",
      "fields" => [%{"name" => "name", "type" => "string", "required" => true, "unique" => true}]
    }
  end

  # Sends the App Data changes `from` made since the last shipment to `to`, as the
  # peer `device` would: this Engine's own ledger rows, renamed into the peer's id
  # space (one database cannot hold one mutation id for two workspaces).
  defp ship(ctx, from, to, device) do
    local = Sync.replica_id()
    since = Map.get(Process.get(:shipped), {from, to}, 0)
    page = Sync.changes(ctx.tenant, from, since: since, limit: 2_000)
    Process.put(:shipped, Map.put(Process.get(:shipped), {from, to}, page["cursor"]))

    mutations =
      for m <- page["mutations"], m["device_id"] == local, m["entity_type"] == "data_changes" do
        %{m | "id" => "mut_#{device}_#{ctx.n}_#{m["id"]}", "device_id" => device}
        |> Map.put("idempotency_key", nil)
      end

    {:ok, result} = Sync.apply_changes(ctx.tenant, to, mutations)
    Map.put(result, :sent, length(mutations))
  end

  defp record(ctx, ws, collection, id) do
    {:ok, record} = AppData.get(scope(ctx, ws), collection, id)
    Map.take(record, ["id", "version", "data", "created_by", "updated_by"])
  end

  defp changes_of(ws, record_id) do
    {:ok, rows} =
      Store.raw_query(
        "SELECT op, version, actor, origin_replica FROM data_changes WHERE workspace_id = ?1 AND record_id = ?2 ORDER BY seq",
        [ws, record_id]
      )

    rows
  end

  defp app_conflicts(ctx, ws),
    do: ctx.tenant |> Sync.conflicts(ws) |> Enum.filter(&(&1.table == "data_changes"))

  describe "replication" do
    test "collections and records made on one Engine arrive on the other with the same ids and versions, and an edit there comes back",
         ctx do
      a = scope(ctx, ctx.a)
      {:ok, _} = AppData.create_collection(a, projects())
      {:ok, _} = AppData.create_collection(a, tasks())
      {:ok, %{"id" => p}} = AppData.create(a, "projects", %{"data" => %{"name" => "Launch"}})

      {:ok, %{"id" => t}} =
        AppData.create(a, "tasks", %{
          "id" => "task-1",
          "data" => %{"title" => "Draft", "project" => p}
        })

      {:ok, _} = AppData.update(a, "tasks", t, %{"data" => %{"priority" => 1}, "version" => 1})

      shipped = ship(ctx, ctx.a, ctx.b, "rep_laptop")
      assert shipped.sent == 5
      assert shipped.applied == 5
      assert shipped.failed == []
      assert shipped.conflicts == 0

      {:ok, collections} = AppData.list_collections(scope(ctx, ctx.b))
      assert Enum.map(collections, & &1["name"]) == ["projects", "tasks"]

      assert record(ctx, ctx.b, "tasks", "task-1") == record(ctx, ctx.a, "tasks", "task-1")

      assert %{"version" => 2, "data" => %{"title" => "Draft", "priority" => 1, "project" => ^p}} =
               record(ctx, ctx.b, "tasks", "task-1")

      assert record(ctx, ctx.b, "projects", p) == record(ctx, ctx.a, "projects", p)

      # The receiver's change feed says who made each change, and on which Engine.
      assert changes_of(ctx.b, "task-1") == [
               ["create", 1, "user:ada", "rep_laptop"],
               ["update", 2, "user:ada", "rep_laptop"]
             ]

      # Its search index is its own, filled as the records were written.
      {:ok, %{"records" => found}} =
        AppData.query(scope(ctx, ctx.b), "tasks", %{"search" => "draft"})

      assert Enum.map(found, & &1["id"]) == ["task-1"]

      # Nothing applied is captured again on the receiver, so nothing echoes back.
      {:ok, _} = Capture.seal()
      assert ship(ctx, ctx.b, ctx.a, "rep_cloud").sent == 0

      b = scope(ctx, ctx.b, "user:grace")

      {:ok, _} =
        AppData.update(b, "tasks", "task-1", %{"data" => %{"done" => true}, "version" => 2})

      back = ship(ctx, ctx.b, ctx.a, "rep_cloud")
      assert back.applied == 1

      assert %{"version" => 3, "updated_by" => "user:grace", "data" => %{"done" => true}} =
               record(ctx, ctx.a, "tasks", "task-1")

      assert List.last(changes_of(ctx.a, "task-1")) == ["update", 3, "user:grace", "rep_cloud"]

      {:ok, _} = AppData.delete(a, "tasks", "task-1", %{"version" => 3})
      assert ship(ctx, ctx.a, ctx.b, "rep_laptop").applied == 1
      assert {:error, {:not_found, _}} = AppData.get(scope(ctx, ctx.b), "tasks", "task-1")
    end

    test "a schema change and an app migration arrive before the records that need them, and a deploy of the same migrations there is a no-op",
         ctx do
      a = scope(ctx, ctx.a)

      migrations = %{
        "app" => "todo",
        "migrations" => [
          %{
            "version" => 1,
            "name" => "projects",
            "operations" => [%{"op" => "create_collection", "collection" => projects()}]
          },
          %{
            "version" => 2,
            "name" => "owner",
            "operations" => [
              %{
                "op" => "alter_collection",
                "name" => "projects",
                "operations" => [
                  %{"op" => "add_field", "field" => %{"name" => "lead", "type" => "string"}}
                ]
              }
            ]
          }
        ]
      }

      {:ok, %{"applied" => [1, 2]}} = AppData.migrate(a, migrations)

      {:ok, _} =
        AppData.alter_collection(a, "projects", [
          %{"op" => "add_field", "field" => %{"name" => "budget", "type" => "integer"}}
        ])

      {:ok, _} =
        AppData.create(a, "projects", %{
          "id" => "p-1",
          "data" => %{"name" => "Launch", "lead" => "ada", "budget" => 10}
        })

      shipped = ship(ctx, ctx.a, ctx.b, "rep_laptop")
      assert shipped.failed == []
      assert shipped.conflicts == 0

      b = scope(ctx, ctx.b)
      {:ok, described} = AppData.describe_collection(b, "projects")
      assert described["schema_version"] == 3
      assert Enum.map(described["fields"], & &1["name"]) == ["name", "lead", "budget"]

      assert %{"version" => 1, "data" => %{"lead" => "ada", "budget" => 10}} =
               record(ctx, ctx.b, "projects", "p-1")

      {:ok, on_a} = AppData.migrations(a, "todo")
      {:ok, on_b} = AppData.migrations(b, "todo")

      assert Enum.map(on_b, &Map.take(&1, ["version", "name", "checksum"])) ==
               Enum.map(on_a, &Map.take(&1, ["version", "name", "checksum"]))

      # The app deploys its migrations to the other Engine as well: both are applied.
      assert {:ok, %{"applied" => [], "skipped" => [1, 2]}} = AppData.migrate(b, migrations)
    end

    test "a record that fails the receiver's schema is not applied: it is a conflict with the reason, and the rest of the batch applies",
         ctx do
      a = scope(ctx, ctx.a)
      {:ok, _} = AppData.create_collection(a, projects())
      {:ok, _} = AppData.create_collection(a, tasks())
      assert ship(ctx, ctx.a, ctx.b, "rep_laptop").applied == 2

      # The receiver's copy of the collection has changed on its own.
      {:ok, _} =
        AppData.alter_collection(scope(ctx, ctx.b), "tasks", [
          %{"op" => "drop_field", "name" => "priority", "confirm" => true}
        ])

      {:ok, _} = AppData.create(a, "tasks", %{"id" => "t-1", "data" => %{"title" => "Draft"}})
      {:ok, _} = AppData.create(a, "projects", %{"id" => "p-1", "data" => %{"name" => "Launch"}})

      shipped = ship(ctx, ctx.a, ctx.b, "rep_laptop")
      assert shipped.sent == 2
      assert shipped.applied == 1
      assert shipped.conflicts == 1

      assert {:error, {:not_found, _}} = AppData.get(scope(ctx, ctx.b), "tasks", "t-1")
      assert %{"version" => 1} = record(ctx, ctx.b, "projects", "p-1")

      assert [conflict] = app_conflicts(ctx, ctx.b)
      assert conflict.kind == "schema_invalid"
      assert conflict.resolution == "not_applied"
      assert conflict.entity_key == "tasks/t-1"
      assert conflict.remote_device == "rep_laptop"
      assert conflict.detail["errors"] == ["unknown fields: priority"]
    end

    test "a change whose base version is not the receiver's is a version conflict, and the receiver keeps its record",
         ctx do
      a = scope(ctx, ctx.a)
      b = scope(ctx, ctx.b, "user:grace")
      {:ok, _} = AppData.create_collection(a, projects())
      {:ok, _} = AppData.create(a, "projects", %{"id" => "p-1", "data" => %{"name" => "Launch"}})
      assert ship(ctx, ctx.a, ctx.b, "rep_laptop").applied == 2

      # Both Engines edit version 1 before either hears of the other's edit.
      {:ok, _} = AppData.update(a, "projects", "p-1", %{"data" => %{"name" => "Go live"}})
      {:ok, _} = AppData.update(b, "projects", "p-1", %{"data" => %{"name" => "Ship it"}})

      shipped = ship(ctx, ctx.a, ctx.b, "rep_laptop")
      assert shipped.applied == 0
      assert shipped.conflicts == 1

      assert %{"version" => 2, "data" => %{"name" => "Ship it"}} =
               record(ctx, ctx.b, "projects", "p-1")

      assert [conflict] = app_conflicts(ctx, ctx.b)
      assert conflict.kind == "version_conflict"
      assert conflict.resolution == "kept_local"
      assert conflict.entity_key == "projects/p-1"
      assert conflict.detail["base_version"] == 1
      assert conflict.detail["local_version"] == 2
      assert conflict.local["record"]["data"]["name"] == "Ship it"

      # Shipped again, the same change is judged the same way and recorded once.
      Process.put(:shipped, %{})
      assert ship(ctx, ctx.a, ctx.b, "rep_laptop").applied == 0
      assert length(app_conflicts(ctx, ctx.b)) == 1
    end
  end

  describe "what a peer's app data change cannot do" do
    test "a change is checked and replayed through app data, never written as it came", ctx do
      {:ok, _} = AppData.create_collection(scope(ctx, ctx.b), projects())
      {:ok, [[before]]} = Store.raw_query("SELECT COUNT(*) FROM data_changes", [])

      forged = fn i, operation, row ->
        %{
          "id" => "mut_rep_evil_#{ctx.n}_#{i}",
          "device_id" => "rep_evil",
          "entity_type" => "data_changes",
          "entity_id" => "row:#{i}",
          "operation" => operation,
          "occurred_at" => "2026-11-24T10:00:00.000Z",
          "payload" => %{"row" => row, "blobs" => %{}}
        }
      end

      record = fn id ->
        Jason.encode!(%{
          "id" => id,
          "version" => 1,
          "created_at" => "2026-11-24T10:00:00.000Z",
          "updated_at" => "2026-11-24T10:00:00.000Z",
          "data" => %{"name" => "Evil"}
        })
      end

      evil_field = ~s(x" TEXT, "y)

      evil_schema =
        Jason.encode!(%{
          "action" => "create",
          "schema_version" => 1,
          "schema" => %{
            "fields" => [%{"name" => evil_field, "type" => "string"}],
            "indexes" => [],
            "owner_field" => nil,
            "search" => %{}
          }
        })

      row = fn attrs ->
        Map.merge(%{"collection" => "projects", "op" => "create", "version" => 1}, attrs)
      end

      mutations = [
        # A collection name is an identifier.
        forged.(
          1,
          "create",
          row.(%{"collection" => ~s(projects"), "record_id" => "r-1", "data" => record.("r-1")})
        ),
        # The feed records inserts only.
        forged.(2, "delete", %{"seq" => 1}),
        # A column the feed does not have.
        forged.(3, "create", row.(%{"record_id" => "r-3", "table_name" => "contexts"})),
        # A schema is checked as a definition is.
        forged.(4, "create", %{"collection" => "evil", "op" => "schema", "data" => evil_schema}),
        # A record must be the one the change names.
        forged.(5, "create", row.(%{"record_id" => "r-5", "data" => record.("r-other")}))
      ]

      assert {:ok, result} = Sync.apply_changes(ctx.tenant, ctx.b, mutations)
      assert result.applied == 0

      assert Enum.map(result.failed, & &1.reason) == [
               :invalid_app_data_change,
               :operation_not_supported,
               :unknown_columns,
               inspect(
                 {:validation, ["field name #{inspect(evil_field)} is not a valid identifier"]}
               ),
               :invalid_app_data_change
             ]

      assert {:error, {:not_found, _}} = AppData.describe_collection(scope(ctx, ctx.b), "evil")

      assert {:ok, %{"record_count" => 0}} =
               AppData.describe_collection(scope(ctx, ctx.b), "projects")

      assert {:ok, [[^before]]} = Store.raw_query("SELECT COUNT(*) FROM data_changes", [])
    end
  end

  describe "workspace bundles" do
    test "a bundle carries the workspace's collections and records, and the import makes its own tables for them",
         ctx do
      a = scope(ctx, ctx.a)
      {:ok, _} = AppData.create_collection(a, projects())
      {:ok, _} = AppData.create_collection(a, tasks())
      {:ok, _} = AppData.create(a, "projects", %{"id" => "p-1", "data" => %{"name" => "Launch"}})

      {:ok, _} =
        AppData.create(a, "tasks", %{
          "id" => "t-1",
          "data" => %{"title" => "Draft the plan", "project" => "p-1"}
        })

      {:ok, _} = AppData.update(a, "tasks", "t-1", %{"data" => %{"done" => true}})

      {:ok, %{"id" => file_id}} =
        AppData.upload_file(a, "tasks", "t-1", %{
          "filename" => "plan.txt",
          "content_base64" => Base.encode64("the plan"),
          "content_type" => "text/plain"
        })

      path = Path.join(System.tmp_dir!(), "appdata-bundle-#{ctx.n}.tar.gz")
      on_exit(fn -> File.rm(path) end)
      task_before = record(ctx, ctx.a, "tasks", "t-1")
      project_before = record(ctx, ctx.a, "projects", "p-1")

      {:ok, [[source_table]]} =
        Store.raw_query(
          "SELECT table_name FROM data_collections WHERE workspace_id = ?1 AND name = 'tasks'",
          [ctx.a]
        )

      {:ok, manifest} = WorkspaceBundle.export(ctx.tenant, ctx.a, path)
      # Ids are unique per Engine, so the workspace moves out before it is
      # seeded back in under a new id, as a move between Engines does.
      :ok = WorkspaceBundle.prepare_move(ctx.tenant, ctx.a, manifest["bundle_sha256"])

      {:ok, _} =
        WorkspaceBundle.finalize_move(ctx.tenant, ctx.a, manifest["bundle_sha256"], %{
          "target_url" => "https://other.example"
        })

      target = "#{ctx.tenant}:seeded"
      assert {:ok, summary} = WorkspaceBundle.import(path, ctx.tenant, workspace_id: target)
      assert summary.app_data == %{"projects" => 1, "tasks" => 1}

      seeded = scope(ctx, target)
      {:ok, collections} = AppData.list_collections(seeded)

      assert Enum.map(collections, &{&1["name"], &1["schema_version"]}) == [
               {"projects", 1},
               {"tasks", 1}
             ]

      assert record(ctx, target, "tasks", "t-1") == task_before
      assert %{"version" => 2, "data" => %{"done" => true}} = record(ctx, target, "tasks", "t-1")
      assert record(ctx, target, "projects", "p-1") == project_before

      {:ok, %{"records" => found}} = AppData.query(seeded, "tasks", %{"search" => "plan"})
      assert Enum.map(found, & &1["id"]) == ["t-1"]

      # The record's file comes with it, linked to the seeded copy's collection.
      assert {:ok, [%{"id" => ^file_id, "filename" => "plan.txt"}]} =
               AppData.list_files(seeded, "tasks", "t-1")

      assert {:ok, %{path: file_path}} = AppData.open_file(seeded, "tasks", "t-1", file_id)
      assert File.read!(file_path) == "the plan"

      # The seeded copy's tables are its own, not the source's.
      {:ok, [[seeded_table]]} =
        Store.raw_query(
          "SELECT table_name FROM data_collections WHERE workspace_id = ?1 AND name = 'tasks'",
          [target]
        )

      assert seeded_table != source_table

      # A record written on the seeded copy goes on from the bundled version.
      {:ok, %{"version" => 3}} =
        AppData.update(seeded, "tasks", "t-1", %{"data" => %{"priority" => 1}, "version" => 2})
    end

    test "the table a bundle names for a collection is never used: the import makes its own",
         ctx do
      {:ok, _} = AppData.create_collection(scope(ctx, ctx.a), projects())
      {:ok, _} = AppData.create(scope(ctx, ctx.a), "projects", %{"data" => %{"name" => "Launch"}})
      path = Path.join(System.tmp_dir!(), "appdata-forged-#{ctx.n}.tar.gz")
      on_exit(fn -> File.rm(path) end)
      {:ok, _manifest} = WorkspaceBundle.export(ctx.tenant, ctx.a, path)

      forged = forge(path, "tables/data_collections.jsonl", &Map.put(&1, "table_name", "contexts"))
      on_exit(fn -> File.rm(forged) end)

      target = "#{ctx.tenant}:forged"
      assert {:ok, _summary} = WorkspaceBundle.import(forged, ctx.tenant, workspace_id: target)

      {:ok, [[table]]} =
        Store.raw_query("SELECT table_name FROM data_collections WHERE workspace_id = ?1", [target])

      assert "appdata_" <> _ = table
      {:ok, %{"record_count" => 1}} = AppData.describe_collection(scope(ctx, target), "projects")
    end

    # SQLite's catalog lists the collections' tables.
    @tag :sqlite_store
    test "an import that fails after it made collections takes them back with their tables", ctx do
      a = scope(ctx, ctx.a)
      {:ok, _} = AppData.create_collection(a, projects())
      {:ok, _} = AppData.create_collection(a, tasks())
      {:ok, _} = AppData.create(a, "projects", %{"id" => "p-1", "data" => %{"name" => "Launch"}})
      {:ok, _} = AppData.create(a, "tasks", %{"id" => "t-1", "data" => %{"title" => "Draft"}})
      path = Path.join(System.tmp_dir!(), "appdata-undo-#{ctx.n}.tar.gz")
      on_exit(fn -> File.rm(path) end)
      {:ok, _manifest} = WorkspaceBundle.export(ctx.tenant, ctx.a, path)

      # The second collection's records name a column it does not have.
      forged = forge(path, "app_data/tasks.jsonl", &Map.put(&1, "f_evil", "x"))
      on_exit(fn -> File.rm(forged) end)
      before = collection_tables()

      target = "#{ctx.tenant}:undone"

      assert {:error, {:import_failed, "data_collections", {:unknown_columns, "tasks"}}} =
               WorkspaceBundle.import(forged, ctx.tenant, workspace_id: target)

      assert collection_tables() == before
      assert {:error, _} = Workspace.get(target)

      assert {:ok, []} =
               Store.raw_query("SELECT id FROM data_collections WHERE workspace_id = ?1", [target])
    end
  end

  # Rewrites one file of the bundle with `fun` and signs the manifest again, as
  # anyone can: what a bundle says is checked, not trusted.
  defp forge(path, file, fun) do
    dir = Path.join(System.tmp_dir!(), "appdata-forge-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    :ok = :erl_tar.extract(String.to_charlist(path), [:compressed, {:cwd, String.to_charlist(dir)}])

    rows =
      Path.join(dir, file)
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&(&1 |> Jason.decode!() |> fun.() |> Jason.encode!()))
      |> Enum.map_join(&(&1 <> "\n"))

    File.write!(Path.join(dir, file), rows)
    sha = :crypto.hash(:sha256, rows) |> Base.encode16(case: :lower)

    resign = fn entries, key, name ->
      Enum.map(entries, &if(&1[key] == name, do: Map.put(&1, "sha256", sha), else: &1))
    end

    manifest_path = Path.join(dir, "manifest.json")
    manifest = manifest_path |> File.read!() |> Jason.decode!()

    manifest =
      case Path.split(file) do
        ["tables", name] ->
          Map.update!(manifest, "tables", &resign.(&1, "name", Path.rootname(name)))

        ["app_data", name] ->
          Map.update!(manifest, "app_data", &resign.(&1, "collection", Path.rootname(name)))
      end
      |> Map.delete("bundle_sha256")
      |> then(&Map.put(&1, "bundle_sha256", OptimalEngine.Authority.CanonicalJSON.hash(&1)))

    File.write!(manifest_path, Jason.encode!(manifest))

    forged = dir <> ".tar.gz"
    entries = dir |> File.ls!() |> Enum.map(&String.to_charlist/1)

    :ok =
      File.cd!(dir, fn -> :erl_tar.create(String.to_charlist(forged), entries, [:compressed]) end)

    File.rm_rf!(dir)
    forged
  end

  defp collection_tables do
    {:ok, rows} =
      Store.raw_query(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE 'appdata\\_%' ESCAPE '\\' AND name NOT LIKE '%\\_fts%' ESCAPE '\\'",
        []
      )

    rows |> List.flatten() |> Enum.sort()
  end
end
