defmodule OptimalEngine.DataContract do
  @moduledoc "Validates governed write contracts before data reaches canonical modules."

  @contracts %{
    entity: %{required: ~w(workspace_id entity_kind canonical_name), version: 1},
    mention: %{required: ~w(workspace_id surface_text), version: 1},
    relationship: %{
      required: ~w(workspace_id from_entity_id to_entity_id relationship_type actor_id),
      version: 1
    }
  }

  def validate(type, attrs) when is_map(attrs) do
    case Map.fetch(@contracts, type) do
      {:ok, contract} ->
        missing =
          Enum.filter(
            contract.required,
            &blank?(Map.get(attrs, &1) || Map.get(attrs, String.to_atom(&1)))
          )

        if missing == [] do
          {:ok, %{type: type, schema_version: contract.version, attrs: attrs}}
        else
          {:error,
           {:contract_violation, %{type: type, missing: missing, schema_version: contract.version}}}
        end

      :error ->
        {:error, {:unknown_contract, type}}
    end
  end

  defp blank?(value), do: value in [nil, ""]
end
