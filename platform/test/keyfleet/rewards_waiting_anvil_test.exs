defmodule Keyfleet.RewardsWaitingAnvilTest do
  # A Key's rewards waiting read from a real node: a local anvil, never a real
  # network, with Classic #1 as `AnvilLab.s.sol` puts it there, whose buyer
  # holds its Keys 1 and 2.
  use ExUnit.Case, async: false

  alias Keyfleet.AnvilLab
  alias Keyfleet.Chain.{RewardsWaiting, RpcClient}
  alias Keyfleet.Fleets.Fleet

  @moduletag :external
  @moduletag timeout: 600_000

  @contracts Path.expand("../../../contracts", __DIR__)
  @buyer "0x70997970C51812dc3A010C7d01b50e0d17dc79C8"
  @accrued "accrued(address,uint256)(uint256)"
  @credits "credits(address,address)(uint256)"

  setup do
    :ets.delete_all_objects(RewardsWaiting)
    url = AnvilLab.start!()
    %{manager: manager} = AnvilLab.lab!(url, @buyer)
    %{url: url, manager: manager}
  end

  test "a Key's rewards are what the ledger says it has accrued and its holder has in credit",
       %{url: url, manager: manager} do
    rewards = cast_call!(url, manager, "REWARDS()(address)")
    usdc = cast_call!(url, manager, "USDC()(address)")

    shown = %{
      fleet_id: "fleet_tech_classic",
      chain_fleet_id: 1,
      rewards_address: String.downcase(rewards)
    }

    cohort = cast_call!(url, rewards, "keyCohort(uint256)(uint256)", [token_id(shown, 1)])

    # The manager alone hands rewards to a cohort, so anvil sends as the
    # manager. An odd amount leaves a remainder the division must drop.
    cast_send!(url, @buyer, usdc, "mint(address,uint256)", [rewards, "5000001"])
    AnvilLab.rpc!(url, "anvil_impersonateAccount", [manager])
    AnvilLab.rpc!(url, "anvil_setBalance", [manager, "0xde0b6b3a7640000"])

    cast_send!(url, manager, rewards, "allocateToCohort(address,uint256,uint256)", [
      usdc,
      cohort,
      "5000001"
    ])

    asset = String.downcase(usdc)
    credit = String.to_integer(cast_call!(url, rewards, @credits, [usdc, @buyer]))

    for token_id <- [1, 2] do
      assert {:ok, [%{asset: ^asset, accrued: 2_500_000, credit: ^credit}]} =
               RewardsWaiting.read(shown, token_id, String.downcase(@buyer), RpcClient)

      assert cast_call!(url, rewards, @accrued, [usdc, token_id(shown, token_id)]) == "2500000"
    end
  end

  defp token_id(fleet, key_number), do: "#{Fleet.onchain_token_id(fleet, key_number)}"

  defp cast_call!(url, to, signature, args \\ []) do
    cast!(["call", to, signature] ++ args ++ ["--rpc-url", url])
  end

  defp cast_send!(url, from, to, signature, args) do
    cast!(["send", to, signature] ++ args ++ ["--rpc-url", url, "--unlocked", "--from", from])
  end

  # `cast` prints a number with its scientific form after it, so only the
  # first word is kept.
  defp cast!(args) do
    {output, status} = System.cmd("cast", args, cd: @contracts, stderr_to_stdout: true)
    assert status == 0, "cast #{hd(args)} failed:\n#{output}"
    output |> String.split() |> hd()
  end
end
