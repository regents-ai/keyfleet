defmodule KeyfleetWeb.Components.PresenceCard do
  @moduledoc """
  Whether keys are present, and the button that marks them present: one key
  on its own page, or every key the signed-in wallet holds or holds a shard of
  on the fleet's proposals. A present key is counted when a proposal opens.
  When lapsed presences are still queued, a proposal can't be made until
  someone tidies them up, so the card says maintenance is needed.
  """
  use KeyfleetWeb, :html

  alias Keyfleet.Fleets.Rules
  alias KeyfleetWeb.WalletPanel
  alias KeyfleetWeb.WalletWords

  attr :id, :string, required: true
  attr :fleet, :map, required: true, doc: "the fleet's `fleet_id` and `chain_id`"
  attr :actor, :any, required: true
  attr :token_id, :integer, default: nil, doc: "the one key, or nil for the wallet's own"
  attr :tool, :string, default: nil, doc: "the browser tool that presses Mark present, if any"
  attr :class, :any, default: nil

  def card(assigns) do
    ~H"""
    <section id={@id} class={@class} aria-labelledby={"#{@id}-title"}>
      <h2 id={"#{@id}-title"} class="presence-title">
        Present
        <Regent.Primitives.tip id={"#{@id}-tip"} label="About being present">
          A present key is counted when a proposal opens. Marking it lasts 48 hours, and voting or proposing with it marks it too.
        </Regent.Primitives.tip>
      </h2>
      <.live_component
        module={WalletPanel}
        id={"#{@id}-action"}
        flow={:present}
        fleet={@fleet}
        actor={@actor}
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
          <p :if={maintenance?(panel)} id={"#{@id}-maintenance"} class="presence-maintenance">
            Maintenance needed
            <Regent.Primitives.tip id={"#{@id}-maintenance-tip"} label="About maintenance">
              Some keys’ presence has lapsed. Tidy up clears them, and a proposal can be made again. Anyone can press it.
            </Regent.Primitives.tip>
          </p>
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
            Tidy up
          </WalletPanel.step_button>
        </:buttons>
      </.live_component>
    </section>
    """
  end

  defp keys(panel), do: panel |> WalletPanel.figures() |> Map.get(:keys, [])
  defp maintenance?(panel), do: panel |> WalletPanel.figures() |> Map.get(:maintenance?, false)
end
