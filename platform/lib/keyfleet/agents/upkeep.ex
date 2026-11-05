defmodule Keyfleet.Agents.Upkeep do
  @moduledoc """
  What an agent's scheduled run needs from one fleet, worked out from the chain
  reader's records and never from anything the agent says about itself: when
  each Key it can mark stops being present, the proposals its person's Keys or
  its own haven't decided, and how many marks its wallet's ETH would pay for.

  `setup/4` reads the same figures as the five states an agent's setup ends in.
  """

  alias Keyfleet.Actors.Human
  alias Keyfleet.Agents
  alias Keyfleet.Agents.CheckInStatus
  alias Keyfleet.Keys
  alias Keyfleet.Proposals
  alias Keyfleet.WalletSteps.Reads

  # `KeyfleetPresence.WINDOW`.
  @window_seconds 172_800
  # More than a day, so a daily run that comes a little early still marks and
  # the next one never arrives after the Key's 48 hours end.
  @due_within_seconds 30 * 3600
  # What marking costs at most for each Key, and the tip a wallet adds.
  @gas_per_key 60_000
  @tip_wei 1_000_000

  @doc """
  `%{presence: %{marking_due, keys}, proposals_awaiting: [...], gas: gas}` for
  `actor` in the fleet. `read_gas?` says whether to ask the chain for the
  wallet's ETH; `gas` is nil when it wasn't asked, when the agent has no Key
  to mark, or when the chain doesn't answer.
  """
  def read(actor, fleet_id, read_gas?) do
    now = DateTime.utc_now()
    keys = Keys.held_keys(actor, fleet_id)
    markable = for %{for_person: false, token_id: token_id} <- keys, do: token_id

    %{
      presence: presence(fleet_id, markable, now),
      proposals_awaiting: awaiting(fleet_id, Enum.map(keys, & &1.token_id), now),
      gas: if(read_gas? and markable != [], do: gas(actor.wallet_address, length(markable)))
    }
  end

  @doc """
  The five states of an agent's setup, read from `upkeep` (`read/3`, with its
  gas), and the one thing to do next, nil once all five are true.
  """
  def setup(actor, fleet_id, profile, upkeep) do
    now = DateTime.utc_now()
    check_in = profile && Agents.get_check_in!(profile.id, fleet_id)
    keys = upkeep.presence.keys

    states = %{
      paired: match?(%Human{}, actor.pairing),
      gas: can_pay?(actor, keys, upkeep.gas),
      schedule: check_in != nil and check_in.schedule_minutes != nil,
      marked: keys != [] and Enum.all?(keys, &present?(&1, now)),
      repeated: CheckInStatus.repeating?(check_in, now)
    }

    Map.put(states, :next_step, next_step(states, keys))
  end

  # With no Key to mark there is nothing to pay for yet. A plain wallet pays with
  # its own ETH; nil when the chain didn't say how much. A smart wallet may have
  # its fee paid for it, as `Reads.short_of_gas?/2` holds.
  defp can_pay?(_actor, [], _gas), do: nil
  defp can_pay?(%{verification_method: :eoa_recovery}, _keys, nil), do: nil
  defp can_pay?(%{verification_method: :eoa_recovery}, _keys, %{marks_left: left}), do: left > 0
  defp can_pay?(_smart_wallet, _keys, _gas), do: true

  defp next_step(%{paired: false}, _keys), do: "Ask your person for a pairing code."

  defp next_step(_states, []),
    do: "Ask your person for a shard of their Key, or to mark it present themselves."

  defp next_step(%{gas: nil}, _keys), do: "The chain didn't answer. Read this again in a minute."
  defp next_step(%{gas: false}, _keys), do: "Ask your person to send your wallet ETH on Base."

  defp next_step(%{schedule: false}, _keys),
    do: "Schedule your daily run, then start it once now."

  defp next_step(%{marked: false}, _keys), do: "Mark your Keys present."
  defp next_step(%{repeated: false}, _keys), do: "Check again after your next scheduled run."
  defp next_step(_states, _keys), do: nil

  defp present?(%{present_until: nil}, _now), do: false
  defp present?(%{present_until: until}, now), do: DateTime.after?(until, now)

  defp presence(fleet_id, token_ids, now) do
    last = Keys.last_presence(fleet_id, token_ids)

    keys =
      Enum.map(token_ids, &%{token_id: &1, present_until: present_until(Map.get(last, &1))})

    %{marking_due: Enum.any?(keys, &due?(&1, now)), keys: keys}
  end

  defp present_until(%{kind: kind, at: at}) when kind in [:present, :scheduled],
    do: DateTime.add(at, @window_seconds)

  defp present_until(_cleared_or_none), do: nil

  defp due?(%{present_until: nil}, _now), do: true

  defp due?(%{present_until: until}, now),
    do: DateTime.diff(until, now) <= @due_within_seconds

  defp awaiting(_fleet_id, [], _now), do: []

  defp awaiting(fleet_id, token_ids, now) do
    for proposal <- Proposals.votable(fleet_id, now),
        undecided = token_ids -- Enum.flat_map(proposal.votes, & &1.token_ids),
        undecided != [] do
      counted = proposal.opening_count + proposal.late_keys

      %{
        number: proposal.number,
        status: Proposals.status(proposal, now),
        closes_at: proposal.closes_at,
        moves_money: Proposals.waits?(proposal),
        counted: counted,
        needed: Proposals.approvals_needed(counted),
        yes_votes: proposal.yes_keys,
        no_votes: proposal.no_keys,
        undecided: undecided,
        counted_at_opening: counted_at_opening(fleet_id, undecided, proposal)
      }
    end
  end

  # The Keys the contract counted when the proposal opened: each one's last
  # record before it is a renewal or an automatic start whose 48 hours were
  # running (`Keyfleet.Proposals.Calculations.LateKeys`).
  defp counted_at_opening(fleet_id, token_ids, proposal) do
    last = Keys.last_presence(fleet_id, token_ids, {proposal.block_number, proposal.log_index})

    Enum.filter(token_ids, fn token_id ->
      case Map.get(last, token_id) do
        %{kind: kind, at: at} when kind in [:present, :scheduled] ->
          DateTime.compare(at, proposal.opened_at) != :gt and
            DateTime.diff(proposal.opened_at, at) < @window_seconds

        _cleared_or_none ->
          false
      end
    end)
  end

  defp gas(wallet, key_count) do
    with {:ok, %Reads{head: head} = reads} <- Reads.at_head(),
         {:ok, wei} <- Reads.balance(reads, wallet) do
      cost = key_count * @gas_per_key * (2 * head.base_fee + @tip_wei)
      %{wei: Integer.to_string(wei), marks_left: div(wei, cost)}
    else
      {:error, _reason} -> nil
    end
  end
end
