defmodule Keyfleet.Proposals.Calculations.LateKeys do
  @moduledoc """
  How many of the keys that voted on a proposal were not present when it
  opened, as the contract counts them (`KeyfleetVotes.wasActiveAtOpening`):
  a key was present when its last presence record before the proposal, in
  chain order, is a renewal less than 48 hours before the proposal opened. A
  key whose last record is its change of hands, or that has none, was not.
  The contract adds each such key, once, to the keys a proposal needs more
  than half of.
  """

  use Ash.Resource.Calculation

  import Ash.Expr

  # `KeyfleetPresence.WINDOW`.
  @window_seconds 172_800

  @impl true
  def expression(_opts, _context) do
    expr(
      fragment(
        """
        (SELECT count(*) FROM (
          SELECT DISTINCT key.token_id
          FROM keyfleet_app.proposal_votes AS vote
          CROSS JOIN LATERAL unnest(vote.token_ids) AS key(token_id)
          WHERE vote.proposal_id = ?
        ) AS voted
        WHERE NOT EXISTS (
          SELECT 1 FROM (
            SELECT presence.kind, presence.at
            FROM keyfleet_app.key_presences AS presence
            WHERE presence.fleet_id = ? AND presence.token_id = voted.token_id
              AND (presence.block_number, presence.log_index) < (?, ?)
            ORDER BY presence.block_number DESC, presence.log_index DESC
            LIMIT 1
          ) AS last
          WHERE last.kind = 'present' AND ? < last.at + make_interval(secs => ?)
        ))
        """,
        id,
        fleet_id,
        block_number,
        log_index,
        opened_at,
        ^@window_seconds
      )
    )
  end
end
