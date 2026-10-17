defmodule KeyfleetWeb.KeysLive do
  @moduledoc """
  One key's page: who owns it, whether it is present, the shards it has given
  out, whether its shards may vote, and whether a vote of the fleet has
  stopped it changing the workspace.

  Everything here is read from what the chain recorded, so a visitor sees the
  same standing the owner does; only the owner is offered the wallet buttons
  that issue, renew and end shards and turn agent voting on or off. Anyone
  sees the key's presence, and its holder or a shard may mark it present.

  Someone holding a Key of the fleet is offered its messages: the Key's own
  holder opens its inbox, and the holder of another Key writes to it.
  """

  use KeyfleetWeb, :html

  import KeyfleetWeb.Components.AddressLinks
  import KeyfleetWeb.Components.AgentPicture

  alias Keyfleet.Actors.Human
  alias Keyfleet.Chain
  alias Keyfleet.Fleets.Rules
  alias Keyfleet.Keys
  alias Keyfleet.Keys.Profile
  alias KeyfleetWeb.Components.FleetRisks
  alias KeyfleetWeb.Components.PresenceCard
  alias KeyfleetWeb.DmsLive
  alias KeyfleetWeb.ShellLive
  alias KeyfleetWeb.WalletPanel

  @refreshing "Key ownership is being refreshed; try again in a moment."

  attr :key, :map, required: true
  attr :actor, :any, required: true, doc: "the signed-in person, or nil"
  attr :lease, :map, required: true, doc: "the page's `session_lease`, or nil"

  def page(assigns) do
    ~H"""
    <article id="key-page" class="key-page">
      <header class="key-heading">
        <%!-- Refreshing sits in the kicker's own line, so it never moves the panels below. --%>
        <p class="key-kicker">
          {@key.fleet_name || "Keyfleet"}<span :if={@key.refreshing?} id="key-refreshing"> · Refreshing…</span>
        </p>
        <h1 tabindex="-1">Key {Rules.grouped(@key.token_id)}</h1>
        <.link
          :if={@key.messages}
          id="key-messages"
          class="rg-button rg-button--primary key-messages"
          patch={@key.messages.path}
        >
          <span class="rg-button__label">{@key.messages.label}</span>
        </.link>
      </header>

      <section :if={is_nil(@key.owner_wallet)} id="key-not-sold" class="key-panel">
        <h2>Not sold yet</h2>
        <p>Its holder and shards show up here once it’s sold.</p>
      </section>

      <div :if={@key.owner_wallet} class="key-grid">
        <p :if={@key.edits_restricted?} id="key-edits-restricted" class="key-notice">
          Edits restricted
          <Regent.Primitives.tip id="key-edits-tip" label="About restricted edits">
            A vote of the fleet stopped this Key and its shards changing the workspace. They can still read it and chat.
          </Regent.Primitives.tip>
        </p>

        <section class="key-panel" aria-labelledby="key-owner-title">
          <h2 id="key-owner-title">Held by</h2>
          <p class="key-wallet">
            <code title={@key.owner_wallet}>{RegentFormat.short_address(@key.owner_wallet)}</code>
            <span :if={@key.owner?} id="key-owner-you" class="key-detail">You</span>
            <.address_links id="key-owner-links" address={@key.owner_wallet} />
          </p>
        </section>

        <PresenceCard.card
          :if={@key.deployed?}
          id="key-present"
          names_sender={false}
          class="key-panel"
          fleet={@key.fleet}
          actor={@actor}
          lease={@lease}
          token_id={@key.token_id}
        />

        <section id="key-shards" class="key-panel" aria-labelledby="key-shards-title">
          <h2 id="key-shards-title">
            Shards
            <Regent.Primitives.tip id="key-shards-tip" label="About shards">
              A shard lets an agent’s wallet chat, work in the workspace, mark the Key present and claim for it, for up to a year. With agent voting on, it can also vote and propose. The money always goes to the Key’s holder. Every shard ends when the Key changes hands.
            </Regent.Primitives.tip>
          </h2>

          <%!-- Only the holder can issue one, in the panel just below. --%>
          <Regent.Primitives.empty_state
            :if={@key.shards == [] and @key.owner?}
            id="key-no-shards"
            class="kf-empty"
            title="No shards yet."
          >
            Issue one below to let an agent act for this Key.
          </Regent.Primitives.empty_state>
          <Regent.Primitives.empty_state
            :if={@key.shards == [] and not @key.owner?}
            id="key-no-shards"
            class="kf-empty"
            title="No shards yet."
          />

          <.live_component
            :if={@key.owner? and @key.shards != []}
            module={WalletPanel}
            names_sender={false}
            id="key-shards-action"
            flow={:end_shard}
            fleet={@key.fleet}
            actor={@actor}
            lease={@lease}
            token_id={@key.token_id}
            refresh={@key.shards}
          >
            <:buttons :let={panel}>
              <.shard_list shards={@key.shards} panel={panel} />
            </:buttons>
          </.live_component>

          <.shard_list :if={not @key.owner?} shards={@key.shards} panel={nil} />
        </section>

        <section
          :if={@key.owner?}
          id="key-issue-shard"
          class="key-panel"
          aria-labelledby="key-issue-shard-title"
        >
          <h2 id="key-issue-shard-title">
            Issue a shard
            <Regent.Primitives.tip id="key-issue-tip" label="About issuing a shard">
              Check the agent’s wallet address. Issuing again to a wallet with a shard renews it from now.
            </Regent.Primitives.tip>
          </h2>

          <FleetRisks.disclosure id="key-issue-shard-risks" shard?={true} />

          <.live_component
            module={WalletPanel}
            names_sender={false}
            id="key-issue-shard-action"
            class="key-issue-shard"
            flow={:issue_shard}
            fleet={@key.fleet}
            actor={@actor}
            lease={@lease}
            inputs={%{"keys" => "#{@key.token_id}", "wallet" => "", "days" => "30"}}
          >
            <:fields :let={panel}>
              <div class="key-shard-form">
                <.field id="key-shard-keys" name="keys" label="Keys" value={panel.inputs["keys"]} />
                <.field
                  id="key-shard-wallet"
                  name="wallet"
                  label="Agent’s wallet"
                  value={panel.inputs["wallet"]}
                />
                <.field
                  id="key-shard-days"
                  name="days"
                  label="Days"
                  inputmode="numeric"
                  value={panel.inputs["days"]}
                />
              </div>
            </:fields>
            <:buttons :let={panel}>
              <WalletPanel.step_button panel={panel} step="issue" id="key-issue-shard-button">
                Issue shard
              </WalletPanel.step_button>
            </:buttons>
          </.live_component>
        </section>

        <section
          :if={@key.owner?}
          id="key-agent-voting"
          class="key-panel"
          aria-labelledby="key-agent-voting-title"
        >
          <h2 id="key-agent-voting-title">
            Agent voting
            <Regent.Primitives.tip id="key-agent-voting-tip" label="About agent voting">
              When it’s on, the Key’s shards can vote and propose with it. It stays as set until changed, even across new shards.
            </Regent.Primitives.tip>
          </h2>

          <.live_component
            module={WalletPanel}
            names_sender={false}
            id="key-agent-voting-action"
            flow={:agent_voting}
            fleet={@key.fleet}
            actor={@actor}
            lease={@lease}
            refresh={@key.shards}
            inputs={%{"keys" => "#{@key.token_id}"}}
          >
            <:fields :let={panel}>
              <div class="key-shard-form">
                <.field
                  id="key-agent-voting-keys"
                  name="keys"
                  label="Keys"
                  value={panel.inputs["keys"]}
                />
              </div>
            </:fields>
            <:notes :let={panel}>
              <p :if={voting(panel)} id="key-agent-voting-state" class="key-detail">
                On for {voting(panel)}
              </p>
            </:notes>
            <:buttons :let={panel}>
              <WalletPanel.step_button panel={panel} step="on" id="key-agent-voting-on">
                Turn on
              </WalletPanel.step_button>
              <WalletPanel.step_button
                panel={panel}
                step="off"
                id="key-agent-voting-off"
                variant="secondary"
              >
                Turn off
              </WalletPanel.step_button>
            </:buttons>
          </.live_component>
        </section>
      </div>
    </article>
    """
  end

  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :inputmode, :string, default: nil

  # A field the wallet buttons' steps are built from.
  defp field(assigns) do
    ~H"""
    <Regent.Primitives.field :let={field} id={@id} label={@label}>
      <input
        id={field.id}
        name={@name}
        value={@value}
        inputmode={@inputmode}
        autocomplete="off"
        aria-describedby={field.described_by}
        data-onchain-input={@name}
      />
    </Regent.Primitives.field>
    """
  end

  # The keys named whose shards may vote now, or nil for none.
  defp voting(panel) do
    case WalletPanel.figures(panel) do
      %{voting: [_key | _more] = keys} -> Enum.map_join(keys, ", ", &"Key #{Rules.grouped(&1)}")
      _none -> nil
    end
  end

  attr :shards, :list, required: true
  attr :panel, :any, required: true, doc: "the end and renew buttons' panel, nil for a visitor"

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
          <p :if={is_nil(shard.agent)} class="key-name">No agent yet</p>
          <span :if={shard.agent}>{shard.agent.harness}</span>
          <span>Until {date(shard.expires_at)}</span>
          <.address id={"key-shard-address-#{shard.wallet}"} wallet={shard.wallet} />
        </div>

        <div :if={@panel} class="key-shard-actions">
          <WalletPanel.step_button
            panel={@panel}
            step={"renew-#{shard.wallet}"}
            id={"key-shard-renew-#{shard.wallet}"}
          >
            Renew 30 days
          </WalletPanel.step_button>
          <WalletPanel.step_button
            panel={@panel}
            step={"end-#{shard.wallet}"}
            id={"key-shard-end-#{shard.wallet}"}
            variant="secondary"
          >
            End
          </WalletPanel.step_button>
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
      deployed?: key != nil and key.fleet.manager_address != nil,
      owner_wallet: key && key.owner_wallet,
      owner?: owns_key?(actor, key),
      refreshing?: not Chain.fresh?(fleet_id),
      edits_restricted?:
        match?([%{restricted: true}], Keys.latest_edits_restrictions!(fleet_id, [token_id])),
      shards: if(key, do: Profile.shards(fleet_id, token_id), else: []),
      messages: DmsLive.message_link(actor, key && key.owner_wallet, fleet_id, token_id)
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
