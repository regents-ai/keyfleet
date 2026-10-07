defmodule Keyfleet.WalletSteps.MoneySteps do
  @moduledoc """
  The steps of a fleet's money that anyone may press: running the daily
  split, returning an advance, and sending the protocol share owed to REGENT
  staking. `Keyfleet.WalletSteps.Build` describes what every builder answers.

  The daily split's figures are its preview, read at the latest block the
  way the treasury works it out: for each asset it splits, the balance, the
  least it splits from, and what each key would get now.
  """

  alias Keyfleet.Treasury
  alias Keyfleet.WalletSteps.{Build, Reads, Typed}
  alias RegentChain.{Call, Review}

  # The least ETH the treasury splits from, as the treasury fixes it.
  @eth_threshold 50_000_000_000_000_000

  @doc false
  def steps(:run_split, %{fleet: fleet}) do
    treasury = fleet.treasury_address
    uint = &Reads.one(&1, treasury, &2, [], {:uint, 256})

    with {:ok, reads} <- Reads.at_head(),
         {:ok, assets} <- Reads.one(reads, treasury, "splitAssets()", [], {:array, :address}),
         {:ok, bps} <- uint.(reads, "dailySplitBps()"),
         {:ok, last_run_at} <- uint.(reads, "lastRunAt()"),
         {:ok, next_run_at} <- uint.(reads, "nextRunAt()"),
         {:ok, keys} <-
           Reads.one(reads, fleet.contract_address, "totalMinted()", [], {:uint, 256}),
         {:ok, preview} <- Reads.each(assets, &preview(reads, fleet, &1, bps, keys)) do
      opens_at = if next_run_at > 0, do: DateTime.from_unix!(next_run_at)

      blocked =
        cond do
          opens_at == nil -> %{"run_split" => :no_keys_sold}
          DateTime.before?(Reads.now(reads), opens_at) -> %{"run_split" => {:opens_at, opens_at}}
          true -> %{}
        end

      {:ok, [Review.step("run_split", treasury, Call.encode("runDailySplit()", []))],
       %{
         assets: named(fleet, preview),
         rate_bps: bps,
         keys: keys,
         last_run_at: if(last_run_at > 0, do: DateTime.from_unix!(last_run_at)),
         opens_at: opens_at,
         blocked: blocked
       }}
    else
      # No preview: the page says the network can't be reached.
      _unread -> {:problem, :unread, %{blocked: %{}}}
    end
  end

  # Part or all of one advance, back to the treasury from whoever presses.
  # ETH goes with the call; a token is approved to the treasury first, as a
  # step of its own.
  def steps(:return_advance, %{fleet: fleet, signer: signer, advance_id: id, inputs: inputs}) do
    figures = %{advance_id: id}

    with {:ok, reads} <- reads(figures),
         {:ok, [operator, asset, outstanding, _purpose]} <- advance(reads, fleet, id, figures),
         asset = named_asset(fleet, asset),
         figures =
           Map.merge(figures, %{operator: operator, asset: asset, outstanding: outstanding}),
         {:ok, amount} <-
           Build.typed(
             inputs,
             "amount",
             &Typed.amount(&1, asset.decimals || 0, Typed.largest_uint256()),
             figures
           ),
         figures = Map.put(figures, :amount, amount),
         {:ok, held, allowance} <- standing(reads, fleet, signer, asset, figures) do
      native? = asset.address == Treasury.native()

      give_back =
        Review.step(
          "return",
          fleet.treasury_address,
          Call.encode("returnAdvance(uint256,uint256)", [id, amount]),
          if(native?, do: amount, else: 0)
        )

      {:ok, if(native?, do: [give_back], else: [approve(fleet, asset, amount), give_back]),
       Map.put(figures, :blocked, return_blocked(outstanding, amount, held, allowance))}
    end
  end

  # The protocol share the fleet owes REGENT staking, which anyone may send.
  def steps(:send_share, %{fleet: fleet}) do
    figures = %{owed: nil}

    with {:ok, reads} <- Reads.at_head(),
         {:ok, owed} <-
           Reads.one(reads, fleet.contract_address, "protocolShareOwed()", [], {:uint, 256}) do
      {:ok,
       [
         Review.step("send_share", fleet.contract_address, Call.encode("sendProtocolShare()", []))
       ], %{owed: owed, blocked: if(owed == 0, do: %{"send_share" => :nothing_owed}, else: %{})}}
    else
      _unread -> {:problem, :unread, figures}
    end
  end

  defp approve(fleet, asset, amount),
    do:
      Review.step(
        "approve",
        asset.address,
        Call.encode("approve(address,uint256)", [fleet.treasury_address, amount])
      )

  # Why returning `amount` is certain to fail now, if it is. ETH goes with
  # the call, so its allowance is never needed and reads as all of it.
  defp return_blocked(outstanding, amount, held, allowance) do
    cond do
      outstanding == 0 -> %{"return" => :advance_returned}
      amount > outstanding -> %{"return" => :above_outstanding}
      held < amount -> %{"return" => :not_enough}
      allowance < amount -> %{"return" => :approve_first}
      true -> %{}
    end
  end

  # One asset as the treasury would split it now: its balance, the least it
  # splits from (0.05 ETH, or 100 of a token), and each key's part, nothing
  # under the least.
  defp preview(reads, fleet, asset, bps, keys) do
    with {:ok, balance} <- held(reads, asset, fleet.treasury_address),
         {:ok, threshold} <- threshold(reads, asset) do
      per_key =
        if keys == 0 or balance < threshold, do: 0, else: div(div(balance * bps, 10_000), keys)

      {:ok, %{asset: asset, balance: balance, threshold: threshold, per_key: per_key}}
    end
  end

  defp threshold(reads, asset) do
    if asset == Treasury.native() do
      {:ok, @eth_threshold}
    else
      with {:ok, decimals} <- Reads.one(reads, asset, "decimals()", [], {:uint, 8}),
           do: {:ok, 100 * 10 ** decimals}
    end
  end

  defp held(reads, asset, account) do
    if asset == Treasury.native(),
      do: Reads.balance(reads, account),
      else: Reads.one(reads, asset, "balanceOf(address)", [account], {:uint, 256})
  end

  defp reads(figures) do
    case Reads.at_head() do
      {:ok, reads} -> {:ok, reads}
      {:error, _reason} -> {:problem, :unread, figures}
    end
  end

  # An advance the treasury never made has no operator.
  defp advance(reads, fleet, id, figures) do
    types = [:address, :address, {:uint, 256}, :bytes32]

    case Reads.many(reads, fleet.treasury_address, "advances(uint256)", [id], types) do
      {:ok, [operator | _rest] = advance} ->
        if operator == Treasury.native(),
          do: {:problem, :advance_unknown, figures},
          else: {:ok, advance}

      {:error, _reason} ->
        {:problem, :unread, figures}
    end
  end

  # What the signer holds of the asset, and has let the treasury take of it.
  defp standing(reads, fleet, signer, asset, figures) do
    with {:ok, held} <- held(reads, asset.address, signer),
         {:ok, allowance} <- allowance(reads, fleet, signer, asset.address) do
      {:ok, held, allowance}
    else
      _unread -> {:problem, :unread, figures}
    end
  end

  defp allowance(reads, fleet, signer, asset) do
    if asset == Treasury.native(),
      do: {:ok, Typed.largest_uint256()},
      else:
        Reads.one(
          reads,
          asset,
          "allowance(address,address)",
          [signer, fleet.treasury_address],
          {:uint, 256}
        )
  end

  defp named(fleet, preview), do: Enum.map(preview, &Map.merge(named_asset(fleet, &1.asset), &1))

  defp named_asset(fleet, asset) do
    Enum.find(
      Treasury.payable_assets(fleet),
      %{address: asset, symbol: nil, decimals: nil, usdc?: false, known?: false},
      &(&1.address == asset)
    )
  end
end
