defmodule Keyfleet.Points.Award do
  @moduledoc """
  Offers Regent Points what may earn, inside the transaction that made it, so
  something that rolls back offers nothing. The offer is saved with the
  action: it can fail only when the site's own database is failing, and then
  the action fails too. Points decides whether it earns; while a rule is off
  nothing is queued.

    * A new Regent account (`account.activated`), from
      `Keyfleet.Accounts.Signals`. The account is one Regents account on
      every site, so every site names it "regents" and it earns once.
    * A social account linked to an account (`social.x`, `social.github`,
      `social.farcaster`), from `Keyfleet.Accounts.Signals`, keyed by the
      provider and its subject so one social account earns once.
    * An agent paired with its person (`agent.activated`), from
      `RegentAgents.Signals`, keyed by the pairing.
    * A wallet coming to hold a Key (`keyfleet.first_membership`), and a Key
      sold, its epoch 1 (`keyfleet.key_bought`), from `Keyfleet.Keys.Signals`,
      keyed by the Key's ownership epoch: each epoch is recorded once.
    * The first shard a Key's holder lends in an ownership period of the Key
      (`keyfleet.first_authorized_agent`), from `Keyfleet.Keys.Signals`, keyed
      by the shard's record. It earns when it went to the holder's own agent.
    * The first post written as a Key in an ownership period of the Key, by
      its holder or the holder's own agent (`keyfleet.first_message`), from
      `Keyfleet.Rooms.Signals`, keyed by the post.
    * The first vote of a Key in an ownership period of the Key, by its holder
      or the holder's own agent (`keyfleet.first_vote`), from
      `Keyfleet.Polls.Signals`, keyed by the vote.
    * The first push to a fleet's code as a Key in an ownership period of the
      Key, by its holder or the holder's own agent
      (`keyfleet.integration.git`), from `Keyfleet.Code.Signals`, keyed by the
      push.

  Each of Keyfleet's own earns for the account that held the Key when it was
  done, and each Key earns each one-time rule once
  (`Keyfleet.Points.Holder`). So a one-time rule is offered only while it is
  earning (`earning?/1`), and once per ownership period of the Key
  (`offer_first/4`): a repeat in the same period offers nothing. Who counts as
  the holder here is read from the person's wallets today
  (`Keyfleet.Keys.person_wallets/1`); Points still decides from the wallets
  they had when they acted. A member's workspace write
  (`keyfleet.integration.activegraph`) is made on the graph machine, which
  never offers anything; the site offers it as it answers the write
  (`Keyfleet.Points.GraphEvent.offer/3`), through `mark_and_offer/4` as these
  do.
  """

  use Ash.Resource,
    domain: Keyfleet.Points,
    authorizers: [Ash.Policy.Authorizer]

  alias Keyfleet.Actors.System

  signals_in do
    from Keyfleet.Accounts.Signals do
      on :account_registered, :account_registered
      on :social_linked, :social_linked
    end

    from RegentAgents.Signals do
      on :agent_paired, :agent_paired
    end

    from Keyfleet.Keys.Signals do
      on :key_epoch_recorded, :key_epoch_recorded
      on :shard_issued, :shard_issued
    end

    from Keyfleet.Rooms.Signals do
      on :message_posted, :message_posted
    end

    from Keyfleet.Polls.Signals do
      on :vote_cast, :vote_cast
    end

    from Keyfleet.Code.Signals do
      on :push_recorded, :push_recorded
    end
  end

  actions do
    action :account_registered do
      argument :signal, Keyfleet.Accounts.Signals.AccountRegistered, allow_nil?: false

      run fn %{arguments: %{signal: signal}}, _context ->
        record(%{
          rule_id: "account.activated",
          source_app: "regents",
          source_kind: "account",
          source_event_key: to_string(signal.account_id)
        })
      end
    end

    action :social_linked do
      argument :signal, Keyfleet.Accounts.Signals.SocialLinked, allow_nil?: false

      run fn %{arguments: %{signal: signal}}, _context ->
        record(%{
          rule_id: "social.#{signal.provider}",
          source_app: "keyfleet",
          source_kind: "linked_identity",
          source_event_key: "#{signal.provider}:#{signal.subject}"
        })
      end
    end

    action :agent_paired do
      argument :signal, RegentAgents.Signals.AgentPaired, allow_nil?: false

      run fn %{arguments: %{signal: signal}}, _context ->
        record(%{
          rule_id: "agent.activated",
          source_app: "keyfleet",
          source_kind: "pairing",
          source_event_key: signal.paired_agent_id
        })
      end
    end

    action :key_epoch_recorded do
      argument :signal, Keyfleet.Keys.Signals.KeyEpochRecorded, allow_nil?: false
      run fn %{arguments: %{signal: signal}}, _context -> key_epoch(signal) end
    end

    action :shard_issued do
      argument :signal, Keyfleet.Keys.Signals.ShardIssued, allow_nil?: false

      run fn %{arguments: %{signal: signal}}, _context ->
        offer_first("keyfleet.first_authorized_agent", "shard_issue", signal.shard_event_id,
          fleet_id: signal.fleet_id,
          token_id: signal.token_id,
          ownership_epoch: signal.ownership_epoch
        )
      end
    end

    action :message_posted do
      argument :signal, Keyfleet.Rooms.Signals.MessagePosted, allow_nil?: false

      run fn %{arguments: %{signal: signal}}, _context ->
        offer_first("keyfleet.first_message", "room_post", signal.message_id, held(signal))
      end
    end

    action :vote_cast do
      argument :signal, Keyfleet.Polls.Signals.VoteCast, allow_nil?: false

      run fn %{arguments: %{signal: signal}}, _context ->
        offer_first("keyfleet.first_vote", "poll_vote", signal.vote_id, held(signal))
      end
    end

    action :push_recorded do
      argument :signal, Keyfleet.Code.Signals.PushRecorded, allow_nil?: false

      run fn %{arguments: %{signal: signal}}, _context ->
        offer_first("keyfleet.integration.git", "code_push", signal.push_id, held(signal))
      end
    end
  end

  policies do
    # Each is the listener of its own signal: a direct call, and a call carrying
    # another signal, is refused. Each records as the system, never as the actor.
    policy action(:account_registered) do
      authorize_if signal_in(Keyfleet.Accounts.Signals, :account_registered)
    end

    policy action(:social_linked) do
      authorize_if signal_in(Keyfleet.Accounts.Signals, :social_linked)
    end

    policy action(:agent_paired) do
      authorize_if signal_in(RegentAgents.Signals, :agent_paired)
    end

    policy action(:key_epoch_recorded) do
      authorize_if signal_in(Keyfleet.Keys.Signals, :key_epoch_recorded)
    end

    policy action(:shard_issued) do
      authorize_if signal_in(Keyfleet.Keys.Signals, :shard_issued)
    end

    policy action(:message_posted) do
      authorize_if signal_in(Keyfleet.Rooms.Signals, :message_posted)
    end

    policy action(:vote_cast) do
      authorize_if signal_in(Keyfleet.Polls.Signals, :vote_cast)
    end

    policy action(:push_recorded) do
      authorize_if signal_in(Keyfleet.Code.Signals, :push_recorded)
    end
  end

  # Every epoch is a wallet coming to hold the Key; epoch 1 is also its sale.
  defp key_epoch(signal) do
    key = "#{signal.fleet_id}:#{signal.token_id}:#{signal.ownership_epoch}"

    with :ok <- offer("keyfleet.first_membership", "key_epoch", key) do
      if signal.ownership_epoch == 1,
        do: offer("keyfleet.key_bought", "key_epoch", key),
        else: :ok
    end
  end

  # The Key's current ownership period, held by the person who acted.
  defp held(signal),
    do: [fleet_id: signal.fleet_id, token_id: signal.token_id, owner_wallets: signal.wallets]

  @doc """
  Whether Regent Points' rule `rule_id` earns right now, from Points' settings
  alone (`RegentPoints.Rules.snapshot/2`): nothing is read from the database.
  """
  def earning?(rule_id),
    do: match?({:ok, _rule}, RegentPoints.Rules.snapshot(rule_id, DateTime.utc_now()))

  @doc """
  Offers Keyfleet's own `kind` record `key` under the one-time rule `rule_id`
  when it is the first in the Key's ownership period `period`, inside the
  caller's transaction, while the rule is earning (`mark_and_offer/4`). While
  it is not earning nothing is read or written.
  """
  def offer_first(rule_id, kind, key, period) do
    if earning?(rule_id), do: mark_and_offer(rule_id, kind, key, period), else: :ok
  end

  @doc """
  Marks the one-time rule `rule_id` offered in the Key's ownership period
  `period` (`Keyfleet.Keys.mark_points_offered/2`) and offers `kind` record
  `key` only when this marked it, inside the caller's transaction, so a
  rollback takes back the mark with the offer. For a caller that has found the
  rule earning (`earning?/1`).
  """
  def mark_and_offer(rule_id, kind, key, period) do
    case Keyfleet.Keys.mark_points_offered(period, rule_id) do
      {:ok, true} -> offer(rule_id, kind, key)
      {:ok, false} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp offer(rule_id, kind, key) do
    record(%{rule_id: rule_id, source_app: "keyfleet", source_kind: kind, source_event_key: key})
  end

  defp record(reference) do
    with {:ok, _event} <- RegentPoints.record_event(reference, actor: %System{}), do: :ok
  end
end
