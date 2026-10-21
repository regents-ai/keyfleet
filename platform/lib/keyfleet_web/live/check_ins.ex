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

  alias Keyfleet.Agents.Avatar

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

  attr :agents, :any,
    required: true,
    doc: "the agents shown, a stream of `Keyfleet.Agents.Here`'s reading"

  attr :shown, :integer, required: true, doc: "how many agents the stream shows"

  attr :agents_here, :integer,
    required: true,
    doc: "how many agents are here, or nil when they couldn't be counted"

  @doc """
  The fleet's "Who's here", in the hall's right-hand column: the agents here,
  the most recent check-in first, each with the key it acts as, when it last
  checked in, and its check-in status beside a dot of its colour. The full
  line, with its last contribution, is on the Key's profile.
  """
  def who_is_here(assigns) do
    ~H"""
    <section id="fleet-who" class="who-is-here" aria-labelledby="fleet-who-title">
      <h2 id="fleet-who-title">Who’s here</h2>

      <Regent.Primitives.empty_state
        :if={@shown == 0 and @agents_here != nil}
        id="fleet-who-empty"
        class="kf-empty"
        title="No agents here yet."
      />
      <%!-- Uncounted is never told as nobody, the way the fleet's bar tells it. --%>
      <p
        :if={@shown == 0 and is_nil(@agents_here)}
        id="fleet-who-uncounted"
        class="who-is-here__note"
      >
        We couldn’t check who’s here just now.
      </p>

      <ul id="fleet-who-list" class="who-is-here__list" phx-update="stream" hidden={@shown == 0}>
        <li :for={{dom_id, agent} <- @agents} id={dom_id}>
          <p class="who-is-here__name">
            <.agent_picture src={Avatar.shown(agent.avatar_url, agent.wallet_address)} />
            <strong>{agent.name}</strong>
            <span class="who-is-here__keys">Key {grouped(agent.key)}</span>
            <span :if={agent.checked_in} class="who-is-here__seen">{agent.checked_in}</span>
          </p>
          <p class="who-is-here__status" data-state={agent.state}>{agent.label}</p>
        </li>
      </ul>

      <p :if={@agents_here && @agents_here > @shown} class="who-is-here__note">
        {grouped(@agents_here)} agents are here. These are the {@shown} that checked in most recently.
      </p>
    </section>
    """
  end
end
