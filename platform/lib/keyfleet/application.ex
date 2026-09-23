defmodule KeyFleet.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    children =
      [
        KeyFleetWeb.Telemetry,
        {KeyFleet.Accounts.RequestRateLimiter, []},
        database_child(),
        {Phoenix.PubSub, name: KeyFleet.PubSub},
        chain_child(),
        keeper_child(),
        graph_children(),
        # Start a worker by calling: KeyFleet.Worker.start_link(arg)
        # {KeyFleet.Worker, arg},
        # Start to serve requests, typically the last entry
        KeyFleetWeb.Endpoint
      ]
      |> List.flatten()
      |> Enum.reject(&is_nil/1)

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: KeyFleet.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp database_child do
    if Application.get_env(:keyfleet, :database_startup_enabled, false),
      do: KeyFleet.Repo
  end

  # Fleets are read from the chain only where a node is configured, which the
  # test build never is.
  defp chain_child do
    if Application.fetch_env!(:keyfleet, KeyFleet.Chain)[:rpc_url],
      do: KeyFleet.Chain.Supervisor
  end

  # The keeper signs only with its key, which only production reads, and
  # keeps its records in the database. It runs under its own supervisor,
  # which the site never restarts: a keeper that keeps crashing gives up and
  # leaves the site running.
  @doc false
  def keeper_child do
    cond do
      is_nil(Application.fetch_env!(:keyfleet, KeyFleet.Keeper)[:private_key]) ->
        Logger.info(
          "Keeper off: no KEYFLEET_KEEPER_PRIVATE_KEY in production; nothing on this site sends transactions."
        )

        nil

      Application.get_env(:keyfleet, :database_startup_enabled, false) ->
        Supervisor.child_spec(KeyFleet.Keeper.Supervisor, restart: :temporary)

      true ->
        Logger.info(
          "Keeper off: the database is not enabled; nothing on this site sends transactions."
        )

        nil
    end
  end

  # The projectors read each fleet's log through its writer, so they start
  # after the writers.
  defp graph_children do
    if Keyword.fetch!(Application.fetch_env!(:keyfleet, :graph), :enabled),
      do: [KeyFleet.Graph.Supervisor, KeyFleet.Graph.Projectors]
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    KeyFleetWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
