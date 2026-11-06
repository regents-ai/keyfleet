defmodule KeyfleetWeb.Components.PresenceCard do
  @moduledoc """
  Whether keys are present, and the button that marks them present: one key
  on its own page, or every key the signed-in wallet holds or holds a shard of
  on the fleet's proposals. A present key is counted when a proposal opens;
  an idle one can still vote, and joins the count when it does. The card shows
  the fleet's figures (`KeyfleetWeb.Components.FleetFigures`).
  """
  use KeyfleetWeb, :html

  alias Keyfleet.Fleets.Rules
  alias KeyfleetWeb.Components.FleetFigures
  alias KeyfleetWeb.WalletPanel
  alias KeyfleetWeb.WalletWords

  attr :id, :string, required: true
  attr :fleet, :map, required: true, doc: "the fleet's `fleet_id` and `chain_id`"
  attr :actor, :any, required: true
  attr :lease, :map, required: true, doc: "the page's `session_lease`, or nil"
  attr :token_id, :integer, default: nil, doc: "the one key, or nil for the wallet's own"
  attr :tool, :string, default: nil, doc: "the browser tool that presses Mark present, if any"
  attr :class, :any, default: nil

  attr :names_sender, :boolean,
    default: true,
    doc: "false where the page leaves out the line naming the sending wallet"

  def card(assigns) do
    ~H"""
    <section id={@id} class={@class} aria-labelledby={"#{@id}-title"}>
      <h2 id={"#{@id}-title"} class="presence-title">
        Present
        <Regent.Primitives.tip id={"#{@id}-tip"} label="About being present">
          A present Key is counted when a proposal opens. A new Key waits 2 days, then is present on its own until day 4. After that, marking it present lasts 48 hours, and voting or proposing with it marks it too.
        </Regent.Primitives.tip>
      </h2>
      <.live_component
        module={WalletPanel}
        names_sender={@names_sender}
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
        </:buttons>
      </.live_component>
      <.live_component module={FleetFigures} id={"#{@id}-figures"} fleet_id={@fleet.fleet_id} />
    </section>
    """
  end

  defp keys(panel), do: panel |> WalletPanel.figures() |> Map.get(:keys, [])
end
