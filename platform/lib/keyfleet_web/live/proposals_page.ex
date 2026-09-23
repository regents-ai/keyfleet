defmodule KeyFleetWeb.ProposalsPage do
  @moduledoc """
  What a fleet's proposal pages show, read from the proposals, votes and
  launches the chain reader recorded.

  `list/2` is the fleet's proposals, newest first, twenty to a page;
  `detail/3` is one proposal with its votes, fifty to a page. Each answers
  `check_in`, how long the page may wait before its proposals could read
  differently without anything new being recorded: a proposal closing, or a
  closed one being counted. A page name that is not a proposal number is a
  page that doesn't exist.
  """

  alias KeyFleet.Chain
  alias KeyFleet.Fleets
  alias KeyFleet.Proposals
  alias KeyFleetWeb.NotFoundError

  @number ~r/\A[1-9][0-9]{0,17}\z/
  @votes_page 50
  # A closed proposal's votes are counted by the chain reader's next pass.
  @after_closing 5_000
  @while_counting 10_000
  @usdc_decimals 6
  @regent_decimals 18
  @text_cap 64 * 1024

  @kinds %{decision: "Decision", autolaunch: "Launch", pay: "Payment from the budget"}

  @doc "The page of proposals below the one `params` names, if it names one."
  def list(fleet_id, params) do
    before = number!(params["before"])

    with_fleet(fleet_id, fn fleet, reading ->
      {proposals, older?} = Proposals.list_page(fleet_id, before)
      now = DateTime.utc_now()
      shown = Enum.map(proposals, &summary(&1, reading.cursor, now))

      Map.merge(reading, %{
        proposals: shown,
        first_page?: is_nil(before),
        older: if(older?, do: list_path(fleet_id, before: List.last(proposals).number)),
        check_in: check_in(shown, now),
        assets: assets(fleet)
      })
    end)
  end

  @doc "Proposal `number` and a page of its votes, from the one `params` names."
  def detail(fleet_id, number, params) do
    votes_after = seq!(params["votes_after"])

    with_fleet(fleet_id, fn fleet, reading ->
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

  @doc "An amount of an asset in its own units, grouped, with its symbol when it is known."
  def amount(atoms, asset, assets) do
    case assets[asset] do
      {symbol, decimals} -> "#{units(atoms, decimals)} #{symbol}"
      nil -> "#{units(atoms, 0)} units of #{asset}"
    end
  end

  @doc "REGENT, which has eighteen decimals."
  def regent(atoms), do: "#{units(atoms, @regent_decimals)} REGENT"

  defp with_fleet(fleet_id, read) do
    case Fleets.get_fleet!(fleet_id) do
      nil ->
        %{fleet_id: fleet_id, fleet_name: nil, check_in: nil}

      fleet ->
        deployed? = fleet.contract_address != nil

        read.(fleet, %{
          fleet_id: fleet_id,
          fleet_name: fleet.name,
          cursor: Chain.get_cursor!(fleet_id),
          catching_up?: deployed? and not Chain.fresh?(fleet_id)
        })
    end
  end

  defp summary(proposal, cursor, now) do
    %{
      number: proposal.number,
      kind: proposal.kind,
      status: Proposals.status(proposal, cursor, now),
      closes_at: proposal.closes_at,
      eligible_keys: proposal.eligible_keys,
      yes: proposal.yes_keys,
      no: proposal.no_keys,
      gist: gist(proposal)
    }
  end

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
      last_day: proposal.execution_expiry && expiry(proposal.execution_expiry),
      executor: proposal.execution && proposal.execution.executor
    }
  end

  defp pay(%{kind: :pay} = proposal, fleet),
    do: %{
      amount: amount(proposal.amount, proposal.asset, assets(fleet)),
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
      raise: regent(envelope.required_regent_raised)
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

  # The assets whose units are known without reading anything.
  defp assets(fleet), do: %{fleet.usdc_address => {"USDC", @usdc_decimals}}

  # A proposal on show reads differently once it closes, and a closed one
  # once its votes are counted.
  defp check_in(proposals, now) do
    closing =
      for %{status: :voting, closes_at: closes_at} <- proposals,
          do: DateTime.diff(closes_at, now, :millisecond) + @after_closing

    counting = for %{status: :counting} <- proposals, do: @while_counting
    Enum.min(closing ++ counting, fn -> nil end)
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

  defp units(atoms, decimals) do
    scale = Decimal.new(1, 1, decimals)
    whole = Decimal.div_int(atoms, scale)

    fraction =
      atoms
      |> Decimal.rem(scale)
      |> Decimal.to_integer()
      |> Integer.to_string()
      |> String.pad_leading(decimals, "0")
      |> String.trim_trailing("0")

    case fraction do
      "" -> grouped(whole)
      fraction -> "#{grouped(whole)}.#{fraction}"
    end
  end

  defp grouped(number) do
    number
    |> Decimal.to_integer()
    |> Integer.to_string()
    |> String.reverse()
    |> String.graphemes()
    |> Enum.chunk_every(3)
    |> Enum.map_join(",", &Enum.join/1)
    |> String.reverse()
  end
end
