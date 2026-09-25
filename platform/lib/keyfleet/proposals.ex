defmodule Keyfleet.Proposals do
  @moduledoc """
  A fleet's proposals, the votes cast on them, their executions and the
  launches they approve, recorded from its vote contract by the chain reader
  and by nothing else. The chain is the authority; these records only mirror
  it. Anyone may read them.
  """
  use Ash.Domain

  require Ash.Query

  alias Keyfleet.Actors.System
  alias Keyfleet.Chain
  alias Keyfleet.Proposals.{Execution, LaunchEnvelope, Proposal, Vote}
  alias Keyfleet.Treasury.{BudgetPayment, BudgetReceipt, IncomeSplit}

  @page 20
  @changes_page 50
  # What a proposal is shown with: its tally, its execution and its launch,
  # and whether its fleet's launch has gone ahead.
  @summary [:yes_keys, :no_keys, :execution, :launch_envelope, :fleet_launched?]

  resources do
    resource Keyfleet.Proposals.Proposal do
      define :record_proposal, action: :record
      define :get_proposal, action: :read, get_by: [:fleet_id, :number], not_found_error?: false

      define :latest_proposal,
        action: :latest_in_fleet,
        args: [:fleet_id],
        not_found_error?: false

      define :proposals_recorded_in_blocks,
        action: :recorded_in_blocks,
        args: [:fleet_id, :from_block, :to_block]

      define :launches_without_envelope, action: :launches_without_envelope, args: [:fleet_id]

      define :proposals_recorded_before,
        action: :recorded_before,
        args: [:fleet_id, :before_seq, :limit]

      define :proposals_closed_before,
        action: :closed_before,
        args: [:fleet_id, :before_at, :before_number, :limit]
    end

    resource Keyfleet.Proposals.LaunchEnvelope do
      define :record_launch_envelope, action: :record
    end

    resource Keyfleet.Proposals.Vote do
      define :record_vote, action: :record

      define :votes_recorded_in_blocks,
        action: :recorded_in_blocks,
        args: [:fleet_id, :from_block, :to_block]

      define :votes_recorded_before,
        action: :recorded_before,
        args: [:fleet_id, :before_seq, :limit]
    end

    resource Keyfleet.Proposals.Execution do
      define :record_execution, action: :record

      define :executions_recorded_in_blocks,
        action: :recorded_in_blocks,
        args: [:fleet_id, :from_block, :to_block]

      define :executions_recorded_before,
        action: :recorded_before,
        args: [:fleet_id, :before_seq, :limit]
    end
  end

  @doc "Where the reader says a fleet's proposal records may have changed."
  def topic(fleet_id), do: "fleet:#{fleet_id}:proposals"

  @doc """
  Where a proposal stands at `now`, as far as the fleet's history has been
  read (`cursor`, or nil before any reading), loaded with `#{inspect(@summary)}`:

    * `:executed` once its execution is recorded;
    * `:voting` before it closes;
    * `:counting` after it closes, until the reading has passed its closing
      time, since a vote cast before then may not have been read yet;
    * `:failed` unless more than half of the keys that could vote on it voted
      yes: exactly half fails, and a key that did not vote counts against it;
    * `:closed` for a launch that passed after another launch of the fleet
      was carried out, since the fleet contract refuses a second launch;
    * `:expired` for a payment or a launch that passed and is past the last
      second it could be carried out;
    * `:passed` otherwise.
  """
  def status(%Proposal{} = proposal, cursor, %DateTime{} = now) do
    cond do
      proposal.execution -> :executed
      DateTime.before?(now, proposal.closes_at) -> :voting
      not read_past?(cursor, proposal.closes_at) -> :counting
      true -> outcome(proposal, now)
    end
  end

  # Where a proposal stands once every vote on it has been read.
  defp outcome(proposal, now) do
    cond do
      proposal.yes_keys * 2 <= proposal.eligible_keys -> :failed
      proposal.kind == :autolaunch and proposal.fleet_launched? -> :closed
      proposal.kind != :decision and expired?(proposal, now) -> :expired
      true -> :passed
    end
  end

  defp read_past?(%{read_through_at: %DateTime{} = read_through_at}, closes_at),
    do: not DateTime.before?(read_through_at, closes_at)

  defp read_past?(_cursor, _closes_at), do: false

  defp expired?(proposal, now),
    do: Decimal.gt?(DateTime.to_unix(now), proposal.execution_expiry)

  @doc "Each asset the fleet's payment proposals name, by address."
  def payment_assets(fleet_id) do
    Proposal
    |> Ash.Query.filter(fleet_id == ^fleet_id and kind == :pay)
    |> Ash.Query.distinct(:asset)
    |> Ash.Query.select([:asset])
    |> Ash.read!()
    |> Enum.map(& &1.asset)
    |> Enum.sort()
  end

  @doc "The fleet's proposal `number`, as `status/3` needs it, or nil."
  def get_by_number(fleet_id, number),
    do: get_proposal!(fleet_id, number, load: @summary)

  @doc """
  The fleet's proposals below `before_number` (all of them for nil), newest
  first, #{@page} at most, as `status/3` needs them, and whether older ones remain.
  """
  def list_page(fleet_id, before_number \\ nil) do
    Proposal
    |> Ash.Query.filter(fleet_id == ^fleet_id)
    |> below(before_number)
    |> Ash.Query.sort(number: :desc)
    |> Ash.Query.limit(@page + 1)
    |> Ash.Query.load(@summary)
    |> Ash.read!()
    |> Enum.split(@page)
    |> then(fn {proposals, older} -> {proposals, older != []} end)
  end

  @doc """
  The fleet's launch proposals that point to a version of its launch plan
  `object_id` by their digest, newest first, `limit` at most, as `status/3`
  needs them, and whether older ones remain.
  """
  def launches_of_plan(fleet_id, object_id, limit) do
    Proposal
    |> Ash.Query.filter(
      fleet_id == ^fleet_id and kind == :autolaunch and
        exists(
          Keyfleet.Graph.LaunchPlanRevision,
          fleet_id == parent(fleet_id) and digest == parent(digest) and object_id == ^object_id
        )
    )
    |> Ash.Query.sort(number: :desc)
    |> Ash.Query.limit(limit + 1)
    |> Ash.Query.load(@summary)
    |> Ash.read!()
    |> Enum.split(limit)
    |> then(fn {proposals, older} -> {proposals, older != []} end)
  end

  defp below(query, nil), do: query
  defp below(query, number), do: Ash.Query.filter(query, number < ^number)

  @doc """
  The votes on a proposal after its record number `after_seq`, oldest first,
  `limit` at most, and whether more remain.
  """
  def votes_after(proposal_id, after_seq, limit) do
    Vote
    |> Ash.Query.filter(proposal_id == ^proposal_id and record_seq > ^after_seq)
    |> Ash.Query.sort(record_seq: :asc)
    |> Ash.Query.limit(limit + 1)
    |> Ash.Query.load(:key_count)
    |> Ash.read!()
    |> Enum.split(limit)
    |> then(fn {votes, rest} -> {votes, rest != []} end)
  end

  @doc """
  What changed in the fleet's proposals after its record number `after_seq`.

  The first #{@changes_page} records after it, of every kind the reader numbers,
  are read. `items` holds each proposal they touch, as it stands at `now`, with
  `changed_seq`, the last of them that touched it, and in that order.
  `next_cursor` is the last record read, to send as `after_seq` next time;
  `head_seq` the fleet's last record number, and `has_more` whether records
  after `next_cursor` are waiting. Budget records are counted but touch no
  proposal.
  """
  def changes(fleet_id, after_seq, %DateTime{} = now) do
    # The head is read first and bounds every query: a record numbered after
    # it may be saved between the queries below, and reading it from one kind
    # but not from another would move the next cursor past the one missed.
    cursor = Chain.get_cursor!(fleet_id)
    head_seq = if(cursor, do: cursor.proposal_seq, else: 0)

    {read, rest} =
      [Proposal, Vote, Execution, LaunchEnvelope, BudgetReceipt, IncomeSplit, BudgetPayment]
      |> Enum.flat_map(&records_after(&1, fleet_id, after_seq, head_seq))
      |> Enum.sort()
      |> Enum.split(@changes_page)

    changed = for {seq, proposal_id} <- read, proposal_id, into: %{}, do: {proposal_id, seq}

    items =
      Proposal
      |> Ash.Query.filter(id in ^Map.keys(changed))
      |> Ash.Query.load(@summary)
      |> Ash.read!()
      |> Enum.map(
        &%{proposal: &1, status: status(&1, cursor, now), changed_seq: Map.fetch!(changed, &1.id)}
      )
      |> Enum.sort_by(& &1.changed_seq)

    %{
      items: items,
      next_cursor: read |> List.last({after_seq, nil}) |> elem(0),
      head_seq: head_seq,
      has_more: rest != []
    }
  end

  defp records_after(resource, fleet_id, after_seq, head_seq) do
    fields = Enum.filter([:record_seq, :proposal_id], &Ash.Resource.Info.attribute(resource, &1))

    resource
    |> Ash.Query.filter(
      fleet_id == ^fleet_id and record_seq > ^after_seq and record_seq <= ^head_seq
    )
    |> Ash.Query.sort(record_seq: :asc)
    |> Ash.Query.limit(@changes_page + 1)
    |> Ash.Query.select(fields)
    |> Ash.read!()
    |> Enum.map(&{&1.record_seq, proposal_of(&1)})
  end

  defp proposal_of(%Proposal{id: id}), do: id
  defp proposal_of(%{proposal_id: id}), do: id
  defp proposal_of(_budget_record), do: nil

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
