defmodule Keyfleet.Proposals.Actions do
  @moduledoc """
  The calls a proposal can make, both ways: `encode/3` builds the exact
  calls of each kind of proposal the site offers, and `decode/2` reads a
  recorded call back as the action it takes, so a proposal's page can say in
  plain words what carrying it out does.

  Every call but a launch is made to the fleet's own treasury or vote
  contract: paying, advancing, the daily split's rate, approving or revoking
  a hash the treasury will answer as its signature, and restricting a key's
  edits, which names the Key by its id in the Key collection. A launch calls Autolaunch v2's factory and names the fleet's
  treasury as the launch's treasury. A decision makes no call at all.
  """

  alias Keyfleet.Fleets.Fleet
  alias RegentChain.{Abi, Call}

  @pay "pay(address,address,uint256)"
  @advance "advance(uint256,address,address,uint256,bytes32)"
  @rate "setDailySplitBps(uint256)"
  @approve_hash "approveSignatureHash(bytes32)"
  @revoke_hash "revokeSignatureHash(bytes32)"
  @voted_split "runVotedSplit()"
  @admit_ousd "admitOusd(address)"
  @edits "setEditsRestricted(uint256,bool)"
  @launch "launch((string,string,string,string,string,address))"

  @doc "The selector of the factory's launch call."
  def launch_selector, do: Call.selector(@launch)

  @doc """
  The calls of one kind of proposal, as `{target, wei, calldata}`:

    * `:decision`, no call;
    * `{:pay, asset, to, amount}` and `{:advance, id, operator, asset,
      amount, purpose}` from the treasury;
    * `{:rate, bps}`, the daily split's rate;
    * `{:signature, :approve | :revoke, hash}`;
    * `{:edits, token_id, restricted?}`, `token_id` the fleet's Key number;
    * `{:launch, %{name:, symbol:, description:, website:, image:}}`.
  """
  def encode(:decision, _fleet), do: []

  def encode({:pay, asset, to, amount}, fleet),
    do: [treasury(fleet, Call.encode(@pay, [asset, to, amount]))]

  def encode({:advance, id, operator, asset, amount, purpose}, fleet),
    do: [treasury(fleet, Call.encode(@advance, [id, operator, asset, amount, purpose]))]

  def encode({:rate, bps}, fleet), do: [treasury(fleet, Call.encode(@rate, [bps]))]

  def encode({:signature, :approve, hash}, fleet),
    do: [treasury(fleet, Call.encode(@approve_hash, [hash]))]

  def encode({:signature, :revoke, hash}, fleet),
    do: [treasury(fleet, Call.encode(@revoke_hash, [hash]))]

  def encode({:edits, token_id, restricted?}, fleet),
    do: [
      {fleet.votes_address, 0,
       Call.encode(@edits, [Fleet.onchain_token_id(fleet, token_id), restricted?])}
    ]

  def encode({:launch, launch}, fleet) do
    params =
      {launch.name, launch.symbol, launch.description, launch.website, launch.image,
       fleet.treasury_address}

    [{fleet.autolaunch_factory_address, 0, Call.encode(@launch, [params])}]
  end

  defp treasury(fleet, data), do: {fleet.treasury_address, 0, data}

  @doc """
  What one recorded call does, as `encode/2` names it, plus `:voted_split`,
  `{:admit_ousd, token}` and, for any other call, `{:other, target, wei,
  data}`. A call is read as an action only when it is made to the contract
  that action belongs to and sends no ETH.
  """
  def decode(%{target: target, value: 0, data: "0x" <> _hex = data}, fleet) do
    {selector, arguments} = String.split_at(data, 10)

    with {:ok, bytes} <- Abi.bytes("0x" <> arguments),
         {:ok, action} <- action(contract(target, fleet), selector, bytes, fleet) do
      action
    else
      _other -> {:other, target, 0, data}
    end
  end

  def decode(%{target: target, value: wei, data: data}, _fleet), do: {:other, target, wei, data}

  defp contract(target, fleet) do
    cond do
      target == fleet.treasury_address -> :treasury
      target == fleet.votes_address -> :votes
      target == fleet.autolaunch_factory_address -> :autolaunch
      true -> :other
    end
  end

  defp action(contract, selector, bytes, fleet) do
    case {contract, selector} do
      {:treasury, selector} -> treasury_action(selector, bytes)
      {:votes, selector} -> if selector == Call.selector(@edits), do: edits(bytes, fleet), else: :error
      {:autolaunch, selector} -> if selector == launch_selector(), do: launch(bytes), else: :error
      _other -> :error
    end
  end

  defp treasury_action(selector, bytes) do
    cond do
      selector == Call.selector(@pay) ->
        with {:ok, [asset, to, amount]} <- Abi.decode(bytes, [:address, :address, {:uint, 256}]),
             do: {:ok, {:pay, asset, to, amount}}

      selector == Call.selector(@advance) ->
        with {:ok, [id, operator, asset, amount, purpose]} <-
               Abi.decode(bytes, [{:uint, 256}, :address, :address, {:uint, 256}, :bytes32]),
             do: {:ok, {:advance, id, operator, asset, amount, purpose}}

      selector == Call.selector(@rate) ->
        with {:ok, [bps]} <- Abi.decode(bytes, [{:uint, 256}]), do: {:ok, {:rate, bps}}

      selector == Call.selector(@approve_hash) ->
        with {:ok, [hash]} <- Abi.decode(bytes, [:bytes32]),
             do: {:ok, {:signature, :approve, hash}}

      selector == Call.selector(@revoke_hash) ->
        with {:ok, [hash]} <- Abi.decode(bytes, [:bytes32]),
             do: {:ok, {:signature, :revoke, hash}}

      selector == Call.selector(@voted_split) ->
        with {:ok, []} <- Abi.decode(bytes, []), do: {:ok, :voted_split}

      selector == Call.selector(@admit_ousd) ->
        with {:ok, [token]} <- Abi.decode(bytes, [:address]), do: {:ok, {:admit_ousd, token}}

      true ->
        :error
    end
  end

  # A Key of another fleet is no action of this one.
  defp edits(bytes, fleet) do
    with {:ok, [token_id, restricted?]} <- Abi.decode(bytes, [{:uint, 256}, :bool]),
         {:ok, key} <- Fleet.key_number(fleet, token_id) do
      {:ok, {:edits, key, restricted?}}
    else
      _other -> :error
    end
  end

  # The launch's one argument is a tuple with strings in it, so its head is
  # the offset of the tuple, and the tuple is read as its own fields.
  defp launch(<<32::256, tuple::binary>>) do
    with {:ok, [name, symbol, description, website, image, treasury]} <-
           Abi.decode(tuple, [:bytes, :bytes, :bytes, :bytes, :bytes, :address]) do
      {:ok,
       {:launch,
        %{
          name: name,
          symbol: symbol,
          description: description,
          website: website,
          image: image,
          treasury: treasury
        }}}
    end
  end

  defp launch(_bytes), do: :error
end
