# Property tests on Keyfleet's real agent sign-in and pairing checks
# (platform/lib/keyfleet/actors/agent.ex), with the pairing table replaced by
# a stand-in each case sets. No database, no network once StreamData is
# fetched.
#
#   elixir agent_properties.exs <keyfleet platform folder>
#
# What the models in verification/formal take from this file, checked here:
#   - Counts in PairingLife and ActionGuards: authenticated?/1 admits a plain
#     wallet on Ethereum or Base and a smart wallet only on Base.
#   - Recheck in PairingLife: refresh/1 and valid?/1 admit only the same
#     pairing episode and the same person; an agent with no pairing gets
#     nothing, without the pairing table being read.

Mix.install([{:stream_data, "~> 1.4"}])

platform =
  case System.argv() do
    [platform] -> platform
    _ -> raise ArgumentError, "usage: elixir agent_properties.exs <keyfleet platform folder>"
  end

# The pairing table as each case sets it.
defmodule Keyfleet.Agents do
  def with_pairing(agent) do
    Process.put(:pairing_read, true)
    Process.get(:pairing_now).(agent)
  end
end

defmodule RegentAgents.Authority do
  def resolve(Keyfleet.Repo, wallet) do
    Process.put(:pairing_read, true)
    Process.get(:resolve_now).(wallet)
  end
end

# The real module derives Inspect after Elixir's own protocols are built.
Code.put_compiler_option(:ignore_already_consolidated, true)
Code.require_file(Path.join(platform, "lib/keyfleet/actors/agent.ex"))

ExUnit.start(seed: String.to_integer(System.get_env("SEED", "0")))

defmodule Keyfleet.AgentPropertiesTest do
  use ExUnit.Case
  use ExUnitProperties

  alias Keyfleet.Actors.Agent

  @smart [:erc1271, :erc6492, :connected_app]
  @methods [:eoa_recovery | @smart]

  defp hex(n), do: StreamData.string(Enum.concat([?0..?9, ?a..?f]), length: n)

  defp wallet do
    StreamData.frequency([
      {6, StreamData.map(hex(40), &("0x" <> &1))},
      {1, StreamData.map(hex(40), &("0x" <> String.upcase(&1)))},
      {1, StreamData.map(hex(39), &("0x" <> &1))},
      {1, StreamData.map(hex(42), &("0x" <> &1))},
      {1, StreamData.string(:ascii, max_length: 44)}
    ])
  end

  defp agent do
    gen all wallet <- wallet(),
            chain_id <- StreamData.frequency([{6, StreamData.member_of([1, 8453])}, {1, StreamData.integer()}]),
            method <-
              StreamData.frequency([{6, StreamData.member_of(@methods)}, {1, StreamData.atom(:alphanumeric)}]),
            audience <- StreamData.frequency([{6, StreamData.constant("keyfleet")}, {1, StreamData.member_of(["keyfleet ", "patchbay", ""])}]),
            pairing_id <- StreamData.member_of([nil, "episode-1", "episode-2"]),
            owner <- StreamData.member_of([nil, "person-a", "person-b"]) do
      %Agent{
        wallet_address: wallet,
        chain_id: chain_id,
        verification_method: method,
        audience: audience,
        pairing_id: pairing_id,
        privy_user_id: owner
      }
    end
  end

  # What the pairing table holds for the wallet when the check runs.
  defp pairing_now do
    StreamData.one_of([
      StreamData.constant(:none),
      StreamData.tuple({StreamData.member_of(["episode-1", "episode-2", "episode-3"]),
                        StreamData.member_of(["person-a", "person-b"])})
    ])
  end

  defp counts?(%Agent{} = a) do
    a.audience == "keyfleet" and is_binary(a.wallet_address) and
      Regex.match?(~r/\A0x[0-9a-f]{40}\z/, a.wallet_address) and
      ((a.verification_method == :eoa_recovery and a.chain_id in [1, 8453]) or
         (a.verification_method in @smart and a.chain_id == 8453))
  end

  defp same_episode?(%Agent{pairing_id: id, privy_user_id: owner}, {id, owner})
       when is_binary(id) and is_binary(owner),
       do: true

  defp same_episode?(_agent, _now), do: false

  defp set_pairing(now) do
    Process.delete(:pairing_read)

    Process.put(:pairing_now, fn agent ->
      case now do
        :none -> {:error, :not_paired}
        {id, owner} -> {:ok, %{agent | pairing_id: id, privy_user_id: owner}}
      end
    end)

    Process.put(:resolve_now, fn _wallet ->
      case now do
        :none -> {:error, :not_paired}
        {id, owner} -> {:ok, %{id: id, privy_user_id: owner}}
      end
    end)
  end

  property "a wallet counts exactly when it is a plain wallet on Ethereum or Base, or a smart wallet on Base" do
    check all a <- agent(), max_runs: 5_000 do
      assert Agent.authenticated?(a) == counts?(a)
    end
  end

  property "a smart wallet never counts on Ethereum" do
    check all a <- agent(), method <- StreamData.member_of(@smart), max_runs: 2_000 do
      refute Agent.authenticated?(%{a | verification_method: method, chain_id: 1})
    end
  end

  property "an agent with no pairing gets nothing and the pairing table is not read" do
    check all a <- agent(), now <- pairing_now(),
              missing <- StreamData.member_of([[:pairing_id], [:privy_user_id], [:pairing_id, :privy_user_id]]),
              max_runs: 2_000 do
      a = Enum.reduce(missing, a, &Map.put(&2, &1, nil))
      set_pairing(now)
      assert Agent.refresh(a) == {:error, :not_paired}
      refute Agent.valid?(a)
      refute Process.get(:pairing_read)
    end
  end

  property "refresh admits only the same pairing episode and the same person" do
    check all a <- agent(), now <- pairing_now(), max_runs: 5_000 do
      set_pairing(now)

      case Agent.refresh(a) do
        {:ok, current} ->
          assert counts?(a) and same_episode?(a, now)
          assert {current.pairing_id, current.privy_user_id} == now

        {:error, :not_paired} ->
          refute counts?(a) and same_episode?(a, now)
      end
    end
  end

  property "valid? holds only for the same pairing episode and the same person" do
    check all a <- agent(), now <- pairing_now(), max_runs: 5_000 do
      set_pairing(now)
      assert Agent.valid?(a) == (counts?(a) and same_episode?(a, now))
    end
  end
end
