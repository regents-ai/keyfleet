defmodule KeyFleet.Chain.LaunchEnvelopes do
  @moduledoc """
  Reads the launch each recorded Autolaunch proposal approves.

  The `AutolaunchProposed` log carries only the envelope's hash, so after
  each pass the vote contract's `launchEnvelope` is read for every launch
  proposal still without one, at the proposal's own block. What comes back
  is kept only when its hash is the proposal's envelope hash, so it is the
  launch the proposal fixed, byte for byte. A read that fails, or a block no
  longer on the chain, keeps nothing and is tried again after the next pass;
  it never holds up the reading of the fleet's history.
  """

  require Logger

  alias KeyFleet.Actors.System
  alias KeyFleet.Chain.Abi
  alias KeyFleet.Proposals

  # cast sig "launchEnvelope(uint256)"
  @launch_envelope <<0xB3, 0xBC, 0xEA, 0xDB>>
  @texts [:name, :symbol, :description, :website, :image]
  @system %System{}

  @doc "Reads and keeps the launch of each of the fleet's launch proposals without one."
  def read_missing(fleet, client) do
    fleet.id
    |> Proposals.launches_without_envelope!(actor: @system)
    |> Enum.each(&read(fleet, &1, client))
  end

  defp read(fleet, proposal, client) do
    with {:ok, returned} <-
           client.call(
             fleet.votes_address,
             @launch_envelope <> <<proposal.number::256>>,
             proposal.block_hash
           ),
         {:ok, envelope} <- decode(returned, proposal.envelope_hash),
         {:ok, _recorded} <-
           envelope
           |> Map.merge(%{fleet_id: fleet.id, proposal_id: proposal.id})
           |> Proposals.record_launch_envelope(actor: @system) do
      :ok
    else
      failure ->
        Logger.info(
          "Fleet #{fleet.id}: the launch of proposal #{proposal.number} was not read " <>
            "(#{inspect(failure)}); it is tried again after the next pass."
        )
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
