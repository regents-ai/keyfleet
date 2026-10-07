defmodule KeyfleetWeb.KeysLive do
  @moduledoc """
  One key's page: who owns it, the shards it has given out, and whether a
  vote of the fleet has stopped it changing the workspace.

  Everything here is read from what the chain recorded, so a visitor sees the
  same standing the owner does; only the owner is offered the wallet buttons
  that issue, renew and end shards.
  """

  use KeyfleetWeb, :html

  import KeyfleetWeb.Components.AgentPicture

  alias Keyfleet.Actors.Human
  alias Keyfleet.Chain
  alias Keyfleet.Fleets.Rules
  alias Keyfleet.Keys
  alias Keyfleet.Keys.Profile
  alias KeyfleetWeb.ShellLive
  alias KeyfleetWeb.WalletPanel

  @refreshing "Key ownership is being refreshed; try again in a moment."

  attr :key, :map, required: true
  attr :actor, :any, required: true, doc: "the signed-in person, or nil"

  def page(assigns) do
    ~H"""
    <article id="key-page" class="key-page">
      <header class="key-heading">
        <p class="key-kicker">{@key.fleet_name || "Keyfleet"}</p>
        <h1 tabindex="-1">Key {Rules.grouped(@key.token_id)}</h1>
        <p class="key-lede">Who owns this key, and the agents it has given shards to.</p>
      </header>

      <section :if={is_nil(@key.owner_wallet)} class="key-panel">
        <h2>This key isn’t here yet</h2>
        <p>Once the key is sold, its owner and shards appear on this page.</p>
      </section>

      <div :if={@key.owner_wallet} class="key-grid">
        <p :if={@key.refreshing?} class="key-notice">
          Key ownership is being refreshed, so the shards shown here may be a few minutes behind.
        </p>

        <p :if={@key.edits_restricted?} id="key-edits-restricted" class="key-notice">
          A vote of the fleet has stopped this key and its shards changing the workspace. They can
          still read it and chat.
        </p>

        <section class="key-panel" aria-labelledby="key-owner-title">
          <h2 id="key-owner-title">Owner</h2>
          <p class="key-wallet"><code>{@key.owner_wallet}</code></p>
          <p :if={@key.owner?} class="key-detail">You own this key.</p>
        </section>

        <section id="key-shards" class="key-panel" aria-labelledby="key-shards-title">
          <h2 id="key-shards-title">Shards</h2>
          <p class="key-detail">
            A shard lets an agent’s wallet chat in rooms and work in the workspace as this key, for
            up to a year. It can’t vote, propose, buy, collect or move money. Every shard ends when
            the key changes hands.
          </p>

          <p :if={@key.shards == []} id="key-no-shards">This key has no shards.</p>

          <.live_component
            :if={@key.owner? and @key.shards != []}
            module={WalletPanel}
            id="key-shards-action"
            flow={:end_shard}
            fleet={@key.fleet}
            actor={@actor}
            token_id={@key.token_id}
            refresh={@key.shards}
          >
            <:buttons>
              <.shard_list shards={@key.shards} owner?={true} />
            </:buttons>
          </.live_component>

          <.shard_list :if={not @key.owner?} shards={@key.shards} owner?={false} />
        </section>

        <section
          :if={@key.owner?}
          id="key-issue-shard"
          class="key-panel"
          aria-labelledby="key-issue-shard-title"
        >
          <h2 id="key-issue-shard-title">Issue a shard</h2>
          <p class="key-detail">
            Check this is your agent’s wallet address. A wallet holds one shard in this fleet at a
            time, and issuing again to a wallet with a shard of this key renews it.
          </p>

          <.live_component
            module={WalletPanel}
            id="key-issue-shard-action"
            class="key-issue-shard"
            flow={:issue_shard}
            fleet={@key.fleet}
            actor={@actor}
            token_id={@key.token_id}
            inputs={%{"wallet" => "", "days" => "30"}}
          >
            <:fields :let={panel}>
              <div class="key-shard-form">
                <Regent.Primitives.field :let={field} id="key-shard-wallet" label="Agent’s wallet">
                  <input
                    id={field.id}
                    name="wallet"
                    value={panel.inputs["wallet"]}
                    autocomplete="off"
                    aria-describedby={field.described_by}
                    data-onchain-input="wallet"
                  />
                </Regent.Primitives.field>
                <Regent.Primitives.field :let={field} id="key-shard-days" label="Days">
                  <input
                    id={field.id}
                    name="days"
                    value={panel.inputs["days"]}
                    inputmode="numeric"
                    autocomplete="off"
                    aria-describedby={field.described_by}
                    data-onchain-input="days"
                  />
                  <:hint>From 1 to 365.</:hint>
                </Regent.Primitives.field>
              </div>
            </:fields>
            <:buttons>
              <Regent.Primitives.button id="key-issue-shard-button" data-onchain-step="issue">
                <span data-press-label>Issue shard</span>
              </Regent.Primitives.button>
            </:buttons>
          </.live_component>
        </section>
      </div>
    </article>
    """
  end

  attr :shards, :list, required: true
  attr :owner?, :boolean, required: true

  # Each shard: its agent, or its wallet while no agent has signed in with it,
  # when it runs out, and for the owner the buttons that end or renew it.
  defp shard_list(assigns) do
    ~H"""
    <ul :if={@shards != []} class="key-shard-list">
      <li :for={shard <- @shards} id={"key-shard-#{shard.wallet}"}>
        <div>
          <p :if={shard.agent} class="key-name">
            <.agent_picture src={shard.agent.avatar_src} />
            {shard.agent.name}
          </p>
          <p :if={is_nil(shard.agent)} class="key-name">No agent has signed in with it yet</p>
          <span :if={shard.agent}>Runs on {shard.agent.harness}</span>
          <span>Until {date(shard.expires_at)}</span>
          <.address id={"key-shard-address-#{shard.wallet}"} wallet={shard.wallet} />
        </div>

        <div :if={@owner?} class="key-shard-actions">
          <Regent.Primitives.button
            id={"key-shard-renew-#{shard.wallet}"}
            data-onchain-step={"renew-#{shard.wallet}"}
          >
            <span data-press-label>Renew for 30 days</span>
          </Regent.Primitives.button>
          <Regent.Primitives.button
            id={"key-shard-end-#{shard.wallet}"}
            variant="secondary"
            data-onchain-step={"end-#{shard.wallet}"}
          >
            <span data-press-label>End shard</span>
          </Regent.Primitives.button>
        </div>
      </li>
    </ul>
    """
  end

  attr :id, :string, required: true
  attr :wallet, :string, required: true

  # A shard's wallet in full, so its owner can check it character for character.
  defp address(assigns) do
    ~H"""
    <p class="key-address">
      <code>{@wallet}</code>
      <Regent.Primitives.copy_button id={@id} text={@wallet} aria-label="Copy the wallet address">
        Copy address
      </Regent.Primitives.copy_button>
    </p>
    """
  end

  defp date(datetime), do: Calendar.strftime(datetime, "%-d %B %Y")

  @doc """
  What someone is told when a change waits on the fleet's key ownership being
  read again from the chain.
  """
  def refreshing, do: @refreshing

  @doc "What the key's page shows of the key, as the visitor may see it."
  def key_view(socket, fleet_id, token_id) do
    actor = ShellLive.human_actor(socket)
    key = Keys.current_key!(fleet_id, token_id, actor: actor, load: [:fleet])

    %{
      fleet_id: fleet_id,
      token_id: token_id,
      fleet_name: key && key.fleet.name,
      fleet: key && %{fleet_id: fleet_id, chain_id: key.fleet.chain_id},
      owner_wallet: key && key.owner_wallet,
      owner?: owns_key?(actor, key),
      refreshing?: not Chain.fresh?(fleet_id),
      edits_restricted?:
        match?([%{restricted: true}], Keys.latest_edits_restrictions!(fleet_id, [token_id])),
      shards: if(key, do: Profile.shards(fleet_id, token_id), else: [])
    }
  end

  @doc "The key on show read again when it is among the fleet's changed keys."
  def refresh_key(
        %{assigns: %{key: %{fleet_id: fleet_id, token_id: token_id}}} = socket,
        fleet_id,
        token_ids
      ) do
    if token_id in token_ids,
      do: assign(socket, :key, key_view(socket, fleet_id, token_id)),
      else: socket
  end

  def refresh_key(socket, _fleet_id, _token_ids), do: socket

  defp owns_key?(%Human{wallet_addresses: wallets}, %{owner_wallet: owner}),
    do: owner in wallets

  defp owns_key?(_actor, _key), do: false
end
