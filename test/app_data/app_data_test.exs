defmodule OptimalEngine.AppDataTest do
  use ExUnit.Case, async: false

  alias OptimalEngine.AppData
  alias OptimalEngine.AppData.Scope

  defmodule FakeEmbedder do
    @moduledoc false
    # Deterministic bag-of-words vectors: one dimension per vocabulary word.
    @vocabulary ~w(money budget invoice payment cat dog pet garden plant flower report)

    def embed("probe", _opts), do: {:ok, List.duplicate(1.0, length(@vocabulary))}

    def embed(text, _opts) do
      words = ~r/[a-z]+/ |> Regex.scan(String.downcase(text)) |> List.flatten()
      {:ok, Enum.map(@vocabulary, fn w -> if w in words, do: 1.0, else: 0.0 end)}
    end
  end

  defmodule DownEmbedder do
    @moduledoc false
    def embed(_text, _opts), do: {:error, :econnrefused}
  end

  defp workspace, do: "default:apps-#{System.unique_integer([:positive])}"

  defp scope(workspace, opts \\ []) do
    Scope.new(
      Keyword.merge([tenant_id: "default", workspace_id: workspace, actor: "local:operator"], opts)
    )
  end

  defp tasks_definition do
    %{
      "name" => "tasks",
      "fields" => [
        %{"name" => "title", "type" => "string", "required" => true, "max_length" => 200},
        %{"name" => "notes", "type" => "text"},
        %{"name" => "done", "type" => "boolean", "default" => false},
        %{"name" => "due", "type" => "datetime"},
        %{"name" => "priority", "type" => "integer", "default" => 3},
        %{"name" => "owner", "type" => "string"},
        %{"name" => "tags", "type" => "json"}
      ],
      "owner_field" => "owner",
      "indexes" => [%{"fields" => ["owner", "done", "due"]}],
      "search" => %{"text" => ["title", "notes"], "semantic" => ["title"]}
    }
  end

  defp setup_tasks(ws) do
    {:ok, _} = AppData.create_collection(scope(ws), tasks_definition())
    scope(ws)
  end

  defp due(i) do
    ~U[2026-11-01 09:00:00Z]
    |> DateTime.add(i * 3_600, :second)
    |> OptimalEngine.AppData.Schema.format_datetime()
  end

  defp seed_tasks(s, count) do
    records =
      for i <- 1..count do
        %{
          "data" => %{
            "title" => "task #{i}",
            "owner" => if(rem(i, 2) == 0, do: "user-a", else: "user-b"),
            "done" => rem(i, 5) == 0,
            "due" => due(rem(i * 7919, count)),
            "priority" => rem(i, 4)
          }
        }
      end

    {:ok, result} = AppData.bulk_create(s, "tasks", records)
    result
  end

  describe "acceptance: tasks app" do
    test "1,000 tasks; open tasks for one owner sorted by due date, paged by cursor" do
      ws = workspace()
      s = setup_tasks(ws)
      %{results: results} = seed_tasks(s, 1_000)
      assert length(results) == 1_000

      expected =
        for i <- 1..1_000, rem(i, 2) == 0, rem(i, 5) != 0, do: due(rem(i * 7919, 1_000))

      spec = %{
        "where" => %{"owner" => "user-a", "done" => false},
        "sort" => ["due"],
        "limit" => 37,
        "count" => true
      }

      {pages, dues} = page_all(s, spec, [], [])
      assert length(dues) == length(expected)
      assert dues == Enum.sort(expected)
      assert length(Enum.uniq(dues)) == length(dues)
      assert pages == ceil(length(expected) / 37)

      {:ok, first} = AppData.query(s, "tasks", spec)
      assert first["count"] == length(expected)
      assert first["has_more"]
    end

    test "an update with a stale version is rejected and changes nothing" do
      s = setup_tasks(workspace())
      {:ok, task} = AppData.create(s, "tasks", %{"data" => %{"title" => "write report"}})
      assert task["version"] == 1

      {:ok, updated} =
        AppData.update(s, "tasks", task["id"], %{"data" => %{"done" => true}, "version" => 1})

      assert updated["version"] == 2

      assert {:error, {:conflict, "version_conflict", %{"current_version" => 2}}} =
               AppData.update(s, "tasks", task["id"], %{"data" => %{"title" => "x"}, "version" => 1})

      {:ok, current} = AppData.get(s, "tasks", task["id"])
      assert current["version"] == 2
      assert current["data"]["title"] == "write report"
      assert current["data"]["done"] == true
    end

    test "a two-write transaction whose second write fails commits nothing" do
      s = setup_tasks(workspace())
      {:ok, before} = AppData.changes(s, %{"since" => "latest"})

      assert {:error, {:operation_failed, 1, {:validation, _}}} =
               AppData.transact(s, [
                 %{
                   "op" => "create",
                   "collection" => "tasks",
                   "id" => "t-1",
                   "data" => %{"title" => "first"}
                 },
                 %{
                   "op" => "create",
                   "collection" => "tasks",
                   "id" => "t-2",
                   "data" => %{"priority" => 1}
                 }
               ])

      assert {:error, {:not_found, "record_not_found"}} = AppData.get(s, "tasks", "t-1")
      {:ok, %{"count" => 0}} = AppData.query(s, "tasks", %{"count" => true})
      {:ok, after_txn} = AppData.changes(s, %{"since" => before["latest_seq"]})
      assert after_txn["changes"] == []
    end

    test "a two-write transaction commits both writes with one txn id" do
      s = setup_tasks(workspace())

      {:ok, result} =
        AppData.transact(s, [
          %{
            "op" => "create",
            "collection" => "tasks",
            "id" => "t-1",
            "data" => %{"title" => "first"}
          },
          %{
            "op" => "update",
            "collection" => "tasks",
            "id" => "t-1",
            "data" => %{"done" => true},
            "version" => 1
          }
        ])

      assert Enum.map(result.results, & &1["op"]) == ["create", "update"]
      {:ok, feed} = AppData.changes(s, %{})
      record_changes = Enum.filter(feed["changes"], &(&1["record_id"] == "t-1"))
      assert Enum.map(record_changes, & &1["txn_id"]) |> Enum.uniq() == [result.txn_id]
    end

    test "full-text search on title" do
      s = setup_tasks(workspace())

      for title <- ["Quarterly budget review", "Buy cat food", "Budget for garden", "Call the bank"] do
        {:ok, _} = AppData.create(s, "tasks", %{"data" => %{"title" => title}})
      end

      {:ok, result} =
        AppData.query(s, "tasks", %{"search" => %{"text" => "budget"}, "count" => true})

      titles = Enum.map(result["records"], & &1["data"]["title"])
      assert Enum.sort(titles) == ["Budget for garden", "Quarterly budget review"]
      assert result["count"] == 2
      assert Enum.all?(result["records"], &is_float(&1["score"]))

      {:ok, prefix} =
        AppData.query(s, "tasks", %{"search" => %{"text" => "gard", "prefix" => true}})

      assert Enum.map(prefix["records"], & &1["data"]["title"]) == ["Budget for garden"]

      {:ok, any} =
        AppData.query(s, "tasks", %{"search" => %{"text" => "cat bank", "match" => "any"}})

      assert length(any["records"]) == 2

      {:ok, none} = AppData.query(s, "tasks", %{"search" => "\" OR * NEAR("})
      assert none["records"] == []

      {:ok, task} = AppData.create(s, "tasks", %{"data" => %{"title" => "Plain task"}})

      {:ok, _} =
        AppData.update(s, "tasks", task["id"], %{"data" => %{"title" => "Budget follow up"}})

      {:ok, updated} = AppData.query(s, "tasks", %{"search" => "budget", "count" => true})
      assert updated["count"] == 3
      {:ok, _} = AppData.delete(s, "tasks", task["id"])
      {:ok, deleted} = AppData.query(s, "tasks", %{"search" => "budget", "count" => true})
      assert deleted["count"] == 2
    end

    test "an owner-bound scope cannot read, change, or claim another owner's tasks" do
      ws = workspace()
      admin = setup_tasks(ws)

      {:ok, b_task} =
        AppData.create(admin, "tasks", %{"data" => %{"title" => "b's task", "owner" => "user-b"}})

      {:ok, _} =
        AppData.create(admin, "tasks", %{"data" => %{"title" => "a's task", "owner" => "user-a"}})

      a = scope(ws, owner: "user-a", admin: false, keyed: true, actor: "api_key:a")

      {:ok, visible} = AppData.query(a, "tasks", %{"count" => true})
      assert visible["count"] == 1
      assert hd(visible["records"])["data"]["owner"] == "user-a"
      assert {:error, {:not_found, _}} = AppData.get(a, "tasks", b_task["id"])

      assert {:error, {:not_found, _}} =
               AppData.update(a, "tasks", b_task["id"], %{"data" => %{"done" => true}})

      assert {:error, {:not_found, _}} = AppData.delete(a, "tasks", b_task["id"])

      {:ok, own} = AppData.create(a, "tasks", %{"data" => %{"title" => "mine"}})
      assert own["data"]["owner"] == "user-a"

      assert {:error, {:forbidden, "owner_mismatch"}} =
               AppData.create(a, "tasks", %{"data" => %{"title" => "spoof", "owner" => "user-b"}})

      assert {:error, {:forbidden, "owner_mismatch"}} =
               AppData.update(a, "tasks", own["id"], %{"data" => %{"owner" => "user-b"}})

      {:ok, search} = AppData.query(a, "tasks", %{"search" => "task", "count" => true})
      assert search["count"] == 1

      {:ok, feed} = AppData.changes(a, %{})
      owners = for c <- feed["changes"], c["op"] in ["create", "update", "delete"], do: c["owner"]
      assert Enum.uniq(owners) == ["user-a"]
    end

    test "the change feed resumes from a sequence number" do
      s = setup_tasks(workspace())
      {:ok, one} = AppData.create(s, "tasks", %{"data" => %{"title" => "one"}})
      {:ok, two} = AppData.create(s, "tasks", %{"data" => %{"title" => "two"}})
      {:ok, _} = AppData.update(s, "tasks", one["id"], %{"data" => %{"done" => true}})
      {:ok, _} = AppData.delete(s, "tasks", two["id"])

      {:ok, page1} = AppData.changes(s, %{"since" => 0, "limit" => 2, "collection" => "tasks"})
      assert length(page1["changes"]) == 2
      {:ok, page2} = AppData.changes(s, %{"since" => page1["next_since"], "collection" => "tasks"})

      ops = Enum.map(page1["changes"] ++ page2["changes"], &{&1["op"], &1["record_id"]})

      assert ops == [
               {"schema", nil},
               {"create", one["id"]},
               {"create", two["id"]},
               {"update", one["id"]},
               {"delete", two["id"]}
             ]

      seqs = Enum.map(page1["changes"] ++ page2["changes"], & &1["seq"])
      assert seqs == Enum.sort(seqs)
      assert List.last(seqs) == page2["latest_seq"]

      {:ok, caught_up} = AppData.changes(s, %{"since" => page2["next_since"]})
      assert caught_up["changes"] == []
      assert {:ok, %{"changes" => []}} = AppData.changes(s, %{"since" => "latest"})
    end
  end

  defp page_all(s, spec, dues, pages_acc) do
    {:ok, page} = AppData.query(s, "tasks", spec)
    dues = dues ++ Enum.map(page["records"], & &1["data"]["due"])
    pages_acc = [page | pages_acc]

    case page["next_cursor"] do
      nil -> {length(pages_acc), dues}
      cursor -> page_all(s, Map.put(spec, "cursor", cursor), dues, pages_acc)
    end
  end

  describe "collections and schema" do
    test "rejects invalid definitions with every reason" do
      s = scope(workspace())

      assert {:error, {:validation, errors}} =
               AppData.create_collection(s, %{
                 "name" => "Bad Name",
                 "fields" => [%{"name" => "x", "type" => "string"}]
               })

      assert Enum.any?(errors, &String.contains?(&1, "name must match"))

      assert {:error, {:validation, errors}} =
               AppData.create_collection(s, %{
                 "name" => "things",
                 "fields" => [
                   %{"name" => "id", "type" => "string"},
                   %{"name" => "x\"; DROP TABLE contexts; --", "type" => "string"},
                   %{"name" => "y", "type" => "money"},
                   %{"name" => "or", "type" => "string"}
                 ]
               })

      assert length(errors) == 4
    end

    test "defaults, required, enum, unique and type checks" do
      s = scope(workspace())

      {:ok, _} =
        AppData.create_collection(s, %{
          "name" => "people",
          "fields" => %{
            "email" => %{"type" => "string", "unique" => true, "required" => true},
            "role" => %{"type" => "string", "enum" => ["member", "admin"], "default" => "member"},
            "age" => "integer",
            "joined" => %{"type" => "datetime", "default" => "now"},
            "score" => %{"type" => "float", "default" => 1}
          }
        })

      {:ok, p} = AppData.create(s, "people", %{"data" => %{"email" => "a@example.com"}})
      assert p["data"]["role"] == "member"
      assert p["data"]["score"] == 1.0
      assert {:ok, _, _} = DateTime.from_iso8601(p["data"]["joined"])

      assert {:error, {:conflict, "unique_violation", %{"fields" => ["email"]}}} =
               AppData.create(s, "people", %{"data" => %{"email" => "a@example.com"}})

      assert {:error, {:validation, errors}} =
               AppData.create(s, "people", %{
                 "data" => %{"role" => "owner", "age" => "old", "nope" => 1}
               })

      assert ["unknown fields: nope"] = errors

      assert {:error, {:validation, errors}} =
               AppData.create(s, "people", %{"data" => %{"role" => "owner", "age" => "old"}})

      assert "email is required" in errors
      assert Enum.any?(errors, &String.starts_with?(&1, "role must be one of"))
      assert Enum.any?(errors, &String.starts_with?(&1, "age must be a integer"))

      assert {:error, {:conflict, "record_exists", _}} =
               AppData.create(s, "people", %{
                 "id" => p["id"],
                 "data" => %{"email" => "b@example.com"}
               })
    end

    test "datetimes are normalized to UTC milliseconds and compare as time" do
      s = setup_tasks(workspace())

      {:ok, t} =
        AppData.create(s, "tasks", %{
          "data" => %{"title" => "x", "due" => "2026-11-01T10:00:00+02:00"}
        })

      assert t["data"]["due"] == "2026-11-01T08:00:00.000Z"
      {:ok, d} = AppData.create(s, "tasks", %{"data" => %{"title" => "y", "due" => "2026-11-01"}})
      assert d["data"]["due"] == "2026-11-01T00:00:00.000Z"

      {:ok, r} =
        AppData.query(s, "tasks", %{"where" => %{"due" => %{"gt" => "2026-11-01T03:00:00-04:00"}}})

      assert Enum.map(r["records"], & &1["id"]) == [t["id"]]
    end

    test "alter: add a required field with a default backfills, drop needs confirmation" do
      s = setup_tasks(workspace())
      {:ok, t} = AppData.create(s, "tasks", %{"data" => %{"title" => "x"}})

      assert {:error, {:operation_failed, 0, {:validation, _}}} =
               AppData.alter_collection(s, "tasks", [
                 %{
                   "op" => "add_field",
                   "field" => %{"name" => "area", "type" => "string", "required" => true}
                 }
               ])

      {:ok, altered} =
        AppData.alter_collection(s, "tasks", [
          %{
            "op" => "add_field",
            "field" => %{
              "name" => "area",
              "type" => "string",
              "required" => true,
              "default" => "home"
            }
          },
          %{"op" => "add_index", "fields" => ["area", "due"], "name" => "by_area"}
        ])

      assert altered["schema_version"] == 2
      {:ok, got} = AppData.get(s, "tasks", t["id"])
      assert got["data"]["area"] == "home"

      assert {:error, {:operation_failed, 0, {:validation, [message]}}} =
               AppData.alter_collection(s, "tasks", [%{"op" => "drop_field", "name" => "notes"}])

      assert message =~ "confirm"

      assert {:error, {:operation_failed, 0, {:validation, _}}} =
               AppData.alter_collection(s, "tasks", [
                 %{"op" => "drop_field", "name" => "area", "confirm" => true}
               ])

      {:ok, dropped} =
        AppData.alter_collection(s, "tasks", [
          %{"op" => "drop_index", "name" => "by_area"},
          %{"op" => "drop_field", "name" => "notes", "confirm" => true},
          %{"op" => "set_default", "name" => "priority", "default" => 5}
        ])

      refute Enum.any?(dropped["fields"], &(&1["name"] == "notes"))
      assert dropped["search"]["text"] == ["title"]
      {:ok, n} = AppData.create(s, "tasks", %{"data" => %{"title" => "budget"}})
      assert n["data"]["priority"] == 5
      {:ok, found} = AppData.query(s, "tasks", %{"search" => "budget"})
      assert Enum.map(found["records"], & &1["id"]) == [n["id"]]
    end

    test "a failed alteration leaves the collection unchanged" do
      s = setup_tasks(workspace())

      assert {:error, {:operation_failed, 1, _}} =
               AppData.alter_collection(s, "tasks", [
                 %{"op" => "add_field", "field" => %{"name" => "area", "type" => "string"}},
                 %{"op" => "add_index", "fields" => ["missing"]}
               ])

      {:ok, c} = AppData.describe_collection(s, "tasks")
      assert c["schema_version"] == 1
      refute Enum.any?(c["fields"], &(&1["name"] == "area"))
      {:ok, _} = AppData.create(s, "tasks", %{"data" => %{"title" => "still works"}})
    end

    test "unique index on existing duplicates is refused" do
      s = setup_tasks(workspace())
      {:ok, _} = AppData.create(s, "tasks", %{"data" => %{"title" => "same"}})
      {:ok, _} = AppData.create(s, "tasks", %{"data" => %{"title" => "same"}})

      assert {:error, {:operation_failed, 0, {:conflict, "unique_index_duplicates", _}}} =
               AppData.alter_collection(s, "tasks", [
                 %{"op" => "add_index", "fields" => ["title"], "unique" => true}
               ])
    end

    test "drop needs the collection name and is refused while referenced" do
      s = setup_tasks(workspace())

      {:ok, _} =
        AppData.create_collection(s, %{
          "name" => "comments",
          "fields" => [%{"name" => "task", "type" => "reference", "references" => "tasks"}]
        })

      assert {:error, {:validation, _}} = AppData.drop_collection(s, "tasks", nil)

      assert {:error, {:conflict, "collection_referenced", %{"referenced_by" => ["comments.task"]}}} =
               AppData.drop_collection(s, "tasks", "tasks")

      assert :ok = AppData.drop_collection(s, "comments", "comments")
      assert :ok = AppData.drop_collection(s, "tasks", "tasks")
      assert {:ok, []} = AppData.list_collections(s)
      {:ok, feed} = AppData.changes(s, %{})
      assert Enum.map(feed["changes"], & &1["op"]) |> Enum.count(&(&1 == "drop")) == 2
    end

    test "collections are isolated per workspace and per tenant" do
      ws_a = workspace()
      ws_b = workspace()
      a = setup_tasks(ws_a)
      {:ok, _} = AppData.create(a, "tasks", %{"data" => %{"title" => "a only"}})

      assert {:error, {:not_found, "collection_not_found"}} =
               AppData.query(scope(ws_b), "tasks", %{})

      assert {:error, {:not_found, "collection_not_found"}} =
               AppData.query(scope(ws_a, tenant_id: "other-tenant"), "tasks", %{})
    end
  end

  describe "references, includes, and joins" do
    setup do
      s = scope(workspace())

      {:ok, _} =
        AppData.create_collection(s, %{
          "name" => "projects",
          "fields" => [
            %{"name" => "name", "type" => "string"},
            %{"name" => "status", "type" => "string"}
          ]
        })

      {:ok, _} =
        AppData.create_collection(s, %{
          "name" => "items",
          "fields" => [
            %{"name" => "title", "type" => "string"},
            %{
              "name" => "project",
              "type" => "reference",
              "references" => "projects",
              "on_delete" => "cascade"
            },
            %{
              "name" => "parent",
              "type" => "reference",
              "references" => "items",
              "on_delete" => "set_null"
            }
          ]
        })

      {:ok, _} =
        AppData.create_collection(s, %{
          "name" => "notes",
          "fields" => [%{"name" => "item", "type" => "reference", "references" => "items"}]
        })

      {:ok, active} =
        AppData.create(s, "projects", %{
          "id" => "p-1",
          "data" => %{"name" => "Launch", "status" => "active"}
        })

      {:ok, idle} =
        AppData.create(s, "projects", %{
          "id" => "p-2",
          "data" => %{"name" => "Later", "status" => "idle"}
        })

      {:ok, i1} =
        AppData.create(s, "items", %{
          "id" => "i-1",
          "data" => %{"title" => "one", "project" => "p-1"}
        })

      {:ok, i2} =
        AppData.create(s, "items", %{
          "id" => "i-2",
          "data" => %{"title" => "two", "project" => "p-2", "parent" => "i-1"}
        })

      %{s: s, active: active, idle: idle, i1: i1, i2: i2}
    end

    test "a reference must point at an existing record", %{s: s} do
      assert {:error, {:validation, [message]}} =
               AppData.create(s, "items", %{"data" => %{"title" => "x", "project" => "p-missing"}})

      assert message =~ "does not exist"
    end

    test "include attaches referenced records and dotted paths filter through references", %{s: s} do
      {:ok, r} = AppData.query(s, "items", %{"include" => ["project"], "sort" => ["title"]})

      assert Enum.map(r["records"], & &1["included"]["project"]["data"]["name"]) == [
               "Launch",
               "Later"
             ]

      {:ok, active} = AppData.query(s, "items", %{"where" => %{"project.status" => "active"}})
      assert Enum.map(active["records"], & &1["id"]) == ["i-1"]

      {:ok, item} =
        AppData.get(s, "items", "i-2", %{"include" => ["parent"], "fields" => ["title"]})

      assert item["included"]["parent"]["id"] == "i-1"
      assert Map.keys(item["data"]) |> Enum.sort() == ["parent", "title"]
    end

    test "on_delete rules: restrict refuses, set_null clears, cascade deletes", %{s: s} do
      {:ok, _} = AppData.create(s, "notes", %{"id" => "n-1", "data" => %{"item" => "i-2"}})

      assert {:error, {:conflict, "reference_restrict", %{"collection" => "notes"}}} =
               AppData.delete(s, "projects", "p-2")

      {:ok, _} = AppData.delete(s, "notes", "n-1")
      {:ok, _} = AppData.delete(s, "items", "i-1")
      {:ok, two} = AppData.get(s, "items", "i-2")
      assert two["data"]["parent"] == nil
      assert two["version"] == 2

      {:ok, _} = AppData.delete(s, "projects", "p-2")
      assert {:error, {:not_found, _}} = AppData.get(s, "items", "i-2")
      {:ok, feed} = AppData.changes(s, %{"collection" => "items"})
      assert Enum.any?(feed["changes"], &(&1["op"] == "delete" and &1["record_id"] == "i-2"))
    end
  end

  describe "filters, sort and cursors" do
    setup do
      s = setup_tasks(workspace())

      for {title, p, tags, done} <- [
            {"alpha", 1, ["red"], false},
            {"beta", 2, ["blue", "red"], true},
            {"gamma", 3, [], false},
            {"delta", nil, nil, false}
          ] do
        {:ok, _} =
          AppData.create(s, "tasks", %{
            "id" => title,
            "data" => %{"title" => title, "priority" => p, "tags" => tags, "done" => done}
          })
      end

      %{s: s}
    end

    test "operators", %{s: s} do
      ids = fn where ->
        {:ok, r} = AppData.query(s, "tasks", %{"where" => where, "sort" => ["id"]})
        Enum.map(r["records"], & &1["id"])
      end

      assert ids.(%{"priority" => %{"gte" => 2}}) == ["beta", "gamma"]
      assert ids.(%{"priority" => %{"gt" => 1, "lt" => 3}}) == ["beta"]
      assert ids.(%{"priority" => %{"in" => [1, 3]}}) == ["alpha", "gamma"]
      assert ids.(%{"priority" => %{"nin" => [1, 3]}}) == ["beta"]
      assert ids.(%{"priority" => nil}) == ["delta"]
      assert ids.(%{"priority" => %{"is_null" => false, "ne" => 2}}) == ["alpha", "gamma"]
      assert ids.(%{"title" => %{"contains" => "lt"}}) == ["delta"]
      assert ids.(%{"tags" => %{"contains" => "red"}}) == ["alpha", "beta"]
      assert ids.(%{"or" => [%{"done" => true}, %{"priority" => 3}]}) == ["beta", "gamma"]
      assert ids.(%{"not" => %{"done" => false}}) == ["beta"]
      assert ids.(%{"id" => %{"in" => ["alpha", "zeta"]}, "version" => 1}) == ["alpha"]
    end

    test "invalid filters are rejected, never interpolated", %{s: s} do
      for where <- [
            %{"nope" => 1},
            %{"priority" => %{"like" => "%"}},
            %{"priority" => "1; DROP TABLE contexts"},
            %{"tags" => %{"gt" => 1}},
            %{"title\" OR 1=1 --" => 1}
          ] do
        assert {:error, {:validation, [_]}} = AppData.query(s, "tasks", %{"where" => where})
      end
    end

    test "descending sort with nulls pages without gaps or repeats", %{s: s} do
      spec = %{"sort" => ["-priority"], "limit" => 1}
      {_, ids} = page_ids(s, spec, [])
      assert ids == ["gamma", "beta", "alpha", "delta"]
      {_, asc} = page_ids(s, %{"sort" => ["priority", "-title"], "limit" => 3}, [])
      assert asc == ["delta", "alpha", "beta", "gamma"]
    end

    test "a cursor is bound to its query", %{s: s} do
      {:ok, page} = AppData.query(s, "tasks", %{"sort" => ["title"], "limit" => 1})

      assert {:error, {:validation, [message]}} =
               AppData.query(s, "tasks", %{
                 "sort" => ["-title"],
                 "limit" => 1,
                 "cursor" => page["next_cursor"]
               })

      assert message =~ "cursor"
      assert {:error, {:validation, _}} = AppData.query(s, "tasks", %{"cursor" => "garbage"})
    end

    test "field selection and limits", %{s: s} do
      {:ok, r} = AppData.query(s, "tasks", %{"fields" => ["title"], "limit" => 2})
      assert Enum.all?(r["records"], &(Map.keys(&1["data"]) == ["title"]))
      assert {:error, {:validation, _}} = AppData.query(s, "tasks", %{"limit" => 5_000})
      {:ok, only_count} = AppData.query(s, "tasks", %{"limit" => 0, "count" => true})
      assert only_count["records"] == [] and only_count["count"] == 4
    end
  end

  defp page_ids(s, spec, acc) do
    {:ok, page} = AppData.query(s, "tasks", spec)
    acc = acc ++ Enum.map(page["records"], & &1["id"])

    case page["next_cursor"] do
      nil -> {:done, acc}
      cursor -> page_ids(s, Map.put(spec, "cursor", cursor), acc)
    end
  end

  describe "upsert and bulk" do
    test "upsert by a unique key creates then updates" do
      s = scope(workspace())

      {:ok, _} =
        AppData.create_collection(s, %{
          "name" => "settings",
          "fields" => [
            %{"name" => "key", "type" => "string", "unique" => true},
            %{"name" => "value", "type" => "json"}
          ]
        })

      {:ok, created} =
        AppData.upsert(s, "settings", %{
          "key" => "key",
          "data" => %{"key" => "theme", "value" => "dark"}
        })

      assert created["op"] == "create"

      {:ok, updated} =
        AppData.upsert(s, "settings", %{
          "key" => "key",
          "data" => %{"key" => "theme", "value" => "light"}
        })

      assert updated["op"] == "update" and updated["id"] == created["id"] and
               updated["version"] == 2

      assert {:error, {:validation, _}} =
               AppData.upsert(s, "settings", %{"key" => "value", "data" => %{"value" => 1}})

      {:ok, by_id} =
        AppData.upsert(s, "settings", %{
          "key" => "id",
          "id" => "fixed",
          "data" => %{"key" => "lang"}
        })

      assert by_id["op"] == "create"
    end

    test "a bulk insert with one bad record inserts none" do
      s = setup_tasks(workspace())

      assert {:error, {:operation_failed, 2, {:validation, _}}} =
               AppData.bulk_create(s, "tasks", [
                 %{"title" => "a"},
                 %{"title" => "b"},
                 %{"done" => true}
               ])

      {:ok, %{"count" => 0}} = AppData.query(s, "tasks", %{"count" => true})
    end
  end

  describe "migrations" do
    defp app_migrations do
      [
        %{
          "version" => 1,
          "name" => "tasks",
          "operations" => [%{"op" => "create_collection", "collection" => tasks_definition()}]
        },
        %{
          "version" => 2,
          "name" => "area",
          "operations" => [
            %{
              "op" => "alter_collection",
              "name" => "tasks",
              "operations" => [
                %{"op" => "add_field", "field" => %{"name" => "area", "type" => "string"}}
              ]
            }
          ]
        }
      ]
    end

    test "apply is idempotent and refuses edited or out-of-order history" do
      s = scope(workspace())
      migrations = app_migrations()

      {:ok, first} = AppData.migrate(s, %{"app" => "todo", "migrations" => migrations})
      assert first["applied"] == [1, 2]
      {:ok, again} = AppData.migrate(s, %{"app" => "todo", "migrations" => migrations})
      assert again["applied"] == [] and again["skipped"] == [1, 2]
      {:ok, c} = AppData.describe_collection(s, "tasks")
      assert c["schema_version"] == 2

      edited = List.update_at(migrations, 1, &put_in(&1, ["name"], "renamed only"))
      {:ok, _} = AppData.migrate(s, %{"app" => "todo", "migrations" => edited})

      changed =
        List.update_at(migrations, 1, fn m ->
          put_in(
            m,
            ["operations", Access.at(0), "operations", Access.at(0), "field", "type"],
            "integer"
          )
        end)

      assert {:error, {:conflict, "migration_checksum_mismatch", %{"version" => 2}}} =
               AppData.migrate(s, %{"app" => "todo", "migrations" => changed})

      {:ok, list} = AppData.migrations(s, "todo")
      assert Enum.map(list, & &1["version"]) == [1, 2]
    end

    test "a failing migration rolls back only itself" do
      s = scope(workspace())

      bad =
        app_migrations() ++
          [
            %{
              "version" => 3,
              "operations" => [
                %{
                  "op" => "alter_collection",
                  "name" => "tasks",
                  "operations" => [%{"op" => "add_index", "fields" => ["nope"]}]
                }
              ]
            }
          ]

      assert {:error, {:migration_failed, 3, _, %{"applied" => [1, 2]}}} =
               AppData.migrate(s, %{"app" => "todo", "migrations" => bad})

      {:ok, list} = AppData.migrations(s, "todo")
      assert Enum.map(list, & &1["version"]) == [1, 2]
    end
  end

  describe "files" do
    test "upload, list, open, and delete with the record" do
      s = setup_tasks(workspace())
      {:ok, t} = AppData.create(s, "tasks", %{"data" => %{"title" => "with file"}})
      bytes = "hello, app data files"

      {:ok, file} =
        AppData.upload_file(s, "tasks", t["id"], %{
          "filename" => "../../notes.txt",
          "content_type" => "text/plain",
          "content_base64" => Base.encode64(bytes)
        })

      assert file["filename"] == "notes.txt"
      assert file["size_bytes"] == byte_size(bytes)
      {:ok, [listed]} = AppData.list_files(s, "tasks", t["id"])
      assert listed["id"] == file["id"]
      {:ok, opened} = AppData.open_file(s, "tasks", t["id"], file["id"])
      assert File.read!(opened.path) == bytes

      other = scope(s.workspace_id, owner: "someone-else", admin: false, keyed: true)
      assert {:error, {:not_found, _}} = AppData.open_file(other, "tasks", t["id"], file["id"])

      {:ok, _} = AppData.delete(s, "tasks", t["id"])
      assert {:error, {:not_found, _}} = AppData.list_files(s, "tasks", t["id"])
    end
  end

  describe "semantic search" do
    setup do
      original = Application.get_env(:optimal_engine, :app_data)

      on_exit(fn ->
        if original,
          do: Application.put_env(:optimal_engine, :app_data, original),
          else: Application.delete_env(:optimal_engine, :app_data)
      end)

      :ok
    end

    test "ranks by meaning with the configured embedder" do
      Application.put_env(:optimal_engine, :app_data,
        embedder: FakeEmbedder,
        embed_model: "fake",
        semantic_indexing: :sync
      )

      s = setup_tasks(workspace())

      for title <- [
            "pay the invoice",
            "walk the dog",
            "water the garden plant",
            "monthly budget and payment"
          ] do
        {:ok, _} = AppData.create(s, "tasks", %{"data" => %{"title" => title}})
      end

      {:ok, r} =
        AppData.query(s, "tasks", %{
          "semantic" => %{"text" => "money payment invoice"},
          "limit" => 2,
          "count" => true
        })

      assert Enum.map(r["records"], & &1["data"]["title"]) == [
               "pay the invoice",
               "monthly budget and payment"
             ]

      assert r["model"] == "fake"
      assert r["has_more"]

      {:ok, page2} =
        AppData.query(s, "tasks", %{
          "semantic" => %{"text" => "money payment invoice"},
          "limit" => 2,
          "cursor" => r["next_cursor"]
        })

      refute Enum.any?(
               page2["records"],
               &(&1["data"]["title"] in ["pay the invoice", "monthly budget and payment"])
             )

      {:ok, counts} = AppData.rebuild_embeddings(s, "tasks")
      assert counts["unchanged"] == 4
    end

    test "reports unavailable instead of pretending" do
      Application.put_env(:optimal_engine, :app_data,
        embedder: DownEmbedder,
        semantic_indexing: :sync
      )

      s = setup_tasks(workspace())
      {:ok, _} = AppData.create(s, "tasks", %{"data" => %{"title" => "pay the invoice"}})

      assert {:error, {:unavailable, "semantic_unavailable", reason}} =
               AppData.query(s, "tasks", %{"semantic" => "invoice"})

      assert reason =~ "econnrefused"
      assert %{"available" => false} = AppData.capabilities()["semantic"]
    end
  end
end
