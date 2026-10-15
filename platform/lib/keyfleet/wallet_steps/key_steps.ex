defmodule Keyfleet.WalletSteps.KeySteps do
  @moduledoc """
  The steps of a key's own buttons: buying the next key, asking again for a
  key's random draw, claiming what a key has earned, claiming a Regents Club
  key waiting for its Pass's holder, marking keys present,
  issuing, renewing and ending shards, and turning agent voting on or off.
  `Keyfleet.WalletSteps.Build` describes what every builder answers.

  Pages and requests name a fleet's Keys by number; every step names them by
  their id in the one Key collection, `Fleet.onchain_token_id/2`.
  """

  alias Keyfleet.Fleets.{Fleet, Presets}
  alias Keyfleet.Keys
  alias Keyfleet.Treasury
  alias Keyfleet.WalletSteps.{Build, Reads, Typed}
  alias RegentChain.{Call, Review}

  # How long a purchase may take to reach the chain, counted from the latest
  # block's own clock, so a wallet's computer running fast or slow doesn't
  # shorten or stretch it.
  @purchase_seconds 600
  # A key's seed before its random draw arrives.
  @no_seed "0x" <> String.duplicate("0", 64)
  # How long a renewed shard lasts, in days.
  @renew_days 30
  # How many lapsed presences one press of Continue clears.
  @sweep_limit 256
  # How long a presence lasts, in seconds.
  @presence_seconds 172_800

  @doc false
  def steps(:buy, request) do
    if Presets.given?(request.fleet.id),
      do: {:problem, :not_for_sale, %{}},
      else: buy(request)
  end

  # Asking again for a key's random draw, which anyone may do while its
  # request was refused: it has no seed, and no request was ever accepted.
  def steps(:reveal, %{fleet: fleet, token_id: token_id}) do
    figures = %{token_id: token_id}
    onchain = Fleet.onchain_token_id(fleet, token_id)

    step =
      Review.step(
        "reveal",
        fleet.keys_address,
        Call.encode("requestReveal(uint256)", [onchain])
      )

    with {:ok, reads} <- Reads.at_head(),
         {:ok, seed} <-
           Reads.one(reads, fleet.keys_address, "revealSeed(uint256)", [onchain], :bytes32),
         {:ok, requested_at} <-
           Reads.one(
             reads,
             fleet.keys_address,
             "revealRequestedAt(uint256)",
             [onchain],
             {:uint, 64}
           ) do
      blocked =
        cond do
          seed != @no_seed -> %{"reveal" => :revealed}
          requested_at != 0 -> %{"reveal" => :reveal_requested}
          true -> %{}
        end

      {:ok, [step], Map.put(figures, :blocked, blocked)}
    else
      _unread -> {:problem, :unread, figures}
    end
  end

  # One step for each token the ledger pays keys in: it settles the key to
  # its holder and pays the holder, and the signer's own credit when the
  # signer is the key's agent rather than its holder.
  def steps(:claim, %{fleet: fleet, signer: signer, token_id: token_id}) do
    figures = %{token_id: token_id, waiting: []}

    with {:ok, reads} <- Reads.at_head(),
         {:ok, assets} <-
           Reads.one(reads, fleet.rewards_address, "rewardAssets()", [], {:array, :address}),
         {:ok, %{^token_id => {holder, allowed?}}} when is_binary(holder) <-
           Reads.acting(reads, fleet, signer, [token_id], "isActive"),
         {:ok, waiting} <-
           Reads.each(assets, &waiting(reads, fleet, &1, token_id, holder, signer)) do
      steps =
        Enum.map(
          waiting,
          &Review.step(
            "claim-#{&1.asset}",
            fleet.rewards_address,
            Call.encode("claim(uint256[],address[])", [
              [Fleet.onchain_token_id(fleet, token_id)],
              [&1.asset]
            ])
          )
        )

      blocked =
        for entry <- waiting, reason = claim_blocked(allowed?, entry), into: %{} do
          {"claim-#{entry.asset}", reason}
        end

      {:ok, steps,
       %{token_id: token_id, holder: holder, waiting: named(fleet, waiting), blocked: blocked}}
    else
      _unread -> {:problem, :unread, figures}
    end
  end

  # Taking Regents Club Key N from the claims contract, where it waits for
  # whoever holds Regents Club Pass N, with everything it earned while it
  # waited, in every asset at once, paid to the same wallet. Certain to fail once the Key has left the
  # contract, while the signer doesn't hold that Pass, and for good once the
  # Pass is burned, which the Pass collection then refuses to name a holder of.
  # Only a Regents Club Key waits there: the contract's claim(N) always moves
  # Club Key N, so any other fleet's Key gets no step.
  def steps(:club_claim, %{fleet: fleet, signer: signer, token_id: token_id}) do
    figures = %{token_id: token_id}
    claims = fleet.club_claims_address

    with :ok <- club(fleet),
         {:ok, reads} <- Reads.at_head(),
         {:ok, holder} <- Reads.holder(reads, fleet, token_id),
         {:ok, pass} <- Reads.one(reads, claims, "PASS()", [], :address),
         {:ok, pass_holder} <- pass_holder(reads, pass, token_id) do
      blocked =
        cond do
          holder != claims -> %{"club-claim" => :club_claimed}
          pass_holder == nil -> %{"club-claim" => :pass_burned}
          pass_holder != signer -> %{"club-claim" => :not_pass_holder}
          true -> %{}
        end

      step =
        Review.step(
          "club-claim",
          claims,
          Call.encode("claim(uint256,address)", [token_id, signer])
        )

      {:ok, [step], Map.put(figures, :blocked, blocked)}
    else
      {:problem, :not_club} -> {:problem, :not_club, figures}
      _unread -> {:problem, :unread, figures}
    end
  end

  # Marking Keys present: the one Key a Key's page is about, or every Key the
  # signer holds or holds an active shard of. A Key's page shows whether its
  # Key is present whoever is looking. A Key sold less than two days ago can't
  # be marked yet, and the vote contract refuses a call naming one, so only
  # the Keys old enough are named; with none old enough the press is certain
  # to fail. Continue clears presences that have lapsed, which anyone may do.
  # A visitor holds no Keys.
  def steps(:present, %{fleet: fleet, signer: signer, token_id: token_id}) do
    candidates = present_candidates(fleet, signer, token_id)
    figures = %{keys: [], maintenance?: false}

    with {:ok, reads} <- Reads.at_head(),
         {:ok, standing} <- Reads.acting(reads, fleet, signer, candidates, "isActive"),
         keys = for(key <- candidates, match?({_holder, true}, standing[key]), do: key),
         {:ok, presence} <-
           Reads.each(if(token_id, do: [token_id], else: keys), &presence(reads, fleet, &1)),
         {:ok, maintenance?} <- maintenance?(reads, fleet) do
      ready = for %{token_id: key, mature?: true} <- presence, key in keys, do: key
      onchain = Enum.map(ready, &Fleet.onchain_token_id(fleet, &1))

      steps = [
        Review.step("present", fleet.votes_address, Call.encode("present(uint256[])", [onchain])),
        Review.step(
          "sweep",
          fleet.votes_address,
          Call.encode("sweepExpired(uint256)", [@sweep_limit])
        )
      ]

      {:ok, steps,
       %{
         keys: Enum.map(presence, &Map.delete(&1, :mature?)),
         maintenance?: maintenance?,
         blocked: present_blocked(keys, ready, token_id)
       }}
    else
      _unread -> {:problem, :unread, figures}
    end
  end

  # Shards of the typed keys for the typed wallet and days. Issuing again to
  # a wallet that holds a shard of a key renews it from now.
  def steps(:issue_shard, %{fleet: fleet, signer: signer, inputs: inputs}) do
    with {:ok, keys} <- Build.typed(inputs, "keys", &Typed.keys/1, %{}),
         {:ok, wallet} <-
           Build.typed(inputs, "wallet", &Typed.address(&1, :shard_wallet_unreadable), %{
             keys: keys
           }),
         figures = %{keys: keys, wallet: wallet},
         {:ok, days} <- Build.typed(inputs, "days", &Typed.days/1, figures),
         figures = Map.put(figures, :days, days),
         {:ok, reads} <- reads(figures),
         {:ok, owned?} <- owned?(reads, fleet, signer, keys, figures) do
      blocked =
        cond do
          wallet == signer -> %{"issue" => :own_wallet}
          not owned? -> %{"issue" => :not_your_key}
          true -> %{}
        end

      {:ok, [Review.step("issue", fleet.shards_address, issue(fleet, keys, wallet, days))],
       Map.put(figures, :blocked, blocked)}
    end
  end

  # For each of the key's active shards, ending it now and renewing it.
  def steps(:end_shard, %{fleet: fleet, signer: signer, token_id: token_id}) do
    wallets = fleet.id |> Keys.active_shards_of_keys!([token_id]) |> Enum.map(& &1.wallet)
    figures = %{token_id: token_id, wallets: wallets, renew_days: @renew_days}

    with {:ok, reads} <- Reads.at_head(),
         {:ok, holder} <- Reads.holder(reads, fleet, token_id),
         {:ok, active} <-
           Reads.each(
             wallets,
             &Reads.one(
               reads,
               fleet.shards_address,
               "isActive(uint256,address)",
               [Fleet.onchain_token_id(fleet, token_id), &1],
               :bool
             )
           ) do
      steps =
        Enum.flat_map(wallets, fn wallet ->
          [
            Review.step(
              "end-#{wallet}",
              fleet.shards_address,
              Call.encode("end(uint256[],address)", [
                [Fleet.onchain_token_id(fleet, token_id)],
                wallet
              ])
            ),
            Review.step(
              "renew-#{wallet}",
              fleet.shards_address,
              issue(fleet, [token_id], wallet, @renew_days)
            )
          ]
        end)

      blocked =
        wallets
        |> Enum.zip(active)
        |> Enum.flat_map(fn {wallet, active?} ->
          [
            {"end-#{wallet}", end_blocked(active?, signer in [holder, wallet])},
            {"renew-#{wallet}", if(signer != holder, do: :not_your_key)}
          ]
        end)
        |> Enum.reject(fn {_step, reason} -> is_nil(reason) end)
        |> Map.new()

      {:ok, steps, Map.put(figures, :blocked, blocked)}
    else
      _unread -> {:problem, :unread, figures}
    end
  end

  # Whether the typed keys' shards may vote them and propose with them, and
  # which of them may now.
  def steps(:agent_voting, %{fleet: fleet, signer: signer, inputs: inputs}) do
    with {:ok, keys} <- Build.typed(inputs, "keys", &Typed.keys/1, %{}),
         figures = %{keys: keys, voting: []},
         {:ok, reads} <- reads(figures),
         {:ok, owned?} <- owned?(reads, fleet, signer, keys, figures),
         {:ok, voting} <- agent_voting_on(reads, fleet, keys, figures) do
      blocked = if owned?, do: %{}, else: %{"on" => :not_your_key, "off" => :not_your_key}

      {:ok,
       [
         Review.step("on", fleet.shards_address, agent_voting(fleet, keys, true)),
         Review.step("off", fleet.shards_address, agent_voting(fleet, keys, false))
       ], %{keys: keys, voting: voting, blocked: blocked}}
    end
  end

  @doc "How long a purchase step stays good after it is built, in seconds."
  def purchase_seconds, do: @purchase_seconds

  defp club(fleet), do: if(Presets.given?(fleet.id), do: :ok, else: {:problem, :not_club})

  # The Keys a presence step covers: the one named, else the signer's own.
  defp present_candidates(_fleet, _signer, token_id) when is_integer(token_id), do: [token_id]
  defp present_candidates(_fleet, nil, nil), do: []
  defp present_candidates(fleet, signer, nil), do: Build.own_keys(fleet, signer)

  defp present_blocked([], _ready, token_id) when is_integer(token_id),
    do: %{"present" => :not_your_key}

  defp present_blocked([], _ready, nil), do: %{"present" => :no_keys}
  defp present_blocked(_keys, [], _token_id), do: %{"present" => :too_new}
  defp present_blocked(_keys, _ready, _token_id), do: %{}

  # The next Key, at its price, bought from the fleet's manager, which takes
  # the USDC. How many Keys are sold, the next one's price and whether the
  # fleet's sales are open are all read from the chain at the latest block,
  # so a Key sold since the page last heard is already counted. The manager
  # refuses to price the next Key only once every Key is sold (Regents Club
  # Keys, never priced, are turned away before this), so a refusal means
  # there is nothing left to buy. The wallet approves exactly the price when its USDC allowance to the
  # manager is below it, and until it does the purchase is certain to fail,
  # as it is before the fleet's sales open; the purchase names the price as
  # its most, so a Key that has since cost more is refused and no USDC is
  # taken. Founding fleets ask nothing of buyers, so the purchase carries no
  # proof.
  defp buy(%{fleet: fleet, signer: signer}) do
    manager = &Reads.one(&1, fleet.manager_address, &2, [], {:uint, 256})

    with {:ok, reads} <- Reads.at_head(),
         {:ok, minted} <- manager.(reads, "totalMinted()") do
      case manager.(reads, "nextPrice()") do
        {:ok, price} -> offer(reads, fleet, signer, %{token_id: minted + 1, price: price})
        {:error, :reverted} -> {:problem, :sold_out, %{max_supply: minted}}
        {:error, _unread} -> {:problem, :unread, %{approve?: nil}}
      end
    else
      _unread -> {:problem, :unread, %{approve?: nil}}
    end
  end

  defp offer(reads, fleet, signer, %{price: price} = figures) do
    with {:ok, open?} <-
           Reads.one(
             reads,
             fleet.keys_address,
             "salesOpen(uint256)",
             [fleet.chain_fleet_id],
             :bool
           ),
         {:ok, allowance} <-
           Reads.one(
             reads,
             fleet.usdc_address,
             "allowance(address,address)",
             [signer, fleet.manager_address],
             {:uint, 256}
           ) do
      deadline = DateTime.to_unix(Reads.now(reads)) + @purchase_seconds
      approve? = allowance < price

      approve =
        Review.step(
          "approve",
          fleet.usdc_address,
          Call.encode("approve(address,uint256)", [fleet.manager_address, price])
        )

      buy =
        Review.step(
          "buy",
          fleet.manager_address,
          Call.encode("purchase(address,uint256,uint256,bytes32[])", [signer, price, deadline, []])
        )

      blocked =
        cond do
          not open? -> %{"buy" => :sales_not_open}
          approve? -> %{"buy" => :approve_usdc_first}
          true -> %{}
        end

      {:ok, if(approve?, do: [approve, buy], else: [buy]),
       Map.merge(figures, %{approve?: approve?, blocked: blocked})}
    else
      _unread -> {:problem, :unread, Map.put(figures, :approve?, nil)}
    end
  end

  # What a claim of one asset would pay: what the key has accrued, which
  # settles to its holder, the holder's credit, and the signer's own when the
  # signer isn't the holder.
  defp waiting(reads, fleet, asset, token_id, holder, signer) do
    credit =
      &Reads.one(
        reads,
        fleet.rewards_address,
        "credits(address,address)",
        [asset, &1],
        {:uint, 256}
      )

    with {:ok, accrued} <-
           Reads.one(
             reads,
             fleet.rewards_address,
             "accrued(address,uint256)",
             [asset, Fleet.onchain_token_id(fleet, token_id)],
             {:uint, 256}
           ),
         {:ok, held} <- credit.(holder),
         {:ok, own} <- if(signer == holder, do: {:ok, 0}, else: credit.(signer)) do
      {:ok, %{asset: asset, amount: accrued + held + own}}
    end
  end

  defp claim_blocked(false, _entry), do: :not_your_key
  defp claim_blocked(true, %{amount: 0}), do: :nothing_to_claim
  defp claim_blocked(true, _entry), do: nil

  defp end_blocked(false, _may_end?), do: :shard_ended
  defp end_blocked(true, false), do: :not_your_key
  defp end_blocked(true, true), do: nil

  # Each amount with its token's symbol and decimals, as the fleet's balances
  # name them; both nil for a token that hasn't said.
  defp named(fleet, waiting) do
    known = Map.new(Treasury.payable_assets(fleet), &{&1.address, &1})

    Enum.map(waiting, fn %{asset: asset} = entry ->
      known
      |> Map.get(asset, %{symbol: nil, decimals: nil, usdc?: false, known?: false})
      |> Map.take([:symbol, :decimals, :usdc?, :known?])
      |> Map.merge(entry)
    end)
  end

  # The Key with when its presence lapses, nil when it isn't present, and
  # whether it is old enough to be marked present.
  defp presence(reads, fleet, key) do
    onchain = Fleet.onchain_token_id(fleet, key)

    with {:ok, active?} <-
           Reads.one(reads, fleet.votes_address, "isActive(uint256)", [onchain], :bool),
         {:ok, from} <-
           Reads.one(reads, fleet.votes_address, "presentFrom(uint256)", [onchain], {:uint, 64}),
         {:ok, matures_at} <- matures_at(reads, fleet, onchain) do
      now = DateTime.to_unix(Reads.now(reads))

      {:ok,
       %{
         token_id: key,
         until: if(active?, do: DateTime.from_unix!(from + @presence_seconds)),
         mature?: matures_at != nil and matures_at <= now
       }}
    end
  end

  # When a Key may first take part, nil for one not sold yet, which the vote
  # contract refuses to date.
  defp matures_at(reads, fleet, onchain) do
    case Reads.one(reads, fleet.votes_address, "maturesAt(uint256)", [onchain], {:uint, 64}) do
      {:error, :reverted} -> {:ok, nil}
      answer -> answer
    end
  end

  # Whether lapsed presences are waiting to be cleared: a proposal clears up
  # to 256 itself and is refused while more are left. Asked of the vote
  # contract by simulating a Continue that clears none.
  defp maintenance?(reads, fleet) do
    with {:ok, [_moved, due?]} <-
           Reads.many(reads, fleet.votes_address, "sweepExpired(uint256)", [0], [
             {:uint, 256},
             :bool
           ]),
         do: {:ok, due?}
  end

  # Whether the signer holds every key named, read at the head.
  defp owned?(reads, fleet, signer, keys, figures) do
    case Reads.each(keys, &Reads.holder(reads, fleet, &1)) do
      {:ok, holders} -> {:ok, Enum.all?(holders, &(&1 == signer))}
      {:error, _reason} -> {:problem, :unread, figures}
    end
  end

  # The keys whose shards may vote now, read at the head.
  defp agent_voting_on(reads, fleet, keys, figures) do
    case Reads.each(
           keys,
           &Reads.one(
             reads,
             fleet.shards_address,
             "agentVoting(uint256)",
             [Fleet.onchain_token_id(fleet, &1)],
             :bool
           )
         ) do
      {:ok, on} -> {:ok, for({key, true} <- Enum.zip(keys, on), do: key)}
      {:error, _reason} -> {:problem, :unread, figures}
    end
  end

  defp reads(figures) do
    case Reads.at_head() do
      {:ok, reads} -> {:ok, reads}
      {:error, _reason} -> {:problem, :unread, figures}
    end
  end

  defp issue(fleet, keys, wallet, days),
    do: Call.encode("issue(uint256[],address,uint16)", [onchain(fleet, keys), wallet, days])

  defp agent_voting(fleet, keys, on),
    do: Call.encode("setAgentVoting(uint256[],bool)", [onchain(fleet, keys), on])

  defp onchain(fleet, keys), do: Enum.map(keys, &Fleet.onchain_token_id(fleet, &1))

  # Who holds Regents Club Pass `pass_id`, or nil once it is burned.
  defp pass_holder(reads, pass, pass_id) do
    case Reads.one(reads, pass, "ownerOf(uint256)", [pass_id], :address) do
      {:error, :reverted} -> {:ok, nil}
      answer -> answer
    end
  end
end
