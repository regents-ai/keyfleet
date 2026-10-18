defmodule Keyfleet.ProposalPagingPropertyTest do
  @moduledoc """
  What lets an agent read a fleet's proposals and a proposal's votes whole:
  following `next_before` from the newest page, and `votes_after` from the
  first vote, visits every one exactly once, in order, and the last page is
  the only one that says nothing more follows. It holds whatever numbers the
  proposals have and however many votes there are.
  """
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Keyfleet.ChainHelpers
  alias Keyfleet.Fleets
  alias Keyfleet.ProposalHelpers
  alias Keyfleet.Proposals
  alias Keyfleet.Repo

  @fleet "fibonacci_syndicate"
  # The proposals one list page holds (`Keyfleet.Proposals`).
  @page 20

  setup do
    pid =
      Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true, isolation: "REPEATABLE READ")

    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    Fleets.bootstrap_catalog!()
    ChainHelpers.seed_cursor!(@fleet)
    :ok
  end

  property "PP-LIST: following next_before lists every proposal once, newest first" do
    # Sized so a run can reach a third page and land on a page's edge.
    most = 3 * @page + 2
    proposal_numbers = resize(uniq_list_of(integer(1..90), max_length: most), most)

    check all numbers <- proposal_numbers, max_runs: 30 do
      each_run(fn ->
        for number <- numbers, do: ProposalHelpers.proposal!(@fleet, number)

        pages = list(nil, [])
        listed = pages |> Enum.flat_map(&elem(&1, 0)) |> Enum.map(& &1.number)

        assert listed == Enum.sort(numbers, :desc)

        for {proposals, older?} <- Enum.drop(pages, -1),
            do: assert({length(proposals), older?} == {@page, true})

        assert {_last, false} = List.last(pages)
      end)
    end
  end

  property "PP-VOTES: following votes_after reads every vote once, in the order it was recorded" do
    check all ballots <- resize(list_of(ballot(), max_length: 45), 45),
              limit <- integer(1..25),
              max_runs: 30 do
      each_run(fn ->
        ProposalHelpers.proposal!(@fleet, 1)

        # Each Key votes once, so every vote stays a record of its own.
        recorded =
          for {{voter, choice}, token_id} <- Enum.with_index(ballots, 1) do
            ProposalHelpers.vote!(@fleet, 1, ProposalHelpers.wallet(voter), choice, [token_id])
          end

        [proposal] = Proposals.list_page(@fleet) |> elem(0)
        pages = votes(proposal.id, 0, limit, [])
        read = pages |> Enum.flat_map(&elem(&1, 0)) |> Enum.map(& &1.id)

        assert read == Enum.map(recorded, & &1.id)

        for {votes, more?} <- Enum.drop(pages, -1),
            do: assert({length(votes), more?} == {limit, true})

        assert {_last, false} = List.last(pages)
      end)
    end
  end

  defp ballot, do: tuple({member_of(~w(a b c d e)), member_of([:yes, :no])})

  # Each run starts from a fleet with no proposals and leaves none behind.
  defp each_run(run) do
    Repo.transaction(fn ->
      run.()
      Repo.rollback(:run_done)
    end)
  end

  defp list(before, pages) do
    {proposals, older?} = page = Proposals.list_page(@fleet, before)

    if older?,
      do: list(List.last(proposals).number, [page | pages]),
      else: Enum.reverse([page | pages])
  end

  defp votes(proposal_id, after_seq, limit, pages) do
    {votes, more?} = page = Proposals.votes_after(proposal_id, after_seq, limit)

    if more?,
      do: votes(proposal_id, List.last(votes).record_seq, limit, [page | pages]),
      else: Enum.reverse([page | pages])
  end
end
