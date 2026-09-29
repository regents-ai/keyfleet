defmodule KeyfleetWeb.WalletWords do
  @moduledoc """
  What Keyfleet's wallet buttons say: the line above each group of buttons,
  naming what a press sends or why it can't be sent as typed, and each sent
  step's title and outcome. `KeyfleetWeb.OnchainSteps` words the presses that
  sent nothing and the steps still on their way.
  """

  alias Keyfleet.Fleets.Rules
  alias KeyfleetWeb.FleetLive
  alias KeyfleetWeb.ProposalsPage

  @address_words "Copy it again in full: 0x and 40 more letters and numbers."

  @doc """
  The line above a group's buttons for what was built, `%{figures: figures,
  problem: problem}`, and the form's `inputs`; nil when there is nothing to
  say.
  """
  def line(_flow, nil, _inputs), do: nil

  def line(:delegate, %{problem: :delegate_unreadable}, %{"delegate" => typed}) do
    if String.trim(typed) == "",
      do: "Type the wallet that may vote for you, or stop any other wallet voting for you.",
      else: "The wallet to vote for you isn’t a valid address. #{@address_words}"
  end

  def line(:issue_shard, %{problem: :shard_wallet_unreadable}, %{"wallet" => typed}) do
    if String.trim(typed) == "",
      do: "Type the wallet to issue a shard to.",
      else: "The wallet isn’t a valid address. #{@address_words}"
  end

  def line(_flow, %{problem: problem}, _inputs) when problem != nil, do: problem(problem)
  def line(flow, %{figures: figures}, _inputs), do: says(flow, figures)

  defp says(:buy, %{token_id: token_id, price: price, approve?: true}),
    do:
      "Key #{Rules.grouped(token_id)} costs #{FleetLive.usdc(price)}. First approve " <>
        "#{FleetLive.usdc(price)} for the fleet, then buy it."

  defp says(:buy, %{token_id: token_id, price: price, approve?: false}),
    do: "Key #{Rules.grouped(token_id)} costs #{FleetLive.usdc(price)}, paid from your wallet."

  defp says(:claim, %{waiting: waiting}),
    do:
      "Waiting for this key: " <>
        (waiting |> Enum.reject(&(&1.amount == 0)) |> Enum.map_join(", ", &token_amount/1)) <>
        ". Each token is claimed with its own button."

  defp says(:vote, %{keys: keys}),
    do: "Voting, changing or withdrawing uses #{key_words(keys)}. Each key is one vote."

  defp says(:collect, %{keys: keys}), do: "Collects the match of #{key_words(keys)}."

  defp says(:propose_decision, %{key: key}),
    do: "Proposes this decision with key #{Rules.grouped(key)}."

  defp says(:propose_payment, %{key: key, asset: asset, amount: amount, recipient: recipient}) do
    paid = asset |> Map.delete(:address) |> Map.merge(%{asset: asset.address, amount: amount})

    "Proposes paying #{token_amount(paid)} to " <>
      "#{RegentFormat.short_address(recipient)}, with key #{Rules.grouped(key)}."
  end

  defp says(:propose_edits, %{key: key, target: target, restricted: true}),
    do:
      "Proposes stopping key #{Rules.grouped(target)} and its shards changing the workspace, " <>
        "with key #{Rules.grouped(key)}. Needs 3 of every 5 keys sold."

  defp says(:propose_edits, %{key: key, target: target, restricted: false}),
    do:
      "Proposes letting key #{Rules.grouped(target)} and its shards change the workspace " <>
        "again, with key #{Rules.grouped(key)}. Needs 3 of every 5 keys sold."

  defp says(:issue_shard, %{token_id: token_id, wallet: wallet, days: days}),
    do:
      "Issues #{RegentFormat.short_address(wallet)} a shard of key #{Rules.grouped(token_id)} " <>
        "for #{days(days)}. Issuing again to a wallet with a shard renews it."

  defp says(:delegate, %{delegate: delegate}),
    do:
      "Lets #{RegentFormat.short_address(delegate)} vote and propose with every key you hold, " <>
        "or stops any other wallet voting for you."

  defp says(_flow, _figures), do: nil

  defp problem(:no_keys), do: "Type the numbers of the keys to use, like 3, 7, 12."
  defp problem(:keys_unreadable), do: "Key numbers are whole numbers, like 3, 7, 12."
  defp problem(:key_too_large), do: "That key number is larger than any key number can be."
  defp problem(:no_key), do: "Name the key you’re proposing with, like 12."
  defp problem(:no_target), do: "Name the key whose edits this is about, like 12."
  defp problem(:target_unreadable), do: "Name the key whose edits this is about, like 12."
  defp problem(:days_unreadable), do: "A shard lasts from 1 to 365 whole days."
  defp problem(:key_unreadable), do: "Name the key you’re proposing with, like 12."

  defp problem(:amount_commas),
    do: "Use a point for decimals, like 12.5. Commas can only group thousands, like 1,250."

  defp problem(:amount_unreadable), do: "Write the amount as a number, like 12.5."
  defp problem({:too_many_decimals, 0}), do: "This token is counted in whole units only."

  defp problem({:too_many_decimals, decimals}),
    do: "This token has at most #{decimals} decimal places."

  defp problem(:amount_too_large), do: "That amount is too large."

  defp problem(:recipient_unreadable),
    do: "The wallet to pay isn’t a valid address. #{@address_words}"

  defp problem(:asset_unreadable), do: "The token isn’t a valid address. #{@address_words}"

  defp problem(:document_code),
    do: "A document code is 64 characters, 0 to 9 and a to f. Leave it empty if there isn’t one."

  defp problem(:unread),
    do: "Ethereum can’t be read right now. This tries again in a few seconds."

  defp problem(:nothing_waiting), do: "Nothing is waiting for this key right now."
  defp problem(:sold_out), do: "Every key in this fleet has been sold."

  defp problem(:reveal_requested),
    do:
      "The request for this key’s random draw was accepted. The draw is on its way, and " <>
        "the key’s traits show here when it arrives."

  defp problem(:revealed), do: "This key’s traits have been drawn. They show here in a moment."

  @doc "A sent step's title, from the review it was sent from."
  def title(%{name: "approve"}), do: "Approve USDC"
  def title(%{name: "buy"}), do: "Buy key"
  def title(%{name: "yes"} = entry), do: "Vote yes#{with_keys(entry)}"
  def title(%{name: "no"} = entry), do: "Vote no#{with_keys(entry)}"
  def title(%{name: "withdraw"} = entry), do: "Withdraw the votes#{with_keys(entry)}"
  def title(%{name: "carry_out"}), do: "Carry it out"
  def title(%{name: "collect"} = entry), do: "Collect#{with_keys(entry)}"
  def title(%{name: "propose"}), do: "Propose"
  def title(%{name: "delegate"}), do: "Let a wallet vote for you"
  def title(%{name: "clear"}), do: "Stop any wallet voting for you"
  def title(%{name: "send"}), do: "Send Regents its share"
  def title(%{name: "claim-" <> _asset}), do: "Claim"
  def title(%{name: "reveal"}), do: "Ask again for the draw"
  def title(%{name: "issue"}), do: "Issue a shard"
  def title(%{name: "end-" <> _wallet}), do: "End a shard"
  def title(%{name: "renew-" <> _wallet}), do: "Renew a shard"
  def title(_unknown), do: "Transaction"

  defp with_keys(%{review: %{inputs: %{"keys" => keys}}}) do
    case String.split(keys, ~r/[\s,]+/, trim: true) do
      [] -> ""
      [key] -> ", key #{key}"
      keys -> ", keys #{Enum.join(keys, ", ")}"
    end
  end

  defp with_keys(_entry), do: ""

  @doc """
  What a sent step shows: `shown`, as `KeyfleetWeb.OnchainSteps.describe/2`
  gives it, with this step's own words once it has landed.
  """
  def outcome(entry, %{state: :confirmed} = shown), do: %{shown | words: confirmed(entry.name)}
  def outcome(entry, %{state: :reverted} = shown), do: %{shown | words: reverted(entry.name)}
  def outcome(_entry, shown), do: shown

  defp confirmed("approve"), do: "Approved. Now press Buy key."
  defp confirmed("buy"), do: "Done. The key is yours, and this page shows it in a few seconds."

  defp confirmed(vote) when vote in ["yes", "no"],
    do: "Done. The count here catches up in a few seconds."

  defp confirmed("withdraw"), do: "Done. Those keys have no vote on this proposal now."

  defp confirmed("carry_out"),
    do: "Done. It has been carried out, and this page shows it in a few seconds."

  defp confirmed("collect"), do: "Done. Each key’s match was paid to whoever holds it."

  defp confirmed("propose"),
    do: "Done. Your proposal joins the list in a few seconds, and it is open to votes."

  defp confirmed("delegate"), do: "Done. That wallet can now vote and propose with your keys."
  defp confirmed("clear"), do: "Done. No other wallet can vote your keys now."
  defp confirmed("send"), do: "Done. Regents’ share has been sent to Regents."
  defp confirmed("claim-" <> _asset), do: "Done. It was paid to your wallet."

  defp confirmed("reveal"),
    do:
      "Sent. If the draw was accepted this time, the key’s traits show here once it " <>
        "arrives; if it was turned down again, Try again is back."

  defp confirmed("issue"),
    do: "Done. The shard is issued, and this page shows it in a few seconds."

  defp confirmed("end-" <> _wallet),
    do: "Done. The shard has ended, and this page shows it in a few seconds."

  defp confirmed("renew-" <> _wallet),
    do: "Done. The shard is renewed, and this page shows it in a few seconds."

  defp confirmed(_step), do: "Done."

  defp reverted("approve"), do: "The approval didn’t go through and nothing moved."

  defp reverted("buy"),
    do:
      "The purchase didn’t go through and no USDC was taken. The key may have sold or its " <>
        "price risen, the time to buy may have run out, or the wallet may not hold or have " <>
        "approved enough USDC. The figures above are read again now."

  defp reverted(vote) when vote in ["yes", "no"],
    do:
      "This vote didn’t go through and nothing changed. A key may already have this vote, " <>
        "may have changed hands after the proposal opened, or may be neither yours nor held " <>
        "by someone who let your wallet vote for them; or the proposal was already carried out."

  defp reverted("withdraw"),
    do:
      "Nothing was withdrawn. A key may have no vote on this proposal, may be neither yours " <>
        "nor held by someone who let your wallet vote for them, or the proposal was already " <>
        "carried out."

  defp reverted("carry_out"),
    do:
      "This wasn’t carried out and nothing moved. Yes votes may not be enough yet (more " <>
        "than half of all the keys sold, or 3 of every 5 for a change to a key’s workspace " <>
        "edits), it may already have been carried out, or a payment and its matches may not " <>
        "fit in the shared money."

  defp reverted("collect"),
    do:
      "Nothing was collected. A key may have voted yes, may already have collected, or may " <>
        "have been sold after the payment was made."

  defp reverted("propose"),
    do:
      "The proposal wasn’t made. The key may be neither yours nor held by someone who let " <>
        "your wallet vote for them, or a key it is about may not have been sold yet."

  defp reverted(delegate) when delegate in ["delegate", "clear"],
    do: "This didn’t go through and nothing changed."

  defp reverted("send"),
    do: "Nothing was sent. Nothing may be set aside for Regents right now."

  defp reverted("claim-" <> _asset),
    do:
      "Nothing was claimed. The key may not be held by the wallet that sent this, or nothing " <>
        "is waiting for it any more."

  defp reverted("reveal"),
    do: "Nothing was asked. The key’s draw may already be on its way, or its traits drawn."

  defp reverted("issue"),
    do:
      "No shard was issued. The key may not be held by the wallet that sent this, the wallet " <>
        "may be the key’s own, or it may already hold a shard of another key in this fleet."

  defp reverted("end-" <> _wallet),
    do: "The shard didn’t end. It may have ended already, or the key may have changed hands."

  defp reverted("renew-" <> _wallet),
    do:
      "The shard wasn’t renewed. The key may not be held by the wallet that sent this, or the " <>
        "shard may have ended."

  defp reverted(_step), do: "This did not go through and nothing moved."

  @doc """
  An amount of a token: the fleet's USDC by name, another token in its own
  units with its symbol and address, or in its smallest units when it hasn't
  said its decimals.
  """
  def token_amount(%{amount: amount, usdc?: true}), do: FleetLive.usdc(amount)

  def token_amount(%{amount: amount, asset: asset, symbol: symbol, decimals: decimals})
      when is_binary(symbol) and is_integer(decimals),
      do:
        "#{ProposalsPage.units(amount, decimals)} #{symbol} (#{RegentFormat.short_address(asset)})"

  def token_amount(%{amount: amount, asset: asset}),
    do:
      "#{Rules.grouped(amount)} in the smallest units of token #{RegentFormat.short_address(asset)}"

  defp days(1), do: "1 day"
  defp days(days), do: "#{days} days"

  defp key_words([key]), do: "key #{Rules.grouped(key)}"
  defp key_words(keys), do: "keys #{Enum.map_join(keys, ", ", &Rules.grouped/1)}"
end
