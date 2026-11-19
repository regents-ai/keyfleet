defmodule Keyfleet.SeasonsTest do
  use ExUnit.Case, async: false

  alias Keyfleet.Actors
  alias Keyfleet.ChainHelpers
  alias Keyfleet.CoinbaseStub
  alias Keyfleet.Fleets
  alias Keyfleet.Keys
  alias Keyfleet.PairingHelpers
  alias Keyfleet.Repo
  alias Keyfleet.Seasons
  alias Keyfleet.Seasons.CoinList
  alias Keyfleet.Seasons.Errors.PicksClosedError
  alias Keyfleet.Seasons.Errors.ProductIneligibleError
  alias Keyfleet.Seasons.Errors.ProductsUnreadError
  alias Keyfleet.Seasons.Errors.SeasonUnknownError
  alias Keyfleet.Seasons.Season
  alias Keyfleet.Seasons.SeasonPick
  alias Phoenix.Socket.Broadcast

  @fleet "fibonacci_syndicate"
  @system %Actors.System{}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Fleets.bootstrap_catalog!()
    ChainHelpers.seed_cursor!(@fleet)
    epoch!(token_id: 1, owner_wallet: wallet("a"))
    epoch!(token_id: 2, owner_wallet: wallet("b"))

    CoinbaseStub.stub(
      [
        CoinbaseStub.product("SOL-USD"),
        CoinbaseStub.product("ETH-USD"),
        CoinbaseStub.product("THIN-USD", %{"approximate_quote_24h_volume" => "999999.99"}),
        CoinbaseStub.product("EDGE-USD", %{"approximate_quote_24h_volume" => "1000000"}),
        CoinbaseStub.product("GONE-USD", %{"trading_disabled" => true, "status" => "delisted"}),
        CoinbaseStub.product("LOOK-USD", %{"view_only" => true}),
        CoinbaseStub.product("NEWS-USD", %{"approximate_quote_24h_volume" => ""}),
        CoinbaseStub.product("SOL-USDC", %{"quote_currency_id" => "USDC"})
      ],
      %{}
    )

    :ok = CoinList.read()
    on_exit(fn -> Keyfleet.SharedReading.delete(CoinList.key()) end)

    %{season: season!(1, Seasons.ends_at(Seasons.boundary(DateTime.utc_now())))}
  end

  test "a Key has one pick a season; a change takes the newest place, the same pick keeps its own",
       %{season: season} do
    Phoenix.PubSub.subscribe(Keyfleet.PubSub, Seasons.season_topic(season.id))

    first = pick!(human("a"), "SOL-USD", "Fast chain")
    assert %{token_id: 1, product: "SOL-USD", reason: "Fast chain"} = first
    assert first.wallet == wallet("a")
    assert_receive %Broadcast{event: "season_changed", payload: payload}
    assert payload == %{}

    second = pick!(human("b"), "ETH-USD", nil)
    assert second.lock_order > first.lock_order
    assert_receive %Broadcast{event: "season_changed"}

    again = pick!(human("a"), "SOL-USD", "Fast chain")
    assert again.id == first.id and again.lock_order == first.lock_order
    refute_receive %Broadcast{event: "season_changed"}

    changed = pick!(human("a"), "ETH-USD", "Fast chain")
    assert changed.id == first.id
    assert changed.product == "ETH-USD"
    assert changed.lock_order > second.lock_order
    assert_receive %Broadcast{event: "season_changed"}

    reasoned = pick!(human("a"), "ETH-USD", "Changed my mind")
    assert reasoned.lock_order > changed.lock_order

    assert [%{token_id: 1, product: "ETH-USD"}, %{token_id: 2}] =
             SeasonPick |> Ash.read!(actor: @system) |> Enum.sort_by(& &1.token_id)
  end

  # The form sends an empty box; the signed request and the seasons_pick
  # tool leave a reason out. Either way the pick has none.
  test "a pick is the whole pick: sent with no reason it has none, and sent again unchanged it writes nothing",
       %{season: season} do
    first = pick!(human("a"), "SOL-USD", "Fast chain")
    pick!(human("b"), "ETH-USD", nil)
    Phoenix.PubSub.subscribe(Keyfleet.PubSub, Seasons.season_topic(season.id))

    bare = Seasons.pick!(@fleet, 1, %{"product" => "SOL-USD"}, actor: human("a"))
    assert %{reason: nil} = bare
    refute Ash.Resource.get_metadata(bare, :upsert_skipped)
    assert bare.lock_order > first.lock_order
    assert_receive %Broadcast{event: "season_changed"}

    for sent <- [%{"product" => "SOL-USD"}, %{"product" => "SOL-USD", "reason" => ""}] do
      again = Seasons.pick!(@fleet, 1, sent, actor: human("a"))
      assert Ash.Resource.get_metadata(again, :upsert_skipped)
      assert %{reason: nil} = Seasons.my_pick!(@fleet, 1, actor: human("a"))
      assert again.lock_order == bare.lock_order
      refute_receive %Broadcast{event: "season_changed"}
    end

    pick!(human("a"), "SOL-USD", "Back again")

    assert %{product: "ETH-USD", reason: nil} =
             Seasons.pick!(@fleet, 1, %{"product" => "ETH-USD"}, actor: human("a"))
  end

  test "before its season starts a pick is read only by its own Key and that Key's agents; from the start, by every member",
       %{season: season} do
    agent = PairingHelpers.agent_for!(human("a"))
    from_agent = pick!(agent, "SOL-USD", "My person's Key")
    assert %{token_id: 1, wallet: agent_wallet, acting_agent_wallet: agent_wallet} = from_agent
    assert agent_wallet == agent.wallet_address

    pick!(human("b"), "ETH-USD", nil)

    assert %{id: id, product: "SOL-USD"} = Seasons.my_pick!(@fleet, 1, actor: human("a"))
    assert id == from_agent.id
    assert %{id: ^id} = Seasons.my_pick!(@fleet, 1, actor: agent)
    assert %{token_id: 2} = Seasons.my_pick!(@fleet, 1, actor: human("b"))
    assert {:ok, {[], false}} = Seasons.picks_page(@fleet, 1, nil, 100, actor: human("b"))

    lock!(season)

    assert {:ok, {[%{token_id: 1, reason: "My person's Key"} = first, %{token_id: 2}], false}} =
             Seasons.picks_page(@fleet, 1, nil, 100, actor: human("b"))

    # A page holds no more than it is asked for, and the next reads on after it.
    assert {:ok, {[^first], true} = page} =
             Seasons.picks_page(@fleet, 1, nil, 1, actor: human("b"))

    assert {:ok, {[%{token_id: 2}], false}} =
             Seasons.picks_page(@fleet, 1, Seasons.next_after(page), 1, actor: human("b"))

    assert %{number: 1, holding: "USDC"} = Seasons.get_season!(@fleet, 1, actor: human("b"))
  end

  test "someone outside the fleet reads no season and no pick, and picks nothing" do
    pick!(human("a"), "SOL-USD", nil)

    for outsider <- [nil, human("c"), PairingHelpers.agent_for!(human("c"))] do
      assert {:error, %Ash.Error.Forbidden{}} =
               Seasons.list_seasons(@fleet, actor: outsider, authorize_with: :error)

      assert {:error, %Ash.Error.Forbidden{}} =
               Seasons.upcoming_season(@fleet, actor: outsider, authorize_with: :error)

      assert {:error, %Ash.Error.Forbidden{}} =
               Seasons.my_pick(@fleet, 1, actor: outsider, authorize_with: :error)

      assert {:error, %Ash.Error.Forbidden{}} =
               Seasons.picks_page(@fleet, 1, nil, 100, actor: outsider, authorize_with: :error)

      assert {:error, %Ash.Error.Forbidden{}} =
               Seasons.pick(@fleet, 1, %{product: "SOL-USD"}, actor: outsider)

      # The fleet's one access table says so, as `doctor`'s `may` answers it.
      refute Keyfleet.Access.allowed?(outsider, :read, :seasons, @fleet)
      refute Keyfleet.Access.allowed?(outsider, :write, :seasons, @fleet)
    end

    assert [%{number: 1}] = Seasons.list_seasons!(@fleet, actor: human("a"))
    assert Keyfleet.Access.allowed?(human("a"), :write, :seasons, @fleet)
  end

  test "a product not open to picks on Coinbase is refused, USDC never is" do
    for product <- ["THIN-USD", "GONE-USD", "LOOK-USD", "NEWS-USD", "NOPE-USD"] do
      assert {:error, %Ash.Error.Invalid{errors: [%ProductIneligibleError{product: ^product}]}} =
               Seasons.pick(@fleet, 1, %{product: product}, actor: human("a"))
    end

    for product <- ["SOL-USDC", "sol-usd", "SOL-USD ", "BTC"] do
      assert {:error, %Ash.Error.Invalid{}} =
               Seasons.pick(@fleet, 1, %{product: product}, actor: human("a"))
    end

    assert %{product: "EDGE-USD"} = pick!(human("a"), "EDGE-USD", nil)
    assert %{product: "USDC"} = pick!(human("a"), "USDC", nil)

    Keyfleet.SharedReading.degraded(CoinList.key())

    assert {:error, %Ash.Error.Framework{errors: [%ProductsUnreadError{}]}} =
             Seasons.pick(@fleet, 1, %{product: "SOL-USD"}, actor: human("a"))
  end

  test "a reason is plain text of at most 500 characters" do
    for reason <- [String.duplicate("a", 501), "Line one\nline two", "Zero​width"] do
      assert {:error, %Ash.Error.Invalid{}} =
               Seasons.pick(@fleet, 1, %{product: "SOL-USD", reason: reason}, actor: human("a"))
    end

    assert %{reason: reason} = pick!(human("a"), "SOL-USD", String.duplicate("é", 500))
    assert String.length(reason) == 500
  end

  test "an agent without a pairing picks nothing, even for a Key it holds a shard of" do
    ChainHelpers.deploy!(@fleet)

    unpaired = %Actors.Agent{
      wallet_address: wallet("d"),
      chain_id: 8453,
      verification_method: :eoa_recovery,
      audience: "keyfleet"
    }

    ChainHelpers.issue_shard!(@fleet, 2, unpaired.wallet_address)

    assert {:error, %Ash.Error.Forbidden{}} =
             Seasons.pick(@fleet, 1, %{product: "SOL-USD"}, actor: unpaired)

    # Its person's Key stops being its own once the pairing ends.
    agent = PairingHelpers.agent_for!(human("a"))
    person = %RegentAgents.Person{privy_user_id: agent.privy_user_id}
    {:ok, agents} = RegentAgents.list_my_agents(actor: person)

    :ok =
      RegentAgents.unpair_agent(Enum.find(agents, &(&1.wallet == agent.wallet_address)),
        actor: person
      )

    assert {:error, %Ash.Error.Forbidden{}} =
             Seasons.pick(@fleet, 1, %{product: "SOL-USD"}, actor: agent)

    assert [] = Ash.read!(SeasonPick, actor: @system)
  end

  test "a season takes picks only until it starts", %{season: season} do
    assert {:error, %Ash.Error.Invalid{errors: [%SeasonUnknownError{number: 2}]}} =
             Seasons.pick(@fleet, 2, %{product: "SOL-USD"}, actor: human("a"))

    lock!(season)

    assert {:error, %Ash.Error.Invalid{errors: [%PicksClosedError{number: 1}]}} =
             Seasons.pick(@fleet, 1, %{product: "SOL-USD"}, actor: human("a"))

    started = season!(2, Seasons.boundary(DateTime.utc_now()))
    assert started.locked_at == nil

    assert {:error, %Ash.Error.Invalid{errors: [%PicksClosedError{number: 2}]}} =
             Seasons.pick(@fleet, 2, %{product: "SOL-USD"}, actor: human("a"))
  end

  defp pick!(actor, product, reason),
    do: Seasons.pick!(@fleet, 1, %{product: product, reason: reason}, actor: actor)

  defp season!(number, starts_at) do
    Season
    |> Ash.Changeset.for_create(:open, %{fleet_id: @fleet, number: number, starts_at: starts_at},
      actor: @system
    )
    |> Ash.create!()
  end

  defp lock!(season) do
    season
    |> Ash.Changeset.for_update(:lock, %{holding: "USDC", holding_open_price: 1}, actor: @system)
    |> Ash.update!()
  end

  defp wallet(character), do: "0x" <> String.duplicate(character, 40)

  defp human(character),
    do: %Actors.Human{human_account_id: 1, wallet_addresses: [wallet(character)]}

  defp epoch!(overrides) do
    %{
      fleet_id: @fleet,
      token_id: 1,
      ownership_epoch: 1,
      owner_wallet: wallet("a"),
      block_number: 10,
      block_hash: "0x" <> String.duplicate("a", 64),
      log_index: 0
    }
    |> Map.merge(Map.new(overrides))
    |> then(fn event ->
      event
      |> Map.put(
        :transaction_hash,
        "0x" <>
          Base.encode16(:crypto.hash(:sha256, "#{event.token_id}/#{event.ownership_epoch}"),
            case: :lower
          )
      )
      |> Keys.record_epoch!(actor: @system)
    end)
  end
end
