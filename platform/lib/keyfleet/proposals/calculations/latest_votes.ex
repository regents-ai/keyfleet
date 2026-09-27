defmodule Keyfleet.Proposals.Calculations.LatestVotes do
  @moduledoc """
  How many of a proposal's keys last voted `support`: a key may vote again,
  and only its latest vote, in chain order, counts.
  """

  use Ash.Resource.Calculation

  import Ash.Expr

  @impl true
  def init(opts), do: {:ok, Keyword.take(opts, [:support])}

  @impl true
  def expression(opts, _context) do
    support = Keyword.fetch!(opts, :support)

    expr(
      fragment(
        """
        (SELECT count(*) FROM (
          SELECT DISTINCT ON (key.token_id) vote.support
          FROM keyfleet_app.proposal_votes AS vote
          CROSS JOIN LATERAL unnest(vote.token_ids) AS key(token_id)
          WHERE vote.proposal_id = ?
          ORDER BY key.token_id, vote.block_number DESC, vote.log_index DESC
        ) AS latest WHERE latest.support = ?)
        """,
        id,
        ^support
      )
    )
  end
end
