defmodule KeyfleetWeb.AccountLive do
  @moduledoc """
  The signed-in person's own page: who the site knows them as, the keys their
  wallets hold, the wallets their sign-in verified and the accounts they have
  connected.

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

  attr :account, :map, default: nil
  attr :account_control, :map, required: true
  attr :verified_connections, KeyfleetWeb.Read, required: true
  attr :verified_connections_notice, :map, default: nil

  attr :held_keys, :list,
    default: [],
    doc: "the keys the account's wallets hold, as `%{fleet_id, name, token_ids}` per fleet"

  def page(assigns) do
    ~H"""
    <article id="account-page" class="account-page">
      <header class="account-heading">
        <p class="account-kicker">Keyfleet</p>
        <h1 tabindex="-1">Account</h1>
        <p class="account-lede">
          The wallet you signed in with and the accounts you have connected.
        </p>
      </header>

      <section :if={is_nil(@account)} class="account-panel account-signed-out">
        <h2>Sign in to see your account</h2>
        <p>Your wallet and connections appear here once you are signed in.</p>
        <Regent.Primitives.button type="button" data-account-target="sign-in">
          Sign in
        </Regent.Primitives.button>
      </section>

      <div :if={@account} class="account-grid">
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

        <section
          id="account-keys"
          class="account-panel account-keys"
          aria-labelledby="account-keys-title"
        >
          <h2 id="account-keys-title">Your Keys</h2>
          <p :if={@held_keys == []}>
            Your wallets don’t hold any Keys yet. Choose a fleet on the
            <.link navigate={~p"/"}>home page</.link>
            to buy one.
          </p>
          <div :for={fleet <- @held_keys} class="account-keys__fleet">
            <h3>
              <.link patch={"/app/fleets/#{fleet.fleet_id}"}>{fleet.name}</.link>
            </h3>
            <ul class="account-keys__list">
              <li :for={token_id <- fleet.token_ids}>
                <.link patch={KeyLinks.key_path(fleet.fleet_id, token_id)}>Key {token_id}</.link>
              </li>
            </ul>
          </div>
        </section>

        <section class="account-panel account-details" aria-labelledby="account-details-title">
          <h2 id="account-details-title">Details</h2>
          <dl>
            <div>
              <dt>Wallet</dt>
              <dd :if={@account.wallet_address} class="account-wallet">
                <code>{@account.wallet_address}</code>
                <Regent.Primitives.copy_button
                  id="account-wallet-copy"
                  text={@account.wallet_address}
                >
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
            <div>
              <dt>Display name</dt>
              <dd>{@account.display_name || "Not set"}</dd>
            </div>
          </dl>
        </section>

        <.verified_connections
          id="account-verified-connections"
          class="account-panel"
          identities={@verified_connections.value}
          read_state={@verified_connections.state}
          notice={@verified_connections_notice}
        />

        <section class="account-panel account-session" aria-labelledby="account-session-title">
          <h2 id="account-session-title">Session</h2>
          <p>Signing out ends this session on this browser only.</p>
          <Regent.Primitives.button type="button" variant="secondary" data-account-target="sign-out">
            Sign out
          </Regent.Primitives.button>
        </section>
      </div>
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
