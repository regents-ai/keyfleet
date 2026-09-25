defmodule Keyfleet.Graph.Projectors do
  @moduledoc """
  Runs one `Keyfleet.Graph.Projector` per catalog fleet beside the registry
  that names them.

  It runs beside `Keyfleet.Graph.Supervisor`, not under it: a projector reads
  the log through its fleet's writer, but the writers never depend on the
  projectors, and while a writer is down its projector's rounds fail and are
  retried. The registry starts first under `rest_for_one`, and the projectors
  share a `one_for_one` supervisor that allows three restarts per fleet in
  five seconds.

  Options default to the `:graph` application environment:
  `:catch_up_interval` is how often a projector copies the log whether or not
  a write asked it to, and `:projection_wait` how long a write waits for its
  change to reach the read tables. `:fleets` defaults to the fixed catalog.
  """
  use Supervisor

  alias Keyfleet.Graph.Projector

  @projector_opts [:catch_up_interval, :projection_wait]

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    opts = Keyword.merge(Application.fetch_env!(:keyfleet, :graph), opts)
    projector_opts = Keyword.take(opts, @projector_opts)

    projectors =
      opts
      |> Keyword.get_lazy(:fleets, &Keyfleet.Fleets.catalog_ids/0)
      |> Enum.map(&{Projector, [{:fleet_id, &1} | projector_opts]})

    Supervisor.init(
      [
        {Registry, keys: :unique, name: Keyfleet.Graph.ProjectorRegistry},
        %{
          id: :projectors,
          type: :supervisor,
          start:
            {Supervisor, :start_link,
             [
               projectors,
               [strategy: :one_for_one, max_restarts: 3 * length(projectors), max_seconds: 5]
             ]}
        }
      ],
      strategy: :rest_for_one
    )
  end
end
