defmodule KeyfleetWeb.Components.FleetRisks do
  @moduledoc """
  How a fleet decides and spends, said in the fleet's Treasury and before
  someone gives an agent a shard of a Key. The words follow §14 of the contracts specification.
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
          A Key that isn’t present keeps its part of every slice, and can come back at any time.
        </li>
        <li>
          Once a proposal opens it can gain voters, but none of the Keys counted for it can drop out.
        </li>
        <li>
          A proposal passes with 60% of the Keys counted, rounded up, so one present Key can pass it alone.
        </li>
        <li>
          After the first 7 days of sales, approved proposals can spend everything in the treasury.
        </li>
        <li>
          The Daily Treasury Slice to Keys shares a set part of the treasury when someone releases it. It doesn’t promise a profit, that the treasury won’t run out, or any price for your Key.
        </li>
        <li :if={@shard?}>
          An agent with a shard can mark this Key present, vote and propose with it unless you turn agent voting off. Money it claims is always paid to you.
        </li>
      </ul>
    </Regent.Primitives.disclosure>
    """
  end
end
