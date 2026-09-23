defmodule KeyFleetWeb.FleetLive do
  @moduledoc """
  One fleet's page: where it lives, how far it has sold, what the next key
  costs, its rooms and workspace, and every key it has issued with who holds and runs it.

  Everything here is public and read from what the fleet's contract has
  recorded. Keys are listed a hundred at a time.
  """

  use KeyFleetWeb, :html

  attr :fleet, :map, required: true
  attr :keys, :any, required: true, doc: "the fleet's issued keys, lowest number first"

  def page(assigns) do
    ~H"""
    <article id="fleet-page" class="fleet-page">
      <header class="fleet-heading">
        <p class="fleet-kicker">Fleet</p>
        <h1 tabindex="-1">{@fleet.name || "KeyFleet"}</h1>
        <p :if={@fleet.name} class="fleet-lede">How this fleet is selling, and who holds its keys.</p>
      </header>

      <section :if={is_nil(@fleet.name)} class="fleet-panel">
        <h2>This fleet doesn’t exist.</h2>
      </section>

      <div :if={@fleet.name} class="fleet-grid">
        <section class="fleet-panel" aria-labelledby="fleet-contract-title">
          <h2 id="fleet-contract-title">Contract</h2>
          <p :if={@fleet.contract_address} class="fleet-wallet">
            <code>{@fleet.contract_address}</code>
          </p>
          <p :if={is_nil(@fleet.contract_address)}>Not yet deployed</p>
        </section>

        <section
          :if={@fleet.deployed?}
          class="fleet-panel"
          aria-labelledby="fleet-progress-title"
        >
          <h2 id="fleet-progress-title">Progress</h2>
          <p :if={not @fleet.current?} class="fleet-detail">Sales figures are catching up.</p>
          <dl :if={@fleet.current?} class="fleet-facts">
            <div>
              <dt>Keys issued</dt>
              <dd>
                {grouped(@fleet.progress.total_minted)} of {grouped(@fleet.progress.max_supply)}
              </dd>
            </div>
            <div :if={@fleet.progress.completed_levels}>
              <dt>Levels complete</dt>
              <dd>{@fleet.progress.completed_levels} of {@fleet.progress.levels}</dd>
            </div>
            <div :if={@fleet.progress.next_price}>
              <dt>Next key</dt>
              <dd>
                Key {@fleet.progress.next_token_id}, {usdc(@fleet.progress.next_price)}
              </dd>
            </div>
          </dl>
          <p :if={@fleet.current? and @fleet.progress.next_price} class="fleet-detail">
            Paid in USDC on Base.
          </p>
          <p :if={@fleet.current? and is_nil(@fleet.progress.next_price)} class="fleet-detail">
            Every key has been issued.
          </p>
        </section>

        <nav class="fleet-panel" aria-labelledby="fleet-rooms-title">
          <h2 id="fleet-rooms-title">Rooms</h2>
          <ul class="fleet-room-list">
            <li :for={room <- @fleet.rooms}>
              <.link navigate={"/app/fleets/#{@fleet.fleet_id}/rooms/#{room.slug}"}>
                {room.name}
              </.link>
            </li>
          </ul>
        </nav>

        <section class="fleet-panel" aria-labelledby="fleet-workspace-title">
          <h2 id="fleet-workspace-title">Workspace</h2>
          <p class="fleet-detail">The goals, tasks, findings and notes this fleet is working on.</p>
          <.link id="fleet-workspace-link" navigate={"/app/fleets/#{@fleet.fleet_id}/workspace"}>
            Open the workspace
          </.link>
        </section>

        <section class="fleet-panel fleet-keys" aria-labelledby="fleet-keys-title">
          <h2 id="fleet-keys-title">Keys</h2>
          <p :if={@fleet.no_keys?}>No keys have been issued yet.</p>

          <ol id="fleet-key-list" class="fleet-key-list" phx-update="stream">
            <li :for={{dom_id, key} <- @keys} id={dom_id}>
              <.link navigate={"/app/keys/#{@fleet.fleet_id}/#{key.token_id}"} class="fleet-name">
                Key {key.token_id}
              </.link>
              <span>Held by {short_wallet(key.owner_wallet)}</span>
              <span>{key.operator_name || "No operator"}</span>
            </li>
          </ol>

          <nav
            :if={@fleet.pages.previous || @fleet.pages.next}
            class="fleet-pages"
            aria-label="More keys"
          >
            <.link :if={@fleet.pages.previous} id="fleet-keys-previous" patch={@fleet.pages.previous}>
              Previous
            </.link>
            <.link :if={@fleet.pages.next} id="fleet-keys-next" patch={@fleet.pages.next}>
              Next
            </.link>
          </nav>
        </section>
      </div>
    </article>
    """
  end

  defp short_wallet(wallet),
    do: String.slice(wallet, 0, 6) <> "…" <> String.slice(wallet, -4, 4)

  # Atomic USDC shown exactly, since it is what the purchase pays.
  defp usdc(atoms) do
    fraction =
      atoms
      |> rem(1_000_000)
      |> Integer.to_string()
      |> String.pad_leading(6, "0")
      |> String.trim_trailing("0")

    case fraction do
      "" -> "#{grouped(div(atoms, 1_000_000))} USDC"
      fraction -> "#{grouped(div(atoms, 1_000_000))}.#{fraction} USDC"
    end
  end

  defp grouped(number) do
    number
    |> Integer.to_string()
    |> String.reverse()
    |> String.graphemes()
    |> Enum.chunk_every(3)
    |> Enum.map_join(",", &Enum.join/1)
    |> String.reverse()
  end
end
