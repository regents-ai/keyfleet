defmodule KeyfleetWeb.AccountLive do
  @moduledoc """
  The signed-in person's account, one tab each: Profile (who the site knows
  them as, the public name they save from the browser with this page's sign-in
  (the `PublicName` hook), their wallets and which one is active
  (`KeyfleetWeb.AccountWallets`),
  their ENS name and World ID, the keys their wallets hold, each new one with
  the time left until it first shares the Daily Treasury Slice to Keys and
  the agents on it, as a gallery of Key cards, those with agents first
  (`KeyfleetWeb.KeyGallery`), with one Claim per fleet for all of them at
  once and, in a fleet where they hold several, the one they post as
  (`KeyfleetWeb.PostingKeyChoice`), and this browser's session, in
  the layout every Regent site shares, `Regent.Account.layout`, Keyfleet's own
  sections first), Agents (the agents paired with their account, which they may
  open, rename and unpair (`KeyfleetWeb.AgentsPanel`), whose Pair New Agent opens
  the pairing window), Wallets (the wallets their sign-in
  verified, the same list) and Connections (the accounts they have connected, which each
  fleet's Member List shows beside their address). Points has its
  own page (`KeyfleetWeb.PointsLive`).

  Everything here is read from the sign-in the shell already holds; nothing on
  the page asks the visitor to sign in again.
  """

  use KeyfleetWeb, :html

  import KeyfleetWeb.Components.Countdown
  import KeyfleetWeb.Components.PageHead, only: [page_head: 1]
  import KeyfleetWeb.Components.VerifiedConnections

  alias Keyfleet.Accounts
  alias Keyfleet.Accounts.EnsIdentity
  alias Keyfleet.Actors.{Human, System}
  alias Keyfleet.Agents
  alias Keyfleet.Agents.Avatar
  alias Keyfleet.Fleets
  alias Keyfleet.Fleets.Fleet
  alias Keyfleet.Keys
  alias Keyfleet.Keys.Metadata
  alias Keyfleet.WalletSteps.Reads
  alias KeyfleetWeb.WalletPanel
  alias KeyfleetWeb.WalletWords

  attr :account, :map, default: nil
  attr :signed_out_reason, :atom, default: :signed_out
  attr :account_control, :map, required: true

  attr :lease, :map,
    default: nil,
    doc: "the page's `session_lease`, which Claim checks"

  attr :actor, :any, default: nil, doc: "the signed-in person, or nil"

  attr :held_keys, :list,
    default: [],
    doc:
      "the keys the account's wallets hold, as `%{fleet_id, chain_id, name, token_ids, pictures}` per fleet, `chain_id` nil for a fleet not on chain, `pictures` their small cards by Key"

  attr :slices, KeyfleetWeb.Read,
    default: %KeyfleetWeb.Read{},
    doc:
      "the read of when each held key still too new first shares the Treasury slice (`slices/1`)"

  attr :key_agents, :map,
    default: %{agents: [], on_keys: %{}},
    doc: "the person's paired agents and the agents on each of their Keys (`key_agents/1`)"

  def profile(assigns) do
    ~H"""
    <.settings_page
      id="account-page"
      title="Profile"
      account={@account}
      signed_out_reason={@signed_out_reason}
    >
      <Regent.Account.layout id="account">
        <:site>
          <section
            id="account-keys"
            class="account-panel account-keys"
            aria-labelledby="account-keys-title"
          >
            <h2 id="account-keys-title">Your Keys</h2>
            <Regent.Primitives.empty_state
              :if={@held_keys == []}
              class="kf-empty"
              title="No Keys yet."
            >
              <:action>
                <.link
                  class="rg-button rg-button--secondary"
                  patch={Keyfleet.Fleets.path("fleet_tech_classic")}
                >
                  <span class="rg-button__label">Get a Key on Classic #1</span>
                </.link>
              </:action>
            </Regent.Primitives.empty_state>
            <div :for={fleet <- @held_keys} class="account-keys__fleet">
              <h3>
                <.link patch={Keyfleet.Fleets.path(fleet.fleet_id)}>{fleet.name}</.link>
              </h3>
              <.live_component
                module={KeyfleetWeb.KeyGallery}
                id={"account-key-agents-#{fleet.fleet_id}"}
                fleet_id={fleet.fleet_id}
                token_ids={fleet.token_ids}
                pictures={fleet.pictures}
                agents={@key_agents.agents}
                on_keys={Map.get(@key_agents.on_keys, fleet.fleet_id, %{})}
                account={@account}
                lease={@lease}
              >
                <:key :let={token_id}>
                  <.slice slices={@slices} fleet_id={fleet.fleet_id} token_id={token_id} />
                </:key>
              </.live_component>
              <.live_component
                :if={fleet.chain_id}
                module={WalletPanel}
                id={"account-claim-#{fleet.fleet_id}"}
                class="account-keys__claim"
                flow={:claim_all}
                tool="keys_claim_all"
                fleet={%{fleet_id: fleet.fleet_id, chain_id: fleet.chain_id}}
                actor={@actor}
                lease={@lease}
                refresh={fleet.token_ids}
              >
                <:buttons :let={panel}>
                  <WalletPanel.step_button
                    :for={waiting <- waiting(panel)}
                    panel={panel}
                    step={"claim-#{waiting.asset}"}
                    id={"account-claim-#{fleet.fleet_id}-#{waiting.asset}"}
                  >
                    Claim {WalletWords.token_amount(waiting)}
                  </WalletPanel.step_button>
                </:buttons>
              </.live_component>
              <.live_component
                :if={length(fleet.token_ids) > 1}
                module={KeyfleetWeb.PostingKeyChoice}
                id={"account-posting-key-#{fleet.fleet_id}"}
                fleet_id={fleet.fleet_id}
                token_ids={fleet.token_ids}
                account={@account}
                lease={@lease}
              />
            </div>
          </section>
        </:site>
        <:site>
          <.live_component
            module={KeyfleetWeb.AccountWallets}
            id="account-wallets"
            class="account-panel"
            account={@account}
          />
        </:site>
        <:identity>
          <Regent.HolographicCard.card
            id="account-identity"
            class="account-identity"
            phx-hook="HolographicCard"
          >
            <Regent.Account.identity
              id="account-who"
              name={@account_control.label}
              wallet={@account_control.wallet}
              ens_name={@account_control.ens_name}
            >
              <:picture>
                <img
                  :if={@account_control.avatar_src}
                  src={@account_control.avatar_src}
                  referrerpolicy="no-referrer"
                  width="64"
                  height="64"
                  alt=""
                />
              </:picture>
            </Regent.Account.identity>
          </Regent.HolographicCard.card>
        </:identity>
        <:profile>
          <%!-- The name is saved from the browser with the page's session and forms token. --%>
          <div id="account-profile" phx-hook="PublicName" phx-update="ignore">
            <Regent.Profile.panel
              id="account-public-name"
              class="account-panel"
              display_name={@account.display_name}
            />
          </div>

          <section class="account-panel account-details" aria-labelledby="account-details-title">
            <h2 id="account-details-title">Details</h2>
            <dl>
              <div id="account-ens-name">
                <dt>ENS name</dt>
                <.ens_name account={@account} />
              </div>
              <div id="account-world-id">
                <dt>World ID</dt>
                <dd :if={@account.world_verified_at}>
                  Verified on {Calendar.strftime(@account.world_verified_at, "%-d %B %Y")}
                </dd>
                <dd :if={is_nil(@account.world_verified_at)}>Not verified</dd>
              </div>
            </dl>
          </section>

          <section class="account-panel account-session" aria-labelledby="account-session-title">
            <h2 id="account-session-title">Session</h2>
            <Regent.Primitives.button type="button" variant="secondary" data-account-target="sign-out">
              Sign out
            </Regent.Primitives.button>
          </section>
        </:profile>
      </Regent.Account.layout>
    </.settings_page>
    """
  end

  attr :slices, KeyfleetWeb.Read, required: true
  attr :fleet_id, :string, required: true
  attr :token_id, :integer, required: true

  # A key still too new to share the Daily Treasury Slice to Keys counts down
  # to when it first does, in the Key page's words; any other key shows nothing.
  defp slice(assigns) do
    assigns =
      assign(
        assigns,
        :matures_at,
        Map.get(assigns.slices.value || %{}, {assigns.fleet_id, assigns.token_id})
      )

    ~H"""
    <.countdown
      :if={@matures_at}
      id={"account-slice-#{@fleet_id}-#{@token_id}"}
      class="account-keys__slice"
      closes_at={@matures_at}
      now={@slices.read_at}
      format="clock"
      lead="Eligible in"
      done="Eligible"
    />
    """
  end

  attr :account, :map, required: true

  # The primary name Ethereum publishes for the account's wallet. A wallet whose
  # name is still being read is never shown as having none.
  defp ens_name(%{account: %{ens_name: name}} = assigns) when is_binary(name) do
    ~H"""
    <dd class="account-wallet">
      <Regent.Primitives.address
        id="account-ens"
        address={@account.wallet_address}
        label={@account.ens_name}
      />
    </dd>
    """
  end

  defp ens_name(%{account: %{wallet_address: nil}} = assigns) do
    ~H"""
    <dd>No wallet linked</dd>
    """
  end

  defp ens_name(%{account: %{ens_lookup_state: :done}} = assigns) do
    ~H"""
    <dd>Not set</dd>
    """
  end

  defp ens_name(%{account: %{ens_lookup_state: :pending}} = assigns) do
    ~H"""
    <dd role="status">Checking…</dd>
    """
  end

  defp ens_name(assigns) do
    ~H"""
    <dd role="status">Couldn’t check. Refresh to try again.</dd>
    """
  end

  attr :lease, :map, required: true
  attr :account, :map, default: nil
  attr :signed_out_reason, :atom, default: :signed_out

  def agents(assigns) do
    ~H"""
    <.settings_page
      id="account-agents-page"
      title="Agents"
      account={@account}
      signed_out_reason={@signed_out_reason}
    >
      <.live_component
        module={KeyfleetWeb.AgentsPanel}
        id="account-agents"
        account={@account}
        lease={@lease}
      />
    </.settings_page>
    """
  end

  attr :account, :map, default: nil
  attr :signed_out_reason, :atom, default: :signed_out

  def wallets(assigns) do
    ~H"""
    <.settings_page
      id="wallets-page"
      title="Wallets"
      account={@account}
      signed_out_reason={@signed_out_reason}
    >
      <.live_component
        module={KeyfleetWeb.AccountWallets}
        id="wallets-list"
        class="account-panel"
        account={@account}
      />
    </.settings_page>
    """
  end

  attr :account, :map, default: nil
  attr :signed_out_reason, :atom, default: :signed_out
  attr :verified_connections, KeyfleetWeb.Read, required: true
  attr :verified_connections_notice, :map, default: nil

  def connections(assigns) do
    ~H"""
    <.settings_page
      id="connections-page"
      title="Connections"
      account={@account}
      signed_out_reason={@signed_out_reason}
    >
      <.verified_connections
        id="account-verified-connections"
        class="account-panel"
        identities={@verified_connections.value}
        read_state={@verified_connections.state}
        notice={@verified_connections_notice}
      />
    </.settings_page>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :account, :map, default: nil
  attr :signed_out_reason, :atom, required: true
  slot :inner_block, required: true

  @doc "One account view: its heading, then its panels, or a sign-in when signed out."
  def settings_page(assigns) do
    ~H"""
    <article id={@id} class="account-page">
      <.page_head title={@title} />

      <Regent.Account.signed_out
        :if={is_nil(@account)}
        id={"#{@id}-signed-out"}
        reason={@signed_out_reason}
      >
        <:sign_in>
          <Regent.Primitives.button type="button" data-account-target="sign-in">
            Sign in
          </Regent.Primitives.button>
        </:sign_in>
      </Regent.Account.signed_out>

      {@account && render_slot(@inner_block)}
    </article>
    """
  end

  @doc """
  Asks Ethereum again for the primary name of the account's wallet when it was
  never answered for that wallet or the last asking failed, so opening the page
  is what "Refresh to try again" means. Asking, and its answer, each reach the
  open pages through the account's lookup notice (`EnsIdentity.topic/1`), which
  reads the account again.
  """
  def check_ens(%{wallet_address: wallet, ens_lookup_state: state} = account)
      when is_binary(wallet) and state in [nil, :failed] do
    if EnsIdentity.looking_up?(),
      do: Accounts.request_ens_lookup(account.id, wallet, actor: %System{})

    :ok
  end

  def check_ens(_account), do: :ok

  @doc """
  Every key the signed-in person's wallets hold, fleet by fleet in catalog
  order, leaving out fleets where they hold none, with each Key's small card
  where it has one (`Keyfleet.Keys.Metadata.small_cards/2`).
  """
  def held_keys(nil), do: []

  def held_keys(%Human{wallet_addresses: wallets} = actor) do
    held = wallets |> Keys.keys_held_everywhere!(actor: actor) |> Enum.group_by(& &1.fleet_id)

    fleets = Map.new(Fleets.list_fleets!(), &{&1.id, &1})

    for %{id: fleet_id, name: name} <- Fleets.catalog(),
        keys = Map.get(held, fleet_id, []),
        keys != [] do
      token_ids = Enum.map(keys, & &1.token_id)

      %{
        fleet_id: fleet_id,
        chain_id: fleets[fleet_id] && fleets[fleet_id].chain_id,
        name: name,
        token_ids: token_ids,
        pictures: pictures(fleets[fleet_id], token_ids)
      }
    end
  end

  # The small cards are read a hundred Keys at a time.
  defp pictures(nil, _token_ids), do: %{}

  defp pictures(fleet, token_ids),
    do:
      token_ids
      |> Enum.chunk_every(100)
      |> Enum.reduce(%{}, &Map.merge(&2, Metadata.small_cards(fleet, &1)))

  @doc """
  The agents paired with the signed-in person now, each with its picture and
  the harness it paired on, and the agents on each of their Keys, fleet by
  fleet, as `%{agents: agents, on_keys: %{fleet_id => %{token_id => agents}}}`
  (`Keyfleet.Keys.AgentKey`), read in one go for every fleet.
  """
  def key_agents(nil), do: %{agents: [], on_keys: %{}}

  def key_agents(%Human{} = actor) do
    agents = actor |> Keys.person_agents() |> with_pictures() |> with_harnesses()

    on_keys =
      for {{fleet_id, token_id}, on_key} <- Keys.agents_on_keys(actor, agents),
          reduce: %{},
          do: (on_keys ->
                 Map.update(
                   on_keys,
                   fleet_id,
                   %{token_id => on_key},
                   &Map.put(&1, token_id, on_key)
                 ))

    %{agents: agents, on_keys: on_keys}
  end

  # The picture each agent set, or the one made from its wallet, a hundred
  # agents at a time.
  defp with_pictures(agents) do
    profiles =
      agents
      |> Enum.map(& &1.wallet)
      |> Enum.chunk_every(100)
      |> Enum.flat_map(&Agents.agents_by_wallets!(&1, actor: %System{}, load: [:avatar_src]))
      |> Map.new(&{&1.wallet_address, &1.avatar_src})

    for agent <- agents,
        do: Map.put(agent, :picture, profiles[agent.wallet] || Avatar.shown(nil, agent.wallet))
  end

  # The harness each agent paired on (`Keyfleet.Agents.Pairing`), a hundred
  # agents at a time; nil for one unpaired since its pairing was read.
  defp with_harnesses(agents) do
    harnesses =
      agents
      |> Enum.map(& &1.wallet)
      |> Enum.chunk_every(100)
      |> Enum.flat_map(&Agents.pairings!(&1, actor: %System{}))
      |> Map.new(&{&1.wallet, &1.harness})

    for agent <- agents, do: Map.put(agent, :harness, harnesses[agent.wallet])
  end

  @doc """
  When each held key in its first 2 days first shares the Daily Treasury Slice
  to Keys, as the vote contract dates it, read at the latest block:
  `%{{fleet_id, token_id} => DateTime}`. Older keys, and fleets not on chain,
  are left out.
  """
  def slices(held_keys) do
    keys =
      for %{fleet_id: fleet_id, chain_id: chain_id, token_ids: token_ids} <- held_keys,
          chain_id != nil,
          fleet = Fleets.get_fleet!(fleet_id),
          token_id <- token_ids,
          do: {fleet, token_id}

    with {:ok, reads} <- Reads.at_head(),
         {:ok, dated} <- Reads.each(keys, &matures_at(reads, &1)) do
      head = Reads.now(reads)
      {:ok, for({key, at} <- dated, DateTime.after?(at, head), into: %{}, do: {key, at})}
    end
  end

  defp matures_at(reads, {fleet, token_id}) do
    onchain = Fleet.onchain_token_id(fleet, token_id)

    with {:ok, at} <-
           Reads.one(reads, fleet.votes_address, "maturesAt(uint256)", [onchain], {:uint, 64}),
         do: {:ok, {{fleet.id, token_id}, DateTime.from_unix!(at)}}
  end

  # What every Key held in the fleet has waiting, in each token, together.
  defp waiting(panel), do: panel |> WalletPanel.figures() |> Map.get(:waiting, [])
end
