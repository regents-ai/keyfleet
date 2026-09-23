defmodule KeyFleetWeb.AgentProposalController do
  use KeyFleetWeb, :controller

  alias KeyFleet.Chain
  alias KeyFleet.Fleets
  alias KeyFleet.Proposals
  alias KeyFleetWeb.ProposalJSON

  @votes_page 20

  def read(conn, %{"fleet_id" => fleet_id, "number" => number, "votes_after_seq" => after_seq}) do
    case Fleets.get_fleet!(fleet_id) do
      nil -> not_found(conn, "fleet_unknown")
      _fleet -> read_proposal(conn, fleet_id, number, after_seq)
    end
  end

  defp read_proposal(conn, fleet_id, number, after_seq) do
    case Proposals.get_by_number(fleet_id, number) do
      nil ->
        not_found(conn, "proposal_unknown")

      proposal ->
        status = Proposals.status(proposal, Chain.get_cursor!(fleet_id), DateTime.utc_now())
        {votes, more?} = Proposals.votes_after(proposal.id, after_seq, @votes_page)

        json(conn, %{
          proposal: ProposalJSON.detail(proposal, status),
          votes: Enum.map(votes, &ProposalJSON.vote/1),
          votes_next_cursor:
            votes |> List.last(%{record_seq: after_seq}) |> Map.fetch!(:record_seq),
          votes_has_more: more?
        })
    end
  end

  defp not_found(conn, error), do: conn |> put_status(404) |> json(%{error: error})
end
