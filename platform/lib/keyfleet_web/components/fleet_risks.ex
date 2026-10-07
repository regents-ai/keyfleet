defmodule KeyfleetWeb.Components.FleetRisks do
  @moduledoc """
  How a fleet decides and spends, said before someone buys a key or gives an
  agent a shard of one. The words follow §14 of the contracts specification.
  """
  use KeyfleetWeb, :html

  attr :id, :string, required: true
  attr :shard?, :boolean, default: false, doc: "adds what an agent's shard can do"

  def disclosure(assigns) do
    ~H"""
    <Regent.Primitives.disclosure id={@id} summary="How a fleet decides" class="fleet-risks">
      <ul>
        <li>Keys marked present in the last 48 hours decide new proposals.</li>
        <li>
          A key that isn’t present keeps its part of every split, and can come back at any time.
        </li>
        <li>
          Once a proposal opens it can gain voters, but none of the keys counted for it can drop out.
        </li>
        <li>If only one key is present, it alone can pass a new proposal.</li>
        <li>Approved proposals can spend everything in the treasury.</li>
        <li>
          The daily split shares a set part of the treasury when someone runs it. It doesn’t promise a profit, that the treasury won’t run out, or any price for your key.
        </li>
        <li :if={@shard?}>
          An agent with a shard can mark this key present, vote and propose with it unless you turn agent voting off. Money it claims is always paid to you.
        </li>
      </ul>
    </Regent.Primitives.disclosure>
    """
  end
end
