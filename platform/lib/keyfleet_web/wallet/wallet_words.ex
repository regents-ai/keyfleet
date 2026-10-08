defmodule KeyfleetWeb.WalletWords do
  @moduledoc """
  What Keyfleet's wallet buttons say, in a few words each: the line above a
  group of buttons, naming what a press sends or why it can't be sent as
  typed; the reason beside a button the chain's own state makes certain to
  fail; and each sent step's title and outcome. `KeyfleetWeb.OnchainSteps`
  words the presses that sent nothing and the steps still on their way.
  """

  alias Keyfleet.Fleets.Rules
  alias KeyfleetWeb.FleetLive
  alias KeyfleetWeb.ProposalsPage

  @address_words "Paste the full address: 0x and 40 letters and numbers."

  @doc """
  The line above a group's buttons for what was built, `%{figures: figures,
  problem: problem}`, and the form's `inputs`; nil when there is nothing to
  say.
  """
  def line(_flow, nil, _inputs), do: nil

  def line(:issue_shard, %{problem: :shard_wallet_unreadable}, %{"wallet" => typed}) do
    if String.trim(typed) == "",
      do: "Paste the agent’s wallet.",
      else: "That wallet isn’t a full address. #{@address_words}"
  end

  def line(_flow, %{problem: problem}, _inputs) when problem != nil, do: problem(problem)
  def line(flow, %{figures: figures}, _inputs), do: says(flow, figures)

  # The same words whether or not Approve is showing: the numbered buttons
  # carry the order, so the line never changes length under a press.
  defp says(:buy, %{token_id: token_id, price: price}),
    do: "Key #{Rules.grouped(token_id)}: #{FleetLive.usdc(price)}."

  defp says(:ballot, %{keys: [_key | _more] = keys}), do: "With #{key_words(keys)}."

  defp says(:propose, %{action: action, closes_at: closes_at}),
    do: "#{action(action)} Voting closes #{at(closes_at)}."

  defp says(:issue_shard, %{keys: keys, wallet: wallet, days: days}),
    do: "#{key_words(keys)} to #{RegentFormat.short_address(wallet)}, #{days(days)}."

  defp says(:agent_voting, %{keys: keys}), do: "For #{key_words(keys)}."

  defp says(:send_share, %{owed: owed}) when is_integer(owed) and owed > 0,
    do: "Owed: #{FleetLive.usdc(owed)}."

  defp says(_flow, _figures), do: nil

  # What carrying out a proposal does, in one short sentence.
  defp action(:decision), do: "A decision; nothing moves."

  defp action({:pay, asset, to, share, amount}),
    do: "Pays #{share_words(asset, share, amount)} to #{RegentFormat.short_address(to)}."

  defp action({:advance, _id, asset, operator, share, amount}),
    do: "Advances #{share_words(asset, share, amount)} to #{RegentFormat.short_address(operator)}."

  defp action({:rate, bps}), do: "Sets the daily split to #{ProposalsPage.units(bps, 2)}%."

  defp action({:edits, target, true}), do: "Restricts Key #{Rules.grouped(target)}’s edits."
  defp action({:edits, target, false}), do: "Allows Key #{Rules.grouped(target)}’s edits."
  defp action({:signature, :approve, _hash}), do: "Signs the message for the fleet."
  defp action({:signature, :revoke, _hash}), do: "Withdraws the fleet’s signature."
  defp action({:launch, %{symbol: symbol}}), do: "Launches #{symbol} through Autolaunch."

  defp share_words(asset, share, amount),
    do:
      "#{ProposalsPage.units(share, 4)}% of the treasury’s #{asset_name(asset)} " <>
        "(about #{token_amount(asset_amount(asset, rough(amount, asset.decimals)))} today)"

  # An amount cut to two decimals from one whole token up, and to six below.
  defp rough(amount, nil), do: amount

  defp rough(amount, decimals) do
    shown = if amount >= Integer.pow(10, decimals), do: 2, else: 6
    step = Integer.pow(10, max(decimals - shown, 0))
    amount - rem(amount, step)
  end

  defp asset_name(%{symbol: symbol}) when is_binary(symbol), do: symbol
  defp asset_name(%{address: address}), do: "token #{RegentFormat.short_address(address)}"

  defp asset_amount(asset, amount),
    do:
      asset
      |> Map.take([:symbol, :decimals, :usdc?, :known?])
      |> Map.merge(%{asset: asset.address, amount: amount})

  defp problem(:no_keys), do: "Type Key numbers, like 3, 7, 12."
  defp problem(:keys_unreadable), do: "Key numbers are whole numbers, like 3, 7, 12."
  defp problem(:key_too_large), do: "No Key has that number."
  defp problem(:no_key), do: "Type the Key you’re proposing with."
  defp problem(:key_unreadable), do: "A Key is a whole number, like 12."
  defp problem(:no_target), do: "Type the Key this is about."
  defp problem(:target_unreadable), do: "A Key is a whole number, like 12."
  defp problem(:days_unreadable), do: "From 1 to 365 days."
  defp problem(:share_unreadable), do: "From 0.0001% to 99%."
  defp problem(:rate_unreadable), do: "From 0.1% to 2%."
  defp problem(:hash_unreadable), do: "The message code is 0x and 64 letters and numbers."
  defp problem(:kind_unknown), do: "Choose what to propose."
  defp problem({:missing, name}), do: "#{field_name(name)} is empty."

  defp problem({:too_long, name, bytes}),
    do: "#{field_name(name)} is too long: #{bytes} characters at most."

  defp problem(:amount_commas), do: "Use a point for decimals, like 12.5."
  defp problem(:amount_unreadable), do: "Type the amount as a number, like 12.5."
  defp problem({:too_many_decimals, 0}), do: "Whole units only."
  defp problem({:too_many_decimals, decimals}), do: "At most #{decimals} decimal places."
  defp problem(:amount_too_large), do: "That amount is too large."
  defp problem(:recipient_unreadable), do: "That wallet isn’t a full address. #{@address_words}"
  defp problem(:asset_unreadable), do: "Choose a token."
  defp problem(:advance_unknown), do: "No advance has this number."
  defp problem(:not_recorded), do: "This proposal isn’t on this page yet."
  defp problem(:no_launch), do: "No launch yet."
  defp problem(:unread), do: "Can’t reach the network right now. Trying again."
  defp problem(:sold_out), do: "Sold out."

  defp field_name(:text), do: "The proposal"
  defp field_name(:name), do: "The name"
  defp field_name(:symbol), do: "The symbol"
  defp field_name(:description), do: "The description"
  defp field_name(:website), do: "The website"
  defp field_name(:image), do: "The image link"

  @doc "Why a button can't be pressed now, in a few words."
  def blocked(:no_eth_for_gas), do: "Not enough ETH for the network fee"
  def blocked(:not_your_key), do: "Not your Key"
  def blocked(:no_keys), do: "No Keys to use"
  def blocked(:nothing_to_claim), do: "Nothing to claim"
  def blocked(:own_wallet), do: "That’s your wallet"
  def blocked(:shard_ended), do: "Already ended"
  def blocked(:revealed), do: "Traits drawn"
  def blocked(:reveal_requested), do: "Draw on its way"
  def blocked(:voting_closed), do: "Voting closed"
  def blocked(:open), do: "Voting still open"
  def blocked(:rejected), do: "Not approved"
  def blocked(:executed), do: "Already carried out"
  def blocked(:cancelled), do: "Cancelled"
  def blocked(:execution_expired), do: "Expired"
  def blocked(:no_keys_sold), do: "No Keys sold yet"
  def blocked({:opens_at, opens_at}), do: "Opens #{at(opens_at)}"
  def blocked({:carry_out_from, from}), do: "From #{at(from)}"
  def blocked(:advance_returned), do: "Fully returned"
  def blocked(:above_outstanding), do: "More than is owed"
  def blocked(:not_enough), do: "Not enough in your wallet"
  def blocked(:approve_first), do: "Approve first"
  def blocked(:approve_usdc_first), do: "Approve USDC first"
  def blocked(:sales_not_open), do: "Sales aren’t open yet"
  def blocked(:too_new), do: "Too new: Keys wait 2 days"
  def blocked(:nothing_owed), do: "Nothing owed"
  def blocked(:launch_settled), do: "Already settled"
  def blocked(:sale_running), do: "Sale still running"
  def blocked(:bound), do: "Already added"
  def blocked(:not_sold), do: "Not settled yet"
  def blocked(:launch_failed), do: "The sale didn’t sell"

  @doc "A sent step's title, from the review it was sent from."
  def title(%{name: "approve"}), do: "Approve"
  def title(%{name: "buy"}), do: "Buy Key"
  def title(%{name: "reveal"}), do: "Ask again for the draw"
  def title(%{name: "claim-" <> _asset}), do: "Claim"
  def title(%{name: "present"}), do: "Mark present"
  def title(%{name: "sweep"}), do: "Tidy up"
  def title(%{name: "issue"}), do: "Issue a shard"
  def title(%{name: "end-" <> _wallet}), do: "End a shard"
  def title(%{name: "renew-" <> _wallet}), do: "Renew a shard"
  def title(%{name: "on"}), do: "Let shards vote"
  def title(%{name: "off"}), do: "Stop shards voting"
  def title(%{name: "yes"}), do: "Vote yes"
  def title(%{name: "no"}), do: "Vote no"
  def title(%{name: "abstain"}), do: "Abstain"
  def title(%{name: "propose"}), do: "Propose"
  def title(%{name: "cancel"}), do: "Cancel"
  def title(%{name: "carry_out"}), do: "Carry it out"
  def title(%{name: "run_split"}), do: "Run the daily split"
  def title(%{name: "return"}), do: "Return"
  def title(%{name: "send_share"}), do: "Send Regents its share"
  def title(%{name: "settle"}), do: "Settle the sale"
  def title(%{name: "bind"}), do: "Add to the daily split"
  def title(%{name: "release"}), do: "Release tokens"
  def title(%{name: "collect"}), do: "Collect pool fees"
  def title(_unknown), do: "Transaction"

  @doc """
  What a sent step shows: `shown`, as `KeyfleetWeb.OnchainSteps.describe/2`
  gives it, with this step's own words once it has landed.
  """
  def outcome(entry, %{state: :confirmed} = shown), do: %{shown | words: confirmed(entry.name)}
  def outcome(entry, %{state: :reverted} = shown), do: %{shown | words: reverted(entry.name)}
  def outcome(_entry, shown), do: shown

  defp confirmed("approve"), do: "Approved. Now press the next button."
  defp confirmed("buy"), do: "Done. The Key is yours."
  defp confirmed("claim-" <> _asset), do: "Done. Paid to the Key’s holder."
  defp confirmed("present"), do: "Done. Present for 48 hours."
  defp confirmed("propose"), do: "Done. It’s open to votes."
  defp confirmed("run_split"), do: "Done. Shared with every Key."
  defp confirmed("send_share"), do: "Done. Sent to Regents."
  defp confirmed(_step), do: "Done."

  defp reverted("approve"), do: "Not approved. Nothing moved."
  defp reverted("buy"), do: "Not bought. No USDC was taken."
  defp reverted("reveal"), do: "Nothing asked. The draw may be on its way."
  defp reverted("claim-" <> _asset), do: "Nothing claimed."
  defp reverted("present"), do: "Not marked. A Key may have changed hands."
  defp reverted("propose"), do: "Not proposed. Tidy up first, or check the Key."

  defp reverted(choice) when choice in ["yes", "no", "abstain"],
    do: "Not counted. Voting may have closed."

  defp reverted("carry_out"), do: "Not carried out. Nothing moved."
  defp reverted("run_split"), do: "Not run. It may have run already today."
  defp reverted("return"), do: "Not returned. Nothing moved."
  defp reverted(_step), do: "Didn’t go through. Nothing moved."

  @doc """
  An amount of a token: the fleet's USDC exactly, another the fleet's
  deployment names in its own units with its symbol, any other token with
  its address too, or in its smallest units when it hasn't said its
  decimals.
  """
  def token_amount(%{amount: amount, usdc?: true}), do: FleetLive.usdc(amount)

  def token_amount(%{amount: amount, known?: true, symbol: symbol, decimals: decimals}),
    do: "#{ProposalsPage.units(amount, decimals)} #{symbol}"

  def token_amount(%{amount: amount, asset: asset, symbol: symbol, decimals: decimals})
      when is_binary(symbol) and is_integer(decimals),
      do:
        "#{ProposalsPage.units(amount, decimals)} #{symbol} (#{RegentFormat.short_address(asset)})"

  def token_amount(%{amount: amount, asset: asset}),
    do: "#{Rules.grouped(amount)} units of #{RegentFormat.short_address(asset)}"

  @doc "A time as the wallet buttons say it."
  def at(datetime), do: Calendar.strftime(datetime, "%-d %b, %H:%M UTC")

  defp days(1), do: "1 day"
  defp days(days), do: "#{days} days"

  defp key_words([key]), do: "Key #{Rules.grouped(key)}"
  defp key_words(keys), do: "Keys #{Enum.map_join(keys, ", ", &Rules.grouped/1)}"
end
