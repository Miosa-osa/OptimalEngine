defmodule OptimalEngine.Connectors.Registry do
  @moduledoc """
  Registry of available connector adapters.

  The registry is compile-time static — every adapter module declares
  its `kind/0`, and the registry enumerates them so CLI + admin UI
  can present a list without reflection tricks.

  Adding a new adapter: implement `OptimalEngine.Connectors.Behaviour`
  and append the module to `@adapters` below. That's the only wiring.
  """

  alias OptimalEngine.Connectors.Adapters

  @adapters [
    Adapters.Slack,
    Adapters.Gmail,
    Adapters.Drive,
    Adapters.Notion,
    Adapters.Jira,
    Adapters.Linear,
    Adapters.GitHub,
    Adapters.Zoom,
    Adapters.Confluence,
    Adapters.Teams,
    Adapters.Dropbox,
    Adapters.OneDrive,
    Adapters.Salesforce,
    Adapters.HubSpot,
    Adapters.GoHighLevel,
    Adapters.Stripe,
    Adapters.Beehiiv,
    Adapters.JotForm,
    Adapters.Fathom,
    Adapters.SourcesFolder
  ]

  @doc "All registered adapter modules."
  @spec all() :: [module()]
  def all, do: @adapters

  @doc "Look up an adapter module by its `kind/0` atom."
  @spec fetch(atom()) :: {:ok, module()} | {:error, :unknown_kind}
  def fetch(kind) when is_atom(kind) do
    Enum.find(@adapters, fn mod -> mod.kind() == kind end)
    |> case do
      nil -> {:error, :unknown_kind}
      mod -> {:ok, mod}
    end
  end

  @doc """
  Look up an adapter module by the name of its kind (a string, as stored in
  the `connectors.kind` column and sent over HTTP).

  This does not go through `String.to_existing_atom/1`: an adapter module
  creates the atom its `kind/0` returns only once it is loaded, which in a
  node that loads modules on demand (development, tests) is not yet the case
  for an adapter nobody has used, so that lookup refuses a kind the Engine
  supports. A name that is not a kind makes no atom.
  """
  @spec fetch_by_name(term(), [module()]) :: {:ok, module()} | {:error, :unknown_kind}
  def fetch_by_name(name, adapters \\ @adapters)

  def fetch_by_name(name, adapters) when is_binary(name) do
    case Enum.find(adapters, fn mod -> Atom.to_string(mod.kind()) == name end) do
      nil -> {:error, :unknown_kind}
      mod -> {:ok, mod}
    end
  end

  def fetch_by_name(_name, _adapters), do: {:error, :unknown_kind}

  @doc "Returns `[{kind, display_name, auth_scheme}]` — useful for listing in CLIs."
  @spec summary() :: [{atom(), String.t(), atom()}]
  def summary do
    Enum.map(@adapters, fn mod -> {mod.kind(), mod.display_name(), mod.auth_scheme()} end)
  end

  @doc "Returns the set of `kind` atoms known to the registry."
  @spec kinds() :: [atom()]
  def kinds, do: Enum.map(@adapters, & &1.kind())
end
