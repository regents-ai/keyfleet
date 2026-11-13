defmodule Keyfleet.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    :ok = KeyfleetWeb.LiveCrashes.attach()
    :ok = RegentHttp.ErrorSaving.attach()
    :ok = KeyfleetWeb.VisitLog.Events.attach()
    # The Claude connector stays off until its one switch turns it on
    # (config/runtime.exs); these only check and store its settings.
    :ok = RegentOAuth.configure(Keyfleet.OAuth)
    :ok = RegentMCPAgents.configure!()

    children =
      Application.fetch_env!(:keyfleet, :machine)
      |> children()
      |> List.flatten()
      |> Enum.reject(&is_nil/1)

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Keyfleet.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # In production the site runs on two kinds of machine (fly.toml). The graph
  # machine keeps the fleets' graph logs on its volume and runs only their
  # writers and projectors; the site machine runs everything else and reaches
  # the writers over the cluster. Anywhere else, one machine runs the site.
  defp children(:graph) do
    [
      database_child(),
      cluster_child(),
      {Phoenix.PubSub, name: Keyfleet.PubSub},
      graph_processes_child(),
      {Task.Supervisor, name: Keyfleet.ErrorSaves, max_children: 20},
      Keyfleet.Graph.Supervisor,
      Keyfleet.Graph.Projectors
    ]
  end

  defp children(:site) do
    [
      KeyfleetWeb.Telemetry,
      {Keyfleet.Accounts.RequestRateLimiter, []},
      database_child(),
      oauth_repo_child(),
      cluster_child(),
      {Phoenix.PubSub, name: Keyfleet.PubSub},
      graph_processes_child(),
      # Failures a page read rescued, saved beside the page; past this many at
      # once, a failure is only logged.
      {Task.Supervisor, name: Keyfleet.ErrorSaves, max_children: 20},
      # Figures every reader they admit sees alike, read once for every open page; its
      # producers start after it.
      Keyfleet.SharedReading,
      # Jobs announce what they change, so they start after PubSub.
      oban_child(),
      KeyfleetWeb.Telemetry.site_poller(),
      # Who was let into a fleet's notebooks or code lately; a key changing
      # hands clears its holder at once, through PubSub.
      Keyfleet.AccessCache,
      # The wallet of each connected account's hosted identity, read once.
      Keyfleet.Agents.HostedAddress,
      # Each paired agent's activity, kept a few minutes for the account menu,
      # and the reads that fetch it.
      Keyfleet.Agents.ActivityReading,
      {Task.Supervisor, name: Keyfleet.Agents.Reads},
      # The share pictures last drawn, by what each shows.
      KeyfleetWeb.SharePictures,
      # After the repository and PubSub: a pairing made or ended on any Regent
      # site reaches the pages showing it.
      shared_changes_child(),
      # A key's profile reads its rewards wherever the site runs.
      Keyfleet.Chain.RewardsWaiting,
      graph_children(),
      here_child(),
      fleet_now_child(),
      fleet_proposals_child(),
      points_board_child(),
      # Agent requests held open waiting for news, by client address.
      KeyfleetWeb.AgentWaits,
      # Counts this machine's open agent feeds.
      KeyfleetWeb.FeedController,
      # Start a worker by calling: Keyfleet.Worker.start_link(arg)
      # {Keyfleet.Worker, arg},
      # Start to serve requests, typically the last entry
      KeyfleetWeb.Endpoint,
      metrics_child()
    ]
  end

  # The machines of one release find each other by their app's private DNS
  # name, so PubSub and the graph's writers reach across them.
  defp cluster_child do
    if query = Application.get_env(:keyfleet, :dns_cluster_query),
      do: {DNSCluster, query: query}
  end

  # The group the fleets' writers and projectors join, wherever they run.
  defp graph_processes_child,
    do: %{id: Keyfleet.Graph.Processes, start: {:pg, :start_link, [Keyfleet.Graph.Processes]}}

  defp database_child do
    if Application.get_env(:keyfleet, :database_startup_enabled, false),
      do: Keyfleet.Repo
  end

  # Connected apps' grants and tokens, in this site's database.
  defp oauth_repo_child do
    if Application.get_env(:keyfleet, :database_startup_enabled, false) and
         RegentOAuth.enabled?(),
       do: RegentOAuth.Repo
  end

  # Background work lives in the database, so it starts with it. AshOban adds a
  # queue and a sweep for every trigger in the site's domains.
  defp oban_child do
    if Application.get_env(:keyfleet, :database_startup_enabled, false) do
      domains = Application.fetch_env!(:keyfleet, :ash_domains)
      {Oban, AshOban.config(domains, Application.fetch_env!(:keyfleet, Oban))}
    end
  end

  defp shared_changes_child do
    if Application.get_env(:keyfleet, :database_startup_enabled, false),
      do: Keyfleet.SharedChanges
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

  # The fleets' proposals and treasuries are read only where pages are
  # served, as each fleet's activity is.
  defp fleet_proposals_child do
    if serving?(), do: KeyfleetWeb.FleetProposals
  end

  # The Points board is read only where pages are served, so a task or a test
  # never reads the database before it asks to.
  defp points_board_child do
    if serving?(), do: Keyfleet.Points.Board
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
