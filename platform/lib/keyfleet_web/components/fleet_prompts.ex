defmodule KeyfleetWeb.Components.FleetPrompts do
  @moduledoc """
  The two buttons at the top of a fleet's page for a signed-in person who
  holds a Key in it, side by side when both apply, each only while it has
  something to do.

  Pair shows while the person has no agent paired, and opens the pairing box
  (`KeyfleetWeb.PairingBox`) under it, whose message sends the agent to this
  fleet once paired. Mark present shows while some of the person's Keys are
  idle, by the rule the page's presence marks read (the `idle` calculation of
  `Keyfleet.Keys.KeyAttachment`), with how many beside it. One press marks
  every idle Key the sending wallet holds present
  (`Keyfleet.WalletSteps` flow `:present_idle`).

  The page sends `changed: true` when the person's agents, the fleet's Keys or
  a step sent from the page change, and the buttons are read again. It sends
  `present: token_ids` when Keys of the fleet are marked present, and they are
  read again only when one of them was the person's idle Key.
  """
  use KeyfleetWeb, :live_component

  alias Keyfleet.Agents
  alias Keyfleet.Fleets
  alias Keyfleet.Keys
  alias KeyfleetWeb.Components.Count
  alias KeyfleetWeb.WalletPanel

  @impl true
  def mount(socket), do: {:ok, assign(socket, pair?: false, idle: [], pairing: false)}

  @impl true
  def update(%{changed: true}, socket), do: {:ok, read(socket)}

  def update(%{present: token_ids}, socket) do
    ours? = Enum.any?(socket.assigns.idle, &(&1 in token_ids))
    {:ok, if(ours?, do: read(socket), else: socket)}
  end

  def update(assigns, socket) do
    socket = assign(socket, assigns)
    moved? = changed?(socket, :fleet) or changed?(socket, :actor)
    {:ok, if(moved?, do: read(socket), else: socket)}
  end

  @impl true
  def handle_event("pair", _params, socket),
    do: {:noreply, update(socket, :pairing, &(not &1))}

  # Pairing without a Key opens nothing here, so a person holding none sees
  # neither button.
  defp read(%{assigns: %{actor: actor, fleet: %{fleet_id: fleet_id}}} = socket) do
    keys = Keys.keys_held_in_fleet!(fleet_id, actor.wallet_addresses, actor: actor, load: [:idle])

    assign(socket,
      pair?: keys != [] and not Agents.has_paired_agent?(actor),
      idle: for(%{idle: true, token_id: token_id} <- keys, do: token_id)
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class="fleet-prompts">
      <div :if={@pair? or @idle != []} class="fleet-prompts__row">
        <Regent.Primitives.button
          :if={@pair?}
          id={"#{@id}-pair"}
          class="fleet-prompts__pair"
          phx-click="pair"
          phx-target={@myself}
          aria-expanded={to_string(@pairing)}
          aria-controls={@pairing && "#{@id}-pairing"}
        >
          Pair your agent to participate in workspaces
        </Regent.Primitives.button>
        <.live_component
          :if={@idle != []}
          module={WalletPanel}
          id={"#{@id}-present"}
          class="fleet-prompts__present"
          flow={:present_idle}
          fleet={@fleet}
          actor={@actor}
          lease={@lease}
          names_sender={false}
          refresh={@idle}
        >
          <:buttons :let={panel}>
            <WalletPanel.step_button
              panel={panel}
              step="present"
              id={"#{@id}-mark"}
              variant={if @pair?, do: "secondary", else: "primary"}
            >
              Mark present
            </WalletPanel.step_button>
            <span class="fleet-prompts__idle">
              <Count.count id={"#{@id}-idle"} value={length(@idle)} one="Key idle" many="Keys idle" />
            </span>
          </:buttons>
        </.live_component>
      </div>
      <.live_component
        :if={@pair? and @pairing}
        module={KeyfleetWeb.PairingBox}
        id={"#{@id}-pairing"}
        account={@account}
        lease={@lease}
        start={Fleets.path(@fleet.fleet_id)}
      />
    </div>
    """
  end
end
