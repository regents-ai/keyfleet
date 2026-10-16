defmodule KeyfleetWeb.Components.MemberList do
  @moduledoc """
  A fleet's Member List: one card for each address holding its Keys, most
  Keys first, twenty to a page (`?view=members&page=N`). Each card names the
  holder (the name of the Regent account whose main address it is, else the
  short address), how many Keys it holds with its lowest ones as
  small cards opening each Key, its connected X, GitHub and Farcaster
  accounts, and whether it is active: a Key of it can vote now, as the
  Treasury counts presence. `club_claims` is the address the Regents Club's
  Keys wait at for their Pass holders, left out of the list; nil for a fleet
  with none.

  The page is read when it opens and again whenever the fleet's Keys change
  hands (`refresh/1`).

  Assigns: `id`, `fleet_id`, `club_claims`, `deck` (the fleet's `id`,
  `deck_hash` and `deck_size`), `params` (the page's address query) and
  `profile_open?`.
  """
  use KeyfleetWeb, :live_component

  alias Keyfleet.Accounts
  alias Keyfleet.Accounts.LinkedIdentity.Providers
  alias Keyfleet.Actors.System
  alias Keyfleet.Fleets.Rules
  alias Keyfleet.Keys
  alias Keyfleet.Keys.Metadata
  alias Keyfleet.PublicIdentity
  alias KeyfleetWeb.KeyLinks
  alias KeyfleetWeb.NotFoundError

  @per_page 20
  @cards_shown 50
  @online_for 3600

  @doc "The Member List on show is read again: Keys changed hands in its fleet."
  def refresh(id), do: send_update(__MODULE__, id: id, refresh: true)

  @impl true
  def update(%{refresh: true}, socket), do: {:ok, read(socket)}

  def update(assigns, socket) do
    page = page!(assigns.params)
    socket = assign(socket, Map.put(assigns, :page, page))

    {:ok,
     if(changed?(socket, :page) or changed?(socket, :fleet_id),
       do: read(socket),
       else: socket
     )}
  end

  # The page the address names: the first when it names none.
  defp page!(%{"page" => page}) do
    case Integer.parse(page) do
      {page, ""} when page >= 1 and page <= 100_000 -> page
      _not_a_page -> raise NotFoundError
    end
  end

  defp page!(_params), do: 1

  defp read(%{assigns: %{fleet_id: fleet_id, club_claims: club_claims, page: page}} = socket) do
    found =
      Keys.holders(fleet_id, List.wrap(club_claims), (page - 1) * @per_page, @per_page + 1)

    if found == [] and page > 1, do: raise(NotFoundError)

    {shown, more} = Enum.split(found, @per_page)
    holders = cards(fleet_id, socket.assigns.deck, shown)
    assign(socket, holders: holders, next?: more != [], now: DateTime.utc_now())
  end

  defp cards(_fleet_id, _deck, []), do: []

  defp cards(fleet_id, deck, holders) do
    wallets = Enum.map(holders, & &1.wallet)
    held = Keys.lowest_held(fleet_id, wallets, @cards_shown)
    pictures = pictures(deck, held |> Map.values() |> List.flatten())
    present = Keys.present_holders(fleet_id, wallets)
    last_active = Keys.last_active(fleet_id, wallets)
    {names, connections} = people(wallets)

    for %{wallet: wallet, count: count} <- holders do
      %{
        wallet: wallet,
        count: count,
        name: names[wallet],
        connections: Map.get(connections, wallet, []),
        present?: MapSet.member?(present, wallet),
        last_active: last_active[wallet],
        cards:
          for(token_id <- held[wallet], do: %{token_id: token_id, image: pictures[token_id]}),
        more: count - length(held[wallet])
      }
    end
  end

  # The small cards are read a hundred Keys at a time.
  defp pictures(deck, token_ids),
    do:
      token_ids
      |> Enum.chunk_every(100)
      |> Enum.reduce(%{}, &Map.merge(&2, Metadata.small_cards(deck, &1)))

  # The name and connections of the account each address is the main address
  # of, by address. An account's other addresses have neither, so a Key held
  # in one of them is never tied to the person.
  defp people(wallets) do
    accounts =
      Accounts.accounts_holding_wallets!(wallets,
        actor: %System{},
        load: [:display_name, :ens_name]
      )

    shown =
      accounts
      |> Enum.map(& &1.id)
      |> Accounts.list_shown_linked_identities!()
      |> Enum.group_by(& &1.human_account_id, &connection/1)
      |> Map.new(fn {account_id, links} -> {account_id, Enum.reject(links, &is_nil/1)} end)

    by_wallet =
      for %{wallet_address: wallet} = account <- accounts,
          is_binary(wallet),
          into: %{},
          do: {String.downcase(wallet), account}

    for wallet <- wallets, account = by_wallet[wallet], reduce: {%{}, %{}} do
      {names, connections} ->
        {Map.put(names, wallet, PublicIdentity.name(account)),
         Map.put(connections, wallet, Map.get(shown, account.id, []))}
    end
  end

  # A connection is shown only with the account name it links to.
  defp connection(identity) do
    with handle when is_binary(handle) <- Providers.handle(identity),
         url when is_binary(url) <- Providers.profile_url(identity.provider, identity.username) do
      %{label: Providers.label(identity.provider), handle: handle, url: url}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section id={@id} class="member-list" aria-labelledby={"#{@id}-title"}>
      <h2 id={"#{@id}-title"}>Member List</h2>
      <p :if={@holders == []} id={"#{@id}-none"}>No Keys have been issued yet.</p>

      <ol id={"#{@id}-holders"} class="member-list__holders">
        <li
          :for={holder <- @holders}
          id={"#{@id}-holder-#{holder.wallet}"}
          class="member-card"
        >
          <p class="member-card__who">
            <strong>{holder.name || RegentFormat.short_address(holder.wallet)}</strong>
            <span :if={holder.name}>{RegentFormat.short_address(holder.wallet)}</span>
            <span class="member-card__count">{Rules.keys(holder.count)}</span>
          </p>
          <p class="member-card__status" data-present={holder.present? && "true"}>
            {if holder.present?, do: "Active", else: "Idle"} · {seen(holder.last_active, @now)}
          </p>
          <p class="member-card__connections">
            <span class="member-card__label">Connections</span>
            <span :if={holder.connections == []}>None</span>
            <a
              :for={link <- holder.connections}
              href={link.url}
              target="_blank"
              rel="noopener noreferrer nofollow"
            >
              {link.label} {link.handle}
            </a>
          </p>
          <ul class="fleet-entry__cards member-card__cards" aria-label="Keys held" tabindex="0">
            <li :for={card <- holder.cards}>
              <.link
                id={"#{@id}-card-#{card.token_id}"}
                class="fleet-entry__card"
                patch={KeyLinks.key_path(@fleet_id, card.token_id, @params)}
                replace={@profile_open?}
              >
                <img
                  :if={card.image}
                  src={card.image}
                  alt=""
                  width="48"
                  height="60"
                  loading="lazy"
                  decoding="async"
                />
                <span :if={!card.image} class="fleet-entry__blank"></span>
                Key {Rules.grouped(card.token_id)}
              </.link>
            </li>
            <li :if={holder.more > 0} class="fleet-entry__more">
              and {Rules.grouped(holder.more)} more
            </li>
          </ul>
        </li>
      </ol>

      <nav :if={@page > 1 or @next?} class="fleet-pages" aria-label="More members">
        <.link :if={@page > 1} id={"#{@id}-previous"} patch={page_path(@fleet_id, @page - 1)}>
          Previous
        </.link>
        <.link :if={@next?} id={"#{@id}-next"} patch={page_path(@fleet_id, @page + 1)}>
          Next
        </.link>
      </nav>
    </section>
    """
  end

  defp seen(nil, _now), do: "never active"

  defp seen(at, now) do
    if DateTime.diff(now, at) < @online_for,
      do: "online now",
      else: "last active #{KeyfleetWeb.Time.moment(at, now)}"
  end

  defp page_path(fleet_id, 1), do: KeyLinks.members_path(fleet_id)
  defp page_path(fleet_id, page), do: KeyLinks.members_path(fleet_id, page)
end
