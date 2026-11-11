----------------------------- MODULE ShardLife -----------------------------
(***************************************************************************)
(* One shard of Key k1 given to agent wallet A, the Key k2 A's person put  *)
(* A on, and one write A sends as a Key, while the shard ends, runs out,   *)
(* or a Key changes hands on the chain, and the site reads the chain       *)
(* behind it.                                                              *)
(*                                                                         *)
(* Code it describes (Keyfleet 9de7fc8c):                                  *)
(*   chain     the fleet's contract: the Key's owner issues or ends a      *)
(*             shard, the shard's wallet may end it, a transfer moves the  *)
(*             Key and starts a new ownership epoch, a move between the    *)
(*             person's own wallets included.                              *)
(*   recorded  what Keyfleet.Chain.Scanner wrote: key_attachments (owner,  *)
(*             ownership_epoch) and Keyfleet.Keys.ShardEvent rows (system  *)
(*             only, never changed or deleted).                            *)
(*   placed    Keyfleet.Keys.AgentKey: the person put A on k2, saved with  *)
(*             k2's ownership epoch as it was then (Placed = TRUE).        *)
(*   Read      Keyfleet.Chain.ReadFleet / Scanner: records chain events in *)
(*             order, sets observed_at and next_block on the cursor.       *)
(*   Fresh     Keyfleet.Chain.Cursor :fresh?: observed within              *)
(*             @fresh_seconds (420) and next_block within @fresh_blocks    *)
(*             (3,000) of the head. Here S and B ticks.                    *)
(*   Check     Keyfleet.Graph.Checks.KeyActor.command/5 -> authority/4:    *)
(*             fresh_reading, then the Keys A acts as, by the one rule     *)
(*             Keys.agent_keys/3. A owns none of the fleet's Keys, so it   *)
(*             acts as the Key its person put it on while that stands      *)
(*             (Keys.placed_on?/3: the same ownership epoch, held by one   *)
(*             of the person's wallets) and every Key it holds an active   *)
(*             shard of (Keys.active_shard/4, ShardEvent :active?: issued, *)
(*             expires_at > now(), ownership_epoch == current, latest      *)
(*             record); only with neither, its person's Keys.              *)
(*             Agents are checked on every request; nothing is cached for  *)
(*             them (CodeGateway.current_holder/3, NotebookGateway.admit). *)
(*   Commit    the write is saved. A database write reads its standing     *)
(*             again inside its own transaction, its pairing locked        *)
(*             (KeyActor.held_command/5); a workspace graph write checks   *)
(*             once before it calls the graph host. Neither locks the      *)
(*             recorded shard or Key, so the reader can record an end      *)
(*             between the check and the save.                             *)
(*                                                                         *)
(* A write is checked and saved within one tick: no tick passes between.   *)
(* One write per run: once it is saved or refused nothing else moves.      *)
(***************************************************************************)
EXTENDS Naturals, Sequences

CONSTANTS S,          \* ticks a reading stays fresh after it was taken
          B,          \* ticks the record may trail the head and stay fresh
          Life,       \* ticks a shard lasts
          MaxTime,    \* last tick in a run
          ReadsAll,   \* TRUE: each reading records everything pending (chart only)
          Writes,     \* FALSE: leave the agent's write out (chart only)
          Placed,     \* TRUE: the person put A on k2 at its first epoch
          Movable,    \* the Keys that may change hands in a run
          MoveTo,     \* the wallets a Key may go to
          Broken      \* "none", or the one check this run removes (run.sh)

Keys == {"k1", "k2"}
Owners == {"O1", "O2", "O3"}
PersonWallets == {"O2", "O3"}   \* A is paired with the person whose wallets are O2 and O3
Never == MaxTime + 1   \* endedAt before the right ends
NoShard == [status |-> "none", key |-> "none", epoch |-> 0, expires |-> 0]
PlacedEpoch == 1       \* k2's epoch when the person put A on it

VARIABLES
  now,          \* the clock, in ticks
  chainOwner,   \* Key -> owner on the chain
  chainEpoch,   \* Key -> ownership epoch on the chain
  chainShard,   \* A's shard on the chain
  endedAt,      \* tick the shard's right ended on the chain (end or move), or Never
  pending,      \* chain events not yet recorded, oldest first, with their tick
  recOwner,     \* recorded owner
  recEpoch,     \* recorded epoch
  recShard,     \* recorded latest shard row for (k1, A)
  observedAt,   \* tick of the last reading
  behindAt,     \* ticks the record trailed the head at that reading
  moves,        \* Key moves so far
  write         \* A's one write

vars == <<now, chainOwner, chainEpoch, chainShard, endedAt, pending, recOwner,
          recEpoch, recShard, observedAt, behindAt, moves, write>>

NoWrite == [phase |-> "not_sent", asKey |-> "none", via |-> "none",
            anyShardAtCheck |-> FALSE, placedAtCheck |-> FALSE, shardExpires |-> 0,
            epochCurrent |-> FALSE, placedEpochCurrent |-> FALSE,
            atCommitActive |-> FALSE, endedAge |-> 0, chainActiveAtCommit |-> FALSE]

Live == write.phase \in {"not_sent", "checked"}

Init ==
  /\ now = 0
  /\ chainOwner = [k \in Keys |-> IF k = "k1" THEN "O1" ELSE "O2"]
  /\ chainEpoch = [k \in Keys |-> 1]
  /\ chainShard = NoShard
  /\ endedAt = Never
  /\ pending = <<>>
  /\ recOwner = chainOwner
  /\ recEpoch = chainEpoch
  /\ recShard = NoShard
  /\ observedAt = 0
  /\ behindAt = 0
  /\ moves = 0
  /\ write = NoWrite

(* --- the chain ---------------------------------------------------------- *)

OwnerIssuesShard ==
  /\ Live
  /\ chainShard.status = "none"
  /\ chainShard' = [status |-> "issued", key |-> "k1", epoch |-> chainEpoch["k1"],
                    expires |-> now + Life]
  /\ pending' = Append(pending, [kind |-> "shard", shard |-> chainShard', at |-> now])
  /\ UNCHANGED <<now, chainOwner, chainEpoch, endedAt, recOwner, recEpoch, recShard,
                 observedAt, behindAt, moves, write>>

(* The Key's owner or the shard's wallet ends the shard. *)
ShardEnds ==
  /\ Live
  /\ chainShard.status = "issued"
  /\ chainShard' = [chainShard EXCEPT !.status = "ended"]
  /\ endedAt' = IF endedAt = Never THEN now ELSE endedAt
  /\ pending' = Append(pending, [kind |-> "shard", shard |-> chainShard', at |-> now])
  /\ UNCHANGED <<now, chainOwner, chainEpoch, recOwner, recEpoch, recShard,
                 observedAt, behindAt, moves, write>>

(* Key k goes to wallet w, a move between the person's wallets included. *)
KeyMoves(k, w) ==
  /\ Live
  /\ moves = 0
  /\ w /= chainOwner[k]
  /\ chainOwner' = [chainOwner EXCEPT ![k] = w]
  /\ chainEpoch' = [chainEpoch EXCEPT ![k] = @ + 1]
  /\ endedAt' = IF k = "k1" /\ endedAt = Never /\ chainShard.status = "issued"
                  THEN now ELSE endedAt
  /\ pending' = Append(pending, [kind |-> "move", key |-> k, owner |-> w,
                                 epoch |-> chainEpoch'[k], at |-> now])
  /\ moves' = moves + 1
  /\ UNCHANGED <<now, chainShard, recOwner, recEpoch, recShard, observedAt, behindAt, write>>

(* --- time and the reader ------------------------------------------------ *)

Tick ==
  /\ Live
  /\ write.phase /= "checked"     \* a write's check and save share one tick
  /\ now < MaxTime
  /\ now' = now + 1
  /\ UNCHANGED <<chainOwner, chainEpoch, chainShard, endedAt, pending, recOwner,
                 recEpoch, recShard, observedAt, behindAt, moves, write>>

Apply(e, o, ep, sh) ==
  IF e.kind = "shard" THEN <<o, ep, e.shard>>
  ELSE <<[o EXCEPT ![e.key] = e.owner], [ep EXCEPT ![e.key] = e.epoch], sh>>

RECURSIVE ApplyAll(_, _, _, _)
ApplyAll(es, o, ep, sh) ==
  IF es = <<>> THEN <<o, ep, sh>>
  ELSE LET r == Apply(Head(es), o, ep, sh) IN ApplyAll(Tail(es), r[1], r[2], r[3])

(* A reading records the oldest n pending events (n may be 0: a slow read). *)
ReaderReads(n) ==
  /\ Live
  /\ n <= Len(pending)
  /\ (ReadsAll => n = Len(pending))
  /\ LET done == SubSeq(pending, 1, n)
         rest == SubSeq(pending, n + 1, Len(pending))
         r == ApplyAll(done, recOwner, recEpoch, recShard)
     IN /\ recOwner' = r[1]
        /\ recEpoch' = r[2]
        /\ recShard' = r[3]
        /\ pending' = rest
        /\ behindAt' = IF rest = <<>> THEN 0 ELSE now - Head(rest).at
  /\ observedAt' = now
  /\ UNCHANGED <<now, chainOwner, chainEpoch, chainShard, endedAt, moves, write>>

(* --- the site's check --------------------------------------------------- *)

(* What the site's record says about A's shard of k now. The rules use this;
   the check below is the code's, and run.sh removes one part of it at a time. *)
RecordedActive(k) ==
  /\ recShard.status = "issued"
  /\ recShard.key = k
  /\ recShard.expires > now
  /\ recShard.epoch = recEpoch[recShard.key]

(* What the site's record says about A's place on k2 now: the same
   ownership epoch, held by one of the person's wallets. *)
RecordedPlaced ==
  /\ Placed
  /\ recOwner["k2"] \in PersonWallets
  /\ recEpoch["k2"] = PlacedEpoch

Fresh ==
  \/ Broken = "no_fresh_check"
  \/ (now - observedAt <= S /\ behindAt < B)

ShardActive(k) ==
  /\ recShard.status = "issued"
  /\ (recShard.key = k \/ Broken = "shard_any_key")
  /\ (recShard.expires > now \/ Broken = "no_expiry_check")
  /\ (recShard.epoch = recEpoch[recShard.key] \/ Broken = "no_epoch_check")

AnyShardActive == \E k \in Keys : ShardActive(k)

(* Keys.placed_on?/3. *)
PlacedOn(k) ==
  /\ Placed
  /\ k = "k2"
  /\ recOwner["k2"] \in PersonWallets
  /\ (recEpoch["k2"] = PlacedEpoch \/ Broken = "placement_ignores_moves")

AnyPlaced == PlacedOn("k2")

Via(k) ==
  IF ShardActive(k) THEN "shard"
  ELSE IF PlacedOn(k) THEN "placed"
  ELSE IF /\ recOwner[k] \in PersonWallets
          /\ (~AnyShardActive \/ Broken = "paired_with_shard")
          /\ (~AnyPlaced \/ Broken = "paired_while_placed")
    THEN "paired"
  ELSE "none"

AgentWritesAs(k) ==
  /\ Writes
  /\ write.phase = "not_sent"
  /\ write' = IF Fresh /\ Via(k) /= "none"
                THEN [NoWrite EXCEPT !.phase = "checked", !.asKey = k, !.via = Via(k),
                        !.anyShardAtCheck = \E j \in Keys : RecordedActive(j),
                        !.placedAtCheck = RecordedPlaced,
                        !.shardExpires = recShard.expires,
                        !.epochCurrent = (recShard.key \in Keys /\ recShard.epoch = recEpoch[recShard.key]),
                        !.placedEpochCurrent = (recEpoch["k2"] = PlacedEpoch)]
                ELSE [NoWrite EXCEPT !.phase = "refused", !.asKey = k]
  /\ UNCHANGED <<now, chainOwner, chainEpoch, chainShard, endedAt, pending, recOwner,
                 recEpoch, recShard, observedAt, behindAt, moves>>

ChainActive ==
  /\ chainShard.status = "issued"
  /\ chainShard.expires > now
  /\ chainShard.epoch = chainEpoch["k1"]

Commit ==
  /\ write.phase = "checked"
  /\ write' = [write EXCEPT !.phase = "saved",
                 !.atCommitActive = RecordedActive(write.asKey),
                 !.chainActiveAtCommit = ChainActive,
                 !.endedAge = IF endedAt = Never THEN 0 ELSE now - endedAt]
  /\ UNCHANGED <<now, chainOwner, chainEpoch, chainShard, endedAt, pending, recOwner,
                 recEpoch, recShard, observedAt, behindAt, moves>>

Done ==
  /\ write.phase \in {"saved", "refused"}
  /\ UNCHANGED vars

Next ==
  \/ OwnerIssuesShard
  \/ ShardEnds
  \/ \E k \in Movable, w \in MoveTo : KeyMoves(k, w)
  \/ Tick
  \/ \E n \in 0..3 : ReaderReads(n)
  \/ \E k \in Keys : AgentWritesAs(k)
  \/ Commit
  \/ Done

Spec == Init /\ [][Next]_vars

(***************************************************************************)
(* Rules                                                                   *)
(***************************************************************************)

TypeOK ==
  /\ now \in 0..MaxTime
  /\ \A k \in Keys : chainOwner[k] \in Owners
  /\ write.phase \in {"not_sent", "checked", "saved", "refused"}
  /\ Len(pending) <= 3

ShardWrite == write.phase \in {"checked", "saved"} /\ write.via = "shard"
PlacedWrite == write.phase \in {"checked", "saved"} /\ write.via = "placed"

(* A shard lets A act only as the Key it is a shard of. *)
ShardOnlyForItsKey == ShardWrite => write.asKey = "k1"

(* A shard that has run out by the clock gives nothing, at once: its end
   time is the one recorded with it, and the check compares it with now. *)
NothingAfterExpiry == ShardWrite => write.shardExpires > now

(* Once the site has recorded that the Key moved, its shards give nothing:
   the shard was issued in an earlier ownership epoch. *)
NothingAfterRecordedMove == ShardWrite => write.epochCurrent

(* A Key that changes hands loses its agent: once the site has recorded the
   move, even to another of the person's wallets, A no longer acts as it. *)
PlacementEndsWithRecordedMove == PlacedWrite => write.placedEpochCurrent

(* Open, the shard side of finding F1. Once the site has recorded the end,
   the move or the expiry, the shard gives nothing more, also to a write
   already checked and not yet saved (breaks: nothing holds the record
   between the check and the save). *)
NothingAfterRecordedEnd == (write.phase = "saved" /\ write.via = "shard") => write.atCommitActive

(* After the shard ends on the chain or its Key moves, a write through it is
   still saved only while the site's reading is fresh: within S + B ticks. *)
EndsWithinFreshWindow ==
  (write.phase = "saved" /\ write.via = "shard" /\ ~write.chainActiveAtCommit)
    => write.endedAge < S + B

(* Not a promise the code makes: the gap between the chain and the site's
   reading, which EndsWithinFreshWindow bounds. run.sh expects it to break. *)
NothingAfterChainEnd ==
  (write.phase = "saved" /\ write.via = "shard") => write.chainActiveAtCommit

(* An agent holding an active shard in the fleet, or on a Key its person
   put it on, acts as those Keys, never as its person's other Keys. *)
PairedOnlyWithoutShardOrPlace ==
  (write.phase \in {"checked", "saved"} /\ write.via = "paired")
    => ~write.anyShardAtCheck /\ ~write.placedAtCheck
=============================================================================
