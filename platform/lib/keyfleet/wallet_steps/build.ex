defmodule Keyfleet.WalletSteps.Build do
  @moduledoc """
  Builds the steps one wallet button group sends, for one signer, as a
  `RegentChain.Review`: every step's contract and calldata, encoded here and
  never in a page.

  The answer is `%{review: review, figures: figures, problem: problem}`.
  `figures` are what the steps were built from, for the page to show beside
  the buttons. When what was typed can't be put into a call, or the chain
  can't be read, the review has no steps and `problem` names why; otherwise
  `problem` is nil.

  `figures.blocked` names each step the chain's own state, read at the latest
  block, makes certain to fail, with why: `%{"claim-0x…" => :nothing_to_claim}`.
  Its button stays in view, can't be pressed, says why in a few words, and
  comes back when a later build no longer names it. Every flow's transactions
  are also named `:no_eth_for_gas` here, in one place, when the signer pays
  its own network fee and holds less ETH than any transaction costs
  (`Keyfleet.WalletSteps.Reads.short_of_gas?/2`). Nothing else holds a press
  back: a pending transaction, a repeat press, or one that only might be
  refused always reaches the wallet, and the contract decides.

  Each group's steps are built by one of `Keyfleet.WalletSteps.KeySteps`,
  `Keyfleet.WalletSteps.VoteSteps`, `Keyfleet.WalletSteps.MoneySteps` and
  `Keyfleet.WalletSteps.LaunchSteps`, each of which answers `{:ok, steps,
  figures}`, `{:ok, steps, figures, problem}` or `{:problem, problem,
  figures}`. Key sales need a fleet the site has recorded as deployed, which
  is how they stay off: no fleet is recorded on Base yet.
  """
  use Ash.Resource.Actions.Implementation

  alias Keyfleet.Fleets
  alias Keyfleet.Keys
  alias Keyfleet.WalletSteps
  alias Keyfleet.WalletSteps.{KeySteps, LaunchSteps, MoneySteps, Reads, VoteSteps}
  alias RegentChain.Review

  @builders %{
    buy: KeySteps,
    reveal: KeySteps,
    claim: KeySteps,
    claim_all: KeySteps,
    club_claim: KeySteps,
    present: KeySteps,
    issue_shard: KeySteps,
    end_shard: KeySteps,
    agent_voting: KeySteps,
    ballot: VoteSteps,
    propose: VoteSteps,
    cancel: VoteSteps,
    carry_out: VoteSteps,
    run_split: MoneySteps,
    return_advance: MoneySteps,
    send_share: MoneySteps,
    convert: MoneySteps,
    launch_upkeep: LaunchSteps
  }

  @doc "Every group of wallet buttons the site builds steps for."
  def flows, do: Map.keys(@builders)

  @impl true
  def run(input, _opts, _context) do
    %{signer: signer, component_id: component_id} = input.arguments

    with {:ok, request, built} <- build(input.arguments, String.downcase(signer)) do
      {:ok,
       %{
         review:
           Review.new(component_id, request.signer, request.chain, built.steps, request.inputs),
         figures: built.figures,
         problem: built.problem
       }}
    end
  end

  @doc """
  The steps `arguments` name, built for `signer`, or for nil, a visitor, who
  acts for no key: `{:ok, request, %{steps, figures, problem}}`.
  """
  def build(arguments, signer) do
    with {:ok, fleet} <- deployed(arguments.fleet_id),
         {:ok, chain} <- chain(fleet.chain_id) do
      request = %{
        fleet: fleet,
        chain: chain,
        signer: signer,
        inputs: Map.get(arguments, :inputs, %{}),
        proposal: Map.get(arguments, :proposal),
        token_id: Map.get(arguments, :token_id),
        advance_id: Map.get(arguments, :advance_id)
      }

      {steps, figures, problem} =
        case Map.fetch!(@builders, arguments.flow).steps(arguments.flow, request) do
          {:ok, steps, figures} -> {steps, figures, nil}
          {:ok, steps, figures, problem} -> {steps, figures, problem}
          {:problem, problem, figures} -> {[], figures, problem}
        end

      figures = no_eth_for_gas(steps, signer, Map.put_new(figures, :blocked, %{}))
      {:ok, request, %{steps: steps, figures: figures, problem: problem}}
    end
  end

  # A signer that pays its own fee with less ETH than any transaction costs
  # can send none of the group's transactions. A signature costs nothing, and
  # a code or balance the chain didn't answer holds nothing back.
  defp no_eth_for_gas(_steps, nil, figures), do: figures

  defp no_eth_for_gas(steps, signer, figures) do
    case for(%{kind: "transaction", step: name} <- steps, do: name) do
      [] -> figures
      sent -> block_if_short(sent, signer, figures)
    end
  end

  defp block_if_short(sent, signer, figures) do
    with {:ok, reads} <- Reads.at_head(),
         {:ok, true} <- Reads.short_of_gas?(reads, signer) do
      %{figures | blocked: Map.merge(figures.blocked, Map.new(sent, &{&1, :no_eth_for_gas}))}
    else
      _not_known_short -> figures
    end
  end

  defp deployed(fleet_id) do
    case Fleets.get_fleet!(fleet_id) do
      %{manager_address: address} = fleet when is_binary(address) -> {:ok, fleet}
      _missing_or_not_on_chain -> {:error, "fleet #{fleet_id} is not on chain"}
    end
  end

  defp chain(chain_id) do
    case WalletSteps.chain(chain_id) do
      nil -> {:error, "no wallet chain is set for chain #{chain_id}"}
      chain -> {:ok, chain}
    end
  end

  @doc """
  A field of the form as typed, read by `read`; a problem with it ends the
  build with `figures` so far.
  """
  def typed(inputs, name, read, figures) do
    case read.(field(inputs, name)) do
      {:ok, value} -> {:ok, value}
      {:error, problem} -> {:problem, problem, figures}
    end
  end

  @doc "A field of the form as typed, or empty."
  def field(inputs, name), do: Map.get(inputs, name, "")

  @doc """
  Every key the signer holds in the fleet, and every key it holds an active
  shard of, as the chain reader recorded them; the chain is then asked which
  of them the signer may act for.
  """
  def own_keys(fleet, signer) do
    held = fleet.id |> Keys.keys_held_in_fleet!([signer]) |> Enum.map(& &1.token_id)

    sharded =
      for shard <- Keys.active_shards_held_by!(signer),
          shard.fleet_id == fleet.id,
          do: shard.token_id

    Enum.sort(Enum.uniq(held ++ sharded))
  end
end
