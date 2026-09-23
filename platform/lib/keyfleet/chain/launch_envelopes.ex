defmodule KeyFleet.Chain.LaunchEnvelopes do
  @moduledoc """
  Reads the launch each recorded Autolaunch proposal approves.
  `KeyFleet.Chain.Repeat` runs it every few seconds, apart from the reading
  of the fleet's history, so a slow node never holds that up.

  The `AutolaunchProposed` log carries only the envelope's hash, so the vote
  contract's `launchEnvelope` is read at the head for every launch proposal
  still without one. What comes back is kept only when its hash is the
  proposal's envelope hash, so it is the launch the proposal fixed, byte for
  byte, whichever block it is read at. A read that fails keeps nothing and
  is tried again the next time. A stopped fleet's record is waiting for an
  operator, so nothing is added to it. A launch kept is announced where the
  fleet's proposal pages listen.
  """

  require Logger

  alias KeyFleet.Actors.System
  alias KeyFleet.Chain
  alias KeyFleet.Chain.Abi
  alias KeyFleet.Proposals

  # cast sig "launchEnvelope(uint256)"
  @launch_envelope <<0xB3, 0xBC, 0xEA, 0xDB>>
  @texts [:name, :symbol, :description, :website, :image]
  @system %System{}

  @doc "Reads and keeps the launch of each of the fleet's launch proposals without one."
  def read(fleet, client) do
    case Proposals.launches_without_envelope!(fleet.id, actor: @system) do
      [] -> :ok
      proposals -> read_unless_stopped(fleet, proposals, client)
    end
  end

  defp read_unless_stopped(fleet, proposals, client) do
    case Chain.get_cursor!(fleet.id) do
      %{rescan_from: nil} -> read_at_head(fleet, proposals, client)
      _stopped -> :ok
    end
  end

  defp read_at_head(fleet, proposals, client) do
    with {:ok, head} <- client.head() do
      if Enum.any?(Enum.map(proposals, &read_one(fleet, &1, head.hash, client))) do
        Phoenix.PubSub.broadcast(
          KeyFleet.PubSub,
          Proposals.topic(fleet.id),
          {:proposals_changed, fleet.id}
        )
      end

      :ok
    end
  end

  defp read_one(fleet, proposal, block_hash, client) do
    with {:ok, returned} <-
           client.call(
             fleet.votes_address,
             @launch_envelope <> <<proposal.number::256>>,
             block_hash
           ),
         {:ok, envelope} <- decode(returned, proposal.envelope_hash),
         {:ok, _recorded} <-
           envelope
           |> Map.merge(%{fleet_id: fleet.id, proposal_id: proposal.id})
           |> Proposals.record_launch_envelope(actor: @system) do
      true
    else
      failure ->
        Logger.info(
          "Fleet #{fleet.id}: the launch of proposal #{proposal.number} was not read " <>
            "(#{inspect(failure)}); it is tried again shortly."
        )

        false
    end
  end

  # The function returns one dynamic struct: its offset, then the struct.
  # `keccak256(abi.encode(envelope))` is those same bytes.
  defp decode(<<32::256, body::binary>> = returned, envelope_hash) do
    types = List.duplicate(:bytes, 5) ++ [{:uint, 128}, :bytes32, {:uint, 64}]

    with true <- hash(returned) == envelope_hash,
         {:ok, [name, symbol, description, website, image, raise | _digest_and_expiry]} <-
           Abi.decode(body, types) do
      {:ok,
       @texts
       |> Enum.zip([name, symbol, description, website, image])
       |> Map.new()
       |> Map.put(:required_regent_raised, Decimal.new(raise))}
    else
      _other -> {:error, :envelope_not_the_approved_one}
    end
  end

  defp decode(_returned, _envelope_hash), do: {:error, :envelope_not_the_approved_one}

  defp hash(bytes), do: "0x" <> Base.encode16(ExKeccak.hash_256(bytes), case: :lower)
end
