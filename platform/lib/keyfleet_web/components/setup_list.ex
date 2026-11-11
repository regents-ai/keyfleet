defmodule KeyfleetWeb.Components.SetupList do
  @moduledoc """
  A new owner's four setup steps at the top of a fleet's page, ticked off from
  the records alone (`Keyfleet.Agents.Upkeep.person_setup/2`): pair an agent,
  give it a shard, its daily run, and every Key present or waiting for its
  automatic start, as an agent's Marked dot reads it. Only the first step not
  yet done is open: pairing holds the pairing box (`KeyfleetWeb.PairingBox`),
  whose message sends the agent to this fleet once paired; the shard step is
  one press, a shard of every Key the person holds here for the agent paired
  last, built on the server. A line above says whether the Keys count in
  votes, and until when.

  It shows only to a signed-in person who holds a Key in the fleet, and only
  until all four are done, so a run that stops and lets the Keys lapse brings
  it back. The page sends `changed: true` when the person's agents (a pairing,
  a shard, a daily run's check-in), the fleet's Keys or a step sent from here
  change, and the list reads again. It sends `present: token_ids` when Keys
  of the fleet are marked present, and the list reads again only when one of
  them is the person's.
  """
  use KeyfleetWeb, :live_component

  import Keyfleet.Fleets.Rules, only: [grouped: 1]

  alias Keyfleet.Agents.Upkeep
  alias Keyfleet.Fleets
  alias KeyfleetWeb.WalletPanel

  @steps [:pair, :shard, :run, :present]
  @shard_days "30"

  @impl true
  def update(%{changed: true}, socket), do: {:ok, read(socket)}

  def update(%{present: token_ids}, %{assigns: %{setup: %{keys: keys}}} = socket),
    do: {:ok, if(Enum.any?(keys, &(&1.token_id in token_ids)), do: read(socket), else: socket)}

  def update(%{present: _token_ids}, socket), do: {:ok, socket}

  def update(assigns, socket) do
    socket = assign(socket, assigns)
    {:ok, if(changed?(socket, :fleet), do: read(socket), else: socket)}
  end

  defp read(%{assigns: %{actor: actor, fleet: fleet}} = socket),
    do: assign(socket, setup: Upkeep.person_setup(actor, fleet.fleet_id))

  # The first step not yet done, or nil when there is nothing to set up.
  defp open(nil), do: nil
  defp open(%{done: done}), do: Enum.find(@steps, &(not done[&1]))

  @impl true
  def render(assigns) do
    assigns = assign(assigns, open: open(assigns.setup))

    ~H"""
    <section id={@id} class="setup-list" aria-labelledby={"#{@id}-title"} hidden={!@open}>
      <.steps
        :if={@open}
        id={@id}
        setup={@setup}
        open={@open}
        fleet={@fleet}
        actor={@actor}
        account={@account}
        lease={@lease}
      />
    </section>
    """
  end

  attr :id, :string, required: true
  attr :setup, :map, required: true
  attr :open, :atom, required: true
  attr :fleet, :map, required: true
  attr :actor, :any, required: true
  attr :account, :map, required: true
  attr :lease, :map, required: true

  defp steps(assigns) do
    ~H"""
    <h2 id={"#{@id}-title"}>Setup</h2>
    <p id={"#{@id}-votes"} class="setup-list__votes">{votes(@setup.keys, DateTime.utc_now())}</p>
    <ol class="setup-list__steps">
      <.step id={"#{@id}-pair"} n={1} title="Pair" done={@setup.done.pair} open={@open == :pair}>
        <.live_component
          module={KeyfleetWeb.PairingBox}
          id={"#{@id}-pairing"}
          account={@account}
          lease={@lease}
          start={Fleets.path(@fleet.fleet_id)}
        />
      </.step>
      <.step id={"#{@id}-shard"} n={2} title="Shard" done={@setup.done.shard} open={@open == :shard}>
        <p>Your agent acts for your Key with a shard. The Key and its money stay yours.</p>
        <.live_component
          module={WalletPanel}
          id={"#{@id}-shard-action"}
          flow={:issue_shard}
          fleet={%{fleet_id: @fleet.fleet_id, chain_id: @fleet.chain_id}}
          actor={@actor}
          lease={@lease}
          names_sender={false}
          inputs={shard_inputs(@setup)}
        >
          <:buttons :let={panel}>
            <WalletPanel.step_button panel={panel} step="issue" id={"#{@id}-shard-button"}>
              Give {agent(@setup.agents).name} a shard
            </WalletPanel.step_button>
          </:buttons>
        </.live_component>
      </.step>
      <.step id={"#{@id}-run"} n={3} title="Daily run" done={@setup.done.run} open={@open == :run}>
        <p>Your agent schedules its daily run from the message it was sent.</p>
      </.step>
      <.step
        id={"#{@id}-present"}
        n={4}
        title="Present"
        done={@setup.done.present}
        open={@open == :present}
      >
        <p>
          Your agent marks your Keys present each day. Its wallet pays a small fee in ETH on Base.
        </p>
      </.step>
    </ol>
    """
  end

  attr :id, :string, required: true
  attr :n, :integer, required: true
  attr :title, :string, required: true
  attr :done, :boolean, required: true
  attr :open, :boolean, required: true
  slot :inner_block, required: true

  defp step(assigns) do
    ~H"""
    <li id={@id} class="setup-list__step" data-done={@done} aria-current={@open && "step"}>
      <span class="setup-list__mark" aria-hidden="true">
        <Regent.Icons.icon :if={@done} name="check" />
        <span :if={not @done}>{@n}</span>
      </span>
      <span class="setup-list__title">
        {@title}<span :if={@done} class="visually-hidden">, done</span>
      </span>
      <div :if={@open} class="setup-list__body">{render_slot(@inner_block)}</div>
    </li>
    """
  end

  # The agent paired last, which a shard goes to. Only read once one is paired.
  defp agent(agents), do: List.last(agents)

  # A shard of every Key the person holds here, for that agent.
  defp shard_inputs(setup),
    do: %{
      "keys" => Enum.map_join(setup.keys, " ", & &1.token_id),
      "wallet" => agent(setup.agents).wallet,
      "days" => @shard_days
    }

  # Whether the person's Keys count in votes now: one Key by name, several
  # as a count.
  defp votes([key], now), do: "Key #{grouped(key.token_id)} #{standing(key, now)}"

  defp votes(keys, now) do
    counting = Enum.count(keys, &counting?(&1, now))
    "#{counting} of #{length(keys)} Keys count in votes."
  end

  defp standing(%{from: nil}, _now), do: "doesn’t count in votes yet."

  defp standing(%{from: from, until: until}, now) do
    cond do
      DateTime.after?(from, now) -> "counts in votes from #{at(from)}."
      DateTime.after?(until, now) -> "counts in votes until #{at(until)}."
      true -> "stopped counting in votes. Marking it present counts it again."
    end
  end

  defp counting?(%{from: nil}, _now), do: false

  defp counting?(%{from: from, until: until}, now),
    do: not DateTime.after?(from, now) and DateTime.after?(until, now)

  defp at(time), do: Calendar.strftime(time, "%-d %b %H:%M UTC")
end
