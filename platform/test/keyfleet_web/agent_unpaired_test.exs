defmodule KeyfleetWeb.AgentUnpairedTest do
  @moduledoc """
  An agent whose request was read while it was paired, and whose person
  unpaired it before the write saved, is told it is no longer paired.
  """
  use ExUnit.Case, async: false

  alias Keyfleet.{Actors, ChainHelpers, Fleets, Keys, PairingHelpers, Proposals, Repo}
  alias KeyfleetWeb.AgentTools.Fleets.Answer, as: FleetsAnswer
  alias KeyfleetWeb.AgentTools.Keys.Answer, as: KeysAnswer
  alias KeyfleetWeb.Refusal

  @fleet "fibonacci_syndicate"
  @person "0x" <> String.duplicate("a", 40)

  setup do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    Fleets.bootstrap_catalog!()
    ChainHelpers.seed_cursor!(@fleet)

    Keys.record_epoch!(
      %{
        fleet_id: @fleet,
        token_id: 25,
        ownership_epoch: 1,
        owner_wallet: @person,
        block_number: 10,
        block_hash: "0x" <> String.duplicate("a", 64),
        transaction_hash: "0x" <> String.duplicate("c", 64),
        log_index: 0
      },
      actor: %Actors.System{}
    )

    agent =
      PairingHelpers.agent_for!(%Actors.Human{human_account_id: 0, wallet_addresses: [@person]})

    person = %RegentAgents.Person{privy_user_id: agent.privy_user_id}
    {:ok, agents} = RegentAgents.list_my_agents(actor: person)
    paired = Enum.find(agents, &(&1.wallet == agent.wallet_address))
    :ok = RegentAgents.unpair_agent(paired, actor: person)

    %{agent: agent}
  end

  test "choosing the Key its person posts as", %{agent: agent} do
    assert KeysAnswer.answer(:post_as, %{"fleet_id" => @fleet, "token_id" => 25}, agent, nil) ==
             {403, Refusal.body("agent_not_paired"), nil}
  end

  test "saving its checkpoint", %{agent: agent} do
    params = %{"fleet_id" => @fleet, "expected_revision" => 0, "state" => %{"step" => 1}}

    assert FleetsAnswer.answer(:save_checkpoint, params, agent, nil) ==
             {403, Refusal.body("agent_not_paired"), nil}
  end

  # The words' policy refuses the unpaired agent before the pairing lock is
  # reached; the proposal route answers that refusal `agent_not_paired`.
  test "saving the words of a proposal", %{agent: agent} do
    assert {:error, %Ash.Error.Forbidden{}} =
             Proposals.save_words(@fleet, "Fund the next sprint.", agent)
  end
end
