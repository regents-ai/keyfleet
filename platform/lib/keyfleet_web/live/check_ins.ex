defmodule KeyfleetWeb.CheckIns do
  @moduledoc """
  What agents' check-ins with a fleet say, as people see it: one agent's
  status line, and the fleet's "Who's here" panel listing the agents running
  its keys.

  A status comes only from when the agent's check-ins arrived
  (`Keyfleet.Agents.CheckInStatus`), never from what it says about itself.
  """

  use KeyfleetWeb, :html

  import Keyfleet.Fleets.Rules, only: [grouped: 1]

  alias KeyfleetWeb.Time

  attr :label, :string, required: true, doc: "the check-in status as people read it"
  attr :last_check_in_at, DateTime, default: nil
  attr :last_contribution_at, DateTime, default: nil
  attr :last_contribution, :atom, default: nil, doc: "`:post` or `:workspace`"
  attr :class, :string, default: nil
  attr :rest, :global

  @doc """
  One agent's check-in status, when it last checked in and when it last
  posted or wrote in the workspace.
  """
  def status(assigns) do
    ~H"""
    <span class={["check-in-status", @class]} {@rest}>{line(
      @label,
      @last_check_in_at,
      @last_contribution_at,
      @last_contribution
    )}</span>
    """
  end

  attr :agents, :list, required: true, doc: "the agents shown, as `Keyfleet.Directory.agents/1`"
  attr :agents_here, :integer, required: true, doc: "every agent running the fleet's keys"
  attr :on_close, JS, required: true

  @doc """
  The fleet's "Who's here" panel: the agents running its keys, the most
  recent check-in first, each with the keys it runs and its check-in status.
  """
  def who_is_here(assigns) do
    ~H"""
    <aside id="fleet-who" class="who-is-here" aria-labelledby="fleet-who-title" hidden>
      <div class="who-is-here__heading">
        <h2 id="fleet-who-title">Who’s here</h2>
        <Regent.Primitives.button
          id="fleet-who-close"
          class="who-is-here__close"
          variant="secondary"
          phx-click={@on_close}
        >
          Close
        </Regent.Primitives.button>
      </div>

      <p :if={@agents == []} id="fleet-who-empty" class="who-is-here__note">
        No agents run keys here yet.
      </p>

      <ul :if={@agents != []} id="fleet-who-list" class="who-is-here__list">
        <li :for={agent <- @agents} id={"fleet-who-#{agent.first_key}"}>
          <p class="who-is-here__name">
            <strong>{agent.name}</strong>
            <span class="who-is-here__keys">{keys(agent)}</span>
          </p>
          <.status
            label={agent.status_label}
            last_check_in_at={agent.last_check_in_at}
            last_contribution_at={agent.last_contribution_at}
            last_contribution={agent.last_contribution}
            class="who-is-here__status"
          />
        </li>
      </ul>

      <p :if={@agents_here > length(@agents)} class="who-is-here__note">
        {grouped(@agents_here)} agents run keys here. These are the {length(@agents)} that checked in most recently.
      </p>
    </aside>
    """
  end

  # An agent that never checked in has no times to give.
  defp line(label, nil, _contribution_at, _kind), do: label

  defp line(label, check_in_at, contribution_at, kind) do
    now = DateTime.utc_now()

    Enum.join(
      [
        label,
        "last check-in #{Time.ago(check_in_at, now)}",
        contribution(contribution_at, kind, now)
      ],
      " · "
    )
  end

  defp contribution(nil, _kind, _now), do: "no contributions yet"

  defp contribution(at, kind, now),
    do: "last contribution #{Time.ago(at, now)} (#{contribution_kind(kind)})"

  defp contribution_kind(:post), do: "a post"
  defp contribution_kind(:workspace), do: "in the workspace"

  defp keys(%{first_key: key, keys_run: 1}), do: "Key #{grouped(key)}"

  defp keys(%{first_key: key, keys_run: run}),
    do: "Key #{grouped(key)} and #{grouped(run - 1)} more"
end
