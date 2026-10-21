defmodule KeyfleetWeb.AccountLive do
  @moduledoc """
  The signed-in person's account, one tab each: Profile (who the site knows
  them as, their wallets and which one is active (`KeyfleetWeb.AccountWallets`),
  their ENS name and World ID, the keys their wallets hold and, in a
  fleet where they hold several, the one they post as
  (`KeyfleetWeb.PostingKeyChoice`), the agents
  paired with their account, which they may open, rename and unpair
  (`KeyfleetWeb.AgentsPanel`), their Credits and this browser's session), Wallets (the wallets their sign-in
  verified, the same list) and Connections (the accounts they have connected, which each
  fleet's Member List shows beside their address). Points has its
  own page (`KeyfleetWeb.PointsLive`).

  Everything here is read from the sign-in the shell already holds; nothing on
  the page asks the visitor to sign in again.
  """

  use KeyfleetWeb, :html

  import KeyfleetWeb.Components.PageHead, only: [page_head: 1]
  import KeyfleetWeb.Components.VerifiedConnections

  alias Keyfleet.Accounts
  alias Keyfleet.Accounts.EnsIdentity
  alias Keyfleet.Actors.{Human, System}
  alias Keyfleet.Fleets
  alias Keyfleet.Keys
  alias Keyfleet.PublicIdentity
  alias KeyfleetWeb.KeyLinks

  attr :account, :map, default: nil
  attr :signed_out_reason, :atom, default: :signed_out
  attr :account_control, :map, required: true
  attr :lease, :map, default: nil, doc: "the page's `session_lease`, which the agents list checks"

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
      <:tip>Who Keyfleet knows you as, your Keys, your agents and your Credits.</:tip>
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
              <h2 :if={!name_is_wallet?(@account, @account_control.label)}>
                {@account_control.label}
              </h2>
              <h2 :if={name_is_wallet?(@account, @account_control.label)}>
                <Regent.Primitives.address
                  id="account-name"
                  address={@account.wallet_address}
                  label={@account_control.label}
                />
              </h2>
            </div>
          </div>
        </Regent.HolographicCard.card>

        <.live_component
          module={KeyfleetWeb.AccountWallets}
          id="account-wallets"
          class="account-panel"
          account={@account}
        />

        <section class="account-panel account-details" aria-labelledby="account-details-title">
          <h2 id="account-details-title">Details</h2>
          <dl>
            <div id="account-ens-name">
              <dt>ENS name</dt>
              <.ens_name account={@account} />
            </div>
            <div>
              <dt>Display name</dt>
              <dd>{@account.display_name || "Not set"}</dd>
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

        <section
          id="account-keys"
          class="account-panel account-keys"
          aria-labelledby="account-keys-title"
        >
          <h2 id="account-keys-title">Your Keys</h2>
          <Regent.Primitives.empty_state
            :if={@held_keys == []}
            class="kf-empty"
            title="Your wallets don’t hold any Keys yet."
          >
            A Regents Club Pass comes with the
            <.link navigate={~p"/app/fleets/regents_club"}>Club Key</.link>
            of the same number.
          </Regent.Primitives.empty_state>
          <div :for={fleet <- @held_keys} class="account-keys__fleet">
            <h3>
              <.link patch={Keyfleet.Fleets.path(fleet.fleet_id)}>{fleet.name}</.link>
            </h3>
            <ul class="account-keys__list">
              <li :for={token_id <- fleet.token_ids}>
                <.link patch={KeyLinks.key_path(fleet.fleet_id, token_id)}>Key {token_id}</.link>
              </li>
            </ul>
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

        <.live_component
          module={KeyfleetWeb.AgentsPanel}
          id="account-agents"
          account={@account}
          lease={@lease}
        />

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
    <dd>No primary name set for this wallet</dd>
    """
  end

  defp ens_name(%{account: %{ens_lookup_state: :pending}} = assigns) do
    ~H"""
    <dd role="status">Checking Ethereum for a primary name…</dd>
    """
  end

  defp ens_name(assigns) do
    ~H"""
    <dd role="status">Couldn’t check Ethereum right now. Refresh to try again.</dd>
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
      <:tip>The wallets your sign-in verified.</:tip>
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
      <:tip>
        The accounts you have connected, such as X, GitHub and Farcaster. They are shown
        beside your address on each fleet's Member List.
      </:tip>
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
  slot :tip, required: true
  slot :inner_block, required: true

  @doc "One account view: its heading, then its panels, or a sign-in when signed out."
  def settings_page(assigns) do
    ~H"""
    <article id={@id} class="account-page">
      <.page_head title={@title}>
        <:tip>{render_slot(@tip)}</:tip>
      </.page_head>

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

  # The card names the person the way the header does. A name that is the
  # wallet itself, its ENS name or short address, opens and copies the address.
  defp name_is_wallet?(%{wallet_address: wallet} = account, label) when is_binary(wallet),
    do: label in [PublicIdentity.short_wallet(wallet), account.ens_name]

  defp name_is_wallet?(_account, _label), do: false

  # A read not yet answered shows as loading, and an answer with nothing in it
  # as current figures.
  defp summary_state(state) when state in [:idle, :loading], do: :loading
  defp summary_state(:empty), do: :ready
  defp summary_state(state), do: state

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
