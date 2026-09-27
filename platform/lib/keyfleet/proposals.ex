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
  alias Keyfleet.Treasury
  alias Keyfleet.Treasury.{BudgetPayment, BudgetReceipt, IncomeReceipt}

  @page 20
  @changes_page 50
  # What a proposal is shown with: its tally, the keys sold, its execution and
  # its launch.
  @summary [:yes_keys, :no_keys, :keys_sold, :execution, :launch_envelope]

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
  Where a proposal stands, as far as the fleet's history has been read,
  loaded with `#{inspect(@summary)}`, and the block the fleet's last failed
  launch was created in (`failed_launch_block/1`). A proposal has no
  deadline: it stays open to votes until it is carried out. The first three
  are the contract's own states.

    * `:executed` once its execution is recorded;
    * `:approved` while more than half of all the keys sold have yes as their
      latest vote, so it can be carried out now;
    * `:open` otherwise. A key that has not voted counts against it, and so
      does every key sold later;
    * `:stale`, in place of the other two, for a launch proposal that opened
      in or before the block the fleet's last failed launch was created in,
      which the fleet refuses to carry out.
  """
  def status(%Proposal{} = proposal, failed_launch_block) do
    cond do
      proposal.execution -> :executed
      stale?(proposal, failed_launch_block) -> :stale
      proposal.yes_keys * 2 > proposal.keys_sold -> :approved
      true -> :open
    end
  end

  defp stale?(%Proposal{kind: :autolaunch, opened_block: opened}, failed) when is_integer(failed),
    do: opened <= failed

  defp stale?(_proposal, _failed_launch_block), do: false

  @doc """
  The block the fleet's last failed launch was created in, as its latest
  budget reading says, or nil.
  """
  def failed_launch_block(fleet_id) do
    case Treasury.get_reading!(fleet_id) do
      %{failed_launch_block: block} -> block
      nil -> nil
    end
  end

  @doc "Each asset the fleet's payment proposals name, by address."
  def payment_assets(fleet_id) do
    Proposal
    |> Ash.Query.filter(fleet_id == ^fleet_id and kind == :pay)
    |> assets()
  end

  @doc "Each asset the fleet's payment proposals not yet carried out name, by address."
  def open_payment_assets(fleet_id) do
    Proposal
    |> Ash.Query.filter(fleet_id == ^fleet_id and kind == :pay and not executed?)
    |> assets()
  end

  defp assets(query) do
    query
    |> Ash.Query.distinct(:asset)
    |> Ash.Query.select([:asset])
    |> Ash.read!()
    |> Enum.map(& &1.asset)
    |> Enum.sort()
  end

  @doc "The fleet's proposal `number`, as `status/2` needs it, or nil."
  def get_by_number(fleet_id, number),
    do: get_proposal!(fleet_id, number, load: @summary)

  @doc """
  The fleet's proposals below `before_number` (all of them for nil), newest
  first, #{@page} at most, as `status/2` needs them, and whether older ones remain.
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
  `object_id` by their digest, newest first, `limit` at most, as `status/1`
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
  are read. `items` holds each proposal they touch, as it stands now, with
  `changed_seq`, the last of them that touched it, and in that order.
  `next_cursor` is the last record read, to send as `after_seq` next time;
  `head_seq` the fleet's last record number, and `has_more` whether records
  after `next_cursor` are waiting. Budget records are counted but touch no
  proposal.
  """
  def changes(fleet_id, after_seq) do
    # The head is read first and bounds every query: a record numbered after
    # it may be saved between the queries below, and reading it from one kind
    # but not from another would move the next cursor past the one missed.
    cursor = Chain.get_cursor!(fleet_id)
    head_seq = if(cursor, do: cursor.proposal_seq, else: 0)

    {read, rest} =
      [Proposal, Vote, Execution, LaunchEnvelope, BudgetReceipt, IncomeReceipt, BudgetPayment]
      |> Enum.flat_map(&records_after(&1, fleet_id, after_seq, head_seq))
      |> Enum.sort()
      |> Enum.split(@changes_page)

    changed = for {seq, proposal_id} <- read, proposal_id, into: %{}, do: {proposal_id, seq}
    failed_launch_block = failed_launch_block(fleet_id)

    items =
      Proposal
      |> Ash.Query.filter(id in ^Map.keys(changed))
      |> Ash.Query.load(@summary)
      |> Ash.read!()
      |> Enum.map(
        &%{
          proposal: &1,
          status: status(&1, failed_launch_block),
          changed_seq: Map.fetch!(changed, &1.id)
        }
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
