defmodule OptimalEngine.Connectors.Routing do
  @moduledoc """
  Where a connector's Signals land, and what they leave behind.

  A connector hands the Engine a stream of Signals. This module decides, per
  Signal, which workspace it belongs to, records the open loops it implies,
  and tags it as outward evidence when the connector says its source is
  outside the organization.

  ## Order of routing

  1. The connector's own workspace. A connector row is registered against one
     workspace, which is the explicit mapping of CONNECTORS.md: a Gmail label,
     a Slack channel, a GHL location, a Stripe account is pinned when the
     connector is created. Everything that no rule claims stays here.
  2. The stored routing rules (`OptimalEngine.Routing.RuleStore`), matched on
     the Signal's sender, domain, label, channel, and keywords. A `high`
     confidence route wins, so a person or company the operator has already
     mapped claims their mail wherever it arrives. A `review` confidence route
     goes to the review workspace when the connector names one, and otherwise
     stays put.
  3. Walled workspaces are only reached by an explicit identity mapping
     (sender, domain, label, or channel rule). A keyword is a guess, and a
     guess never opens a private view.

  ## Where the rule material comes from

  `material/2` reads what a Signal can honestly say about itself:

    * `sender` — the first email-shaped entity, which adapters set from the
      message's From header or the record's contact
    * `title` and `text` — the Signal's title and content, which the keyword
      rules match against
    * `labels` and `channel` — `config.routing_labels` and
      `config.routing_channel`, falling back to the source's own `labels` or
      `channels` list, because a per-message label is not part of a Signal

  ## Configuration keys

      "routing_labels":           ["invoices", "clients"]  (optional)
      "routing_channel":          "#clients"               (optional)
      "review_workspace_id":      "acme:review"            (optional)
      "routing_walled_workspaces": ["hq", "legal"]         (optional)
      "outward_topic":            "customers"              (optional)

  `review_workspace_id` must be a workspace the connector's tenant may place a
  Signal in: one of its active workspaces or, for the default tenant only, an
  id nobody registered that is not named for another tenant. A route that
  names a workspace of another tenant, whether by this key or by a routing
  rule, is not taken, and the Engine logs it.

  `outward_topic` must be one of `OptimalEngine.Viability.SignalEvents.outward_topics/0`.
  When it is set, every Signal this connector produces is recorded as an
  `outward` event on the workspace, which is what System 4 reads to see the
  outside world.
  """

  require Logger

  alias OptimalEngine.Connectors.Rows
  alias OptimalEngine.Operating.Loops
  alias OptimalEngine.Pipeline.Intake
  alias OptimalEngine.Routing.RuleStore
  alias OptimalEngine.Signal
  alias OptimalEngine.Viability.SignalEvents

  @identity_fields ~w(sender domain label channel)
  @email ~r/[^\s<>",;]+@[^\s<>",;]+\.[A-Za-z]{2,}/

  @doc """
  Rejects a connector config that names something this module cannot honor, so
  a typo is caught when the connector is registered rather than silently
  ignored on every sync.
  """
  @spec validate_config(map()) :: :ok | {:error, atom()}
  def validate_config(config) when is_map(config) do
    cond do
      not valid_topic?(config) ->
        {:error, :invalid_outward_topic}

      not is_list(value(config, "routing_walled_workspaces") || []) ->
        {:error, :invalid_walled_workspaces}

      true ->
        :ok
    end
  end

  @doc """
  `validate_config/1`, and the review workspace the config names must be a
  workspace the tenant may place a Signal in (`Rows.routable_workspace?/2`):
  `{:error, :invalid_review_workspace}` otherwise. With `review_workspace:
  false` the review workspace is not checked, for a change that does not touch
  it: a connector registered before the check can still be disabled or
  retuned.
  """
  @spec validate_config(map(), String.t(), keyword()) :: :ok | {:error, atom()}
  def validate_config(config, tenant_id, opts \\ []) when is_map(config) do
    with :ok <- validate_config(config) do
      case value(config, "review_workspace_id") do
        workspace_id when is_nil(workspace_id) or workspace_id == "" ->
          :ok

        workspace_id ->
          if Keyword.get(opts, :review_workspace, true) == false or
               Rows.routable_workspace?(tenant_id, workspace_id),
             do: :ok,
             else: {:error, :invalid_review_workspace}
      end
    end
  end

  @doc """
  The workspace a connector Signal belongs to, with the decision that produced
  it. `default_workspace` is the connector's own workspace.

  A route names a workspace of the tenant or it is not taken: a rule, or a
  connector row written before the review workspace was checked, that names a
  workspace of another tenant leaves the Signal in `default_workspace`.
  """
  @spec workspace_for(String.t(), Signal.t(), map(), String.t()) :: map()
  def workspace_for(tenant_id, %Signal{} = signal, config, default_workspace) do
    decision = RuleStore.classify(tenant_id, material(signal, config))

    proposed =
      cond do
        decision.confidence == :high and claims?(tenant_id, config, decision) ->
          decision.workspace_id

        decision.confidence == :review ->
          present(value(config, "review_workspace_id"))

        true ->
          nil
      end

    {workspace_id, refused} =
      cond do
        is_nil(proposed) -> {default_workspace, nil}
        Rows.routable_workspace?(tenant_id, proposed) -> {proposed, nil}
        true -> {default_workspace, proposed}
      end

    %{
      workspace_id: workspace_id || default_workspace,
      decision: decision,
      default_workspace_id: default_workspace,
      refused_workspace_id: refused
    }
  end

  @doc """
  The rule material for a Signal plus its connector config. See the module
  doc for which config keys supply labels and channel.
  """
  @spec material(Signal.t(), map()) :: map()
  def material(%Signal{} = signal, config) do
    %{
      "sender" => sender(signal),
      "title" => signal.title || "",
      "text" => signal.content || "",
      "labels" => labels(config),
      "channel" => present(value(config, "routing_channel"))
    }
  end

  defp source_uri("optimal://" <> _rest = uri), do: uri
  defp source_uri(_path), do: nil

  @doc """
  Drives one connector Signal through intake into its workspace, then records
  what it leaves behind: the open loops it implies, and an `outward` event when
  the connector names an outward topic.

  Returns the workspace, the stored context's uri, the loops created, and
  whether an outward event was recorded.
  """
  @spec intake_signal(String.t(), Signal.t(), map()) :: {:ok, map()} | {:error, term()}
  def intake_signal(tenant_id, %Signal{} = signal, scope) do
    config = Map.get(scope, :config, %{})
    default_workspace = Map.get(scope, :workspace_id, "default")
    placed = workspace_for(tenant_id, signal, config, default_workspace)
    warn_refused(tenant_id, placed, Map.get(scope, :connector_id))

    # A pulled item is stored in the database only, once per source item, and
    # dated when it happened. A connector that wants markdown files on disk
    # sets `"write_files": true`.
    intake_opts =
      [
        workspace_id: placed.workspace_id,
        tenant_id: tenant_id,
        genre: signal.genre,
        title: signal.title,
        entities: signal.entities || [],
        write_files: value(config, "write_files") == true,
        source_id: signal.id,
        source_uri: source_uri(signal.path),
        occurred_at: signal.created_at
      ]
      |> Keyword.reject(fn {_key, value} -> is_nil(value) end)

    case Intake.process(signal.content || "", intake_opts) do
      {:ok, result} ->
        context_id = context_id(result)

        loops =
          extract_loops(tenant_id, placed.workspace_id, signal,
            context_id: context_id,
            source_uri: Map.get(result, :uri),
            connector_id: Map.get(scope, :connector_id)
          )

        outward = record_outward(tenant_id, placed.workspace_id, signal, config, context_id)

        {:ok,
         %{
           workspace_id: placed.workspace_id,
           decision: placed.decision,
           uri: Map.get(result, :uri),
           context_id: context_id,
           loops: loops,
           outward: outward
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp warn_refused(_tenant_id, %{refused_workspace_id: nil}, _connector_id), do: :ok

  defp warn_refused(tenant_id, placed, connector_id) do
    Logger.warning(
      "[Connectors.Routing] connector #{inspect(connector_id)}: the route to #{inspect(placed.refused_workspace_id)} was not taken, it is not a workspace tenant #{inspect(tenant_id)} may place a Signal in; the Signal stays in #{inspect(placed.workspace_id)}"
    )
  end

  @doc """
  Detects the open loops a Signal implies and stores them against the
  workspace, linked back to the Signal's stored context. Detection uses the
  same deterministic rules as `Loops.extract/3`: a message that expects a
  reply, a commitment, money due, or a decision someone is waiting on.

  An empty content or a Signal with no commitment produces no loops and is not
  an error.
  """
  @spec extract_loops(String.t(), String.t(), Signal.t(), keyword()) :: [map()]
  def extract_loops(tenant_id, workspace_id, %Signal{} = signal, opts \\ []) do
    reference = reference_date(signal)
    context_id = Keyword.get(opts, :context_id)
    source_uri = Keyword.get(opts, :source_uri) || present(signal.path)

    "#{signal.title}\n#{signal.content}"
    |> Loops.detect(reference)
    |> Enum.flat_map(fn found ->
      attrs =
        Map.merge(found, %{
          "workspace_id" => workspace_id,
          "counterparty" => counterparty(signal),
          "detected" => true,
          "source_uri" => source_uri,
          "source_context_id" => context_id,
          "metadata" => %{
            "connector_id" => Keyword.get(opts, :connector_id),
            "signal_id" => signal.id
          }
        })

      case Loops.create(tenant_id, attrs, "engine:connector-intake") do
        {:ok, loop} ->
          [loop]

        {:error, reason} ->
          Logger.debug("[Connectors.Routing] loop not stored: #{inspect(reason)}")
          []
      end
    end)
  end

  @doc """
  Records an `outward` Signal event for a connector-ingested Signal when the
  connector config names an outward topic. Returns `true` when an event was
  recorded. A missing topic is not an error; an invalid one is logged and
  skipped rather than failing the ingest.
  """
  @spec record_outward(String.t(), String.t(), Signal.t(), map(), String.t() | nil) :: boolean()
  def record_outward(tenant_id, workspace_id, %Signal{} = signal, config, context_id \\ nil) do
    case outward_topic(config) do
      {:ok, topic} ->
        SignalEvents.note(tenant_id, %{
          "workspace_id" => workspace_id,
          "kind" => "outward",
          "topic" => topic,
          "context_id" => context_id,
          "ref" => signal.id,
          "genre" => signal.genre,
          "mode" => mode_string(signal.mode),
          "occurred_at" => signal_occurred_at(signal),
          "metadata" => %{
            "connector_id" => Map.get(config, "connector_id"),
            "source_uri" => signal.path
          }
        })

        true

      :none ->
        false

      {:error, reason} ->
        Logger.warning("[Connectors.Routing] outward topic ignored: #{inspect(reason)}")
        false
    end
  end

  @doc "The connector's outward topic: `{:ok, topic}`, `:none`, or an error."
  @spec outward_topic(map()) :: {:ok, String.t()} | :none | {:error, atom()}
  def outward_topic(config) when is_map(config) do
    case present(value(config, "outward_topic")) do
      nil ->
        :none

      topic ->
        if topic in SignalEvents.outward_topics(),
          do: {:ok, topic},
          else: {:error, :invalid_outward_topic}
    end
  end

  # ─── private ─────────────────────────────────────────────────────────────

  # A walled or private workspace is only claimed by an explicit identity
  # mapping. A keyword rule can only ever propose it for review.
  defp claims?(tenant_id, config, decision) do
    walled = walled_workspaces(config)

    decision.workspace_id not in walled or
      decision.rules == [] or
      Enum.all?(decision.rules, &identity_rule?(tenant_id, &1))
  end

  # RuleStore.classify/2 returns rule ids, not rules, so the field of each
  # fired rule is read back. This costs one extra query, and only for a
  # connector that declares walled workspaces.
  defp identity_rule?(tenant_id, rule_id) do
    tenant_id
    |> RuleStore.list()
    |> Enum.find(fn rule -> rule.id == rule_id end)
    |> case do
      nil -> false
      rule -> rule.field in @identity_fields
    end
  end

  defp walled_workspaces(config) do
    case value(config, "routing_walled_workspaces") do
      list when is_list(list) -> Enum.map(list, &to_string/1)
      _ -> []
    end
  end

  defp labels(config) do
    case value(config, "routing_labels") do
      list when is_list(list) -> Enum.map(list, &to_string/1)
      _ -> fallback_labels(config)
    end
  end

  defp fallback_labels(config) do
    case value(config, "labels") || value(config, "channels") do
      list when is_list(list) -> Enum.map(list, &to_string/1)
      value when is_binary(value) -> [value]
      _ -> []
    end
  end

  # Adapters differ on whether an entity is a bare address or a display name
  # and address, so the address is pulled out of whichever shape arrives.
  # `RuleStore` reads the sender the same way.
  defp sender(%Signal{entities: entities}) when is_list(entities) do
    Enum.find_value(entities, &address/1)
  end

  defp sender(_signal), do: nil

  defp counterparty(%Signal{entities: entities}) when is_list(entities) do
    Enum.find_value(entities, &address/1)
  end

  defp counterparty(_signal), do: nil

  defp address(value) when is_binary(value) do
    case Regex.run(@email, value) do
      [address | _] -> String.trim(address)
      _ -> nil
    end
  end

  defp address(_value), do: nil

  defp reference_date(%Signal{modified_at: %DateTime{} = at}), do: DateTime.to_date(at)
  defp reference_date(_signal), do: Date.utc_today()

  defp signal_occurred_at(%Signal{modified_at: %DateTime{} = at}) do
    at |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  end

  defp signal_occurred_at(_signal), do: nil

  defp mode_string(mode) when is_atom(mode) and not is_nil(mode), do: Atom.to_string(mode)
  defp mode_string(mode) when is_binary(mode), do: mode
  defp mode_string(_mode), do: nil

  defp context_id(%{context: %{id: id}}) when is_binary(id), do: id
  defp context_id(_result), do: nil

  defp valid_topic?(config) do
    case outward_topic(config) do
      {:ok, _topic} -> true
      :none -> true
      {:error, _reason} -> false
    end
  end

  defp present(value) when is_binary(value) and value != "", do: value
  defp present(_value), do: nil

  defp value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, to_string(key))
  end
end
