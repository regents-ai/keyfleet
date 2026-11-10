defmodule KeyfleetWeb.FleetProposals do
  @moduledoc """
  The proposal pages of each fleet that most visitors open, read once for
  every open page and held in `Keyfleet.SharedReading`. One runs on each
  machine.

  Four kinds of reading come from each pass over a fleet, the first three
  exactly as `KeyfleetWeb.ProposalsPage.first_pages/2` reads them:

    * `list_key/1`: the first page of its proposals, with what the form for a
      new one starts from;
    * `treasury_key/1`: its Treasury page;
    * `proposal_key/2`: the first page of each proposal on that list, with
      its first votes and where it stands as the vote contract says at the
      latest block. A proposal leaves when twenty newer ones push it off the
      list, and its key goes with it;
    * `KeyfleetWeb.ShareCard.key/1`: for a fleet with a share picture of its
      own, the figures on it (`KeyfleetWeb.ShareCard.figures/1`), so the
      pages naming the picture and the picture itself read nothing. A Key's
      card made after the Key changed hands arrives with the minute's heal.

  None of these depends on who is reading: `KeyfleetWeb.ProposalsPage`
  reads with no actor, and a reader's own Keys and wallet are read by the
  wallet panels beside them, never here. A list page further back, a
  proposal's later votes and a proposal older than the list are read for the
  visit that asks for them.

  This is a reread on notice, the second of the two shapes the
  `elixir-stack` skill lets keep a shared reading. It hears what an open
  proposals page hears, the fleet's proposal records and its treasury's
  balances changing (`Keyfleet.Proposals.topic/1`), and the fleet's Keys
  changing hands (`Keyfleet.Keys.topic/1`), which moves the Keys sold on its
  Treasury page, read before for each visit. A burst of notices is
  answered by one read of each fleet named, a second after the first. Each
  minute `Keyfleet.SharedReading.Heal` asks for every fleet again, which
  mends a lost notice and moves the words that change with the clock: a vote
  that has closed, a proposal that may now be carried out. It holds nothing
  but which fleets are due a read, and it never writes the database.

  A proposal's standing is the chain's, read at the latest block once a
  pass for every proposal on the list that a vote can still change. One
  already settled on its records and on chain keeps what was read of its
  votes and standing, so a quiet fleet costs its proposals' records and no
  call to the chain.

  A crowd costs what one visitor costs (`ash-frontend`,
  `references/public-figures.md`).

  The first read happens as it starts, with a bounded wait, so each fleet
  holds a reading or its degraded mark before the site serves a page, and a
  database or a network that doesn't answer never holds up the start.
  """

  use GenServer

  alias Keyfleet.{Fleets, Keys, Proposals, SharedReading}
  alias KeyfleetWeb.{PageRead, ProposalsPage, ShareCard}

  @kinds [:fleet_proposals, :fleet_treasury, :proposal, :share_card]

  @doc "Where the first page of `fleet_id`'s proposals is held."
  def list_key(fleet_id), do: {:fleet_proposals, fleet_id}

  @doc "Where `fleet_id`'s Treasury page is held."
  def treasury_key(fleet_id), do: {:fleet_treasury, fleet_id}

  @doc """
  Where the first page of proposal `number` is held. `number` is one the
  fleet's list holds, never one taken from an address.
  """
  def proposal_key(fleet_id, number) when is_integer(number),
    do: {:proposal, "#{fleet_id}:#{number}"}

  @doc "The page held at `key`, and whether its last read failed; nil while there is none."
  def fetch(key) do
    case SharedReading.fetch(key) do
      {:ok, %{reading: %{} = reading, degraded?: degraded?}} -> {reading, degraded?}
      _not_read -> nil
    end
  end

  @doc """
  The proposals on `fleet_id`'s list a vote can still change, oldest first, so
  the one closing soonest leads and newer ones never push it down.
  """
  def open(fleet_id) do
    case fetch(list_key(fleet_id)) do
      {%{proposals: proposals}, _degraded?} ->
        proposals |> Enum.filter(&(&1.status in [:open, :waiting])) |> Enum.reverse()

      _none ->
        []
    end
  end

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil)

  @impl true
  def init(nil) do
    Enum.each(@kinds, &SharedReading.subscribe_heal/1)

    for fleet_id <- Fleets.catalog_ids(),
        topic <- [Proposals.topic(fleet_id), Keys.topic(fleet_id)],
        do: Phoenix.PubSub.subscribe(Keyfleet.PubSub, topic)

    first_read(Fleets.catalog_ids())
    {:ok, MapSet.new()}
  end

  # Every fleet is read beside the start, all at once, so a slow database holds
  # the start for one wait, not one per fleet. Any not read in time is marked
  # degraded; its next notice or the minute's heal reads it again.
  defp first_read(fleet_ids) do
    fleet_ids
    |> Task.async_stream(&__MODULE__.read/1,
      max_concurrency: length(fleet_ids),
      timeout: Application.fetch_env!(:keyfleet, :first_read_ms),
      on_timeout: :kill_task
    )
    |> Enum.zip(fleet_ids)
    |> Enum.each(fn
      {{:ok, _read}, _fleet_id} -> :ok
      {{:exit, :timeout}, fleet_id} -> degraded(fleet_id)
    end)
  end

  @impl true
  def handle_info({:proposals_changed, fleet_id}, due), do: {:noreply, due(due, fleet_id)}

  # A new reading of the treasury changes the Treasury page and what each
  # payment comes to at today's balance.
  def handle_info({:balances_changed, fleet_id}, due), do: {:noreply, due(due, fleet_id)}

  # A Key sold or moved changes the Keys sold the Treasury page shows.
  def handle_info({:keys_changed, fleet_id, _token_ids}, due), do: {:noreply, due(due, fleet_id)}

  # The four kinds' heals arrive together each minute and join one pass.
  def handle_info({:shared_reading_heal, _kind}, due),
    do: {:noreply, Enum.reduce(Fleets.catalog_ids(), due, &due(&2, &1))}

  def handle_info(:read, due) do
    Enum.each(due, &__MODULE__.read/1)
    {:noreply, MapSet.new()}
  end

  # The first fleet to fall due starts the one-second wait; the rest join it.
  defp due(due, fleet_id) do
    if MapSet.size(due) == 0, do: Process.send_after(self(), :read, 1_000)
    MapSet.put(due, fleet_id)
  end

  @doc """
  Reads `fleet_id`'s first pages, and its share picture's figures if it has
  one, and puts them, deleting the proposals its list no longer holds. What
  the producer runs on each pass.

  Each proposal's page is put before the list, and the list names the ones
  held (`shared`), so a page that finds its proposal there finds its page
  held too. One refused, a proposal whose calls are too long to hold, is
  read for each visit instead, never shown as unreadable.
  """
  def read(fleet_id) do
    held = held(fleet_id)

    # A failed database read is a read not taken, never a reason for this
    # process, and the site with it, to stop. It is logged and saved with the
    # site's errors as a page's own read is (`KeyfleetWeb.PageRead`), so one
    # that keeps failing is seen at /admin/errors.
    pages = fn -> ProposalsPage.first_pages(fleet_id, &last_page(fleet_id, &1)) end

    case PageRead.run("proposals", pages) do
      {:ok, %{list: list, treasury: treasury, details: details}} ->
        shared =
          for {number, page} <- details,
              SharedReading.put(proposal_key(fleet_id, number), page) == :ok,
              do: number

        SharedReading.put(treasury_key(fleet_id), treasury)
        SharedReading.put(list_key(fleet_id), Map.put(list, :shared, shared))
        kept = MapSet.new(shared, &"#{fleet_id}:#{&1}")

        for id <- held, id not in kept, do: SharedReading.delete({:proposal, id})

      {:error, _not_read} ->
        degraded(fleet_id)
    end

    share(fleet_id)
  end

  defp share(fleet_id) do
    if fleet_id in ShareCard.fleets(), do: read_share(fleet_id)
  end

  defp read_share(fleet_id) do
    case PageRead.run("share picture", fn -> ShareCard.figures(fleet_id) end) do
      {:ok, figures} -> SharedReading.put(ShareCard.key(fleet_id), figures)
      {:error, _not_read} -> SharedReading.degraded(ShareCard.key(fleet_id))
    end
  end

  defp degraded(fleet_id) do
    SharedReading.degraded(list_key(fleet_id))
    SharedReading.degraded(treasury_key(fleet_id))
    Enum.each(held(fleet_id), &SharedReading.degraded({:proposal, &1}))
    if fleet_id in ShareCard.fleets(), do: SharedReading.degraded(ShareCard.key(fleet_id))
  end

  # The proposal's page from the last pass, if one is held.
  defp last_page(fleet_id, number) do
    case fetch(proposal_key(fleet_id, number)) do
      {page, _degraded?} -> page
      nil -> nil
    end
  end

  # The trailing ":" keeps one fleet's ids from matching another's.
  defp held(fleet_id),
    do: Enum.filter(SharedReading.ids(:proposal), &String.starts_with?(&1, fleet_id <> ":"))
end
