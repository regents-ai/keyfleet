defmodule KeyfleetWeb.AccountLive do
  @moduledoc """
  The signed-in person's account, one tab each: Profile (who the site knows
  them as, the keys their wallets hold, the agents paired with their account,
  their Credits and this browser's session), Wallets (the wallets their sign-in
  verified) and Connections (the accounts they have connected, which each
  fleet's Member List shows beside their address). Points has its
  own page (`KeyfleetWeb.PointsLive`).

  Everything here is read from the sign-in the shell already holds; nothing on
  the page asks the visitor to sign in again.
  """

  use KeyfleetWeb, :html

  import KeyfleetWeb.Components.VerifiedConnections

  alias Keyfleet.Actors.Human
  alias Keyfleet.Fleets
  alias Keyfleet.Keys
  alias Keyfleet.PublicIdentity
  alias KeyfleetWeb.KeyLinks
  alias KeyfleetWeb.Read

  attr :account, :map, default: nil
  attr :signed_out_reason, :atom, default: :signed_out
  attr :account_control, :map, required: true
  attr :lease, :map, required: true, doc: "the page's `session_lease`, or nil"

  attr :paired_agents, KeyfleetWeb.Read,
    default: %KeyfleetWeb.Read{},
    doc: "the read of the agents paired with the account, most recent first"

  attr :credits, KeyfleetWeb.Read,
    default: %KeyfleetWeb.Read{},
    doc: "the read of the account's Credits balance, kept on regents.sh"

  attr :held_keys, :list,
    default: [],
    doc: "the keys the account's wallets hold, as `%{fleet_id, name, token_ids}` per fleet"

  def profile(assigns) do
    ~H"""
    <.settings_page
      id="account-page"
      title="Profile"
      account={@account}
      signed_out_reason={@signed_out_reason}
    >
      <:lede>Who Keyfleet knows you as, your Keys, your agents and your Credits.</:lede>
      <div class="account-grid">
        <Regent.HolographicCard.card
          id="account-identity"
          class="account-identity"
          phx-hook="HolographicCard"
        >
          <p class="account-kicker">Your account</p>
          <div class="account-identity__who">
            <img
              :if={@account_control.avatar_src}
              class="account-identity__avatar"
              src={@account_control.avatar_src}
              referrerpolicy="no-referrer"
              width="64"
              height="64"
              alt=""
            />
            <div class="account-identity__name">
              <h2>{@account_control.label}</h2>
              <p :if={short_wallet(@account) not in [nil, @account_control.label]}>
                <code>{short_wallet(@account)}</code>
              </p>
            </div>
          </div>
        </Regent.HolographicCard.card>

        <section class="account-panel account-details" aria-labelledby="account-details-title">
          <h2 id="account-details-title">Details</h2>
          <dl>
            <div>
              <dt>Display name</dt>
              <dd>{@account.display_name || "Not set"}</dd>
            </div>
          </dl>
        </section>

        <section
          id="account-keys"
          class="account-panel account-keys"
          aria-labelledby="account-keys-title"
        >
          <h2 id="account-keys-title">Your Keys</h2>
          <p :if={@held_keys == []}>
            Your wallets don’t hold any Keys yet. A Regents Club Pass comes with the
            <.link navigate={~p"/app/fleets/regents_club"}>Club Key</.link>
            of the same number.
          </p>
          <div :for={fleet <- @held_keys} class="account-keys__fleet">
            <h3>
              <.link patch={Keyfleet.Fleets.path(fleet.fleet_id)}>{fleet.name}</.link>
            </h3>
            <ul class="account-keys__list">
              <li :for={token_id <- fleet.token_ids}>
                <.link patch={KeyLinks.key_path(fleet.fleet_id, token_id)}>Key {token_id}</.link>
              </li>
            </ul>
          </div>
        </section>

        <Regent.Account.agents id="account-agents" agents={agent_rows(@paired_agents)}>
          <:about>
            An agent you pair with your account can post in the rooms of fleets where you hold a Key. It posts as your Key, with its name on every post.
          </:about>
          <:footer>
            <.live_component
              module={KeyfleetWeb.PairingBox}
              id="account-agents-pair"
              lease={@lease}
              account={@account}
            />
            <a href="https://regents.sh/account#account-agents">Unpair agents on regents.sh</a>
          </:footer>
        </Regent.Account.agents>

        <Regent.Account.credits_summary
          id="account-credits"
          available={@credits.value && RegentCredits.Amount.format(@credits.value.available)}
          held={@credits.value && RegentCredits.Amount.format(@credits.value.held)}
          state={summary_state(@credits.state)}
        >
          <a href="https://regents.sh/account">Manage Credits on regents.sh</a>
        </Regent.Account.credits_summary>

        <section class="account-panel account-session" aria-labelledby="account-session-title">
          <h2 id="account-session-title">Session</h2>
          <p>Signing out ends this session on this browser only.</p>
          <Regent.Primitives.button type="button" variant="secondary" data-account-target="sign-out">
            Sign out
          </Regent.Primitives.button>
        </section>
      </div>
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
      <:lede>The wallets your sign-in verified.</:lede>
      <section class="account-panel account-details" aria-labelledby="account-wallets-title">
        <h2 id="account-wallets-title">Your wallets</h2>
        <dl>
          <div>
            <dt>Wallet</dt>
            <dd :if={@account.wallet_address} class="account-wallet">
              <code>{@account.wallet_address}</code>
              <Regent.Primitives.copy_button id="account-wallet-copy" text={@account.wallet_address}>
                Copy
              </Regent.Primitives.copy_button>
            </dd>
            <dd :if={is_nil(@account.wallet_address)}>No wallet linked</dd>
          </div>
          <div :if={other_wallets(@account) != []}>
            <dt>Other linked wallets</dt>
            <dd>
              <ul class="account-wallet-list">
                <li :for={wallet <- other_wallets(@account)}><code>{wallet}</code></li>
              </ul>
            </dd>
          </div>
        </dl>
      </section>
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
      <:lede>
        The accounts you have connected, such as X, GitHub and Farcaster. They are shown
        beside your address on each fleet's Member List.
      </:lede>
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
  slot :lede, required: true
  slot :inner_block, required: true

  @doc "One account view: its heading, then its panels, or a sign-in when signed out."
  def settings_page(assigns) do
    ~H"""
    <article id={@id} class="account-page">
      <header class="account-heading">
        <p class="account-kicker">Account</p>
        <h1 tabindex="-1">{@title}</h1>
        <p class="account-lede">{render_slot(@lede)}</p>
      </header>

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

  defp other_wallets(%{wallet_address: primary, wallet_addresses: wallets}) do
    primary = primary && String.downcase(primary)

    wallets
    |> List.wrap()
    |> Enum.map(&String.downcase/1)
    |> Enum.uniq()
    |> Enum.reject(&(&1 == primary))
  end

  # The card names the person the way the header does; the wallet is only
  # repeated beneath when that name is something other than the wallet itself.
  defp short_wallet(%{wallet_address: wallet}) when is_binary(wallet),
    do: PublicIdentity.short_wallet(wallet)

  defp short_wallet(_account), do: nil

  # A read not yet answered shows as loading, and an answer with nothing in it
  # as current figures.
  defp summary_state(state) when state in [:idle, :loading], do: :loading
  defp summary_state(:empty), do: :ready
  defp summary_state(state), do: state

  # Still being read shows as loading; a failed read shows as unavailable,
  # never as no agents. A re-read keeps the agents already listed on screen.
  defp agent_rows(%Read{state: state}) when state in [:error, :stale], do: :unavailable
  defp agent_rows(%Read{value: nil}), do: :loading

  defp agent_rows(%Read{value: agents}) do
    now = DateTime.utc_now()

    Enum.map(
      agents,
      &%{
        id: &1.id,
        name: &1.name,
        kind: to_string(&1.harness),
        harness: RegentAgents.Harness.label(&1.harness),
        backed: not is_nil(&1.human_id),
        last_contact_iso: DateTime.to_iso8601(&1.last_contact_at),
        last_contact: RegentFormat.relative_time(&1.last_contact_at, now)
      }
    )
  end

  @doc """
  Reads the agents paired with the signed-in person's account, most recent
  first: `{:ok, agents}` or `{:error, reason}`.
  """
  def paired_agents(%{privy_user_id: person}),
    do: RegentAgents.list_my_agents(actor: %RegentAgents.Person{privy_user_id: person})

  @doc "Reads the signed-in person's Credits balance, kept once for every Regent site."
  def credits(%{privy_user_id: person}), do: {:ok, RegentCredits.balance(person)}

  @doc """
  Every key the signed-in person's wallets hold, fleet by fleet in catalog
  order, leaving out fleets where they hold none.
  """
  def held_keys(nil), do: []

  def held_keys(%Human{wallet_addresses: wallets} = actor) do
    for %{id: fleet_id, name: name} <- Fleets.catalog(),
        keys = Keys.keys_held_in_fleet!(fleet_id, wallets, actor: actor),
        keys != [],
        do: %{fleet_id: fleet_id, name: name, token_ids: Enum.map(keys, & &1.token_id)}
  end
end
