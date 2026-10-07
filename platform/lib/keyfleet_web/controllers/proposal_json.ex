defmodule KeyfleetWeb.ProposalJSON do
  @moduledoc """
  Proposals as the agent API answers them. Amounts the contracts hold as any
  uint are decimal strings, and times are ISO 8601 in UTC. A proposal's text
  is kept off the chain; `content_hash` is its hash.
  """

  @doc "One proposal as a sync lists it."
  def summary(%{proposal: proposal, status: status, changed_seq: changed_seq}),
    do: proposal |> detail(status) |> Map.put(:changed_seq, changed_seq)

  @doc "One proposal as `proposals/read` answers it."
  def detail(proposal, status) do
    %{
      number: proposal.number,
      status: status,
      author_key: proposal.author_key,
      proposer: proposal.proposer,
      proposal_hash: proposal.proposal_hash,
      content_hash: proposal.content_hash,
      opened_at: proposal.opened_at,
      closes_at: proposal.closes_at,
      execution_expiry: proposal.execution_expiry,
      opening_count: proposal.opening_count,
      late_votes: proposal.late_keys,
      yes_votes: proposal.yes_keys,
      no_votes: proposal.no_keys,
      abstain_votes: proposal.abstain_keys,
      calls: Enum.map(proposal.calls, &call/1),
      executed: executed(proposal.execution),
      cancelled: cancelled(proposal.cancellation),
      transaction_hash: proposal.transaction_hash,
      block_number: proposal.block_number
    }
  end

  @doc "One vote: every key is one vote."
  def vote(vote) do
    %{
      voter: vote.voter,
      choice: vote.choice,
      votes: vote.key_count,
      keys: vote.token_ids,
      transaction_hash: vote.transaction_hash,
      block_number: vote.block_number,
      seq: vote.record_seq
    }
  end

  defp call(call),
    do: %{target: call.target, value: Integer.to_string(call.value), data: call.data}

  defp executed(nil), do: nil

  defp executed(execution) do
    %{
      executor: execution.executor,
      transaction_hash: execution.transaction_hash,
      block_number: execution.block_number
    }
  end

  defp cancelled(nil), do: nil

  defp cancelled(cancellation) do
    %{
      cancelled_by: cancellation.cancelled_by,
      transaction_hash: cancellation.transaction_hash,
      block_number: cancellation.block_number
    }
  end
end
