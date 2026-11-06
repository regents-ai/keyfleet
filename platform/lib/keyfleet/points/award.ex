defmodule Keyfleet.Points.Award do
  @moduledoc """
  Offers Regent Points what may earn, inside the transaction that made it, so
  something that rolls back offers nothing. Points decides whether it earns;
  while a rule is off nothing is queued. Each record is offered once, when it
  is first saved (`Keyfleet.Points.Changes.Announce`).

    * A Key's ownership epoch: a person's first Key (`keyfleet.first_membership`),
      and, for a Key's first epoch, its sale (`keyfleet.key_bought`).
    * A Key revealed (`keyfleet.first_reveal`).
    * A shard of a Key issued to a wallet (`keyfleet.first_authorized_agent`);
      its check counts only an agent of the Key's person.
    * A poll vote (`keyfleet.first_vote`).
    * A post written as a Key, or a direct message (`keyfleet.first_message`).
    * A push to a fleet's code (`keyfleet.integration.twigpine`).
    * A change to a fleet's workspace made as a Key
      (`keyfleet.integration.activegraph`).
    * A Credits purchase credited to an account, or a waiting one an account
      now holds (`credits.purchase_settled`), from `RegentCredits.Signals`.
      Credits is one Regents ledger, so every site names it "regents" and a
      purchase earns once.
    * A new Regent account (`account.activated`), from
      `Keyfleet.Accounts.Signals`. The account is one Regents account on
      every site, so it is named "regents" too.
    * A social account linked to an account (`social.x`, `social.github`,
      `social.farcaster`), from `Keyfleet.Accounts.Signals`, keyed by the
      provider and its subject so one social account earns once.
    * An agent paired with its person (`agent.activated`), from
      `RegentAgents.Signals`, keyed by the pairing.
  """

  use Ash.Resource,
    domain: Keyfleet.Points,
    authorizers: [Ash.Policy.Authorizer]

  alias Keyfleet.Actors.System
  alias Keyfleet.Keys.Signals.{KeyHeld, KeyRevealed, ShardRecorded}

  signals_in do
    from Keyfleet.Accounts.Signals do
      on :account_registered, :account_registered
      on :social_linked, :social_linked
    end

    from RegentAgents.Signals do
      on :agent_paired, :agent_paired
    end

    from Keyfleet.Keys.Signals do
      on :key_held, :key_held
      on :key_revealed, :key_revealed
      on :shard_recorded, :shard_recorded
    end

    from Keyfleet.Polls.Signals do
      on :vote_cast, :vote_cast
    end

    from Keyfleet.Rooms.Signals do
      on :post_written, :post_written
    end

    from Keyfleet.Dms.Signals do
      on :message_sent, :message_sent
    end

    from Keyfleet.Code.Signals do
      on :ref_pushed, :ref_pushed
    end

    from Keyfleet.Graph.Signals do
      on :event_copied, :event_copied
    end

    from RegentCredits.Signals do
      on :purchase_credited, :purchase_credited, action: :credits_purchase
      on :purchase_attributed, :purchase_attributed, action: :credits_purchase
    end
  end

  actions do
    action :account_registered do
      argument :signal, Keyfleet.Accounts.Signals.AccountRegistered, allow_nil?: false

      run fn %{arguments: %{signal: signal}}, _context ->
        record("account.activated", "account", to_string(signal.account_id), "regents")
      end
    end

    action :social_linked do
      argument :signal, Keyfleet.Accounts.Signals.SocialLinked, allow_nil?: false

      run fn %{arguments: %{signal: signal}}, _context ->
        record(
          "social.#{signal.provider}",
          "linked_identity",
          "#{signal.provider}:#{signal.subject}"
        )
      end
    end

    action :agent_paired do
      argument :signal, RegentAgents.Signals.AgentPaired, allow_nil?: false

      run fn %{arguments: %{signal: signal}}, _context ->
        record("agent.activated", "pairing", signal.paired_agent_id)
      end
    end

    action :key_held do
      argument :signal, KeyHeld, allow_nil?: false

      run fn %{arguments: %{signal: signal}}, _context ->
        rules =
          if signal.ownership_epoch == 1,
            do: ["keyfleet.first_membership", "keyfleet.key_bought"],
            else: ["keyfleet.first_membership"]

        Enum.reduce_while(rules, :ok, fn rule, :ok ->
          case record(rule, "key_epoch", signal.key_epoch_id) do
            :ok -> {:cont, :ok}
            error -> {:halt, error}
          end
        end)
      end
    end

    action :key_revealed do
      argument :signal, KeyRevealed, allow_nil?: false

      run fn %{arguments: %{signal: signal}}, _context ->
        record("keyfleet.first_reveal", "key_reveal", signal.key_reveal_id)
      end
    end

    action :shard_recorded do
      argument :signal, ShardRecorded, allow_nil?: false

      run fn
        %{arguments: %{signal: %{kind: :issued} = signal}}, _context ->
          record("keyfleet.first_authorized_agent", "shard_issue", signal.shard_event_id)

        _shard_ended, _context ->
          :ok
      end
    end

    action :vote_cast do
      argument :signal, Keyfleet.Polls.Signals.VoteCast, allow_nil?: false

      run fn %{arguments: %{signal: signal}}, _context ->
        record("keyfleet.first_vote", "poll_vote", signal.vote_id)
      end
    end

    action :post_written do
      argument :signal, Keyfleet.Rooms.Signals.PostWritten, allow_nil?: false

      run fn
        %{arguments: %{signal: %{as_key: nil}}}, _context ->
          :ok

        %{arguments: %{signal: signal}}, _context ->
          record("keyfleet.first_message", "room_post", signal.message_id)
      end
    end

    action :message_sent do
      argument :signal, Keyfleet.Dms.Signals.MessageSent, allow_nil?: false

      run fn %{arguments: %{signal: signal}}, _context ->
        record("keyfleet.first_message", "direct_message", signal.message_id)
      end
    end

    action :ref_pushed do
      argument :signal, Keyfleet.Code.Signals.RefPushed, allow_nil?: false

      run fn %{arguments: %{signal: signal}}, _context ->
        record("keyfleet.integration.twigpine", "code_push", signal.push_id)
      end
    end

    action :event_copied do
      argument :signal, Keyfleet.Graph.Signals.EventCopied, allow_nil?: false

      run fn %{arguments: %{signal: signal}}, _context ->
        # Only a change made as a Key earns; the workspace's own doing names no member.
        if Keyfleet.Graph.Event.member(signal.actor),
          do:
            record(
              "keyfleet.integration.activegraph",
              "graph_event",
              "#{signal.fleet_id}:#{signal.seq}"
            ),
          else: :ok
      end
    end

    action :credits_purchase do
      argument :signal, :struct, allow_nil?: false

      run fn %{arguments: %{signal: signal}}, _context ->
        record("credits.purchase_settled", "credits_purchase", signal.purchase_id, "regents")
      end
    end
  end

  policies do
    # Reached only through the signals above, after the action that emitted
    # them was allowed; each records as the system, never as the actor.
    policy always() do
      authorize_if always()
    end
  end

  defp record(rule_id, kind, key, app \\ "keyfleet") do
    reference = %{rule_id: rule_id, source_app: app, source_kind: kind, source_event_key: key}
    with {:ok, _event} <- RegentPoints.record_event(reference, actor: %System{}), do: :ok
  end
end
