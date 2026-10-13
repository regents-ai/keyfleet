defmodule KeyfleetWeb.Components.PresenceCard do
  @moduledoc """
  Whether keys are present, and the button that marks them present: one key
  on its own page, or every key the signed-in wallet holds or holds a shard of
  on the fleet's proposals. A present key is counted when a proposal opens;
  an idle one has no vote until it is marked present again. The card says
  so, shows how many of the fleet's keys are idle, and lists them when that
  count is pressed. Continue clears the idle keys the vote contract still
  counts, which anyone may do; a proposal can't be made while more than it
  clears itself are left.
  """
  use KeyfleetWeb, :html

  alias Keyfleet.Fleets.Rules
  alias KeyfleetWeb.Components.IdleKeys
  alias KeyfleetWeb.WalletPanel
  alias KeyfleetWeb.WalletWords

  attr :id, :string, required: true
  attr :fleet, :map, required: true, doc: "the fleet's `fleet_id` and `chain_id`"
  attr :actor, :any, required: true
  attr :lease, :map, required: true, doc: "the page's `session_lease`, or nil"
  attr :token_id, :integer, default: nil, doc: "the one key, or nil for the wallet's own"
  attr :tool, :string, default: nil, doc: "the browser tool that presses Mark present, if any"
  attr :class, :any, default: nil

  def card(assigns) do
    ~H"""
    <section id={@id} class={@class} aria-labelledby={"#{@id}-title"}>
      <h2 id={"#{@id}-title"} class="presence-title">
        Present
        <Regent.Primitives.tip id={"#{@id}-tip"} label="About being present">
          A present Key is counted when a proposal opens. A new Key waits 2 days, then is present on its own until day 4. After that, marking it present lasts 48 hours, and voting or proposing with it marks it too.
        </Regent.Primitives.tip>
      </h2>
      <p id={"#{@id}-rule"} class="presence-rule">
        Any Key idle for 48 hours loses its vote, temporarily until it returns to check in to the Keyfleet.
      </p>
      <.live_component
        module={WalletPanel}
        id={"#{@id}-action"}
        flow={:present}
        fleet={@fleet}
        actor={@actor}
        lease={@lease}
        token_id={@token_id}
        tool={@tool}
      >
        <:notes :let={panel}>
          <ul :if={keys(panel) != []} id={"#{@id}-keys"} class="presence-keys">
            <li :for={key <- keys(panel)} data-key={key.token_id}>
              <span>Key {Rules.grouped(key.token_id)}</span>
              <span :if={key.until} class="presence-on">
                Present until {WalletWords.at(key.until)}
              </span>
              <span :if={!key.until} class="presence-off">Not present</span>
            </li>
          </ul>
        </:notes>
        <:buttons :let={panel}>
          <WalletPanel.step_button panel={panel} step="present" id={"#{@id}-mark"}>
            Mark present
          </WalletPanel.step_button>
          <WalletPanel.step_button
            panel={panel}
            step="sweep"
            id={"#{@id}-sweep"}
            variant="secondary"
          >
            Continue
          </WalletPanel.step_button>
          <.idle :if={@actor} id={@id} fleet={@fleet} />
        </:buttons>
      </.live_component>
      <%!-- A visitor's box has no buttons, so the count stands on its own. --%>
      <.idle :if={!@actor} id={@id} fleet={@fleet} />
    </section>
    """
  end

  attr :id, :string, required: true
  attr :fleet, :map, required: true

  defp idle(assigns) do
    ~H"""
    <.live_component module={IdleKeys} id={"#{@id}-idle"} fleet_id={@fleet.fleet_id} />
    """
  end

  defp keys(panel), do: panel |> WalletPanel.figures() |> Map.get(:keys, [])
end
