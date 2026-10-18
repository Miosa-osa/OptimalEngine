defmodule OptimalEngine.Authority.Decision do
  @moduledoc """
  The decision point: one answer for whether a subject may take an action on
  a resource of a given data class, now.

  Order of evaluation:

  1. An active local deny matching the request wins outright.
  2. Every rule in the applicable packs (tenant, then workspace, then
     subject) that matches the request is collected.
  3. Any matching `deny` makes the decision deny; otherwise any matching
     `ask` makes it ask (approval required); otherwise any matching `allow`
     makes it allow.
  4. With no matching rule the answer is deny: authority is never implied.

  Limits are combined from every matching allow and ask rule, keeping the
  most restrictive: the smallest `max_ttl_seconds`, the smallest value per
  ceiling name, and delegation only if every such rule permits it.
  """

  alias OptimalEngine.Authority.{LocalDeny, Policy}

  @type request :: %{
          required(:tenant_id) => String.t(),
          required(:subject) => String.t(),
          required(:action) => String.t(),
          required(:resource) => String.t(),
          optional(:workspace_id) => String.t() | nil,
          optional(:data_class) => String.t()
        }

  @type t :: %{
          effect: :allow | :ask | :deny,
          reason: String.t(),
          rule_id: String.t() | nil,
          policy_id: String.t() | nil,
          policy_hash: String.t() | nil,
          matched: [map()],
          packs: [map()],
          max_ttl_seconds: pos_integer() | nil,
          ceiling: map(),
          delegable: boolean(),
          local_deny_id: String.t() | nil
        }

  @doc "Decides `request`. Missing `data_class` is treated as `internal`."
  @spec decide(map()) :: t()
  def decide(request) do
    request = normalize(request)

    case LocalDeny.matching(request.tenant_id, request) do
      %{} = deny ->
        %{base([]) | effect: :deny, reason: "local_deny", local_deny_id: deny.id}

      nil ->
        packs = Policy.applicable(request.tenant_id, request.workspace_id, request.subject)

        matched =
          for pack <- packs, rule <- pack.document["rules"], Policy.matches?(rule, request) do
            %{
              "policy_id" => pack.id,
              "policy_hash" => pack.hash,
              "scope" => pack.scope_type,
              "rule" => rule
            }
          end

        resolve(base(packs), matched)
    end
  end

  @doc "Request fields with defaults applied."
  @spec normalize(map()) :: map()
  def normalize(request) do
    request
    |> Map.new(fn {key, value} -> {to_atom_key(key), value} end)
    |> Map.put_new(:workspace_id, nil)
    |> Map.update(:data_class, "internal", &(&1 || "internal"))
  end

  defp resolve(decision, matched) do
    by_effect = Enum.group_by(matched, & &1["rule"]["effect"])

    cond do
      by_effect["deny"] ->
        first = hd(by_effect["deny"])
        %{choose(decision, first, matched) | effect: :deny, reason: "denied_by_rule"}

      by_effect["ask"] ->
        first = hd(by_effect["ask"])

        limits(
          %{choose(decision, first, matched) | effect: :ask, reason: "approval_required"},
          matched
        )

      by_effect["allow"] ->
        first = hd(by_effect["allow"])

        limits(
          %{choose(decision, first, matched) | effect: :allow, reason: "allowed_by_rule"},
          matched
        )

      true ->
        %{decision | effect: :deny, reason: "no_matching_rule"}
    end
  end

  defp choose(decision, match, matched) do
    %{
      decision
      | rule_id: match["rule"]["id"],
        policy_id: match["policy_id"],
        policy_hash: match["policy_hash"],
        matched: Enum.map(matched, &summary/1)
    }
  end

  defp limits(decision, matched) do
    granting = Enum.filter(matched, &(&1["rule"]["effect"] in ["allow", "ask"]))
    rules = Enum.map(granting, & &1["rule"])

    ttl =
      rules
      |> Enum.map(& &1["max_ttl_seconds"])
      |> Enum.reject(&is_nil/1)
      |> Enum.min(fn -> nil end)

    ceiling =
      Enum.reduce(rules, %{}, fn rule, acc ->
        Map.merge(acc, rule["ceiling"] || %{}, fn _name, a, b -> min(a, b) end)
      end)

    %{
      decision
      | max_ttl_seconds: ttl,
        ceiling: ceiling,
        delegable: rules != [] and Enum.all?(rules, &(&1["delegable"] == true))
    }
  end

  defp summary(match) do
    %{
      "policy_id" => match["policy_id"],
      "policy_hash" => match["policy_hash"],
      "scope" => match["scope"],
      "rule_id" => match["rule"]["id"],
      "effect" => match["rule"]["effect"]
    }
  end

  defp base(packs) do
    %{
      effect: :deny,
      reason: "no_matching_rule",
      rule_id: nil,
      policy_id: nil,
      policy_hash: nil,
      matched: [],
      packs:
        Enum.map(packs, fn pack ->
          %{
            "id" => pack.id,
            "hash" => pack.hash,
            "scope" => pack.scope_type,
            "version" => pack.version
          }
        end),
      max_ttl_seconds: nil,
      ceiling: %{},
      delegable: false,
      local_deny_id: nil
    }
  end

  @request_keys ~w(tenant_id subject action resource workspace_id data_class)
  defp to_atom_key(key) when is_atom(key), do: key
  defp to_atom_key(key) when key in @request_keys, do: String.to_existing_atom(key)
  defp to_atom_key(key), do: key

  @doc "A JSON-ready view of a decision."
  @spec to_map(t()) :: map()
  def to_map(decision) do
    decision
    |> Map.update!(:effect, &Atom.to_string/1)
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
  end
end
