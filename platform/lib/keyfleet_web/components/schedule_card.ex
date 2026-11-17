defmodule KeyfleetWeb.Components.ScheduleCard do
  @moduledoc """
  Schedule, for a person whose paired agent has no scheduled check-in seen in
  a fleet where they hold a Key (`Keyfleet.Agents.Upkeep.unscheduled/2`): a
  sentence saying it isn't coming back on its own yet, Copy line with the
  guide's own words for scheduling check-ins, and each such agent with what
  its check-ins say (`Keyfleet.Agents.CheckInStatus`). It sits in the page
  and never covers it.

  A fleet's page shows it for that fleet, and the person may put it away there
  (`KeyfleetWeb.Components.FleetPrompts`); the Agents page shows it for every
  fleet, always (`KeyfleetWeb.AgentsPanel`). It goes from both once a
  scheduled check-in is seen.
  """
  use KeyfleetWeb, :html

  alias Keyfleet.Fleets

  attr :id, :string, required: true

  attr :agents, :list,
    required: true,
    doc: "the agents with no scheduled check-in seen, as `Upkeep.unscheduled/2` gives them"

  attr :fleets?, :boolean, default: false, doc: "whether each agent names its fleet"
  attr :class, :any, default: nil
  attr :rest, :global
  slot :dismiss, doc: "a button that puts the card away"

  def card(assigns) do
    ~H"""
    <section
      id={@id}
      class={["rg-panel", "schedule-card", @class]}
      aria-labelledby={"#{@id}-title"}
      {@rest}
    >
      <div class="rg-panel__body">
        <header class="schedule-card__head">
          <h2 id={"#{@id}-title"}>Schedule</h2>
          {render_slot(@dismiss)}
        </header>
        <p class="schedule-card__words">{words(@agents)}</p>
        <ul class="schedule-card__agents">
          <li :for={agent <- @agents} data-wallet={agent.wallet}>
            <strong class="schedule-card__name">{agent.name}</strong>
            <.link :if={@fleets?} navigate={Fleets.path(agent.fleet_id)}>
              {Fleets.name(agent.fleet_id)}
            </.link>
            <span class="check-in-status" data-light={agent.light}>{agent.status}</span>
          </li>
        </ul>
        <Regent.Primitives.copy_button id={"#{@id}-copy"} text={line()}>
          Copy line
        </Regent.Primitives.copy_button>
      </div>
    </section>
    """
  end

  @doc """
  What the person gives their agent: the guide's own words for scheduling
  check-ins (`/skill.md`, Check-ins), which any agent paired here follows as
  pasted.
  """
  def line,
    do:
      "Schedule your Keyfleet check-ins, every 10 minutes to once a day, with your " <>
        "runtime's scheduler (#{KeyfleetWeb.Endpoint.url()}/agents says how), and start one " <>
        "now. Each starts fresh, told \"#{KeyfleetWeb.PairingBox.check_in()}\""

  defp words(agents) do
    case Enum.uniq_by(agents, & &1.wallet) do
      [_one] ->
        "Your agent isn’t coming back on its own yet: give it this line to schedule its check-ins."

      _more ->
        "Your agents aren’t coming back on their own yet: give each this line to schedule its check-ins."
    end
  end
end
