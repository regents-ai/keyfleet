defmodule KeyfleetWeb.ProposalsPage do
  @moduledoc """
  What a fleet's proposal pages show, read from the proposals, votes and
  launches the chain reader recorded.

  `list/3` is the fleet's proposals, newest first, twenty to a page, with
  its budget once it is on chain: the latest reading of its balances, and
  its latest launch income and payments. `detail/4` is one proposal with its votes, fifty to a
  page. Once the fleet is on chain, each carries what its wallet buttons
  need: the fleet's network, its two contracts, and the wallets of the
  person signed in, which the buttons name when the connected wallet is
  another. Each answers
  `check_in`, how long the page may wait before its proposals could read
  differently without anything new being recorded: a proposal closing, a
  closed one being counted, or a passed one running out of time. A page name that is not a proposal number is a
  page that doesn't exist.
  """

  alias Keyfleet.Chain
  alias Keyfleet.Fleets
  alias Keyfleet.Proposals
  alias Keyfleet.Treasury
  alias KeyfleetWeb.NotFoundError

  @number ~r/\A[1-9][0-9]{0,17}\z/
  @votes_page 50
  # A closed proposal's votes are counted by the chain reader's next pass.
  @after_closing 5_000
  @while_counting 10_000
  @day 24 * 60 * 60 * 1_000
  @regent_decimals 18
  @text_cap 64 * 1024
  # A month of payments, and the part of the budget it can pay out.
  @pay_period 30 * 24 * 60 * 60
  @pay_cap_bps 2_000
  @bps 10_000
  # The fleet's USDC, which its contract refuses to be deployed with unless
  # it has six decimals.
  @usdc_decimals 6
  # How long a proposed launch can be carried out for, unless its proposer
  # changes it.
  @launch_window_days 30

  @kinds %{decision: "Decision", autolaunch: "Launch", pay: "Payment from the budget"}

  @doc """
  The page of proposals below the one `params` names, if it names one, with
  what the forms for new proposals start from. `signed_in` is the wallets of
  the person signed in, primary first.
  """
  def list(fleet_id, params, signed_in) do
    before = number!(params["before"])

    with_fleet(fleet_id, signed_in, fn fleet, reading ->
      {proposals, older?} = Proposals.list_page(fleet_id, before)
      now = DateTime.utc_now()
      shown = Enum.map(proposals, &summary(&1, reading.cursor, now))
      balances = reading.deployed? && Treasury.get_reading!(fleet_id)

      Map.merge(reading, %{
        proposals: shown,
        first_page?: is_nil(before),
        older: if(older?, do: list_path(fleet_id, before: List.last(proposals).number)),
        check_in: check_in(shown, now),
        treasury: reading.deployed? && treasury(fleet, balances),
        propose: reading.deployed? && propose(fleet, balances, now)
      })
    end)
  end

  @doc """
  Proposal `number` and a page of its votes, from the one `params` names.
  `signed_in` is the wallets of the person signed in, primary first.
  """
  def detail(fleet_id, number, params, signed_in) do
    votes_after = seq!(params["votes_after"])

    with_fleet(fleet_id, signed_in, fn fleet, reading ->
      now = DateTime.utc_now()

      case Proposals.get_by_number(fleet_id, String.to_integer(number)) do
        nil ->
          Map.merge(reading, %{number: number, proposal: nil, check_in: nil})

        proposal ->
          shown = summary(proposal, reading.cursor, now)
          {votes, more?} = Proposals.votes_after(proposal.id, votes_after, @votes_page)
          path = &detail_path(fleet_id, proposal.number, &1)

          Map.merge(reading, %{
            number: number,
            proposal: Map.merge(shown, details(proposal, fleet)),
            votes: Enum.map(votes, &vote/1),
            more_votes: if(more?, do: path.(votes_after: List.last(votes).record_seq)),
            first_votes: if(votes_after > 0, do: path.([])),
            check_in: check_in([shown], now)
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

  @doc "What a kind of proposal is called."
  def kind_name(kind), do: Map.fetch!(@kinds, kind)

  # An amount of an asset, grouped: in its own units with its symbol when the
  # token has reported both, and otherwise as the whole number the chain
  # holds. Every asset but the fleet's own USDC, known by its address, comes
  # with its address, so a token calling itself USDC is never taken for it.
  defp amount(atoms, asset, %{usdc: usdc, details: details}) do
    text =
      case {details[asset], asset == usdc} do
        {{symbol, decimals}, _usdc?} when is_binary(symbol) and is_integer(decimals) ->
          "#{units(atoms, decimals)} #{symbol}"

        {_unknown, true} ->
          "#{units(atoms, 0)} in USDC’s smallest units"

        {_unknown, false} ->
          "#{units(atoms, 0)} in the smallest units of token"
      end

    %{text: text, token: if(asset != usdc, do: asset)}
  end

  # REGENT, which has eighteen decimals.
  defp regent(atoms), do: "#{units(atoms, @regent_decimals)} REGENT"

  defp with_fleet(fleet_id, signed_in, read) do
    case Fleets.get_fleet!(fleet_id) do
      nil ->
        %{fleet_id: fleet_id, fleet_name: nil, check_in: nil}

      fleet ->
        deployed? = fleet.contract_address != nil

        read.(fleet, %{
          fleet_id: fleet_id,
          fleet_name: fleet.name,
          deployed?: deployed?,
          wallet: deployed? && wallet(fleet, signed_in),
          cursor: Chain.get_cursor!(fleet_id),
          catching_up?: deployed? and not Chain.fresh?(fleet_id)
        })
    end
  end

  # What the wallet buttons need: the fleet's network, its vote contract,
  # the fleet contract itself, and the signed-in person's wallets.
  defp wallet(fleet, signed_in),
    do: %{
      chain_id: fleet.chain_id,
      votes: fleet.votes_address,
      fleet: fleet.contract_address,
      signed_in: signed_in
    }

  # What the forms for new proposals start from: each asset the budget
  # holds, and a launch that can be carried out for 30 days.
  defp propose(fleet, balances, now) do
    known = assets(fleet)

    %{
      assets: fleet |> budget_assets(balances) |> Enum.map(&pay_asset(&1, fleet, known)),
      launch_until:
        now |> DateTime.add(@launch_window_days, :day) |> Calendar.strftime("%Y-%m-%dT%H:%M")
    }
  end

  defp budget_assets(fleet, nil), do: [fleet.usdc_address]

  defp budget_assets(fleet, balances),
    do: Enum.uniq([fleet.usdc_address | Enum.map(balances.assets, & &1.asset)])

  # An asset to pay in, with the decimals amounts typed in whole tokens are
  # converted with and the words that name an amount of it. A token that
  # hasn't said its decimals is paid in its smallest units.
  defp pay_asset(usdc, %{usdc_address: usdc}, _assets),
    do: %{address: usdc, decimals: @usdc_decimals, name: "USDC", unit: "USDC"}

  defp pay_asset(asset, _fleet, %{details: details}) do
    case details[asset] do
      {symbol, decimals} when is_binary(symbol) and is_integer(decimals) ->
        name = "#{symbol} #{short(asset)}"
        %{address: asset, decimals: decimals, name: name, unit: name}

      _unknown ->
        %{
          address: asset,
          decimals: 0,
          name: "Token #{short(asset)}, in its smallest units",
          unit: "smallest units of token #{short(asset)}"
        }
    end
  end

  defp short(address), do: String.slice(address, 0, 6) <> "…" <> String.slice(address, -4, 4)

  defp summary(proposal, cursor, now) do
    status = Proposals.status(proposal, cursor, now)

    %{
      number: proposal.number,
      kind: proposal.kind,
      status: status,
      closes_at: proposal.closes_at,
      eligible_keys: proposal.eligible_keys,
      yes: proposal.yes_keys,
      no: proposal.no_keys,
      gist: gist(proposal),
      last_day: last_day(status, proposal.execution_expiry)
    }
  end

  # The last second a passed proposal can still be carried out in.
  defp last_day(:passed, %Decimal{} = expiry), do: expiry(expiry)
  defp last_day(_status, _expiry), do: nil

  defp gist(%{kind: :autolaunch, launch_envelope: %{name: name}}), do: as_text(name)
  defp gist(%{kind: :autolaunch}), do: nil
  defp gist(%{text: text}), do: text |> as_text() |> String.slice(0, 280)

  defp details(proposal, fleet) do
    %{
      proposer: proposal.proposer,
      text: proposal.text && as_text(proposal.text),
      text_cut?: proposal.text_bytes != nil and proposal.text_bytes > @text_cap,
      pay: pay(proposal, fleet),
      launch: launch(proposal),
      executor: proposal.execution && proposal.execution.executor
    }
  end

  defp pay(%{kind: :pay} = proposal, fleet),
    do: %{
      amount: amount(Decimal.to_integer(proposal.amount), proposal.asset, assets(fleet)),
      recipient: proposal.recipient
    }

  defp pay(_proposal, _fleet), do: nil

  defp launch(%{kind: :autolaunch, launch_envelope: nil}), do: %{read?: false}

  defp launch(%{kind: :autolaunch, launch_envelope: envelope}) do
    %{
      read?: true,
      fields: [
        {"Name", as_text(envelope.name)},
        {"Symbol", as_text(envelope.symbol)},
        {"Description", as_text(envelope.description)},
        {"Website", as_text(envelope.website)},
        {"Image", as_text(envelope.image)}
      ],
      raise: regent(Decimal.to_integer(envelope.required_regent_raised))
    }
  end

  defp launch(_proposal), do: nil

  defp vote(vote) do
    %{
      id: vote.id,
      voter: vote.voter,
      support: vote.support,
      keys: vote.token_ids
    }
  end

  # The fleet's USDC, and each asset's symbol and decimals as its token
  # reported them.
  defp assets(fleet) do
    %{
      usdc: fleet.usdc_address,
      details:
        fleet.id
        |> Treasury.asset_details!()
        |> Map.new(&{&1.asset, {&1.symbol, &1.decimals}})
    }
  end

  defp treasury(fleet, balances), do: treasury(fleet, balances, assets(fleet))

  defp treasury(fleet, nil, assets),
    do: Map.merge(history(fleet.id, assets), %{read?: false, nothing_owed?: false})

  defp treasury(fleet, balances, assets) do
    usdc = &amount(Decimal.to_integer(&1), fleet.usdc_address, assets)

    fleet.id
    |> history(assets)
    |> Map.merge(%{
      read?: true,
      as_of: balances.block_time,
      payments_open?: balances.launch_settled,
      balances: Enum.map(balances.assets, &balance(&1, balances.block_time, assets)),
      reserve: if(Decimal.gt?(balances.cascade_reserve, 0), do: usdc.(balances.cascade_reserve)),
      owed: usdc.(balances.protocol_share_owed),
      nothing_owed?: Decimal.eq?(balances.protocol_share_owed, 0)
    })
  end

  defp balance(balance, as_of, assets) do
    shown = &amount(&1, balance.asset, assets)

    Map.merge(
      %{
        asset: balance.asset,
        budget: shown.(balance.free_capital),
        set_aside: shown.(balance.backed)
      },
      month(balance, as_of, shown)
    )
  end

  # A month of payments begins with its first payment and can pay out up to
  # a fifth of the budget as it stood then. Until one begins, a fifth of the
  # budget as it stands is what the next month could pay.
  defp month(balance, as_of, shown) do
    if open_month?(balance, as_of) do
      %{
        available: shown.(balance.pay_cap - balance.pay_spent),
        paid: %{spent: shown.(balance.pay_spent), cap: shown.(balance.pay_cap)},
        month_ends: month_end(balance.pay_period_start)
      }
    else
      fifth = div(balance.free_capital * @pay_cap_bps, @bps)
      %{available: shown.(fifth), paid: nil, month_ends: nil}
    end
  end

  defp open_month?(%{pay_period_start: nil}, _as_of), do: false

  defp open_month?(%{pay_period_start: start}, as_of),
    do: DateTime.before?(as_of, month_end(start))

  defp month_end(start), do: DateTime.add(start, @pay_period)

  defp history(fleet_id, assets) do
    %{income: income, payments: payments} = Treasury.latest(fleet_id)
    shown = &amount(Decimal.to_integer(&1), &2.asset, assets)

    %{
      income:
        Enum.map(
          income.shown,
          &%{
            id: &1.id,
            received: shown.(&1.gross, &1),
            fee: shown.(&1.fee, &1),
            to_budget: shown.(&1.to_budget, &1),
            to_keys: shown.(&1.to_keys, &1)
          }
        ),
      earlier_income?: income.earlier?,
      payments:
        Enum.map(
          payments.shown,
          &%{id: &1.id, amount: shown.(&1.amount, &1), recipient: &1.recipient}
        ),
      earlier_payments?: payments.earlier?
    }
  end

  # A proposal on show reads differently once it closes, and a closed one
  # once its votes are counted.
  defp check_in(proposals, now) do
    closing =
      for %{status: :voting, closes_at: closes_at} <- proposals,
          do: DateTime.diff(closes_at, now, :millisecond) + @after_closing

    counting = for %{status: :counting} <- proposals, do: @while_counting

    # The second after the last one it can be carried out in, looked at
    # again at least daily until then.
    running_out =
      for %{status: :passed, last_day: %DateTime{} = last_day} <- proposals,
          do: min(DateTime.diff(last_day, now, :millisecond) + 1_000, @day)

    Enum.min(closing ++ counting ++ running_out, fn -> nil end)
  end

  # The contract holds the last second as any uint64; one past what a date
  # can show is shown as never ending.
  defp expiry(seconds) do
    case DateTime.from_unix(Decimal.to_integer(seconds)) do
      {:ok, datetime} -> datetime
      {:error, _beyond} -> nil
    end
  end

  defp number!(nil), do: nil

  defp number!(value) when is_binary(value) do
    if Regex.match?(@number, value), do: String.to_integer(value), else: raise(NotFoundError)
  end

  defp number!(_value), do: raise(NotFoundError)

  defp seq!(nil), do: 0
  defp seq!(value), do: number!(value)

  defp as_text(bytes), do: String.replace_invalid(bytes)

  # Whole numbers throughout: an amount can be any uint256, more digits than
  # decimal arithmetic keeps.
  defp units(atoms, decimals) do
    scale = Integer.pow(10, decimals)

    fraction =
      atoms
      |> rem(scale)
      |> Integer.to_string()
      |> String.pad_leading(decimals, "0")
      |> String.trim_trailing("0")

    case fraction do
      "" -> grouped(div(atoms, scale))
      fraction -> "#{grouped(div(atoms, scale))}.#{fraction}"
    end
  end

  defp grouped(number) do
    number
    |> Integer.to_string()
    |> String.reverse()
    |> String.graphemes()
    |> Enum.chunk_every(3)
    |> Enum.map_join(",", &Enum.join/1)
    |> String.reverse()
  end
end
