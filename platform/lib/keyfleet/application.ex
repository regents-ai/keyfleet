defmodule Keyfleet.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    Keyfleet.ErrorHandlers.attach()

    children =
      [
        KeyfleetWeb.Telemetry,
        {Keyfleet.Accounts.RequestRateLimiter, []},
        database_child(),
        health_child(),
        {Phoenix.PubSub, name: Keyfleet.PubSub},
        # Failures a page read rescued, saved beside the page; past this many at
        # once, a failure is only logged.
        {Task.Supervisor, name: Keyfleet.ErrorSaves, max_children: 20},
        # Figures every visitor sees alike, read once for every open page; its
        # producers start after it.
        Keyfleet.SharedReading,
        # Jobs announce what they change, so they start after PubSub.
        oban_child(),
        KeyfleetWeb.Telemetry.site_poller(),
        # Who was let into a fleet's notebooks or code lately; a key changing
        # hands clears its holder at once, through PubSub.
        Keyfleet.AccessCache,
        agents_listener_child(),
        credits_listener_child(),
        # A key's profile reads its rewards wherever the site runs.
        Keyfleet.Chain.RewardsWaiting,
        graph_children(),
        here_child(),
        fleet_now_child(),
        fleet_proposals_child(),
        fleet_polls_child(),
        # Agent requests held open waiting for news, by client address.
        KeyfleetWeb.AgentWaits,
        # Start a worker by calling: Keyfleet.Worker.start_link(arg)
        # {Keyfleet.Worker, arg},
        # Start to serve requests, typically the last entry
        KeyfleetWeb.Endpoint,
        metrics_child()
      ]
      |> List.flatten()
      |> Enum.reject(&is_nil/1)

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Keyfleet.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp database_child do
    if Application.get_env(:keyfleet, :database_startup_enabled, false),
      do: Keyfleet.Repo
  end

  # `/healthz` asks the database through a connection of its own. Through the
  # site's pool it waited behind every page whenever pages kept all five
  # connections busy, and failed Fly's check on the site's only machine while
  # the database itself answered.
  defp health_child do
    if Application.get_env(:keyfleet, :database_startup_enabled, false) do
      # Postgrex's own pool, never the test suite's sandbox.
      options =
        Keyfleet.Repo.config()
        |> Keyword.drop([:pool])
        |> Keyword.merge(name: Keyfleet.Health, pool_size: 1)

      %{id: Keyfleet.Health, start: {Postgrex, :start_link, [options]}}
    end
  end

  # Background work lives in the database, so it starts with it. AshOban adds a
  # queue and a sweep for every trigger in the site's domains and in Regent
  # Credits, whose purchase checks and deposit reads run on this site's Oban.
  defp oban_child do
    if Application.get_env(:keyfleet, :database_startup_enabled, false) do
      domains = Application.fetch_env!(:keyfleet, :ash_domains) ++ [RegentCredits]
      {Oban, AshOban.config(domains, Application.fetch_env!(:keyfleet, Oban))}
    end
  end

  # Agent changes announced by any Regent site, through the database, reach
  # this site's pages; it needs the database and PubSub started first.
  defp agents_listener_child do
    if Application.get_env(:keyfleet, :database_startup_enabled, false),
      do: RegentAgents.Listener
  end

  # A Credits balance changed on any Regent site, announced through the
  # database, reaches the account pages showing it.
  defp credits_listener_child do
    if Application.get_env(:keyfleet, :database_startup_enabled, false),
      do: RegentCredits.Listener
  end

  # Metrics are served beside the site, never by a process that only runs a task.
  defp metrics_child do
    if serving?(), do: KeyfleetWeb.Metrics
  end

  # The agents here are read only where pages are served, so a task or a test
  # never reads them on its own.
  defp here_child do
    if serving?(), do: Keyfleet.Agents.Here
  end

  # What each fleet is doing is read only where pages are served, as the
  # agents here are.
  defp fleet_now_child do
    if serving?(), do: KeyfleetWeb.FleetNow
  end

  # The fleets' proposals, treasuries and polls are read only where pages are
  # served, as each fleet's activity is.
  defp fleet_proposals_child do
    if serving?(), do: KeyfleetWeb.FleetProposals
  end

  defp fleet_polls_child do
    if serving?(), do: KeyfleetWeb.FleetPolls
  end

  defp serving?, do: Phoenix.Endpoint.server?(:keyfleet, KeyfleetWeb.Endpoint)

  # The projectors read each fleet's log through its writer, so they start
  # after the writers.
  defp graph_children do
    if Keyword.fetch!(Application.fetch_env!(:keyfleet, :graph), :enabled),
      do: [Keyfleet.Graph.Supervisor, Keyfleet.Graph.Projectors]
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    KeyfleetWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
