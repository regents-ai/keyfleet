defmodule Keyfleet.WalletSteps.KeySteps do
  @moduledoc """
  The steps of a key's own buttons: buying the next key, asking again for a
  key's random draw, claiming what a key has earned, marking keys present,
  issuing, renewing and ending shards, and turning agent voting on or off.
  `Keyfleet.WalletSteps.Build` describes what every builder answers.
  """

  alias Keyfleet.Chain
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
  # How many lapsed presences one press of Tidy up clears.
  @sweep_limit 256

  @doc false
  def steps(:buy, request) do
    progress = Chain.progress(request.fleet.id)

    if progress.next_price,
      do: buy(request, progress),
      else: {:problem, :sold_out, %{max_supply: progress.max_supply}}
  end

  # Asking again for a key's random draw, which anyone may do while its
  # request was refused: it has no seed, and no request was ever accepted.
  def steps(:reveal, %{fleet: fleet, token_id: token_id}) do
    figures = %{token_id: token_id}

    step =
      Review.step(
        "reveal",
        fleet.contract_address,
        Call.encode("requestReveal(uint256)", [token_id])
      )

    with {:ok, reads} <- Reads.at_head(),
         {:ok, seed} <-
           Reads.one(reads, fleet.contract_address, "revealSeed(uint256)", [token_id], :bytes32),
         {:ok, requested_at} <-
           Reads.one(
             reads,
             fleet.contract_address,
             "revealRequestedAt(uint256)",
             [token_id],
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
            Call.encode("claim(uint256[],address[])", [[token_id], [&1.asset]])
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

  # Marking keys present: the one key a key's page is about, or every key the
  # signer holds or holds an active shard of. A key's page shows whether its
  # key is present whoever is looking. Tidy up clears presences that have
  # lapsed, which anyone may do.
  def steps(:present, %{fleet: fleet, signer: signer, token_id: token_id}) do
    candidates = if token_id, do: [token_id], else: Build.own_keys(fleet, signer)
    figures = %{keys: [], maintenance?: false}

    with {:ok, reads} <- Reads.at_head(),
         {:ok, standing} <- Reads.acting(reads, fleet, signer, candidates, "isActive"),
         keys = for(key <- candidates, match?({_holder, true}, standing[key]), do: key),
         {:ok, presence} <-
           Reads.each(if(token_id, do: [token_id], else: keys), &present_until(reads, fleet, &1)),
         {:ok, maintenance?} <- maintenance?(reads, fleet) do
      steps = [
        Review.step("present", fleet.votes_address, Call.encode("present(uint256[])", [keys])),
        Review.step(
          "sweep",
          fleet.votes_address,
          Call.encode("sweepExpired(uint256)", [@sweep_limit])
        )
      ]

      blocked =
        cond do
          keys != [] -> %{}
          token_id -> %{"present" => :not_your_key}
          true -> %{"present" => :no_keys}
        end

      {:ok, steps, %{keys: presence, maintenance?: maintenance?, blocked: blocked}}
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

      {:ok, [Review.step("issue", fleet.shards_address, issue(keys, wallet, days))],
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
               [token_id, &1],
               :bool
             )
           ) do
      steps =
        Enum.flat_map(wallets, fn wallet ->
          [
            Review.step(
              "end-#{wallet}",
              fleet.shards_address,
              Call.encode("end(uint256[],address)", [[token_id], wallet])
            ),
            Review.step(
              "renew-#{wallet}",
              fleet.shards_address,
              issue([token_id], wallet, @renew_days)
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
         Review.step("on", fleet.shards_address, agent_voting(keys, true)),
         Review.step("off", fleet.shards_address, agent_voting(keys, false))
       ], %{keys: keys, voting: voting, blocked: blocked}}
    end
  end

  @doc "How long a purchase step stays good after it is built, in seconds."
  def purchase_seconds, do: @purchase_seconds

  # The key on offer at the price the page shows. The wallet approves exactly
  # that price when its USDC allowance to the fleet is below it; the purchase
  # names the price as its most, so a key that has since cost more is refused
  # and no USDC is taken.
  defp buy(%{fleet: fleet, signer: signer}, progress) do
    price = progress.next_price
    figures = %{token_id: progress.next_token_id, price: price, max_supply: progress.max_supply}

    with {:ok, reads} <- Reads.at_head(),
         {:ok, allowance} <-
           Reads.one(
             reads,
             fleet.usdc_address,
             "allowance(address,address)",
             [signer, fleet.contract_address],
             {:uint, 256}
           ) do
      deadline = DateTime.to_unix(Reads.now(reads)) + @purchase_seconds
      approve? = allowance < price

      approve =
        Review.step(
          "approve",
          fleet.usdc_address,
          Call.encode("approve(address,uint256)", [fleet.contract_address, price])
        )

      buy =
        Review.step(
          "buy",
          fleet.contract_address,
          Call.encode("purchase(address,uint256,uint256)", [signer, price, deadline])
        )

      {:ok, if(approve?, do: [approve, buy], else: [buy]), Map.put(figures, :approve?, approve?)}
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
             [asset, token_id],
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
      |> Map.get(asset, %{symbol: nil, decimals: nil, usdc?: false})
      |> Map.take([:symbol, :decimals, :usdc?])
      |> Map.merge(entry)
    end)
  end

  # The key with when its presence lapses, nil when it isn't present.
  defp present_until(reads, fleet, key) do
    with {:ok, [_prev, _next, expires_at]} <-
           Reads.many(reads, fleet.votes_address, "presenceEntry(uint256)", [key], [
             {:uint, 32},
             {:uint, 32},
             {:uint, 64}
           ]) do
      until = DateTime.from_unix!(expires_at)
      {:ok, %{token_id: key, until: if(DateTime.after?(until, Reads.now(reads)), do: until)}}
    end
  end

  # Whether the oldest presence in the queue has lapsed: a proposal clears up
  # to 256 itself and is refused while more are left.
  defp maintenance?(reads, fleet) do
    with {:ok, [first, _last, _queued]} <-
           Reads.many(reads, fleet.votes_address, "presenceQueue()", [], [
             {:uint, 32},
             {:uint, 32},
             {:uint, 32}
           ]),
         do: lapsed?(reads, fleet, first)
  end

  defp lapsed?(_reads, _fleet, 0), do: {:ok, false}

  defp lapsed?(reads, fleet, key) do
    with {:ok, %{until: until}} <- present_until(reads, fleet, key), do: {:ok, is_nil(until)}
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
           &Reads.one(reads, fleet.shards_address, "agentVoting(uint256)", [&1], :bool)
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

  defp issue(keys, wallet, days),
    do: Call.encode("issue(uint256[],address,uint16)", [keys, wallet, days])

  defp agent_voting(keys, on), do: Call.encode("setAgentVoting(uint256[],bool)", [keys, on])
end
