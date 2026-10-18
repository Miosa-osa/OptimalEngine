defmodule OptimalEngine.AppData do
  @moduledoc """
  App data: lets an app use the Engine as its database.

  An app defines collections in a workspace (typed fields, required,
  unique, defaults, references, indexes, an owner field, search fields),
  then creates, updates, deletes, upserts and queries records, runs
  multi-write transactions, attaches files, follows a durable change feed,
  and ships versioned schema migrations. App collections live beside the
  workspace's knowledge; knowledge APIs are unchanged.

  Every call takes an `OptimalEngine.AppData.Scope` naming the tenant,
  workspace and acting principal, plus any owner, collection and operation
  limits of the caller's key. See `docs/guides/app-data-api.md`.

  Module map:

  * `AppData.Collections` - registry and DDL
  * `AppData.Records` - writes, versions, transactions
  * `AppData.Query` - filters, sort, cursors, search, joins
  * `AppData.Semantic` - embeddings and semantic search
  * `AppData.Changes` - change feed
  * `AppData.Files` - files on records
  * `AppData.Keys` - data keys for end users and components
  * `AppData.Migrations` - app schema migrations
  """

  alias OptimalEngine.AppData.{
    Changes,
    Collections,
    Files,
    Keys,
    Migrations,
    Query,
    Records,
    Scope,
    Semantic
  }

  # -- collections ------------------------------------------------------------

  defdelegate list_collections(scope), to: Collections, as: :list
  defdelegate describe_collection(scope, name), to: Collections, as: :describe

  @spec create_collection(Scope.t(), map()) :: {:ok, map()} | {:error, term()}
  def create_collection(scope, definition),
    do: scope |> Collections.create(definition) |> notified(scope)

  @spec alter_collection(Scope.t(), String.t(), term()) :: {:ok, map()} | {:error, term()}
  def alter_collection(scope, name, operations),
    do: scope |> Collections.alter(name, operations) |> notified(scope)

  @spec drop_collection(Scope.t(), String.t(), term()) :: :ok | {:error, term()}
  def drop_collection(scope, name, confirm),
    do: scope |> Collections.drop(name, confirm) |> notified(scope)

  # -- records ----------------------------------------------------------------

  @doc "Creates one record. `input`: `data`, optional `id`."
  @spec create(Scope.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def create(scope, collection, input),
    do: single(scope, Map.merge(input, %{"op" => "create", "collection" => collection}))

  @doc "Partially updates a record. `input`: `data`, optional `version`."
  @spec update(Scope.t(), String.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def update(scope, collection, id, input),
    do: single(scope, Map.merge(input, %{"op" => "update", "collection" => collection, "id" => id}))

  @doc "Deletes a record. `input`: optional `version`."
  @spec delete(Scope.t(), String.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def delete(scope, collection, id, input \\ %{}),
    do: single(scope, Map.merge(input, %{"op" => "delete", "collection" => collection, "id" => id}))

  @doc "Creates or updates the record matching `key`. `input`: `key`, `data`, optional `id`, `version`."
  @spec upsert(Scope.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def upsert(scope, collection, input),
    do: single(scope, Map.merge(input, %{"op" => "upsert", "collection" => collection}))

  @doc "Creates many records in one transaction (all or nothing)."
  @spec bulk_create(Scope.t(), String.t(), [map()]) :: {:ok, map()} | {:error, term()}
  def bulk_create(scope, collection, records) when is_list(records) do
    ops =
      Enum.map(records, &Map.merge(bulk_input(&1), %{"op" => "create", "collection" => collection}))

    transact(scope, ops)
  end

  def bulk_create(_scope, _collection, _records),
    do: {:error, {:validation, ["records must be a list"]}}

  @doc "Runs a batch of writes that commit or roll back together."
  @spec transact(Scope.t(), [map()]) :: {:ok, map()} | {:error, term()}
  def transact(%Scope{} = scope, operations) do
    case Records.transact(scope, operations) do
      {:ok, result} ->
        after_commit(scope, result)
        {:ok, Map.take(result, [:results, :txn_id, :last_seq])}

      error ->
        error
    end
  end

  defp single(scope, op) do
    case transact(scope, [op]) do
      {:ok, %{results: [result], last_seq: seq}} -> {:ok, Map.put(result, "seq", seq)}
      {:error, {:operation_failed, 0, reason}} -> {:error, reason}
      error -> error
    end
  end

  defp bulk_input(%{"data" => _} = input), do: input
  defp bulk_input(%{} = data), do: %{"data" => data}
  defp bulk_input(other), do: %{"data" => other}

  defp after_commit(scope, result) do
    Changes.notify(scope.tenant_id, scope.workspace_id, result.last_seq)
    Semantic.index_written(result.written)
  end

  # -- reads ------------------------------------------------------------------

  defdelegate get(scope, collection, id, spec \\ %{}), to: Query
  defdelegate query(scope, collection, spec), to: Query, as: :run
  defdelegate changes(scope, opts), to: Changes, as: :list
  defdelegate rebuild_embeddings(scope, collection), to: Semantic, as: :rebuild

  # -- files, keys, migrations ------------------------------------------------

  defdelegate upload_file(scope, collection, id, attrs), to: Files, as: :upload
  defdelegate list_files(scope, collection, id), to: Files, as: :list
  defdelegate open_file(scope, collection, id, file_id), to: Files, as: :open
  defdelegate delete_file(scope, collection, id, file_id), to: Files, as: :delete

  defdelegate mint_key(scope, parent, attrs), to: Keys, as: :mint
  defdelegate list_keys(scope), to: Keys, as: :list
  defdelegate revoke_key(scope, id), to: Keys, as: :revoke

  @spec migrate(Scope.t(), map()) :: {:ok, map()} | {:error, term()}
  def migrate(scope, body), do: scope |> Migrations.apply(body) |> notified(scope)

  defdelegate migrations(scope, app), to: Migrations, as: :list

  @doc "Capabilities and limits of this Engine's app data layer."
  @spec capabilities() :: map()
  def capabilities do
    %{
      "storage" => "sqlite",
      "writer" => "single serialized writer (embedded SQLite)",
      "field_types" => OptimalEngine.AppData.Schema.types(),
      "operations" => Scope.operations(),
      "max_batch" => Records.max_batch(),
      "max_file_bytes" => Files.max_bytes(),
      "full_text" => "sqlite fts5",
      "semantic" => Semantic.status()
    }
  end

  defp notified({:ok, _} = result, scope), do: tap(result, fn _ -> notify_latest(scope) end)
  defp notified(:ok, scope), do: tap(:ok, fn _ -> notify_latest(scope) end)
  defp notified(error, _scope), do: error

  defp notify_latest(scope) do
    case Changes.latest_seq(scope) do
      {:ok, seq} -> Changes.notify(scope.tenant_id, scope.workspace_id, seq)
      _ -> :ok
    end
  end
end
