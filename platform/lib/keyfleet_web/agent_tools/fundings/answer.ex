defmodule KeyfleetWeb.AgentTools.Fundings.Answer do
  @moduledoc """
  What funding a fleet's treasury with NEAR (`Keyfleet.Fundings`) answers an
  agent, the same over its signed requests (`KeyfleetWeb.AgentFundingController`)
  and as the Claude connector's tools (`KeyfleetWeb.AgentTools.Fundings`):
  pricing a funding, starting one, and reading one with the latest state the
  exchange service gives. Each answer is `{status, body, retry_after}`;
  `params` is the signed request's JSON, its body with the names in its
  address (`fleet_id`, `funding_id`).

  The USDC always lands at the fleet's own treasury, so a funding names only
  its amount and the NEAR account a refund goes to. Only the fleet's members
  price one, start one or record its state; any other agent is answered
  `funding_needs_key`.
  """

  alias Keyfleet.Actors.Agent
  alias Keyfleet.Fundings
  alias Keyfleet.Fundings.Errors.{NotLive, ServiceFailed}
  alias KeyfleetWeb.FundingJSON
  alias KeyfleetWeb.Refusal

  @doc "Answers `op` for `actor`; nothing here waits, so the waiter is unused."
  @spec answer(atom(), map(), Agent.t(), term()) ::
          {pos_integer(), map(), pos_integer() | nil}
  def answer(op, %{"fleet_id" => fleet_id} = params, actor, _waiter) do
    if fleet_id in Keyfleet.Fleets.catalog_ids(),
      do: run(op, params, actor),
      else: {404, Refusal.body("fleet_unknown"), nil}
  end

  defp run(:quote, %{"fleet_id" => fleet_id} = params, actor) do
    case Fundings.price_funding(fleet_id, params["usdc_amount"], params["refund_to"],
           actor: actor
         ) do
      {:ok, price} -> {200, %{quote: price_json(fleet_id, params, price)}, nil}
      {:error, error} -> refuse(fleet_id, error)
    end
  end

  defp run(:start, %{"fleet_id" => fleet_id} = params, actor) do
    case Fundings.start_funding(fleet_id, params["usdc_amount"], params["refund_to"],
           actor: actor
         ) do
      {:ok, funding} -> {201, %{funding: FundingJSON.funding(funding)}, nil}
      {:error, error} -> refuse(fleet_id, error)
    end
  end

  # Reading a funding asks the exchange service for its latest state and
  # records it.
  defp run(:show, %{"fleet_id" => fleet_id, "funding_id" => funding_id}, actor) do
    with {:ok, %Fundings.Funding{} = funding} <-
           Fundings.get_funding(fleet_id, funding_id, actor: actor),
         {:ok, funding} <- Fundings.refresh_funding(funding, actor: actor) do
      {200, %{funding: FundingJSON.funding(funding)}, nil}
    else
      {:ok, nil} -> {404, Refusal.body("funding_unknown"), nil}
      {:error, error} -> refuse(fleet_id, error)
    end
  end

  defp price_json(fleet_id, params, price) do
    %{
      fleet_id: fleet_id,
      usdc_amount: params["usdc_amount"],
      usdc: FundingJSON.usdc(params["usdc_amount"]),
      usdc_out_formatted: price.usdc_out_formatted,
      near_in: Decimal.to_string(price.near_in, :normal),
      near_in_formatted: price.near_in_formatted,
      time_estimate_s: price.seconds,
      recipient: price.recipient,
      refund_to: params["refund_to"]
    }
  end

  defp refuse(fleet_id, error) do
    {status, code} = refusal(error, fleet_id)
    {status, Refusal.body(code), nil}
  end

  # Who holds which Key decides whether an agent is a member, so a refusal
  # while ownership is being read again says so.
  defp refusal(%Ash.Error.Forbidden{}, fleet_id) do
    if Keyfleet.Chain.fresh?(fleet_id),
      do: {403, "funding_needs_key"},
      else: {503, "ownership_refreshing"}
  end

  defp refusal(%Ash.Error.Invalid{errors: errors}, _fleet_id) do
    cond do
      Enum.any?(errors, &match?(%ServiceFailed{}, &1)) -> {502, "funding_service_failed"}
      Enum.any?(errors, &match?(%NotLive{}, &1)) -> {409, "fleet_not_on_chain"}
      true -> {422, "invalid_funding"}
    end
  end
end
