defmodule KeyfleetWeb.ProposalsPage do
  @moduledoc """
  What a fleet's proposal pages show, read from the proposals, votes and
  launches the chain reader recorded.

  `list/2` is the fleet's proposals, newest first, twenty to a page, with
  its shared money once it is on chain: the latest reading of its balances,
  and its latest launch income and payments. `detail/3` is one proposal with
  its votes, fifty to a page, and for a launch the version of the fleet's
  launch plan it points to by its digest. The form for a new launch starts
  from the fleet's launch plans. Once the fleet is on chain, each carries the
  network its wallet buttons send on; the buttons' steps are built by
  `Keyfleet.WalletSteps`. A page name that is
  not a proposal number is a page that doesn't exist.
  """

  alias Keyfleet.Chain
  alias Keyfleet.Fleets
  alias Keyfleet.Fleets.Rules
  alias Keyfleet.Graph
  alias Keyfleet.Graph.LaunchPlanDigest
  alias Keyfleet.Proposals
  alias Keyfleet.Proposals.LaunchPrice
  alias Keyfleet.Treasury
  alias Keyfleet.WalletSteps.Typed
  alias KeyfleetWeb.NotFoundError

  @number ~r/\A[1-9][0-9]{0,17}\z/
  @votes_page 50
  @regent_decimals 18
  @text_cap 64 * 1024

  @kinds %{decision: "Decision", autolaunch: "Launch", pay: "Payment from shared money"}

  # A launch's details as a launch plan names them, and as the page words
  # them when they differ.
  @launch_texts [
    {:name, "name"},
    {:symbol, "symbol"},
    {:description, "description"},
    {:website, "website"},
    {:image, "image"}
  ]

  # What a launch plan says beyond the launch's details, as the page names it.
  @plan_fields [
    {"who_we_serve", "Who it’s for"},
    {"what_we_sell", "What we offer"},
    {"why_raise", "What the money is for"},
    {"commitments", "Who does what afterwards"}
  ]

  @doc """
  The page of proposals below the one `params` names, if it names one, with
  what the forms for new proposals start from.
  """
  def list(fleet_id, params) do
    before = number!(params["before"])

    with_fleet(fleet_id, fn fleet, reading ->
      {proposals, older?} = Proposals.list_page(fleet_id, before)
      balances = reading.deployed? && Treasury.get_reading!(fleet_id)

      Map.merge(reading, %{
        proposals: Enum.map(proposals, &summary(&1, failed_launch_block(balances))),
        first_page?: is_nil(before),
        older: if(older?, do: list_path(fleet_id, before: List.last(proposals).number)),
        treasury: reading.deployed? && treasury(fleet, balances),
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
          failed = failed_launch_block(reading.deployed? && Treasury.get_reading!(fleet_id))

          Map.merge(reading, %{
            number: number,
            proposal: Map.merge(summary(proposal, failed), details(proposal, fleet)),
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

  @doc "What a kind of proposal is called."
  def kind_name(kind), do: Map.fetch!(@kinds, kind)

  @doc """
  An amount of an asset as every page shows it, `%{text: text, token: address
  | nil, symbol?: boolean}`, grouped: in its own units with its symbol when
  the token has reported both, and otherwise as the whole number the chain
  holds. `symbol?` says whether `text` ends in the symbol the token chose.
  Every asset but the fleet's own USDC, known by its address, comes with its
  address as `token`, so a token calling itself USDC is never taken for it.
  `assets` is as `Keyfleet.Treasury.assets/1` reads them.
  """
  def amount(atoms, asset, %{usdc: usdc, details: details}) do
    {text, symbol?} =
      case {details[asset], asset == usdc} do
        {{symbol, decimals}, _usdc?} when is_binary(symbol) and is_integer(decimals) ->
          {"#{units(atoms, decimals)} #{symbol}", true}

        {_unknown, true} ->
          {"#{units(atoms, 0)} in USDC’s smallest units", false}

        {_unknown, false} ->
          {"#{units(atoms, 0)} in the smallest units of token", false}
      end

    %{text: text, token: if(asset != usdc, do: asset), symbol?: symbol?}
  end

  # REGENT, which has eighteen decimals.
  defp regent(atoms), do: "#{units(atoms, @regent_decimals)} REGENT"

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
  # latest reading (REGENT, the launched token and each token an open payment
  # names). The form takes any other token by its address.
  defp propose(fleet),
    do: %{
      assets:
        Enum.map(
          Treasury.payable_assets(fleet),
          &%{address: &1.address, name: pay_name(&1)}
        )
    }

  @doc """
  Each launch plan of the fleet a launch can be proposed from, at its
  current version: its six launch details and its minimum raise exactly as
  that version holds them, and the digest a proposal carries to point to it. The launch form
  reads them once, when it is first shown, and keeps them after.
  """
  def launch_plans(fleet_id) do
    case Graph.proposable_launch_plans!(fleet_id) do
      [] ->
        []

      plans ->
        revisions =
          fleet_id
          |> Graph.current_launch_plan_revisions!(
            Enum.map(plans, &%{object_id: &1.id, version: &1.version})
          )
          |> Map.new(&{{&1.object_id, &1.version}, &1})

        for plan <- plans do
          revision = Map.fetch!(revisions, {plan.id, plan.version})
          data = revision.data

          %{
            id: plan.id,
            title: data["title"],
            version: revision.version,
            digest: revision.digest,
            fields: %{
              name: data["name"],
              symbol: data["symbol"],
              description: data["description"],
              website: data["website"],
              image: data["image"],
              floor: data["floor_price"],
              minimum: data["minimum_regent_raised"]
            }
          }
        end
    end
  end

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

  defp summary(proposal, failed_launch_block) do
    %{
      number: proposal.number,
      kind: proposal.kind,
      status: Proposals.status(proposal, failed_launch_block),
      keys_sold: proposal.keys_sold,
      yes: proposal.yes_keys,
      no: proposal.no_keys,
      gist: gist(proposal)
    }
  end

  # The block the latest reading says the fleet's failed launch was created
  # in, or nil.
  defp failed_launch_block(%{failed_launch_block: block}), do: block
  defp failed_launch_block(_no_reading), do: nil

  defp gist(%{kind: :autolaunch, launch_envelope: %{name: name}}), do: as_text(name)
  defp gist(%{kind: :autolaunch}), do: nil
  defp gist(%{text: text}), do: text |> as_text() |> String.slice(0, 280)

  defp details(proposal, fleet) do
    %{
      proposer: proposal.proposer,
      text: proposal.text && as_text(proposal.text),
      text_cut?: proposal.text_bytes != nil and proposal.text_bytes > @text_cap,
      pay: pay(proposal, fleet),
      match: match(proposal, fleet),
      launch: launch(proposal),
      plan: plan(proposal),
      executor: proposal.execution && proposal.execution.executor
    }
  end

  defp pay(%{kind: :pay} = proposal, fleet),
    do: %{
      amount: amount(Decimal.to_integer(proposal.amount), proposal.asset, Treasury.assets(fleet)),
      recipient: proposal.recipient
    }

  defp pay(_proposal, _fleet), do: nil

  # What each key that didn't vote yes on a carried-out payment may collect,
  # from the payment its execution made; unknown until the reader has
  # recorded that payment.
  defp match(%{kind: :pay, execution: %{transaction_hash: hash}}, fleet) do
    case Treasury.payment_made_in(fleet.id, hash) do
      nil ->
        %{read?: false}

      payment ->
        %{
          read?: true,
          share: amount(Decimal.to_integer(payment.share), payment.asset, Treasury.assets(fleet))
        }
    end
  end

  defp match(_proposal, _fleet), do: nil

  defp launch(%{kind: :autolaunch, launch_envelope: nil}), do: %{read?: false}

  defp launch(%{kind: :autolaunch, launch_envelope: envelope}) do
    floor = Decimal.to_integer(envelope.floor_price_q96)
    minimum = Decimal.to_integer(envelope.minimum_regent_raised)

    %{
      read?: true,
      fields: [
        {"Name", as_text(envelope.name)},
        {"Symbol", as_text(envelope.symbol)},
        {"Description", as_text(envelope.description)},
        {"Website", as_text(envelope.website)},
        {"Image", as_text(envelope.image)},
        {"Floor price", "#{floor_price(floor)} REGENT per token"},
        {"Higher minimum raise", if(minimum == 0, do: "None", else: regent(minimum))},
        {"REGENT to raise",
         "At least #{regent_at_least(LaunchPrice.required_regent_raised(floor, minimum))} REGENT"}
      ]
    }
  end

  defp launch(_proposal), do: nil

  # The launch plan version a launch points to by its digest, when the
  # fleet's workspace has it: what that version says, whether the plan has
  # changed or been archived since, and which of the launch's details, once
  # read, differ from it.
  defp plan(%{kind: :autolaunch, digest: nil}), do: %{found?: false}

  defp plan(%{kind: :autolaunch} = proposal) do
    case Graph.launch_plan_revisions!(proposal.fleet_id, [proposal.digest]) do
      [] -> %{found?: false}
      [revision] -> found_plan(proposal, revision)
    end
  end

  defp plan(_proposal), do: nil

  defp found_plan(proposal, revision) do
    data = revision.data
    current = Graph.read_object!(proposal.fleet_id, revision.object_id)

    %{
      found?: true,
      object_id: revision.object_id,
      title: data["title"],
      version: revision.version,
      changed?: LaunchPlanDigest.plan(current.data) != data,
      archived?: current.sys["archived"] == true,
      fields:
        for(
          {field, label} <- @plan_fields,
          data[field] not in [nil, ""],
          do: {label, data[field]}
        ),
      mismatches: mismatches(proposal.launch_envelope, data)
    }
  end

  # Unknown until the launch's details have been read.
  defp mismatches(nil, _data), do: nil

  defp mismatches(envelope, data) do
    texts =
      for {field, key} <- @launch_texts,
          Map.fetch!(envelope, field) != data[key],
          do: key

    floor? = Decimal.to_integer(envelope.floor_price_q96) != plan_floor(data["floor_price"])

    minimum? =
      Decimal.to_integer(envelope.minimum_regent_raised) !=
        plan_minimum(data["minimum_regent_raised"])

    texts ++
      if(floor?, do: ["the floor price"], else: []) ++
      if(minimum?, do: ["the minimum raise"], else: [])
  end

  # A plan names its floor price in REGENT per token, and its minimum raise
  # in whole REGENT, as decimal strings; the launch holds them as the
  # proposal carries them, read the way the launch form reads them, a
  # minimum left out being none.
  defp plan_floor(nil), do: nil

  defp plan_floor(text) do
    case Typed.floor_price(text) do
      {:ok, floor} -> floor
      {:error, _problem} -> nil
    end
  end

  defp plan_minimum(nil), do: 0

  defp plan_minimum(text) do
    case Typed.amount(text, @regent_decimals, Typed.largest_uint256()) do
      {:ok, minimum} -> minimum
      {:error, _problem} -> nil
    end
  end

  defp vote(vote) do
    %{
      id: vote.id,
      voter: vote.voter,
      support: vote.support,
      keys: vote.token_ids
    }
  end

  defp treasury(fleet, balances), do: treasury(fleet, balances, Treasury.assets(fleet))

  defp treasury(fleet, nil, assets),
    do: Map.merge(history(fleet.id, assets), %{read?: false, nothing_owed?: false})

  defp treasury(fleet, balances, assets) do
    usdc = &amount(Decimal.to_integer(&1), fleet.usdc_address, assets)

    fleet.id
    |> history(assets)
    |> Map.merge(%{
      read?: true,
      as_of: balances.block_time,
      balances: Enum.map(balances.assets, &balance(&1, assets)),
      reserve: if(Decimal.gt?(balances.cascade_reserve, 0), do: usdc.(balances.cascade_reserve)),
      owed: usdc.(balances.protocol_share_owed),
      nothing_owed?: Decimal.eq?(balances.protocol_share_owed, 0)
    })
  end

  defp balance(balance, assets) do
    shown = &amount(&1, balance.asset, assets)

    %{
      asset: balance.asset,
      budget: shown.(balance.free_capital),
      set_aside: shown.(balance.backed)
    }
  end

  defp history(fleet_id, assets) do
    %{income: income, payments: payments} = Treasury.latest(fleet_id)
    shown = &amount(Decimal.to_integer(&1), &2.asset, assets)

    %{
      income:
        Enum.map(
          income.shown,
          &%{id: &1.id, amount: shown.(&1.amount, &1)}
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

  defp number!(nil), do: nil

  defp number!(value) when is_binary(value) do
    if Regex.match?(@number, value), do: String.to_integer(value), else: raise(NotFoundError)
  end

  defp number!(_value), do: raise(NotFoundError)

  defp seq!(nil), do: 0
  defp seq!(value), do: number!(value)

  defp as_text(bytes), do: String.replace_invalid(bytes)

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

  @doc """
  A floor price, REGENT per token times 2^96, in REGENT per token to six
  significant figures, like `0.000001`.
  """
  def floor_price(floor_price_q96),
    do: significant(floor_price_q96, LaunchPrice.q96(), :half_up)

  @doc """
  `atoms` of REGENT in whole REGENT, rounded up to six decimal places,
  thousands grouped: what a launch must raise "at least", so raising the
  amount shown is always enough.
  """
  def regent_at_least(atoms) do
    step = Integer.pow(10, @regent_decimals - 6)
    units(div(atoms + step - 1, step) * step, @regent_decimals)
  end

  defp significant(numerator, denominator, rounding) do
    shown =
      Decimal.Context.with(%Decimal.Context{precision: 6, rounding: rounding}, fn ->
        Decimal.div(numerator, denominator)
      end)
      |> Decimal.normalize()
      |> Decimal.to_string(:normal)

    case String.split(shown, ".") do
      [whole] -> Rules.grouped(String.to_integer(whole))
      [whole, fraction] -> "#{Rules.grouped(String.to_integer(whole))}.#{fraction}"
    end
  end
end
