defmodule Keyfleet.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        KeyfleetWeb.Telemetry,
        {Keyfleet.Accounts.RequestRateLimiter, []},
        database_child(),
        {Phoenix.PubSub, name: Keyfleet.PubSub},
        agents_listener_child(),
        # A key's profile reads its rewards wherever the site runs, so their
        # table stands apart from the fleets' readers below.
        Keyfleet.Chain.RewardsWaiting,
        chain_child(),
        graph_children(),
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

  # Agent changes announced by any Regent site, through the database, reach
  # this site's pages; it needs the database and PubSub started first.
  defp agents_listener_child do
    if Application.get_env(:keyfleet, :database_startup_enabled, false),
      do: RegentAgents.Listener
  end

  # Metrics are served beside the site, never by a process that only runs a task.
  defp metrics_child do
    if Phoenix.Endpoint.server?(:keyfleet, KeyfleetWeb.Endpoint),
      do: KeyfleetWeb.Metrics
  end

  # Fleets are read from the chain only where a node is configured, which the
  # test build never is.
  defp chain_child do
    if Application.fetch_env!(:keyfleet, Keyfleet.Chain)[:rpc_url],
      do: Keyfleet.Chain.Supervisor
  end

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
