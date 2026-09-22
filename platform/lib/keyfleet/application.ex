defmodule KeyFleet.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        KeyFleetWeb.Telemetry,
        {KeyFleet.Accounts.RequestRateLimiter, []},
        database_child(),
        {Phoenix.PubSub, name: KeyFleet.PubSub},
        # Start a worker by calling: KeyFleet.Worker.start_link(arg)
        # {KeyFleet.Worker, arg},
        # Start to serve requests, typically the last entry
        KeyFleetWeb.Endpoint
      ]
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

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    KeyFleetWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
