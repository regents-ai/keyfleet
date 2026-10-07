defmodule KeyfleetWeb.ProposalsPage do
  @moduledoc """
  What a fleet's proposal pages show, read from the proposals and votes the
  chain reader recorded.

  `list/2` is the fleet's proposals, newest first, twenty to a page, with
  its shared money once it is on chain: the latest reading of its treasury,
  its daily split and its latest money in and out. `detail/3` is one proposal with its
  votes, fifty to a page. Once the fleet is on chain, each carries the
  network its wallet buttons send on; the buttons' steps are built by
  `Keyfleet.WalletSteps`. A page name that is not a proposal number is a
  page that doesn't exist.
  """

  alias Keyfleet.Chain
  alias Keyfleet.Fleets
  alias Keyfleet.Fleets.Rules
  alias Keyfleet.Proposals
  alias Keyfleet.Treasury
  alias KeyfleetWeb.NotFoundError

  @number ~r/\A[1-9][0-9]{0,17}\z/
  @votes_page 50

  @doc """
  The page of proposals below the one `params` names, if it names one, with
  what the forms for new proposals start from.
  """
  def list(fleet_id, params) do
    before = number!(params["before"])

    with_fleet(fleet_id, fn fleet, reading ->
      {proposals, older?} = Proposals.list_page(fleet_id, before)

      Map.merge(reading, %{
        proposals: Enum.map(proposals, &summary/1),
        first_page?: is_nil(before),
        older: if(older?, do: list_path(fleet_id, before: List.last(proposals).number)),
        treasury: reading.deployed? && treasury(fleet, Treasury.get_reading!(fleet_id)),
        propose: reading.deployed? && propose(fleet)
      })
    end)
  end

  @doc """
  Proposal `number` and a page of its votes, from the one `params` names.
  """
  def detail(fleet_id, number, params) do
    votes_after = seq!(params["votes_after"])

    with_fleet(fleet_id, fn fleet, reading ->
      case Proposals.get_by_number(fleet_id, String.to_integer(number)) do
        nil ->
          Map.merge(reading, %{number: number, proposal: nil})

        proposal ->
          {votes, more?} = Proposals.votes_after(proposal.id, votes_after, @votes_page)
          path = &detail_path(fleet_id, proposal.number, &1)

          Map.merge(reading, %{
            number: number,
            proposal: Map.merge(summary(proposal), details(proposal, fleet)),
            votes: Enum.map(votes, &vote/1),
            more_votes: if(more?, do: path.(votes_after: List.last(votes).record_seq)),
            first_votes: if(votes_after > 0, do: path.([]))
          })
      end
    end)
  end

  @doc "The path of the fleet's proposals, from `position`."
  def list_path(fleet_id, position \\ []),
    do: with_query("/app/fleets/#{fleet_id}/proposals", position)

  @doc "The path of one proposal's page, from `position` in its votes."
  def detail_path(fleet_id, number, position \\ []),
    do: with_query("/app/fleets/#{fleet_id}/proposals/#{number}", position)

  defp with_query(path, []), do: path
  defp with_query(path, query), do: path <> "?" <> URI.encode_query(query)

  @doc """
  An amount of an asset as every page shows it, `%{text: text, token: address
  | nil, symbol?: boolean}`, grouped: in its own units with its symbol when
  the token has reported both, and otherwise as the whole number the chain
  holds. `symbol?` says whether `text` ends in the symbol the token chose.
  Every asset but ETH and the fleet's own USDC, both known by their
  addresses, comes with its address as `token`, so a token calling itself
  USDC is never taken for it. `assets` is as `Keyfleet.Treasury.assets/1`
  reads them.
  """
  def amount(atoms, asset, %{usdc: usdc, details: details}) do
    {text, symbol?} =
      case details[asset] do
        {symbol, decimals} when is_binary(symbol) and is_integer(decimals) ->
          {"#{units(atoms, decimals)} #{symbol}", true}

        _unknown ->
          {"#{units(atoms, 0)} in the smallest units of token", false}
      end

    %{text: text, token: if(asset not in [usdc, Treasury.native()], do: asset), symbol?: symbol?}
  end

  defp with_fleet(fleet_id, read) do
    case Fleets.get_fleet!(fleet_id) do
      nil ->
        %{fleet_id: fleet_id, fleet_name: nil}

      fleet ->
        deployed? = fleet.contract_address != nil

        read.(fleet, %{
          fleet_id: fleet_id,
          fleet_name: fleet.name,
          deployed?: deployed?,
          chain_id: fleet.chain_id,
          catching_up?: deployed? and not Chain.fresh?(fleet_id)
        })
    end
  end

  # The tokens the payment form lists by name: USDC, then the tokens of the
  # latest reading (each token an open payment names). The form takes any
  # other token by its address.
  defp propose(fleet),
    do: %{
      assets:
        Enum.map(
          Treasury.payable_assets(fleet),
          &%{address: &1.address, name: pay_name(&1)}
        )
    }

  # A token as the payment form names it: the fleet's own USDC by name, any
  # other with its address beside its symbol, so a token calling itself USDC
  # is never taken for it. One that hasn't said its decimals is paid in its
  # smallest units.
  defp pay_name(%{usdc?: true}), do: "USDC"

  defp pay_name(%{address: address, symbol: symbol, decimals: decimals})
       when is_binary(symbol) and is_integer(decimals),
       do: "#{symbol} #{RegentFormat.short_address(address)}"

  defp pay_name(%{address: address}),
    do: "Token #{RegentFormat.short_address(address)}, in its smallest units"

  defp summary(proposal) do
    %{
      number: proposal.number,
      status: Proposals.status(proposal),
      yes: proposal.yes_keys,
      no: proposal.no_keys,
      abstain: proposal.abstain_keys,
      counted: proposal.opening_count + proposal.late_keys,
      closes_at: proposal.closes_at
    }
  end

  defp details(proposal, fleet) do
    assets = Treasury.assets(fleet)

    %{
      proposer: proposal.proposer,
      author_key: proposal.author_key,
      content_hash: proposal.content_hash,
      opened_at: proposal.opened_at,
      execution_expiry: proposal.execution_expiry,
      calls: Enum.map(proposal.calls, &call(&1, assets)),
      executor: proposal.execution && proposal.execution.executor,
      cancelled_by: proposal.cancellation && proposal.cancellation.cancelled_by
    }
  end

  # One call the treasury makes if the proposal is carried out, with the ETH
  # it sends, if any.
  defp call(call, assets) do
    %{
      target: call.target,
      value: if(call.value > 0, do: amount(call.value, Treasury.native(), assets)),
      data: call.data
    }
  end

  defp vote(vote) do
    %{
      id: vote.id,
      voter: vote.voter,
      choice: vote.choice,
      keys: vote.token_ids
    }
  end

  defp treasury(fleet, reading) do
    assets = Treasury.assets(fleet)
    %{shown: shown, earlier?: earlier?} = Treasury.latest(fleet.id)

    %{
      history: Enum.map(shown, &event(&1, fleet, assets)),
      earlier?: earlier?,
      advances: Enum.map(Treasury.open_advances(fleet.id), &advance(&1, assets))
    }
    |> Map.merge(figures(fleet, reading, assets))
  end

  defp figures(_fleet, nil, _assets), do: %{read?: false, nothing_owed?: false}

  defp figures(fleet, reading, assets) do
    usdc = &amount(Decimal.to_integer(&1), fleet.usdc_address, assets)

    %{
      read?: true,
      as_of: reading.block_time,
      balances:
        Enum.map(
          reading.assets,
          &%{
            asset: &1.asset,
            held: amount(&1.held, &1.asset, assets),
            backed: amount(&1.backed, &1.asset, assets)
          }
        ),
      split_rate: "#{units(reading.daily_split_bps, 2)}%",
      last_run_at: reading.last_run_at,
      next_run_at: reading.next_run_at,
      reserve: if(Decimal.gt?(reading.cascade_reserve, 0), do: usdc.(reading.cascade_reserve)),
      owed: usdc.(reading.protocol_share_owed),
      nothing_owed?: Decimal.eq?(reading.protocol_share_owed, 0)
    }
  end

  # One line of the money history: what happened, how much and, for money
  # paid or advanced, to whom.
  defp event(%{kind: :split_allocated} = event, _fleet, assets) do
    shared = Decimal.to_integer(event.per_key) * Decimal.to_integer(event.keys)

    %{
      id: event.id,
      kind: event.kind,
      amount: amount(shared, event.asset, assets),
      account: nil
    }
  end

  defp event(%{kind: :protocol_share_sent} = event, fleet, assets),
    do: %{
      id: event.id,
      kind: event.kind,
      amount: amount(Decimal.to_integer(event.amount), fleet.usdc_address, assets),
      account: nil
    }

  defp event(event, _fleet, assets),
    do: %{
      id: event.id,
      kind: event.kind,
      amount: amount(Decimal.to_integer(event.amount), event.asset, assets),
      account: if(event.kind in [:paid, :advanced], do: event.account)
    }

  defp advance(advance, assets),
    do: %{
      id: Decimal.to_string(advance.advance_id),
      operator: advance.operator,
      amount: amount(Decimal.to_integer(advance.amount), advance.asset, assets),
      outstanding: amount(Decimal.to_integer(advance.outstanding), advance.asset, assets)
    }

  defp number!(nil), do: nil

  defp number!(value) when is_binary(value) do
    if Regex.match?(@number, value), do: String.to_integer(value), else: raise(NotFoundError)
  end

  defp number!(_value), do: raise(NotFoundError)

  defp seq!(nil), do: 0
  defp seq!(value), do: number!(value)

  @doc """
  `atoms` of a token with `decimals` places, in whole tokens, thousands
  grouped. Whole numbers throughout: an amount can be any uint256, more
  digits than decimal arithmetic keeps.
  """
  def units(atoms, decimals) do
    scale = Integer.pow(10, decimals)

    fraction =
      atoms
      |> rem(scale)
      |> Integer.to_string()
      |> String.pad_leading(decimals, "0")
      |> String.trim_trailing("0")

    case fraction do
      "" -> Rules.grouped(div(atoms, scale))
      fraction -> "#{Rules.grouped(div(atoms, scale))}.#{fraction}"
    end
  end
end
