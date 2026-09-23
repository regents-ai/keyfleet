defmodule KeyFleet.Proposals do
  @moduledoc """
  A fleet's proposals, the votes cast on them and their executions, recorded
  from its vote contract by the chain reader and by nothing else. The chain is
  the authority; these records only mirror it.
  """
  use Ash.Domain

  alias KeyFleet.Actors.System

  resources do
    resource KeyFleet.Proposals.Proposal do
      define :record_proposal, action: :record
      define :get_proposal, action: :read, get_by: [:fleet_id, :number], not_found_error?: false

      define :latest_proposal,
        action: :latest_in_fleet,
        args: [:fleet_id],
        not_found_error?: false

      define :proposals_recorded_in_blocks,
        action: :recorded_in_blocks,
        args: [:fleet_id, :from_block, :to_block]
    end

    resource KeyFleet.Proposals.Vote do
      define :record_vote, action: :record

      define :votes_recorded_in_blocks,
        action: :recorded_in_blocks,
        args: [:fleet_id, :from_block, :to_block]
    end

    resource KeyFleet.Proposals.Execution do
      define :record_execution, action: :record

      define :executions_recorded_in_blocks,
        action: :recorded_in_blocks,
        args: [:fleet_id, :from_block, :to_block]
    end
  end

  @doc "Where the reader says a fleet's proposal records may have changed."
  def topic(fleet_id), do: "fleet:#{fleet_id}:proposals"

  @doc "The fleet's highest proposal number recorded so far, or 0."
  def highest_number!(fleet_id) do
    case latest_proposal!(fleet_id) do
      nil -> 0
      latest -> latest.number
    end
  end

  @doc """
  Every proposal, vote and execution recorded from blocks `from..to` of the
  fleet, so a second reading of them can be checked against the record.
  """
  def recorded_in_blocks!(fleet_id, from, to) do
    Enum.flat_map(
      [
        &proposals_recorded_in_blocks!/4,
        &votes_recorded_in_blocks!/4,
        &executions_recorded_in_blocks!/4
      ],
      & &1.(fleet_id, from, to, actor: %System{})
    )
  end
end
