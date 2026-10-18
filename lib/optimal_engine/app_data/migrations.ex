defmodule OptimalEngine.AppData.Migrations do
  @moduledoc """
  Versioned app schema migrations, so an app ships its schema with its code.

  An app sends its full, ordered migration list on every deploy:

      %{"app" => "todo",
        "migrations" => [
          %{"version" => 1, "name" => "tasks",
            "operations" => [%{"op" => "create_collection", "collection" => %{...}}]},
          %{"version" => 2, "name" => "priority",
            "operations" => [%{"op" => "alter_collection", "name" => "tasks",
                               "operations" => [%{"op" => "add_field", "field" => %{...}}]}]}]}

  Each pending version runs in its own transaction together with its
  ledger row in `data_schema_migrations`, so it is applied exactly once
  even across crashes and concurrent deploys. Already applied versions are
  skipped when their checksum (SHA-256 of the canonical operations) is
  unchanged and refused when it changed. A new version lower than one
  already applied is refused. Applying stops at the first failure.

  Operations: `create_collection` (`collection`: a definition),
  `alter_collection` (`name`, `operations`: alter operations), and
  `drop_collection` (`name`, `confirm`: the name).
  """

  alias OptimalEngine.AppData.{Collections, Schema, Scope, SQL}
  alias OptimalEngine.Store

  @max_migrations 1_000

  @doc "Applies pending migrations. Returns applied and skipped versions."
  @spec apply(Scope.t(), map()) :: {:ok, map()} | {:error, term()}
  def apply(%Scope{} = scope, %{"app" => app, "migrations" => migrations})
      when is_list(migrations) do
    with :ok <- Scope.allow_admin(scope),
         :ok <- valid_app(app),
         {:ok, migrations} <- normalize(migrations),
         {:ok, applied} <- applied(scope, app),
         :ok <- consistent(migrations, applied) do
      max_applied = applied |> Map.keys() |> Enum.max(fn -> 0 end)
      pending = Enum.reject(migrations, &Map.has_key?(applied, &1["version"]))

      case Enum.find(pending, &(&1["version"] < max_applied)) do
        nil -> run(scope, app, pending, Map.keys(applied) |> Enum.sort())
        m -> {:error, {:conflict, "migration_out_of_order", %{"version" => m["version"]}}}
      end
    end
  end

  def apply(_scope, _body),
    do: {:error, {:validation, ["migrations need app and a migrations list"]}}

  @doc "Applied migrations for an app."
  @spec list(Scope.t(), String.t()) :: {:ok, [map()]} | {:error, term()}
  def list(%Scope{} = scope, app) do
    with :ok <- valid_app(app),
         {:ok, rows} <-
           SQL.query(
             :store,
             "SELECT version, name, checksum, applied_by, applied_at FROM data_schema_migrations WHERE tenant_id = ? AND workspace_id = ? AND app = ? ORDER BY version",
             [scope.tenant_id, scope.workspace_id, app]
           ) do
      {:ok,
       Enum.map(rows, fn [version, name, checksum, by, at] ->
         %{
           "version" => version,
           "name" => name,
           "checksum" => checksum,
           "applied_by" => by,
           "applied_at" => at
         }
       end)}
    end
  end

  defp run(scope, app, pending, already) do
    Enum.reduce_while(pending, {:ok, %{"applied" => [], "skipped" => already}}, fn m, {:ok, acc} ->
      case Store.transaction(fn txn -> apply_one(txn, scope, app, m) end, 120_000) do
        {:ok, _} ->
          {:cont, {:ok, Map.update!(acc, "applied", &(&1 ++ [m["version"]]))}}

        {:error, reason} ->
          {:halt, {:error, {:migration_failed, m["version"], reason, Map.take(acc, ["applied"])}}}
      end
    end)
  end

  # The ledger is re-read inside the transaction, so a deploy racing another
  # one for the same version finds it applied and skips it.
  defp apply_one(txn, scope, app, %{"checksum" => expected} = m) do
    case SQL.scalar(
           txn,
           "SELECT checksum FROM data_schema_migrations WHERE tenant_id = ? AND workspace_id = ? AND app = ? AND version = ?",
           [scope.tenant_id, scope.workspace_id, app, m["version"]]
         ) do
      {:ok, nil} ->
        apply_operations(txn, scope, app, m)

      {:ok, ^expected} ->
        {:ok, m["version"]}

      {:ok, _other} ->
        {:error, {:conflict, "migration_checksum_mismatch", %{"version" => m["version"]}}}

      error ->
        error
    end
  end

  defp apply_operations(txn, scope, app, m) do
    result =
      m["operations"]
      |> Enum.with_index()
      |> Enum.reduce_while(:ok, fn {op, index}, :ok ->
        case operation(txn, scope, op) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, {:operation_failed, index, reason}}}
        end
      end)

    with :ok <- result,
         {:ok, 1} <-
           SQL.exec(
             txn,
             "INSERT INTO data_schema_migrations (tenant_id, workspace_id, app, version, name, checksum, applied_by, applied_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
             [
               scope.tenant_id,
               scope.workspace_id,
               app,
               m["version"],
               m["name"],
               m["checksum"],
               scope.actor,
               Schema.now()
             ]
           ) do
      {:ok, m["version"]}
    end
  end

  defp operation(txn, scope, %{"op" => "create_collection", "collection" => definition}) do
    with {:ok, schema} <- Schema.normalize_definition(definition),
         {:ok, c} <- Collections.create_in(txn, scope, schema),
         :ok <-
           Collections.log_change(txn, scope, c, "schema", nil, nil, nil, %{
             "action" => "create",
             "schema_version" => 1
           }) do
      :ok
    end
  end

  defp operation(txn, scope, %{"op" => "alter_collection", "name" => name, "operations" => ops}) do
    with {:ok, c} <- Collections.load(txn, scope, name),
         {:ok, _c} <- Collections.alter_in(txn, scope, c, ops) do
      :ok
    end
  end

  defp operation(txn, scope, %{"op" => "drop_collection", "name" => name} = op) do
    case Collections.drop_in(txn, scope, name, op["confirm"]) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp operation(_txn, _scope, op) do
    {:error, {:validation, ["unknown migration operation #{inspect(op["op"] || op)}"]}}
  end

  defp valid_app(app) do
    if Schema.identifier?(app),
      do: :ok,
      else: {:error, {:validation, ["app must be a lowercase identifier"]}}
  end

  defp normalize(migrations) when length(migrations) > @max_migrations,
    do: {:error, {:validation, ["at most #{@max_migrations} migrations"]}}

  defp normalize(migrations) do
    normalized =
      Enum.map(migrations, fn
        %{"version" => v, "operations" => ops} = m
        when is_integer(v) and v > 0 and is_list(ops) and ops != [] ->
          %{
            "version" => v,
            "name" => to_string(m["name"] || "v#{v}"),
            "operations" => ops,
            "checksum" => checksum(ops)
          }

        _ ->
          :invalid
      end)

    versions = for %{"version" => v} <- normalized, do: v

    cond do
      :invalid in normalized ->
        {:error, {:validation, ["each migration needs a positive integer version and operations"]}}

      versions != Enum.sort(Enum.uniq(versions)) ->
        {:error, {:validation, ["migration versions must be unique and ascending"]}}

      true ->
        {:ok, normalized}
    end
  end

  defp applied(scope, app) do
    with {:ok, rows} <-
           SQL.query(
             :store,
             "SELECT version, checksum FROM data_schema_migrations WHERE tenant_id = ? AND workspace_id = ? AND app = ?",
             [scope.tenant_id, scope.workspace_id, app]
           ) do
      {:ok, Map.new(rows, fn [version, checksum] -> {version, checksum} end)}
    end
  end

  defp consistent(migrations, applied) do
    case Enum.find(
           migrations,
           &(Map.has_key?(applied, &1["version"]) and applied[&1["version"]] != &1["checksum"])
         ) do
      nil -> :ok
      m -> {:error, {:conflict, "migration_checksum_mismatch", %{"version" => m["version"]}}}
    end
  end

  @doc "SHA-256 of the canonical JSON of a migration's operations."
  @spec checksum(term()) :: String.t()
  def checksum(operations) do
    "sha256:" <>
      (:crypto.hash(:sha256, Jason.encode!(canonical(operations))) |> Base.encode16(case: :lower))
  end

  defp canonical(%{} = map) when not is_struct(map) do
    map
    |> Enum.sort_by(fn {key, _} -> to_string(key) end)
    |> Enum.map(fn {key, value} -> {to_string(key), canonical(value)} end)
    |> Jason.OrderedObject.new()
  end

  defp canonical(list) when is_list(list), do: Enum.map(list, &canonical/1)
  defp canonical(value), do: value
end
