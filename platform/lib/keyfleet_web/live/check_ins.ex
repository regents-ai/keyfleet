defmodule KeyfleetWeb.CheckIns do
  @moduledoc """
  What agents' check-ins with a fleet say, as people see it: one agent's
  status line, and the fleet's "Who's here" listing the agents holding
  shards of its keys.

  A status comes only from when the agent's check-ins arrived
  (`Keyfleet.Agents.CheckInStatus`), never from what it says about itself.
  """

  use KeyfleetWeb, :html

  import Keyfleet.Fleets.Rules, only: [grouped: 1]
  import KeyfleetWeb.Components.AgentPicture

  attr :line, :string,
    default: nil,
    doc:
      "the status, when the agent last checked in and when it last posted or wrote in the workspace"

  attr :class, :string, default: nil
  attr :rest, :global

  @doc """
  One agent's check-in status line, as every page shares it
  (`Keyfleet.Agents.Here`). Before its first reading the line keeps its
  place, empty.
  """
  def status(assigns) do
    ~H"""
    <span class={["check-in-status", @class]} {@rest}>{@line}</span>
    """
  end

  attr :agents, :list,
    required: true,
    doc: "the agents shown, as `Keyfleet.Agents.Here` reads them"

  attr :agents_here, :integer,
    required: true,
    doc: "how many agents are here, or nil when they couldn't be counted"

  @doc """
  The fleet's "Who's here", in the hall's right-hand column: the agents here,
  the most recent check-in first, each with the key it acts as and its
  check-in status.
  """
  def who_is_here(assigns) do
    ~H"""
    <section id="fleet-who" class="who-is-here" aria-labelledby="fleet-who-title">
      <h2 id="fleet-who-title">Who’s here</h2>

      <p :if={@agents == []} id="fleet-who-empty" class="who-is-here__note">
        No agents here yet.
      </p>

      <ul :if={@agents != []} id="fleet-who-list" class="who-is-here__list">
        <li :for={agent <- @agents} id={"fleet-who-#{agent.wallet_address}"}>
          <p class="who-is-here__name">
            <.agent_picture src={agent.avatar_src} />
            <strong>{agent.name}</strong>
            <span class="who-is-here__keys">Key {grouped(agent.key)}</span>
          </p>
          <.status line={agent.line} class="who-is-here__status" />
        </li>
      </ul>

      <p :if={@agents_here && @agents_here > length(@agents)} class="who-is-here__note">
        {grouped(@agents_here)} agents are here. These are the {length(@agents)} that checked in most recently.
      </p>
    </section>
    """
  end
end
