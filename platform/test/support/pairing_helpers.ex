defmodule Keyfleet.PairingHelpers do
  @moduledoc """
  An agent paired with a person the way regents.sh pairs them: the person's
  account issues a code and the agent's wallet redeems it. The agent comes
  back as a signed request makes it, with its pairing.
  """

  alias Keyfleet.Accounts
  alias Keyfleet.Actors.Agent
  alias Keyfleet.Actors.Human
  alias Keyfleet.Actors.System

  @doc """
  Pairs `agent` with the person whose account links `wallets`, making that
  account first: the person's Privy user is named for their first wallet.
  """
  def pair!(%Agent{wallet_address: agent_wallet} = agent, [first | _] = wallets) do
    person = "did:privy:test-" <> first
    Accounts.register_verified!(person, first, wallets, actor: %System{})

    %{code: code} =
      RegentAgents.issue_pairing_code!(actor: %RegentAgents.Person{privy_user_id: person})

    RegentAgents.pair_agent!(code, "Test agent", :codex,
      actor: %RegentAgents.Agent{wallet: agent_wallet}
    )

    {:ok, paired} = Keyfleet.Agents.with_pairing(agent)
    paired
  end

  @doc """
  Pairs the agent that signs as `wallet` with a person of its own, the way a
  signed request finds it.
  """
  def pair_wallet!(wallet) do
    person = "0x" <> Base.encode16(:crypto.strong_rand_bytes(20), case: :lower)

    pair!(
      %Agent{
        wallet_address: wallet,
        chain_id: 8453,
        verification_method: :eoa_recovery,
        audience: "keyfleet"
      },
      [person]
    )
  end

  @doc """
  An agent paired with `person`, with a profile of its own, so it writes in a
  fleet's rooms as the person's Key. Its wallet is made from the person's
  first wallet, so the same person always has the same agent: paired the
  first time it is asked for, and the one already paired after that.
  """
  def agent_for!(%Human{wallet_addresses: [first | _] = wallets}) do
    wallet = "0x" <> binary_part(Base.encode16(:crypto.hash(:sha256, first), case: :lower), 0, 40)

    unpaired = %Agent{
      wallet_address: wallet,
      chain_id: 8453,
      verification_method: :eoa_recovery,
      audience: "keyfleet"
    }

    agent =
      case Keyfleet.Agents.with_pairing(unpaired) do
        {:ok, paired} -> paired
        {:error, :not_paired} -> pair!(unpaired, wallets)
      end

    Keyfleet.Agents.ensure_profile!(%{name: "Their agent", declared_harness: "test"},
      actor: agent
    )

    agent
  end
end
