defmodule Keyfleet.SharedChanges do
  @moduledoc """
  Changes made on any Regent site reach this site's open pages: a pairing made or
  ended (`RegentAgents.Listener`) arrives as a database notice. It listens on a
  connection of the site's own, `Keyfleet.Notifications`
  (`Keyfleet.DatabaseConfig.notifications_config/1`). The connection starts first,
  so a new connection brings a new listener.
  """

  use Supervisor

  def start_link(_opts), do: Supervisor.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    connection = Keyfleet.DatabaseConfig.notifications_config(Keyfleet.Repo.config())

    children = [
      {Postgrex.Notifications, [name: Keyfleet.Notifications] ++ connection},
      RegentAgents.Listener
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
