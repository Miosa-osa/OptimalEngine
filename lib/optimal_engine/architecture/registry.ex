defmodule OptimalEngine.Architecture.Registry do
  @moduledoc """
  Compile-time + runtime registry of data architectures.

  Built-ins are declared at compile time. Tenant-specific
  architectures persist in the `architectures` SQL table (migration
  025) and are fetched on demand.

  Adding a new built-in: implement a module with `definition/0`
  returning an `%Architecture{}` and add it to `@built_ins`. That's
  the only wiring.
  """

  alias OptimalEngine.Architecture.Architecture
  alias OptimalEngine.Architecture.Architectures
  alias OptimalEngine.Architecture.Field
  alias OptimalEngine.Architecture.ProcessorRegistry
  alias OptimalEngine.SafeAtom

  alias OptimalEngine.Store

  @built_ins [
    Architectures.TextSignal,
    Architectures.ImageAsset,
    Architectures.AudioTranscript,
    Architectures.StructuredRecord,
    Architectures.TimeSeriesWindow,
    Architectures.CodeCommit,
    Architectures.MultimodalMedia
  ]

  @doc "Every built-in architecture, resolved."
  @spec built_ins() :: [Architecture.t()]
  def built_ins do
    Enum.map(@built_ins, & &1.definition())
  end

  @doc "Summary triples — useful for CLI listings."
  @spec summary() :: [{atom(), String.t(), Field.modality()}]
  def summary do
    Enum.map(built_ins(), fn a ->
      {String.to_atom(a.name), a.description || "", a.modality_primary}
    end)
  end

  @doc """
  Look up an architecture by id or name. Checks built-ins first,
  then falls through to the `architectures` table for tenant-defined
  schemas. Returns `{:ok, %Architecture{}}` or `{:error, :not_found}`.
  """
  @spec fetch(String.t(), keyword()) :: {:ok, Architecture.t()} | {:error, :not_found}
  def fetch(id_or_name, opts \\ []) when is_binary(id_or_name) do
    tenant_id = Keyword.get(opts, :tenant_id, "default")

    case find_built_in(id_or_name) do
      {:ok, _} = ok -> ok
      :error -> fetch_from_store(id_or_name, tenant_id)
    end
  end

  @doc "Bang variant for the happy path."
  @spec fetch!(String.t(), keyword()) :: Architecture.t()
  def fetch!(id_or_name, opts \\ []) do
    case fetch(id_or_name, opts) do
      {:ok, arch} -> arch
      {:error, _} -> raise ArgumentError, "unknown architecture: #{inspect(id_or_name)}"
    end
  end

  @doc "Persist a custom architecture into the tenant's store."
  @spec register(Architecture.t(), keyword()) :: :ok | {:error, term()}
  def register(%Architecture{} = arch, opts \\ []) do
    tenant_id = Keyword.get(opts, :tenant_id, "default")
    spec_json = Jason.encode!(Architecture.to_spec(arch))

    sql = """
    INSERT INTO architectures (id, tenant_id, name, version, description, modality_primary, spec)
    VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
    ON CONFLICT(tenant_id, name, version) DO UPDATE SET
      description = excluded.description,
      modality_primary = excluded.modality_primary,
      spec = excluded.spec
    """

    case Store.raw_query(sql, [
           arch.id,
           tenant_id,
           arch.name,
           arch.version,
           arch.description,
           Atom.to_string(arch.modality_primary),
           spec_json
         ]) do
      {:ok, _} -> :ok
      other -> other
    end
  end

  @doc "List every architecture visible to a tenant — built-ins + custom."
  @spec list(keyword()) :: [Architecture.t()]
  def list(opts \\ []) do
    tenant_id = Keyword.get(opts, :tenant_id, "default")
    custom = list_custom(tenant_id)

    # Built-ins win on name collision — a tenant can't shadow a built-in
    # id without a version bump.
    built_in_ids = MapSet.new(built_ins(), & &1.id)
    custom = Enum.reject(custom, fn a -> MapSet.member?(built_in_ids, a.id) end)

    built_ins() ++ custom
  end

  # ─── private ─────────────────────────────────────────────────────────────

  defp find_built_in(id_or_name) do
    Enum.find_value(built_ins(), :error, fn arch ->
      if arch.id == id_or_name or arch.name == id_or_name, do: {:ok, arch}
    end)
  end

  defp fetch_from_store(id_or_name, tenant_id) do
    sql = """
    SELECT id, name, version, description, modality_primary, spec
    FROM architectures
    WHERE tenant_id = ?1 AND (id = ?2 OR name = ?2)
    ORDER BY version DESC LIMIT 1
    """

    case Store.raw_query(sql, [tenant_id, id_or_name]) do
      {:ok, [row]} -> {:ok, row_to_architecture(row, vocabulary())}
      {:ok, []} -> {:error, :not_found}
      _ -> {:error, :not_found}
    end
  end

  defp list_custom(tenant_id) do
    sql = """
    SELECT id, name, version, description, modality_primary, spec
    FROM architectures
    WHERE tenant_id = ?1
    ORDER BY name, version DESC
    """

    case Store.raw_query(sql, [tenant_id]) do
      {:ok, rows} ->
        vocab = vocabulary()
        Enum.map(rows, &row_to_architecture(&1, vocab))

      _ ->
        []
    end
  end

  # The atoms a stored architecture's text may name: the modalities and
  # processors the engine implements, and the granularity and retention values
  # the built-in architectures use.
  defp vocabulary do
    built_ins = built_ins()

    %{
      modalities: Field.modalities(),
      processors: ProcessorRegistry.ids(),
      granularity: built_ins |> Enum.flat_map(& &1.granularity) |> Enum.uniq(),
      retention: built_ins |> Enum.map(& &1.retention) |> Enum.uniq()
    }
  end

  # A row is stored data (it can arrive from a peer or a bundle), so none of
  # its text becomes an atom unless it names something in `vocabulary`:
  #
  #   * a modality outside the known ones reads as `:binary`, the opaque
  #     fallback;
  #   * a processor outside the registered ones reads as no processor hint;
  #   * a field name, and a granularity or retention value the built-ins do
  #     not use, stay text.
  defp row_to_architecture(
         [id, name, version, description, modality_primary, spec_json],
         vocab
       ) do
    spec = decode_spec(spec_json)

    fields =
      spec
      |> Map.get("fields")
      |> List.wrap()
      |> Enum.map(fn f ->
        %Field{
          name: to_string(f["name"]),
          modality: SafeAtom.cast(f["modality"], vocab.modalities, :binary),
          dims: Enum.map(f["dims"] || [], &parse_dim/1),
          required: f["required"] || false,
          processor: SafeAtom.cast(f["processor"], vocab.processors, nil),
          description: f["description"]
        }
      end)

    %Architecture{
      id: id,
      name: name,
      version: version,
      description: description,
      modality_primary: SafeAtom.cast(modality_primary, vocab.modalities, :binary),
      fields: fields,
      granularity:
        (spec["granularity"] || ["document"])
        |> List.wrap()
        |> Enum.map(&SafeAtom.cast_or_string(&1, vocab.granularity)),
      retention: SafeAtom.cast_or_string(spec["retention"] || "default", vocab.retention),
      metadata: spec["metadata"] || %{}
    }
  end

  defp decode_spec(nil), do: %{}
  defp decode_spec(""), do: %{}

  defp decode_spec(json) do
    case Jason.decode(json) do
      {:ok, m} when is_map(m) -> m
      _ -> %{}
    end
  end

  defp parse_dim("any"), do: :any
  defp parse_dim(n) when is_integer(n), do: n
  defp parse_dim(_), do: :any
end
