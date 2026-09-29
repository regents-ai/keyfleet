defmodule KeyfleetWeb.ProposalJSON do
  @moduledoc """
  Proposals as the agent API answers them. Amounts and times the contracts
  hold as any uint are decimal strings. Text the chain holds as bytes is
  answered as text, with any bytes that are not valid text replaced.
  """

  @preview_chars 500

  @doc "One proposal as a sync lists it."
  def summary(%{proposal: proposal, status: status, changed_seq: changed_seq}) do
    proposal
    |> common(status)
    |> Map.merge(%{
      text_preview: proposal.text |> as_text() |> String.slice(0, @preview_chars),
      changed_seq: changed_seq
    })
  end

  @doc "One proposal as `proposals/read` answers it, with its whole recorded text."
  def detail(proposal, status) do
    proposal
    |> common(status)
    |> Map.merge(%{
      text: as_text(proposal.text),
      text_sha256: proposal.text_sha256
    })
  end

  @doc "One vote: every key is one vote."
  def vote(vote) do
    %{
      voter: vote.voter,
      support: vote.support,
      votes: vote.key_count,
      keys: vote.token_ids,
      transaction_hash: vote.transaction_hash,
      block_number: vote.block_number,
      seq: vote.record_seq
    }
  end

  defp common(proposal, status) do
    %{
      number: proposal.number,
      kind: proposal.kind,
      status: status,
      proposer: proposal.proposer,
      opened_block: proposal.opened_block,
      keys_sold: proposal.keys_sold,
      yes_votes: proposal.yes_keys,
      no_votes: proposal.no_keys,
      digest: proposal.digest,
      text_bytes: proposal.text_bytes,
      pay: pay(proposal),
      edits: edits(proposal),
      executed: executed(proposal.execution),
      transaction_hash: proposal.transaction_hash,
      block_number: proposal.block_number
    }
  end

  defp pay(%{kind: :pay} = proposal) do
    %{
      asset: proposal.asset,
      amount: decimal(proposal.amount),
      recipient: proposal.recipient
    }
  end

  defp pay(_proposal), do: nil

  defp edits(%{kind: :restrict_edits} = proposal),
    do: %{token_id: proposal.target_token_id, restricted: proposal.restricted}

  defp edits(_proposal), do: nil

  defp executed(nil), do: nil

  defp executed(execution) do
    %{
      executor: execution.executor,
      transaction_hash: execution.transaction_hash,
      block_number: execution.block_number
    }
  end

  defp as_text(bytes), do: String.replace_invalid(bytes)
  defp decimal(value), do: Decimal.to_string(value, :normal)
end
