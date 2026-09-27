defmodule Keyfleet.WalletSteps.Build do
  @moduledoc """
  Builds the steps one wallet button group sends, for one signer, as a
  `RegentChain.Review`: every step's contract and calldata, encoded here and
  never in a page.

  The answer is `%{review: review, figures: figures, problem: problem}`.
  `figures` are what the steps were built from, for the page to show beside
  the buttons. When what was typed can't be put into a call, or the chain
  can't be read, the review has no steps and `problem` names why; otherwise
  `problem` is nil. The contract decides everything else: nothing here
  guesses whether it will take a step.

  Reads go to the site's own node through `Keyfleet.Chain.Client`, at the
  latest block. Key sales need a fleet the site has recorded as deployed,
  which is how they stay off: no fleet is recorded on Base yet.
  """
  use Ash.Resource.Actions.Implementation

  alias Keyfleet.Chain
  alias Keyfleet.Chain.Abi
  alias Keyfleet.Fleets
  alias Keyfleet.Treasury
  alias Keyfleet.WalletSteps.Typed
  alias RegentChain.{Call, Review}

  # How long a purchase may take to reach the chain, counted from the
  # latest block's own clock, so a wallet's computer running fast or slow
  # doesn't shorten or stretch it.
  @purchase_seconds 600
  @largest_uint128 Integer.pow(2, 128) - 1
  # REGENT, which a launch raises, has eighteen decimals.
  @regent_decimals 18

  @doc "How long a purchase step stays good after it is built, in seconds."
  def purchase_seconds, do: @purchase_seconds

  @impl true
  def run(input, _opts, _context) do
    %{fleet_id: fleet_id, flow: flow, signer: signer, component_id: component_id} =
      input.arguments

    inputs = Map.get(input.arguments, :inputs, %{})

    with {:ok, fleet} <- deployed(fleet_id),
         {:ok, chain} <- chain(fleet.chain_id) do
      signer = String.downcase(signer)

      {steps, figures, problem} =
        case steps(flow, fleet, signer, inputs, input.arguments) do
          {:ok, steps, figures} -> {steps, figures, nil}
          {:ok, steps, figures, problem} -> {steps, figures, problem}
          {:problem, problem, figures} -> {[], figures, problem}
        end

      {:ok,
       %{
         review: Review.new(component_id, signer, chain, steps, inputs),
         figures: figures,
         problem: problem
       }}
    end
  end

  defp deployed(fleet_id) do
    case Fleets.get_fleet!(fleet_id) do
      %{contract_address: address} = fleet when is_binary(address) -> {:ok, fleet}
      _missing_or_not_on_chain -> {:error, "fleet #{fleet_id} is not on chain"}
    end
  end

  defp chain(chain_id) do
    case Application.fetch_env!(:keyfleet, :wallet_chains) do
      %{^chain_id => %{name: name, rpc_url: rpc_url}} ->
        {:ok, %{chain_id: chain_id, name: name, rpc_url: rpc_url}}

      _unlisted ->
        {:error, "no wallet chain is set for chain #{chain_id}"}
    end
  end

  # --- buying a key ----------------------------------------------------

  # The key on offer at the price the page shows. The wallet approves
  # exactly that price when its USDC allowance to the fleet is below it; the
  # purchase names the price as its most, so a key that has since cost more
  # is refused and no USDC is taken.
  defp steps(:buy, fleet, signer, _inputs, _arguments) do
    progress = Chain.progress(fleet.id)

    if progress.next_price do
      buy(fleet, signer, progress)
    else
      {:problem, :sold_out, %{max_supply: progress.max_supply}}
    end
  end

  defp steps(:claim, fleet, signer, _inputs, %{token_id: token_id}) do
    client = Chain.Client.configured()

    with {:ok, head} <- client.head(),
         {:ok, assets} <- read(client, fleet.rewards_address, "rewardAssets()", [], head,
                            {:array, :address}),
         {:ok, waiting} <- waiting(client, fleet, assets, token_id, head) do
      figures = %{token_id: token_id, waiting: waiting}

      case Enum.reject(waiting, &(&1.amount == 0)) do
        [] ->
          {:problem, :nothing_waiting, figures}

        owed ->
          {:ok,
           Enum.map(
             owed,
             &Review.step(
               "claim-#{&1.asset}",
               fleet.rewards_address,
               Call.encode("claim(address,uint256[],address)", [&1.asset, [token_id], signer])
             )
           ), figures}
      end
    else
      _unread -> {:problem, :unread, %{token_id: token_id, waiting: []}}
    end
  end

  # --- votes -----------------------------------------------------------

  defp steps(:vote, fleet, _signer, inputs, %{proposal: proposal}) do
    with {:ok, keys} <- typed(inputs, "keys", &Typed.keys/1, %{keys: []}) do
      {:ok,
       [
         Review.step("yes", fleet.votes_address, vote(proposal, keys, true)),
         Review.step("no", fleet.votes_address, vote(proposal, keys, false)),
         Review.step(
           "withdraw",
           fleet.votes_address,
           Call.encode("withdrawVote(uint256,uint256[])", [proposal, keys])
         )
       ], %{keys: keys}}
    end
  end

  defp steps(:carry_out, fleet, _signer, _inputs, %{proposal: proposal}),
    do:
      {:ok,
       [
         Review.step(
           "carry_out",
           fleet.votes_address,
           Call.encode("execute(uint256)", [proposal])
         )
       ], %{}}

  defp steps(:collect, fleet, _signer, inputs, %{proposal: proposal}) do
    with {:ok, keys} <- typed(inputs, "keys", &Typed.keys/1, %{keys: []}) do
      {:ok,
       [
         Review.step(
           "collect",
           fleet.votes_address,
           Call.encode("collect(uint256,uint256[])", [proposal, keys])
         )
       ], %{keys: keys}}
    end
  end

  # --- proposals -------------------------------------------------------

  defp steps(:propose_decision, fleet, _signer, inputs, _arguments) do
    with {:ok, key} <- typed(inputs, "key", &Typed.key/1, %{}),
         {:ok, digest} <- typed(inputs, "digest", &Typed.document_code/1, %{key: key}) do
      {:ok,
       [
         Review.step(
           "propose",
           fleet.votes_address,
           Call.encode("proposeDecision(uint256,string,bytes32)", [key, text(inputs), digest])
         )
       ], %{key: key}}
    end
  end

  defp steps(:propose_payment, fleet, _signer, inputs, _arguments) do
    with {:ok, key} <- typed(inputs, "key", &Typed.key/1, %{}),
         {:ok, asset} <- pay_asset(fleet, inputs, %{key: key}),
         {:ok, amount} <-
           typed(
             inputs,
             "amount",
             &Typed.amount(&1, asset.decimals || 0, Typed.largest_uint256()),
             %{key: key, asset: asset}
           ),
         {:ok, recipient} <-
           typed(
             inputs,
             "recipient",
             &Typed.address(&1, :recipient_unreadable),
             %{key: key, asset: asset, amount: amount}
           ),
         {:ok, digest} <- typed(inputs, "digest", &Typed.document_code/1, %{key: key}) do
      {:ok,
       [
         Review.step(
           "propose",
           fleet.votes_address,
           Call.encode(
             "proposePay(uint256,address,uint256,address,string,bytes32)",
             [key, asset.address, amount, recipient, text(inputs), digest]
           )
         )
       ], %{key: key, asset: asset, amount: amount, recipient: recipient}}
    end
  end

  defp steps(:propose_launch, fleet, _signer, inputs, _arguments) do
    with {:ok, key} <- typed(inputs, "key", &Typed.key/1, %{}),
         {:ok, raise} <-
           typed(
             inputs,
             "raise",
             &Typed.amount(&1, @regent_decimals, @largest_uint128),
             %{key: key}
           ),
         {:ok, digest} <- typed(inputs, "digest", &Typed.document_code/1, %{key: key}) do
      envelope =
        {field(inputs, "name"), field(inputs, "symbol"), field(inputs, "description"),
         field(inputs, "website"), field(inputs, "image"), raise, digest}

      {:ok,
       [
         Review.step(
           "propose",
           fleet.votes_address,
           Call.encode(
             "proposeAutolaunch(uint256,(string,string,string,string,string,uint128,bytes32))",
             [key, envelope]
           )
         )
       ], %{key: key, raise: raise, digest: digest}}
    end
  end

  # --- voting for another ----------------------------------------------

  # The contract stops any other wallet voting a holder's keys when the
  # holder names none (the zero address), which a step can't carry
  # (`RegentChain.Call` refuses it), or names itself; "clear" names the
  # signer, which leaves only the holder voting.
  defp steps(:delegate, fleet, signer, inputs, _arguments) do
    clear =
      Review.step(
        "clear",
        fleet.votes_address,
        Call.encode("setVotingDelegate(address)", [signer])
      )

    case typed(inputs, "delegate", &Typed.address(&1, :delegate_unreadable), %{}) do
      {:ok, delegate} ->
        {:ok,
         [
           Review.step(
             "delegate",
             fleet.votes_address,
             Call.encode("setVotingDelegate(address)", [delegate])
           ),
           clear
         ], %{delegate: delegate}}

      {:problem, problem, _figures} ->
        {:ok, [clear], %{delegate: nil}, problem}
    end
  end

  defp steps(:send_share, fleet, _signer, _inputs, _arguments),
    do:
      {:ok,
       [Review.step("send", fleet.contract_address, Call.encode("sendProtocolShare()", []))],
       %{}}

  defp buy(fleet, signer, progress) do
    client = Chain.Client.configured()
    price = progress.next_price

    figures = %{
      token_id: progress.next_token_id,
      price: price,
      max_supply: progress.max_supply
    }

    with {:ok, head} <- client.head(),
         {:ok, allowance} <-
           read(
             client,
             fleet.usdc_address,
             "allowance(address,address)",
             [signer, fleet.contract_address],
             head,
             {:uint, 256}
           ) do
      deadline = DateTime.to_unix(head.timestamp) + @purchase_seconds
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

  defp waiting(client, fleet, assets, token_id, head) do
    Enum.reduce_while(assets, {:ok, []}, fn asset, {:ok, waiting} ->
      case read(
             client,
             fleet.rewards_address,
             "accrued(address,uint256)",
             [asset, token_id],
             head,
             {:uint, 256}
           ) do
        {:ok, amount} -> {:cont, {:ok, [%{asset: asset, amount: amount} | waiting]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, waiting} -> {:ok, Enum.reverse(waiting)}
      error -> error
    end
  end

  # One view function's answer at the head block.
  defp read(client, to, signature, arguments, head, type) do
    "0x" <> hex = Call.encode(signature, arguments)

    with {:ok, returned} <- client.call(to, Base.decode16!(hex, case: :lower), head.hash),
         {:ok, [value]} <- Abi.decode(returned, [type]) do
      {:ok, value}
    else
      :error -> {:error, :unreadable_answer}
      error -> error
    end
  end

  defp vote(proposal, keys, support),
    do: Call.encode("vote(uint256,uint256[],bool)", [proposal, keys, support])

  # The token the payment form names: one it lists, by address, or another
  # pasted in, which is paid in its smallest units.
  defp pay_asset(fleet, inputs, figures) do
    listed = Treasury.payable_assets(fleet)

    case field(inputs, "asset") do
      "other" ->
        with {:ok, address} <-
               typed(inputs, "other_asset", &Typed.address(&1, :asset_unreadable), figures) do
          {:ok,
           Enum.find(listed, &(&1.address == address)) ||
             %{address: address, symbol: nil, decimals: nil}}
        end

      address ->
        case Enum.find(listed, &(&1.address == address)) do
          nil -> {:problem, :asset_unreadable, figures}
          asset -> {:ok, asset}
        end
    end
  end

  defp typed(inputs, name, read, figures) do
    case read.(field(inputs, name)) do
      {:ok, value} -> {:ok, value}
      {:error, problem} -> {:problem, problem, figures}
    end
  end

  defp field(inputs, name), do: Map.get(inputs, name, "")

  defp text(inputs), do: field(inputs, "text")
end
