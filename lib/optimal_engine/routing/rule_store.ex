defmodule OptimalEngine.Routing.RuleStore do
  @moduledoc """
  Per-workspace routing rules stored in the Engine and applied to incoming
  material (connector messages, uploads, intake).

  A rule says: when `field` matches `pattern`, the material probably belongs
  to `workspace_id`, with a `weight`. Fields are `sender` (an address),
  `domain` (the sender's domain), `label` (a mailbox or connector label),
  `channel` (a chat channel), and `keyword` (a word or phrase in the text).
  Matching is case-insensitive; keywords match whole words.

  `classify/2` scores every workspace and proposes the best one with a
  confidence (`high` needs a score of at least 8 and a margin of 5 over the
  runner-up, matching the corpus organizer). `feedback/3` records an accept
  or reject for the rules that fired, and each rule's effective weight moves
  with its record: `weight * (1 + accepted) / (1 + rejected)`.

  `seed_from_routing_file/1` loads the keyword rules of the deployment's
  routing rules file (`OptimalEngine.RoutingRules`) as `seed` rules.
  """

  alias OptimalEngine.Store

  @fields ~w(sender domain label channel keyword)
  @minimum_score 8
  @minimum_margin 5

  @doc "The rule fields."
  @spec fields() :: [String.t()]
  def fields, do: @fields

  @doc "Adds a rule (or returns the existing one for the same field and pattern)."
  @spec add(String.t(), map(), String.t()) :: {:ok, map()} | {:error, atom()}
  def add(tenant_id, attrs, created_by) do
    attrs = Map.new(attrs, fn {key, value} -> {to_string(key), value} end)
    field = attrs["field"]
    pattern = attrs["pattern"] |> to_string() |> String.trim() |> String.downcase()
    weight = attrs["weight"] || 5
    source = attrs["source"] || "manual"

    cond do
      not (is_binary(attrs["workspace_id"]) and attrs["workspace_id"] != "") ->
        {:error, :workspace_id_required}

      field not in @fields ->
        {:error, :invalid_field}

      pattern == "" ->
        {:error, :pattern_required}

      not (is_integer(weight) and weight in 1..20) ->
        {:error, :invalid_weight}

      source not in ~w(seed manual learned) ->
        {:error, :invalid_source}

      true ->
        insert(tenant_id, attrs["workspace_id"], field, pattern, weight, source, created_by)
    end
  end

  @doc "Rules in the tenant, optionally for one workspace."
  @spec list(String.t(), keyword()) :: [map()]
  def list(tenant_id, opts \\ []) do
    {sql, params} =
      case opts[:workspace_id] do
        nil -> {"WHERE tenant_id = ?1", [tenant_id]}
        workspace_id -> {"WHERE tenant_id = ?1 AND workspace_id = ?2", [tenant_id, workspace_id]}
      end

    {:ok, rows} =
      Store.raw_query(select_sql() <> sql <> " ORDER BY workspace_id, field, pattern", params)

    Enum.map(rows, &to_rule/1)
  end

  @doc "Deletes a rule."
  @spec delete(String.t(), String.t()) :: :ok | {:error, :not_found}
  def delete(tenant_id, id) do
    case Store.transaction(fn txn ->
           Store.txn_execute(txn, "DELETE FROM routing_rules WHERE tenant_id = ?1 AND id = ?2", [
             tenant_id,
             id
           ])
         end) do
      {:ok, 1} -> :ok
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Proposes a workspace for `material`: a map with any of `text`, `title`,
  `sender`, `labels`, `channel`. Returns the proposal, its confidence
  (`high`, `review`, `unresolved`), the score margin, and the rules that
  fired (so feedback can be recorded against them).
  """
  @spec classify(String.t(), map()) :: map()
  def classify(tenant_id, material) do
    material = Map.new(material, fn {key, value} -> {to_string(key), value} end)
    sender = material["sender"] |> to_string() |> String.downcase() |> extract_address()
    domain = sender |> String.split("@") |> Enum.at(1)
    labels = material["labels"] |> List.wrap() |> Enum.map(&String.downcase(to_string(&1)))
    channel = material["channel"] && String.downcase(to_string(material["channel"]))
    text = String.downcase("#{material["title"]}\n#{material["text"]}")

    fired =
      tenant_id
      |> list()
      |> Enum.filter(fn rule ->
        case rule.field do
          "sender" ->
            sender != "" and sender == rule.pattern

          "domain" ->
            domain != nil and
              (domain == rule.pattern or String.ends_with?(domain, "." <> rule.pattern))

          "label" ->
            rule.pattern in labels

          "channel" ->
            channel == rule.pattern

          "keyword" ->
            Regex.match?(~r/(?<![[:alnum:]])#{Regex.escape(rule.pattern)}(?![[:alnum:]])/u, text)
        end
      end)

    ranked =
      fired
      |> Enum.group_by(& &1.workspace_id)
      |> Enum.map(fn {workspace_id, rules} ->
        {workspace_id, rules |> Enum.map(&effective_weight/1) |> Enum.sum() |> Float.round(2),
         rules}
      end)
      |> Enum.sort_by(fn {_workspace, score, _rules} -> score end, :desc)

    case ranked do
      [] ->
        %{
          workspace_id: nil,
          proposed_workspace_id: nil,
          confidence: :unresolved,
          score: 0.0,
          margin: 0.0,
          rules: []
        }

      [{workspace_id, score, rules} | rest] ->
        second =
          case rest do
            [{_, second, _} | _] -> second
            [] -> 0.0
          end

        margin = Float.round(score - second, 2)

        confidence =
          if score >= @minimum_score and margin >= @minimum_margin, do: :high, else: :review

        %{
          workspace_id: if(confidence == :high, do: workspace_id),
          proposed_workspace_id: workspace_id,
          confidence: confidence,
          score: score,
          margin: margin,
          rules: Enum.map(rules, & &1.id),
          alternatives: Enum.map(rest, fn {id, s, _} -> %{workspace_id: id, score: s} end)
        }
    end
  end

  @doc """
  Records an `accept` or `reject` for the rules that fired on a routing
  decision. A reject of a `high` route is how a wrong rule loses weight.
  """
  @spec feedback(String.t(), [String.t()], :accept | :reject) :: {:ok, non_neg_integer()}
  def feedback(tenant_id, rule_ids, decision)
      when decision in [:accept, :reject] and is_list(rule_ids) do
    column = if decision == :accept, do: "accepted", else: "rejected"

    updated =
      Enum.count(rule_ids, fn id ->
        match?(
          {:ok, 1},
          Store.transaction(fn txn ->
            Store.txn_execute(
              txn,
              "UPDATE routing_rules SET #{column} = #{column} + 1 WHERE tenant_id = ?1 AND id = ?2",
              [tenant_id, id]
            )
          end)
        )
      end)

    {:ok, updated}
  end

  @doc "Loads the routing file's keyword rules as seed rules."
  @spec seed_from_routing_file(String.t()) :: {:ok, non_neg_integer()}
  def seed_from_routing_file(tenant_id) do
    seeded =
      for {workspace_id, markers} <- OptimalEngine.CorpusOrganizer.rules(),
          {marker, weight} <- markers,
          match?(
            {:ok, _},
            add(
              tenant_id,
              %{
                "workspace_id" => workspace_id,
                "field" => "keyword",
                "pattern" => marker,
                "weight" => min(weight, 20),
                "source" => "seed"
              },
              "engine:seed"
            )
          ) do
        marker
      end

    {:ok, length(seeded)}
  end

  @doc "A rule's weight adjusted by its accept and reject record."
  @spec effective_weight(map()) :: float()
  def effective_weight(rule), do: rule.weight * (1 + rule.accepted) / (1 + rule.rejected)

  # ---------------------------------------------------------------------------

  defp insert(tenant_id, workspace_id, field, pattern, weight, source, created_by) do
    id = "rr_" <> (:crypto.strong_rand_bytes(9) |> Base.url_encode64(padding: false))

    {:ok, _} =
      Store.raw_query(
        """
        INSERT OR IGNORE INTO routing_rules (id, tenant_id, workspace_id, field, pattern, weight, source, created_by)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
        """,
        [id, tenant_id, workspace_id, field, pattern, weight, source, created_by]
      )

    case Store.raw_query(
           select_sql() <>
             "WHERE tenant_id = ?1 AND workspace_id = ?2 AND field = ?3 AND pattern = ?4",
           [tenant_id, workspace_id, field, pattern]
         ) do
      {:ok, [row]} -> {:ok, to_rule(row)}
      _ -> {:error, :not_found}
    end
  end

  defp extract_address(value) do
    case Regex.run(~r/[^\s<>"]+@[^\s<>"]+/, value) do
      [address] -> address
      _ -> value
    end
  end

  defp select_sql do
    "SELECT id, tenant_id, workspace_id, field, pattern, weight, source, accepted, rejected, created_by, created_at FROM routing_rules "
  end

  defp to_rule([
         id,
         tenant_id,
         workspace_id,
         field,
         pattern,
         weight,
         source,
         accepted,
         rejected,
         by,
         at
       ]) do
    %{
      id: id,
      tenant_id: tenant_id,
      workspace_id: workspace_id,
      field: field,
      pattern: pattern,
      weight: weight,
      source: source,
      accepted: accepted,
      rejected: rejected,
      created_by: by,
      created_at: at
    }
  end
end
